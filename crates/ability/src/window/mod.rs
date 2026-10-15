//! OpenHarmony window operations.
//!
//! Window operations go through the typed bridge facade `WindowClient` in the
//! `plugin-window` crate (e.g. `app.window()?.focus_window(id).await`). Window
//! creation uses `create_os_window` / `WindowCreateParams` — a runtime
//! integration-layer API consumed directly by the embedding runtime.

use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use napi_ohos::threadsafe_function::{
    ThreadsafeCallContext, ThreadsafeFunction, ThreadsafeFunctionCallMode,
};
use napi_ohos::Env;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Mutex, OnceLock};

/// Global window ID generator to ensure unique IDs across Rust and ArkTS.
static NEXT_WINDOW_ID: AtomicI64 = AtomicI64::new(1);

/// Parameters for creating a new OS-level window on OpenHarmony.
///
/// `windowId` is not included — it is auto-generated internally by `create_os_window`
/// via `NEXT_WINDOW_ID` to ensure global uniqueness.
pub struct WindowCreateParams {
    /// Window label/name, used as the ArkTS sub-window name.
    pub name: String,
    /// OHOS window type enum value (0=App, 8=Float, etc.)
    pub window_type: i32,
    /// Initial window width in px. Default: 800.
    pub width: i32,
    /// Initial window height in px. Default: 600.
    pub height: i32,
    /// Initial window X position in px. Default: 100.
    pub x: i32,
    /// Initial window Y position in px. Default: 100.
    pub y: i32,
    /// Whether to show window decorations (title bar, drag area, close button).
    /// Phase 2: controls FloatPage conditional rendering via LocalStorage.
    pub decorations: bool,
    /// Whether the window background should be fully transparent.
    /// Phase 3: when true, overrides background_color with 0x00000000.
    pub transparent: bool,
    /// Window background color in 0xAARRGGBB format.
    /// Phase 3: ignored when transparent is true.
    pub background_color: Option<u32>,
}

impl Default for WindowCreateParams {
    fn default() -> Self {
        Self {
            name: String::new(),
            window_type: 0,
            width: 800,
            height: 600,
            x: 100,
            y: 100,
            decorations: true,
            transparent: false,
            background_color: None,
        }
    }
}

/// Generates a unique window ID for use when creating sub-windows
/// outside of `create_os_window` (e.g., from `handleWindowNew` when
/// `window_kind == "window"`). Uses the same `NEXT_WINDOW_ID` counter to
/// ensure no collision with Rust-created windows.
///
/// Currently unused — reserved for future when `OnWindowNewResult` carries
/// a pre-generated window ID for ArkTS-side sub-window creation.
#[allow(dead_code)]
pub fn generate_window_id() -> i64 {
    NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst)
}

/// Creates a new OS-level window on OpenHarmony.
///
/// Uses `WindowCreateParams` to pass all window attributes (geometry, decorations,
/// transparent, background_color) in a single struct, avoiding signature bloat
/// as Phase 2/3 add more parameters.
///
/// Pre-allocates a unique window ID, then fires a TSFN to trigger async sub-window
/// creation on the ArkTS main thread (fire-and-forget). The sub-window is guaranteed
/// to be ready before the webview bridge create arrives, since both operations are
/// serialized on the ArkTS UI thread and createSubWindow is dispatched first.
pub fn create_os_window(params: WindowCreateParams) -> napi_ohos::Result<i64> {
    let id = NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst);
    crate::debug!("create_os_window: Pre-allocated window ID: {}", id);

    let tsfn = match TSFN_CREATE_SUB_WINDOW.get() {
        Some(tsfn) => tsfn,
        None => {
            crate::error!(
                "create_os_window: TSFN not initialized (register_create_sub_window_tsfn not called)"
            );
            return Err(Error::from_reason("create_sub_window TSFN not initialized"));
        }
    };

    // Float creation race fix (doc/OHOS窗口遗留问题.md issue-7 addendum): open the
    // pending entry BEFORE dispatching, so window ops the embedding runtime
    // dispatches between now and the ArkTS creation chain settling (tauri's
    // post-build set_visible/set_focus, or user setters right after build)
    // queue instead of racing the ArkTS-side registration. Registered AFTER
    // the tsfn lookup so the "TSFN not initialized" early return leaks
    // nothing, and gated on the capability handshake: a stale HAR without
    // the notify wiring would leave the entry pending forever — the
    // handshake keeps that configuration on today's fire-and-forget
    // semantics (review V1).
    if FLOAT_PENDING_TRACKING.load(Ordering::Acquire) {
        register_pending_float(id);
    }

    let status = tsfn.call(
        (
            params.name,
            id,
            params.width,
            params.height,
            params.x,
            params.y,
            params.decorations,
            params.transparent,
            params.background_color,
        ),
        ThreadsafeFunctionCallMode::NonBlocking,
    );

    if status != Status::Ok {
        // The dispatch failed — no ArkTS creation chain will ever settle this
        // id, so the pending entry (if opened) must go.
        unregister_pending_float(id);
        crate::error!("create_os_window: TSFN dispatch failed: {:?}", status);
        return Err(Error::from_reason(format!(
            "TSFN call failed: {:?}",
            status
        )));
    }

    crate::debug!(
        "create_os_window: Dispatched ArkTS createSubWindow for ID: {}",
        id
    );
    Ok(id)
}

// ─── TSFN for cross-thread vibrancy calls (threadsafe, no main-thread Env needed) ───
// Fire-and-forget (NonBlocking, no return value wait): applyWindowBlur queues pendingBlurs
// (build-time inject via registerController) or calls setAllWebviewsBlurRadius (runtime
// modifier refresh), both idempotent, so no synchronous result needed.

// ─── TSFN for cross-thread sub-window creation (fire-and-forget) ───
// ArkTS registers WindowManager.createSubWindow wrapper via register_create_sub_window_tsfn
// during ProcessInitializer.initialize(). create_os_window calls this TSFN to trigger
// async sub-window creation on the ArkTS main thread, returning the pre-allocated ID
// immediately without waiting for ArkTS to finish (the sub-window is guaranteed to be
// ready before the webview bridge create arrives, since both are serialized on the
// ArkTS UI thread event loop and createSubWindow is dispatched first).
type CreateSubWindowTsfn = ThreadsafeFunction<
    (String, i64, i32, i32, i32, i32, bool, bool, Option<u32>),
    (),
    FnArgs<(Object<'static>,)>,
    Status,
    false,
>;
static TSFN_CREATE_SUB_WINDOW: OnceLock<CreateSubWindowTsfn> = OnceLock::new();

/// Register the ArkTS `createSubWindow` wrapper as a ThreadsafeFunction.
///
/// Called from `ProcessInitializer.initialize()` after native modules are loaded.
/// The ArkTS wrapper is an arrow function that captures `WindowManager.getInstance()`
/// and calls `createSubWindow(config)`, returning a `Promise<number>`.
///
/// After registration, `create_os_window` can fire-and-forget sub-window creation
/// from any thread (TSFN is threadsafe).
#[napi(ts_args_type = "createFn: (config: ESObject) => Promise<number>")]
pub fn register_create_sub_window_tsfn(
    _env: Env,
    create_fn: Function<'static, Object<'static>, ()>,
) -> Result<()> {
    if TSFN_CREATE_SUB_WINDOW.get().is_some() {
        crate::info!("create_sub_window TSFN already registered");
        return Ok(());
    }
    let tsfn = create_fn
        .build_threadsafe_function::<(String, i64, i32, i32, i32, i32, bool, bool, Option<u32>)>()
        .callee_handled::<false>()
        .build_callback(
            move |ctx: ThreadsafeCallContext<(
                String,
                i64,
                i32,
                i32,
                i32,
                i32,
                bool,
                bool,
                Option<u32>,
            )>| {
                build_create_sub_window_args(ctx.env, ctx.value).map(|args| FnArgs { data: args })
            },
        )?;
    let _ = TSFN_CREATE_SUB_WINDOW.set(tsfn);
    crate::info!("Registered create_sub_window TSFN");
    Ok(())
}

/// TSFN callback helper (runs on ArkTS main thread).
/// Builds a WindowConfig Object from the flattened parameter tuple.
fn build_create_sub_window_args(
    env: Env,
    value: (String, i64, i32, i32, i32, i32, bool, bool, Option<u32>),
) -> Result<(Object<'static>,)> {
    let (name, window_id, width, height, x, y, decorations, transparent, bg_color) = value;
    let mut config = Object::new(&env)?;
    config.set("name", name)?;
    config.set("windowId", window_id)?;
    config.set("width", width)?;
    config.set("height", height)?;
    config.set("x", x)?;
    config.set("y", y)?;
    config.set("decorations", decorations)?;
    config.set("transparent", transparent)?;
    if let Some(color) = bg_color {
        config.set("backgroundColor", color)?;
    }
    Ok((config,))
}

// ─── Group A: fullscreen ──────────────────────────────────────
// Multi-arg (2+) parameters must be wrapped with FnArgs (a bare tuple is
// passed as a single argument; see napi-ohos JsValuesTupleIntoVec blanket
// impl). Single-arg func.call(id) is unaffected.

/// Allocates the next global window ID without creating a window.
///
/// Used by the windowing backend when a subsequent UIAbility is created: the windowing backend
/// pre-allocates an ID, passes it to the new EntryAbility instance via
/// `want.parameters`, then calls `start_ui_ability`. The new instance's
/// `onWindowStageCreate` registers its WindowStage against this ID via
/// `register_ui_ability_stage`.
pub fn next_window_id() -> i64 {
    NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst)
}

/// Global record of the last windowId reported by a subsequent EntryAbility
/// instance via `register_ui_ability_stage`. Used by automated tests
/// (get_last_ui_ability_window_id command) to verify that want.parameters
/// survived the startAbility call to the new instance.
static LAST_UI_ABILITY_WINDOW_ID: AtomicI64 = AtomicI64::new(-1);

// ─── Multi-UIAbility handshake registry (design.md D7, openspec change
// multi-uiability-windows) ───────────────────────────────────────────────────
//
// start_ui_ability pre-allocates a window id and fires the startAbility want
// fire-and-forget; the new EntryAbility instance reports back asynchronously
// from its onWindowStageCreate via `register_ui_ability_stage`. This registry
// tracks that pending handshake so the embedding runtime can poll readiness
// or attach a waker that fires the moment the stage registers. No blocking
// wait exists anywhere in this chain (HC-5: no main-thread block_on/recv).
//
// Only handshakes opened by `register_pending_ui_ability` are tracked — the
// process-launched first instance (id 0) and any untracked spawn never pass
// through, and read as "ready" from `is_ui_ability_stage_ready`.

struct PendingAbility {
    stage_registered: bool,
    /// Event-loop waker attached while waiting; consumed (and woken) when the
    /// stage registers, so queued work for this window dispatches on the next
    /// event-loop pass instead of waiting for an unrelated wake.
    waker: Option<crate::OpenHarmonyWaker>,
}

static PENDING_UI_ABILITIES: Mutex<Option<HashMap<i64, PendingAbility>>> = Mutex::new(None);

/// Capability handshake for the UIAbility pending registry (mirrors
/// `FLOAT_PENDING_TRACKING`): armed by the ArkTS ProcessInitializer via
/// `enable_ui_ability_pending_tracking` before any spawn can run. A stale
/// HAR (fresh .so, cached ArkTS) never sets the flag — the embedding
/// runtime's spawn branch then skips pending registration and keeps the
/// pre-registry fire-and-forget semantics, instead of queueing ops against
/// an entry no ArkTS code would ever settle (`register_ui_ability_stage`
/// ships in the same HAR generation as the arming call).
static UI_ABILITY_PENDING_TRACKING: AtomicBool = AtomicBool::new(false);

fn pending_ui_abilities() -> std::sync::MutexGuard<'static, Option<HashMap<i64, PendingAbility>>> {
    // A poisoned lock means some other thread panicked mid-handshake; the
    // registry contents are still consistent enough to keep serving.
    PENDING_UI_ABILITIES
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Opens the pending-handshake entry for a UIAbility window id allocated via
/// [`next_window_id`]. Called by the embedding runtime when it fires
/// start_ui_ability — only when the capability handshake is armed (see
/// [`ui_ability_pending_tracking_enabled`]); the entry flips to ready when
/// the new instance calls [`register_ui_ability_stage`] with the same id.
pub fn register_pending_ui_ability(id: i64) {
    pending_ui_abilities()
        .get_or_insert_with(HashMap::new)
        .insert(id, PendingAbility { stage_registered: false, waker: None });
    crate::info!(
        "register_pending_ui_ability: id={} (startAbility dispatched, awaiting stage registration)",
        id
    );
}

/// NAPI: capability handshake for the UIAbility pending registry. Called by
/// the ArkTS ProcessInitializer at bridge init — only after this does the
/// embedding runtime (tao's UIAbility spawn branch) open pending entries. A
/// stale HAR never calls it, keeping the pre-registry fire-and-forget
/// semantics (and never wedging ops against entries no ArkTS code would
/// settle).
#[napi]
pub fn enable_ui_ability_pending_tracking() {
    let was = UI_ABILITY_PENDING_TRACKING.swap(true, Ordering::AcqRel);
    if !was {
        crate::info!(
            "enable_ui_ability_pending_tracking: UIAbility spawn pending tracking armed (ProcessInitializer handshake)"
        );
    }
}

/// Whether the ArkTS side has armed the UIAbility pending-tracking
/// handshake. Consumed by the embedding runtime's spawn branch (tao) to
/// choose between pending registration (ops queue until the spawned
/// instance's stage registers) and fire-and-forget dispatch.
pub fn ui_ability_pending_tracking_enabled() -> bool {
    UI_ABILITY_PENDING_TRACKING.load(Ordering::Acquire)
}

/// Attaches an event-loop waker to a pending handshake. If the stage has
/// already registered by the time this is called, the waker fires
/// immediately — the wait is already over.
pub fn set_ui_ability_waker(id: i64, waker: crate::OpenHarmonyWaker) {
    let mut immediate_wake = None;
    {
        let mut map = pending_ui_abilities();
        match map.as_mut().and_then(|m| m.get_mut(&id)) {
            Some(pending) if pending.stage_registered => immediate_wake = Some(waker),
            Some(pending) => pending.waker = Some(waker),
            // Unknown id: never opened as a pending handshake — nothing to
            // wait for, drop the waker.
            None => {}
        }
    }
    // Wake outside the registry lock: the TSFN call is non-blocking, but the
    // lock discipline stays uniform (never call out to ArkTS under a lock).
    if let Some(waker) = immediate_wake {
        waker.wake();
    }
}

/// Whether the EntryAbility instance for `id` has registered its WindowStage.
/// Unknown ids read as `true`: only handshakes opened by
/// `register_pending_ui_ability` are tracked (the process-launched first
/// instance, id 0, never passes through here).
pub fn is_ui_ability_stage_ready(id: i64) -> bool {
    pending_ui_abilities()
        .as_ref()
        .and_then(|m| m.get(&id))
        .map(|p| p.stage_registered)
        .unwrap_or(true)
}

/// NAPI: Called by each EntryAbility instance's `onWindowStageCreate` (via
/// ArkTS `WindowManager.registerUIAbilityStage`) to report the windowId it
/// received from want.parameters. Records the id globally for automated
/// tests, and completes the multi-UIAbility handshake: marks the pending
/// entry ready and wakes the event-loop waker the embedding runtime attached
/// while waiting (see `register_pending_ui_ability`).
#[napi]
pub fn register_ui_ability_stage(window_id: i64) {
    crate::info!(
        "register_ui_ability_stage: id={} (ArkTS-side registration triggered replay)",
        window_id
    );
    LAST_UI_ABILITY_WINDOW_ID.store(window_id, Ordering::SeqCst);
    let waker = {
        let mut map = pending_ui_abilities();
        match map.get_or_insert_with(HashMap::new).get_mut(&window_id) {
            Some(pending) => {
                pending.stage_registered = true;
                pending.waker.take()
            }
            // First instance (id 0) or an untracked spawn — nothing pending.
            None => None,
        }
    };
    if let Some(waker) = waker {
        waker.wake();
    }
}

/// Removes the pending-handshake entry for a destroyed UIAbility instance
/// (design.md D13). Window ids are never reused (`NEXT_WINDOW_ID` is
/// monotonic), so a removed entry can never collide with a future spawn.
/// Returns the registry's remaining size for the E4 ten-round leak check.
/// Any waker still attached to the entry is woken after removal, so tasks
/// queued against this handshake re-poll — with the entry gone, readiness
/// now reads true and their queued ops can drain instead of waiting for an
/// unrelated event-loop wake.
///
/// Known bounded edge: a startAbility that fails after
/// `register_pending_ui_ability` never fires an ability-destroy callback.
/// The tao caller rolls the entry back on failure (unregister +
/// drop_pending_window_ops), and — for a rejection arriving after the bridge
/// response already returned accepted (AMS refuses the deferred startAbility)
/// — the ArkTS catch rolls it back through `notify_ui_ability_start_failed`
/// below. `is_window_ready` — the combined gate
/// behind tao's dispatch_or_queue/spawn_or_queue — is a direct consumer of
/// this registry: a stale entry would silently hold that window's queued
/// ops forever (G15).
pub fn unregister_pending_ui_ability(id: i64) -> usize {
    let (waker, len) = {
        let mut map = pending_ui_abilities();
        match map.as_mut() {
            Some(map) => {
                let waker = map.remove(&id).and_then(|pending| pending.waker);
                (waker, map.len())
            }
            None => (None, 0),
        }
    };
    // Wake outside the registry lock (uniform lock discipline: never call out
    // to ArkTS or wake under a lock).
    if let Some(waker) = waker {
        waker.wake();
    }
    len
}

/// NAPI: Called by the ArkTS `start-ui-ability` handler's deferred catch
/// (AppControlPlugin.ets) when AMS rejects the spawn AFTER the bridge response
/// already returned accepted=true ("dispatched", not "created"). Completes the
/// same rollback the synchronous failure legs perform (G15): drops the pending
/// D7 handshake entry (tao's Err leg) and the label→id pairing (the
/// app-control facade's Err leg). Without it, a rejected spawn leaves an entry
/// no `register_ui_ability_stage` will ever flip — `is_window_ready` stays
/// false and every op queued for that window is held silently forever.
///
/// tao's queued-op drop (`drop_pending_window_ops`) is not reachable from this
/// crate: removing the pending entry makes the id read as ready, so the
/// embedding runtime's next drain pass replays those ops and each fails loudly
/// at the bridge — the blessed degradation for a rolled-back id, never an
/// infinite silent queue. The loop wake mirrors `notify_window_close` so that
/// drain pass runs promptly instead of waiting for an unrelated event.
///
/// Idempotent by construction: an id that never registered (or was already
/// torn down) is a no-op for both registries. A stray id 0 cannot corrupt
/// primary state either — id 0 never has a pending handshake entry, and an
/// unknown label already falls back to the primary id on lookup.
#[napi]
pub fn notify_ui_ability_start_failed(window_id: i64) {
    let pending_len = unregister_pending_ui_ability(window_id);
    crate::unregister_window_label(window_id);
    crate::info!(
        "notify_ui_ability_start_failed: id={} rolled back (pending registry now {} entries)",
        window_id,
        pending_len
    );
    // Wake the embedding runtime's event loop so queued ops drain (and fail
    // loudly) on the next pass instead of sitting until an unrelated event —
    // see the drop_pending_window_ops note above.
    crate::waker::wake_installed_app();
}

// ─── UIAbility spawn rejection trace (mobile-form fail-fast surfacing) ──────
//
// tao's desktop-only spawn gate (window.rs) rejects a mobile-form UIAbility
// spawn by returning Err from Window::new — but on the tauri stack that Err
// never surfaces: runtime-wry's `Message::CreateWindow` dispatch has no reply
// channel (upstream design), it logs the error and returns Ok, so
// WebviewWindowBuilder::build() resolves Ok and the manager registers a
// label-only zombie window. The embedding runtime therefore records the
// rejection here under the window label BEFORE returning Err, and the
// embedding app (tauri examples cmd.rs) consumes it after build() to surface
// `mobile_fail_fast` at the API layer.
//
// Keyed by label, not window id: the gate runs before `next_window_id()`
// opens any state (fail-fast, zero residue), so no id exists yet — the label
// (which runtime-wry always sets via `with_label`) is the only key both
// sides share.

static UI_ABILITY_SPAWN_REJECTIONS: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

fn ui_ability_spawn_rejections(
) -> std::sync::MutexGuard<'static, Option<HashMap<String, String>>> {
    // Poisoned lock: same policy as the pending registry — keep serving, the
    // trace is diagnostic only.
    UI_ABILITY_SPAWN_REJECTIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Records that the embedding runtime (tao) refused a UIAbility spawn for
/// `label` with `reason` (the desktop-only form-factor gate). Called before
/// the Err is handed to the caller — whatever swallows it afterwards, the
/// trace is already here. Overwrites a stale entry for the same label (test
/// labels are timestamp-unique, so in practice each entry is fresh).
pub fn note_ui_ability_spawn_rejected(label: &str, reason: &str) {
    ui_ability_spawn_rejections()
        .get_or_insert_with(HashMap::new)
        .insert(label.to_string(), reason.to_string());
    crate::info!(
        "note_ui_ability_spawn_rejected: label={} reason={}",
        label,
        reason
    );
}

/// Consumes the rejection trace for `label`. Returns `Some(reason)` when the
/// desktop-only gate rejected this spawn — the caller reports it as a
/// structured mobile fail-fast marker instead of trusting build()'s Ok.
/// Consuming (removing) keeps the registry bounded: a queried rejection is a
/// delivered rejection, and a never-consumed entry can only exist for a
/// window whose builder the app abandoned before asking.
pub fn take_ui_ability_spawn_rejection(label: &str) -> Option<String> {
    let reason = ui_ability_spawn_rejections()
        .as_mut()
        .and_then(|m| m.remove(label));
    if reason.is_some() {
        crate::info!(
            "take_ui_ability_spawn_rejection: label={} consumed",
            label
        );
    }
    reason
}

// ─── Float creation pending registry (Float creation-time race fix,
// doc/OHOS窗口遗留问题.md issue-7 addendum) ─────────────────────────────────────────
//
// create_os_window pre-allocates an id and fires the createSubWindow TSFN
// fire-and-forget; the ArkTS creation chain registers the window in
// WindowManager.windows only after the createSubWindowWithOptions system
// call resolves (tens to hundreds of ms later). Window ops dispatched by the
// embedding runtime inside that window (tauri's post-build
// set_visible/set_focus, or user setters immediately after build) raced the
// registration and failed with "Unknown OS sub-window" — silently, 100% of
// the time (22 warns per examples/api suite run).
//
// Mirrors the UIAbility pending registry above: create_os_window opens a
// pending entry (when the capability handshake is on), the ArkTS
// ProcessInitializer TSFN wrapper reports settlement via
// notify_float_window_registered (success OR failure — both remove the entry
// and wake), and the embedding runtime gates window-op dispatch on
// is_window_ready. Ids that never passed through create_os_window read as
// ready — the same "unknown means ready" contract as
// is_ui_ability_stage_ready, so the main window (id 0), UIAbility ids and
// zombie ids all keep today's fast path.
//
// Capability handshake (review V1): enable_float_pending_tracking is called
// by ProcessInitializer before registering the createSubWindow TSFN. A stale
// HAR (fresh .so, cached ArkTS) never sets the flag, so create_os_window
// never gates — behavior degrades to exactly today's fire-and-forget
// semantics instead of queueing every Float op against an entry no ArkTS
// code would ever settle. Reverse skew (fresh HAR, old .so) is covered on
// the ArkTS side with `typeof` guards.

/// Waker attached to a pending Float creation; consumed (and woken) when the
/// ArkTS creation chain settles so the embedding runtime's queued ops replay
/// on the next event-loop pass. Existence of the entry IS the pending state —
/// settlement removes it (unlike PendingAbility, which lingers with a flag).
struct PendingFloat {
    waker: Option<crate::OpenHarmonyWaker>,
}

static PENDING_FLOAT_WINDOWS: Mutex<Option<HashMap<i64, PendingFloat>>> = Mutex::new(None);

/// Set by the ArkTS ProcessInitializer via `enable_float_pending_tracking`
/// before any Float window can be created (capability handshake, review V1).
static FLOAT_PENDING_TRACKING: AtomicBool = AtomicBool::new(false);

fn pending_float_windows() -> std::sync::MutexGuard<'static, Option<HashMap<i64, PendingFloat>>> {
    PENDING_FLOAT_WINDOWS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Opens the pending entry for a Float window id pre-allocated inside
/// `create_os_window`. Only called when the capability handshake is on.
pub fn register_pending_float(id: i64) {
    pending_float_windows()
        .get_or_insert_with(HashMap::new)
        .insert(id, PendingFloat { waker: None });
    crate::info!(
        "register_pending_float: id={} (createSubWindow TSFN dispatched, awaiting ArkTS registration)",
        id
    );
}

/// Whether the ArkTS creation chain for Float window `id` has settled.
/// Unknown ids read as `true`: only creations opened by
/// `register_pending_float` (capability handshake on) are tracked.
pub fn is_float_window_ready(id: i64) -> bool {
    pending_float_windows()
        .as_ref()
        .map(|m| !m.contains_key(&id))
        .unwrap_or(true)
}

/// Combined readiness for window-op gating: ready unless the id is a pending
/// Float creation OR a pending UIAbility handshake. Unknown ids read as
/// ready on both halves.
pub fn is_window_ready(id: i64) -> bool {
    is_ui_ability_stage_ready(id) && is_float_window_ready(id)
}

/// Attaches an event-loop waker to a pending Float creation.
///
/// Deviates from `set_ui_ability_waker` on unknown ids: it STILL wakes. The
/// ArkTS creation chain can settle before the embedding runtime attaches
/// this waker (WindowManager.createSubWindow has synchronous pre-throws that
/// reject the promise immediately), and unlike the UIAbility registry the
/// tao-side PENDING_WINDOW_OPS queue is a real consumer of the wake —
/// without it, ops queued before the waker was attached would only drain on
/// the next unrelated MainEvent, and an idle parked event loop would never
/// replay them (review V2). A spurious wake is harmless: the drain pass
/// simply finds nothing to do.
pub fn set_float_window_waker(id: i64, waker: crate::OpenHarmonyWaker) {
    // The waker is consumed inside the match (attached to the pending entry,
    // or woken immediately for an unknown id); the deferred wake runs outside
    // the registry lock (uniform lock discipline: never call out to ArkTS
    // under a lock; the wake itself is TSFN non-blocking anyway).
    let mut waker = Some(waker);
    let wake_now = {
        let mut map = pending_float_windows();
        match map.as_mut().and_then(|m| m.get_mut(&id)) {
            Some(pending) => {
                pending.waker = waker.take();
                false
            }
            None => true,
        }
    };
    if let (true, Some(waker)) = (wake_now, waker) {
        waker.wake();
    }
}

/// NAPI: called by the ProcessInitializer TSFN wrapper when the ArkTS
/// creation chain for window `id` settles — success or failure. Removes the
/// pending entry (unknown-ids-ready semantics make removal equivalent to
/// "settled") and wakes the attached event-loop waker so queued window ops
/// replay. On failure the replayed ops hit the ArkTS registry and fail with
/// today's "Unknown OS sub-window" warn — loud, never a silent hold.
#[napi]
pub fn notify_float_window_registered(window_id: i64, registered: bool) {
    let waker = {
        let mut map = pending_float_windows();
        match map.as_mut().and_then(|m| m.remove(&window_id)) {
            Some(pending) => {
                crate::info!(
                    "notify_float_window_registered: id={} registered={} (draining queued window ops)",
                    window_id,
                    registered
                );
                pending.waker
            }
            // Never pending (handshake off, or the window handle was dropped
            // and already unregistered) — nothing to drain, silent no-op
            // (mirrors the register_ui_ability_stage None branch).
            None => {
                crate::debug!(
                    "notify_float_window_registered: id={} registered={} but no pending entry (unregistered or tracking off)",
                    window_id,
                    registered
                );
                None
            }
        }
    };
    if let Some(waker) = waker {
        waker.wake();
    }
}

/// NAPI: capability handshake (review V1). Called by ProcessInitializer
/// before registering the createSubWindow TSFN — only after this does
/// create_os_window gate Float ops on ArkTS registration. A stale HAR never
/// calls it, keeping the pre-fix fire-and-forget semantics (and never
/// wedging ops against entries no ArkTS code would settle).
#[napi]
pub fn enable_float_pending_tracking() {
    let was = FLOAT_PENDING_TRACKING.swap(true, Ordering::AcqRel);
    if !was {
        crate::info!(
            "enable_float_pending_tracking: Float creation pending tracking armed (ProcessInitializer handshake)"
        );
    }
}

/// Removes the pending entry for a destroyed Float window (tao `Window::drop`).
/// Idempotent; window ids are never reused (NEXT_WINDOW_ID is monotonic), so a
/// removed entry can never collide with a future Float.
pub fn unregister_pending_float(id: i64) {
    if let Some(map) = pending_float_windows().as_mut() {
        map.remove(&id);
    }
}

#[cfg(test)]
mod float_pending_tests {
    use super::*;

    // Statics are process-global across tests — use distinct far-away ids
    // (real ids start at 1 and increment slowly) so tests can't collide.
    const A: i64 = 9_000_001;
    const B: i64 = 9_000_002;
    const C: i64 = 9_000_003;

    #[test]
    fn register_gates_and_notify_settles() {
        register_pending_float(A);
        assert!(!is_float_window_ready(A));
        assert!(!is_window_ready(A));
        notify_float_window_registered(A, true);
        assert!(is_float_window_ready(A));
        assert!(is_window_ready(A));
    }

    #[test]
    fn notify_failure_also_settles() {
        register_pending_float(B);
        assert!(!is_window_ready(B));
        // Failure settles identically (remove + wake) — replayed ops then
        // fail loudly at ArkTS instead of being held forever.
        notify_float_window_registered(B, false);
        assert!(is_window_ready(B));
    }

    #[test]
    fn unknown_ids_read_ready() {
        // Main window (0), UIAbility ids, zombie ids — never gated.
        assert!(is_window_ready(0));
        assert!(is_window_ready(9_000_004));
    }

    #[test]
    fn unregister_is_idempotent_and_settles() {
        register_pending_float(C);
        assert!(!is_window_ready(C));
        unregister_pending_float(C);
        unregister_pending_float(C); // second call must not panic
        assert!(is_window_ready(C));
        // A late notify after drop is a silent no-op (drop-then-settle race).
        notify_float_window_registered(C, true);
        assert!(is_window_ready(C));
    }

    #[test]
    fn ui_ability_pending_also_blocks_combined_check() {
        // The combined check is an AND: a pending UIAbility handshake gates
        // is_window_ready through the other half.
        register_pending_ui_ability(9_000_005);
        assert!(!is_window_ready(9_000_005));
        unregister_pending_ui_ability(9_000_005);
        assert!(is_window_ready(9_000_005));
    }

    #[test]
    fn start_failed_rollback_clears_pending_and_label() {
        // An AMS rejection arriving after the bridge response returned
        // accepted ("dispatched" ≠ "created") must roll back the same
        // registries the synchronous Err leg does, or the id never becomes
        // ready and its queued ops are held silently forever (G15).
        register_pending_ui_ability(9_000_006);
        crate::register_window_label("af3-rolled-back", 9_000_006);
        assert!(!is_ui_ability_stage_ready(9_000_006));
        notify_ui_ability_start_failed(9_000_006);
        // The pending entry is gone (unknown id reads as ready) and the label
        // resolves back to the primary id.
        assert!(is_ui_ability_stage_ready(9_000_006));
        assert_eq!(crate::window_id_for_label("af3-rolled-back"), 0);
        // Repeated notifies — or one for a never-registered id — are no-ops.
        notify_ui_ability_start_failed(9_000_006);
        notify_ui_ability_start_failed(9_000_099);
    }
}

/// Reads the last windowId reported by a subsequent instance. Returns -1 if no
/// subsequent instance has registered yet. Used by automated tests.
#[napi]
pub fn get_last_ui_ability_window_id() -> i64 {
    LAST_UI_ABILITY_WINDOW_ID.load(Ordering::SeqCst)
}

// ─── Group F: cursor grab (OH_WindowManager_LockCursor/UnlockCursor, NDK C API 22+) ───
//
// Ported from upstream PR#45 (50d3f00). Pure FFI — no ArkTS bridge involvement.
//
// No ArkTS API exists for cursor locking — the only public surface is the NDK
// C API in libnative_window_manager.so (oh_window.h, @since 22, permission
// ohos.permission.LOCK_WINDOW_CURSOR / normal / system_grant). The library is
// resolved lazily via dlopen+dlsym instead of a static `#[link]`:
// compatibleSdkVersion is API 12 and system images below API 22 do not export
// these symbols, so a load-time link would prevent the app from starting on
// older devices. Symbol presence doubles as the version guard
// (dlsym null ⇒ device below API 22 ⇒ NotSupported).
//
// Unlike upstream, this port takes the REAL OHOS window id directly. Upstream
// resolved the tao window id → real id internally via the old ArkHelper channel
// (deleted in the pluginize refactor). The ability crate cannot call the
// plugin-window facade itself (dependency direction: plugin-window → ability),
// so tao resolves the real id via the bridge (`get-real-window-id` action)
// before calling this function (design D3.7, openspec
// upstream-ohdev-rebase-window-ops).

type LockCursorFn = unsafe extern "C" fn(window_id: i32, is_cursor_follow_movement: bool) -> i32;
type UnlockCursorFn = unsafe extern "C" fn(window_id: i32) -> i32;

struct CursorLockApi {
    lock_cursor: LockCursorFn,
    unlock_cursor: UnlockCursorFn,
}

/// WindowManager C API error code for "capability not supported" (oh_window_comm.h).
const WM_ERRORCODE_DEVICE_NOT_SUPPORTED: i32 = 801;
/// WindowManager C API error code for "window state abnormal" (oh_window_comm.h).
const WM_ERRORCODE_STATE_ABNORMAL: i32 = 1300002;

static CURSOR_LOCK_API: OnceLock<Option<CursorLockApi>> = OnceLock::new();

extern "C" {
    fn dlopen(filename: *const std::ffi::c_char, flags: std::ffi::c_int) -> *mut std::ffi::c_void;
    fn dlsym(
        handle: *mut std::ffi::c_void,
        symbol: *const std::ffi::c_char,
    ) -> *mut std::ffi::c_void;
}

/// Resolves the cursor lock C API once per process; `None` when the system
/// does not provide it (API < 22). The handle is intentionally never closed —
/// the library stays loaded for the process lifetime.
fn cursor_lock_api() -> Option<&'static CursorLockApi> {
    CURSOR_LOCK_API
        .get_or_init(|| unsafe {
            // RTLD_NOW | RTLD_LOCAL = 2 on OHOS musl.
            let handle = dlopen(
                b"libnative_window_manager.so\0".as_ptr() as *const std::ffi::c_char,
                2,
            );
            if handle.is_null() {
                crate::warn!("[ohos-window] dlopen libnative_window_manager.so failed (library missing/broken) — cursor grab unsupported");
                return None;
            }
            let lock = dlsym(handle, b"OH_WindowManager_LockCursor\0".as_ptr() as *const std::ffi::c_char);
            let unlock = dlsym(handle, b"OH_WindowManager_UnlockCursor\0".as_ptr() as *const std::ffi::c_char);
            if lock.is_null() || unlock.is_null() {
                crate::warn!("[ohos-window] OH_WindowManager_LockCursor/UnlockCursor not exported — cursor grab unsupported");
                return None;
            }
            Some(CursorLockApi {
                lock_cursor: std::mem::transmute::<*mut std::ffi::c_void, LockCursorFn>(lock),
                unlock_cursor: std::mem::transmute::<*mut std::ffi::c_void, UnlockCursorFn>(unlock),
            })
        })
        .as_ref()
}

/// Typed error for `set_cursor_grab` — tao maps `NotSupported` to
/// `ExternalError::NotSupported` (pre-change behavior on unsupported devices)
/// and the other variants to `ExternalError::Os`.
#[derive(Debug)]
pub enum CursorGrabError {
    /// System does not support cursor lock: dlsym failed (API < 22) or the
    /// FFI call returned 801 (DEVICE_NOT_SUPPORTED).
    NotSupported,
    /// FFI error code: 201 (no permission), 1300002 (window state abnormal),
    /// 1300003 (window manager service abnormal), or any other nonzero code.
    OsCode(i32),
    /// Caller-provided real window id is invalid (≤ 0), or the bridge lookup
    /// upstream failed before reaching this function.
    Bridge(String),
}

impl std::fmt::Display for CursorGrabError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CursorGrabError::NotSupported => write!(f, "cursor lock not supported on this device"),
            CursorGrabError::OsCode(code) => write!(f, "window manager error code {code}"),
            CursorGrabError::Bridge(reason) => write!(f, "cursor grab bridge failure: {reason}"),
        }
    }
}

/// Locks/unlocks the mouse cursor to a window (tao `set_cursor_grab`).
///
/// `real_window_id` is the REAL OHOS window instance id (from
/// `win.getWindowProperties().id`), resolved by tao via the plugin-window
/// bridge before calling — see the module-level comment above.
///
/// Lock uses confined-follow mode (`isCursorFollowMovement=true`, cursor keeps
/// moving within the window area — matches Windows ClipCursor semantics). The
/// lock only takes effect while the window is focused; the system releases it
/// automatically on focus loss. Unlock restores free cursor movement.
///
/// Pure FFI — safe from any thread (no NAPI env access). Returns a typed error
/// (explicit `std::result::Result`) so tao can map `NotSupported` vs OS errors
/// without string matching.
pub fn set_cursor_grab(
    real_window_id: i32,
    grab: bool,
) -> std::result::Result<(), CursorGrabError> {
    if real_window_id <= 0 {
        return Err(CursorGrabError::Bridge(format!(
            "invalid real window id {real_window_id}"
        )));
    }
    let api = cursor_lock_api().ok_or(CursorGrabError::NotSupported)?;
    let code = if grab {
        unsafe { (api.lock_cursor)(real_window_id, true) }
    } else {
        unsafe { (api.unlock_cursor)(real_window_id) }
    };
    match code {
        0 => Ok(()),
        // Unlock is idempotent: the system auto-releases the lock on focus
        // loss, so unlocking an already-unlocked window returns STATE_ABNORMAL
        // (1300002). Treat that as success — matches Windows, where clearing
        // the ClipCursor flag when not grabbed succeeds silently.
        WM_ERRORCODE_STATE_ABNORMAL if !grab => Ok(()),
        WM_ERRORCODE_DEVICE_NOT_SUPPORTED => Err(CursorGrabError::NotSupported),
        other => Err(CursorGrabError::OsCode(other)),
    }
}

// ─── Group G: content protection (OH_WindowManager_SetWindowPrivacyMode, NDK C API 15+) ───
//
// A privacy-mode window's content is excluded from screenshots, screen
// recording, and casting (tao `set_content_protection`, issue #115). Same FFI
// shape as the cursor-grab group above: libnative_window_manager.so resolved
// lazily via dlopen+dlsym — compatibleSdkVersion is API 12 and system images
// below API 15 do not export this symbol, so symbol presence doubles as the
// version guard.
//
// Requires ohos.permission.PRIVACY_WINDOW (normal / system_grant, API 11+).
// HAR module.json5 declarations do not merge into the final HAP — the
// permission must be declared in the app's entry module.json5 (tauri-cli
// open-harmony templates).

type SetWindowPrivacyModeFn = unsafe extern "C" fn(window_id: i32, is_privacy: bool) -> i32;

struct WindowPrivacyApi {
    set_window_privacy_mode: SetWindowPrivacyModeFn,
}

static WINDOW_PRIVACY_API: OnceLock<Option<WindowPrivacyApi>> = OnceLock::new();

/// Resolves the window privacy C API once per process; `None` when the system
/// does not provide it (API < 15). Same lazy-load contract as
/// [`cursor_lock_api`] — the handle is never closed.
fn window_privacy_api() -> Option<&'static WindowPrivacyApi> {
    WINDOW_PRIVACY_API
        .get_or_init(|| unsafe {
            // RTLD_NOW | RTLD_LOCAL = 2 on OHOS musl.
            let handle = dlopen(
                b"libnative_window_manager.so\0".as_ptr() as *const std::ffi::c_char,
                2,
            );
            if handle.is_null() {
                crate::warn!("[ohos-window] dlopen libnative_window_manager.so failed (library missing/broken) — content protection unsupported");
                return None;
            }
            let set_privacy = dlsym(
                handle,
                b"OH_WindowManager_SetWindowPrivacyMode\0".as_ptr() as *const std::ffi::c_char,
            );
            if set_privacy.is_null() {
                crate::warn!("[ohos-window] OH_WindowManager_SetWindowPrivacyMode not exported — content protection unsupported");
                return None;
            }
            Some(WindowPrivacyApi {
                set_window_privacy_mode: std::mem::transmute::<
                    *mut std::ffi::c_void,
                    SetWindowPrivacyModeFn,
                >(set_privacy),
            })
        })
        .as_ref()
}

/// Typed error for `set_window_privacy_mode`. tao only logs these (the public
/// `set_content_protection` returns `()`), so `Display` carries the detail.
#[derive(Debug)]
pub enum WindowPrivacyError {
    /// System does not support window privacy mode: dlsym failed (API < 15)
    /// or the FFI call returned 801 (DEVICE_NOT_SUPPORTED).
    NotSupported,
    /// FFI error code: 201 (PRIVACY_WINDOW not declared in the entry module),
    /// 1300002/1300003 (window state/service abnormal), or any other nonzero.
    OsCode(i32),
    /// Caller-provided real window id is invalid (≤ 0).
    Bridge(String),
}

impl std::fmt::Display for WindowPrivacyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WindowPrivacyError::NotSupported => {
                write!(f, "window privacy mode not supported on this device")
            }
            WindowPrivacyError::OsCode(code) => write!(f, "window manager error code {code}"),
            WindowPrivacyError::Bridge(reason) => {
                write!(f, "window privacy mode bridge failure: {reason}")
            }
        }
    }
}

/// Marks a window as privacy mode (content excluded from screenshot/recording/
/// casting) or clears the flag.
///
/// `real_window_id` is the REAL OHOS window instance id, resolved by tao via
/// the plugin-window bridge (`get-real-window-id` action) before calling —
/// same D3.7 contract as [`set_cursor_grab`].
///
/// Pure FFI — safe from any thread. Idempotent: setting an already-set (or
/// already-cleared) window simply returns 0.
pub fn set_window_privacy_mode(
    real_window_id: i32,
    is_privacy: bool,
) -> std::result::Result<(), WindowPrivacyError> {
    if real_window_id <= 0 {
        return Err(WindowPrivacyError::Bridge(format!(
            "invalid real window id {real_window_id}"
        )));
    }
    let api = window_privacy_api().ok_or(WindowPrivacyError::NotSupported)?;
    let code = unsafe { (api.set_window_privacy_mode)(real_window_id, is_privacy) };
    match code {
        0 => Ok(()),
        WM_ERRORCODE_DEVICE_NOT_SUPPORTED => Err(WindowPrivacyError::NotSupported),
        other => Err(WindowPrivacyError::OsCode(other)),
    }
}
