use std::{
    cell::RefCell,
    collections::HashMap,
    fmt::Debug,
    sync::{
        atomic::{AtomicBool, AtomicI64},
        Arc, Mutex, RwLock,
    },
};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Object, Env, Error, Result};
use ohos_arkui_binding::XComponent;
use ohos_display_binding::{
    default_display_height, default_display_refresh_rate, default_display_scaled_density,
    default_display_width,
};
use ohos_ime_binding::IME;
use ohos_xcomponent_binding::RawWindow;

use crate::{
    bridge::MainThreadBridgeEndpoint, AvoidArea, AvoidAreaType, BridgeMainThread,
    BridgeMainThreadEvent, BridgePlugin, BridgePluginDeclaration, BridgePluginRegistry,
    BridgeRuntime, Configuration, Event, MainThreadScheduler, OpenHarmonyWaker,
    PluginLifecycleEvent, Rect,
};

static ID: AtomicI64 = AtomicI64::new(0);

pub(crate) static HAS_EVENT: AtomicBool = AtomicBool::new(false);

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct AbilityInitContext {
    pub base_path: Option<String>,
    pub pref_path: Option<String>,
    pub preferred_locales: Option<String>,
    pub module_name: Option<String>,
    pub sdk_api_version: Option<i32>,
    #[napi(js_name = "distributionOSApiVersion")]
    pub distribution_api_version: Option<i32>,
}

impl AbilityInitContext {
    pub fn from_object(context: Option<&Object<'_>>) -> Result<Self> {
        let Some(context) = context else {
            return Ok(Self::default());
        };

        Ok(Self {
            base_path: context.get("basePath")?,
            pref_path: context.get("prefPath")?,
            preferred_locales: context.get("preferredLocales")?,
            module_name: context.get("moduleName")?,
            sdk_api_version: context.get("sdkApiVersion")?,
            distribution_api_version: context.get("distributionOSApiVersion")?,
        })
    }
}

#[derive(Clone)]
pub struct OpenHarmonyAppInner {
    pub(crate) raw_window: Option<RawWindow>,
    pub(crate) xcomponent: Option<XComponent>,
    /// Owner token of this native module's one active DefaultXComponent render.
    render_owner: Option<String>,
    surface_active: bool,

    state: Vec<u8>,
    save_state: bool,
    id: i64,
    pub(crate) configuration: Configuration,
    pub(crate) rect: Rect,
    /// Per-window rect cache keyed by windowId (0 = main window, >0 = Float sub-window).
    /// Written by the `window_rect_change` lifecycle closure (lifecycle.rs) from ArkTS
    /// windowRectChange callbacks; read by tao's inner_size/outer_position/etc via
    /// `window_rect_for(window_id)`. See design.md D1/D4 (openspec change
    /// p1-window-state-per-window-rect).
    pub(crate) window_rects: HashMap<i64, Rect>,
    /// Cached main-window decoration (title bar) height, physical px, ≥0.
    /// Latched ONLY on surface events (`latch_decor_height`) where the
    /// XComponent rect is fresh and the WM rect has already been delivered.
    /// Consumers (tao inner_size/set_inner_size/inner_position) must use
    /// `decor_height()` instead of live-diffing window_rect − content_rect:
    /// the WM rect (windowRectChange) and the surface rect (XComponent
    /// onSurfaceChanged) update ASYNCHRONOUSLY — a read in the gap between
    /// them computes a garbage decor (observed 824/770/292 instead of the
    /// real 146), which corrupted inner_size reads and compounded through
    /// save/restore cycles into the shrinking-window bug.
    pub(crate) decor_height: i32,
    /// Listeners fired by `latch_decor_height` whenever the latched decor value
    /// actually changes. Each listener returns `false` to have itself removed
    /// after the call. tao uses this for event-driven set_inner_size
    /// self-correction (startup decor convergence) instead of polling.
    ///
    /// INVARIANT: listeners run while the app RwLock is HELD (write) — they
    /// must not re-enter any OpenHarmonyApp API (deadlock). Keep them lock-free:
    /// channel sends / atomics only. Expected to stay LOW-COUNT (one per tao
    /// window); every listener runs on every decor change under the lock.
    pub(crate) decor_change_callbacks:
        Vec<(u64, std::sync::Arc<dyn Fn(i32) -> bool + Send + Sync>)>,
    next_decor_cb_id: u64,
    pub(crate) avoid_areas: HashMap<AvoidAreaType, AvoidArea>,
    pub(crate) init_context: AbilityInitContext,
    // ─── Session state (migrated from module-level statics, issue #87 major-9) ───
    // These four carried session semantics while living at module scope, which is
    // only correct under a single UIAbility instance. They now ride the app's
    // inner RwLock, so they follow the app instance like every other field.
    /// Latest `want.parameters` JSON from `onNewWant` (drained on take).
    pub(crate) want_parameters: String,
    /// Initial `want.uri` from cold-start `onCreate` (drained on take).
    pub(crate) initial_want_uri: String,
    /// Whether the current launch is an app-continuation restore (peek-only).
    pub(crate) continuation_restore: bool,
    /// Continuation payload JSON from a continuation-restore launch (drained on take).
    pub(crate) continuation_data: String,
}

impl PartialEq for OpenHarmonyAppInner {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

impl Eq for OpenHarmonyAppInner {}

impl std::hash::Hash for OpenHarmonyAppInner {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.id.hash(state);
    }
}

impl PartialOrd for OpenHarmonyAppInner {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for OpenHarmonyAppInner {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.id.cmp(&other.id)
    }
}

impl Debug for OpenHarmonyAppInner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenHarmonyApp")
            .field("id", &self.id)
            .finish()
    }
}

impl Default for OpenHarmonyAppInner {
    fn default() -> Self {
        Self::new()
    }
}

impl OpenHarmonyAppInner {
    pub fn new() -> Self {
        let id = ID.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        OpenHarmonyAppInner {
            raw_window: None,
            xcomponent: None,
            render_owner: None,
            surface_active: false,
            state: vec![],
            save_state: false,
            id,
            configuration: Default::default(),
            rect: Default::default(),
            window_rects: HashMap::new(),
            decor_height: 0,
            decor_change_callbacks: Vec::new(),
            next_decor_cb_id: 0,
            avoid_areas: HashMap::new(),
            init_context: AbilityInitContext::default(),
            want_parameters: String::new(),
            initial_want_uri: String::new(),
            continuation_restore: false,
            continuation_data: String::new(),
        }
    }

    /// load current app state
    ///
    /// Returns `None` until `save()` has been called at least once in this
    /// process (peek-only: repeated loads return the same bytes; nothing is
    /// drained).
    pub fn load(&self) -> Option<Vec<u8>> {
        if self.save_state {
            Some(self.state.clone())
        } else {
            None
        }
    }

    /// save current app state
    pub fn save(&mut self, state: Vec<u8>) {
        self.state = state;
        // Make save/load symmetric (issue #87 major-3): without this, load()
        // gates on a save_state that is never set and always returns None —
        // the write side (ArkTS onSaveState → Event::SaveState → app.save)
        // was live while the read side silently produced nothing.
        self.save_state = true;
    }

    pub fn create_waker(&self) -> OpenHarmonyWaker {
        // Read `WAKER` live at `wake()` time, not here. See `waker.rs` for the
        // snapshot-timing rationale: `WAKER` is populated by `create_lifecycle_handle`,
        // which runs after the embedding runtime's entry that constructs the event-loop proxy.
        OpenHarmonyWaker::new()
    }

    pub fn config(&self) -> Configuration {
        self.configuration.clone()
    }

    pub fn set_frame_rate(&self, min: i32, max: i32, expected: i32) {
        if let Some(xcomponent) = self.xcomponent.as_ref() {
            // Callable from embedding apps; a failure here must not abort the
            // process (issue #87 minor-2 — this used to .expect).
            if let Err(e) = xcomponent.native_xcomponent().set_frame_rate(min, max, expected) {
                crate::warn!("set_frame_rate({min}, {max}, {expected}) failed: {e:?}");
            }
        }
    }

    fn claim_render_owner(&mut self, owner: &str) -> Result<()> {
        if self.render_owner.is_some() {
            return Err(Error::from_reason(
                "This native module already has an active DefaultXComponent render owner",
            ));
        }
        self.render_owner = Some(owner.to_owned());
        self.surface_active = false;
        Ok(())
    }

    fn owns_render(&self, owner: &str) -> bool {
        self.render_owner.as_deref() == Some(owner)
    }

    /// Latch the main-window decoration (title bar) height estimate.
    ///
    /// Called only from surface events (activate/update), the one point where
    /// the XComponent rect is guaranteed fresh. The WM rect (windowRectChange)
    /// is delivered before the surface relayout completes (observed ordering on
    /// every resize in the DBG-D2 probe logs), so window_rects[0] is also
    /// current here — the diff is the real title-bar inset. Out-of-range diffs
    /// (surface mid-relayout, or window_rect not yet delivered) are rejected so
    /// the cache keeps the last plausible value instead of transient garbage.
    fn latch_decor_height(&mut self) {
        // Physically impossible title-bar ceiling: real decor is ~146 px on the
        // 2in1 reference device. Anything larger is a stale-rect diff.
        const DECOR_HEIGHT_MAX: i32 = 320;
        let Some(window) = self.window_rects.get(&0) else {
            return;
        };
        let diff = window.height - self.rect.height;
        let new_decor = if diff == 0 {
            // Decorations hidden (fullscreen / setDecorations(false)): the
            // surface fills the window exactly.
            0
        } else if diff > 0 && diff <= DECOR_HEIGHT_MAX {
            diff
        } else {
            // diff < 0 or diff > MAX: transient — keep the previous estimate
            // (and don't notify listeners).
            return;
        };
        if new_decor == self.decor_height {
            return;
        }
        self.decor_height = new_decor;
        // Notify listeners (lock-free by contract — see field docs). Returning
        // false removes the listener after this call.
        self.decor_change_callbacks
            .retain_mut(|(_, cb)| cb(new_decor));
    }

    fn activate_surface(&mut self, owner: &str, raw_window: Option<RawWindow>, rect: Rect) -> bool {
        if !self.owns_render(owner) || self.surface_active {
            return false;
        }
        self.raw_window = raw_window;
        self.rect = rect;
        self.surface_active = true;
        self.latch_decor_height();
        true
    }

    fn update_surface_rect(&mut self, owner: &str, rect: Rect) -> bool {
        if !self.owns_render(owner) || !self.surface_active {
            return false;
        }
        self.rect = rect;
        self.latch_decor_height();
        true
    }

    fn deactivate_surface(&mut self, owner: &str) -> bool {
        if !self.owns_render(owner) || !self.surface_active {
            return false;
        }
        self.raw_window = None;
        self.rect = Rect::default();
        self.surface_active = false;
        true
    }

    fn release_render_owner(&mut self, owner: &str) -> Option<bool> {
        if !self.owns_render(owner) {
            return None;
        }
        let surface_was_active = self.surface_active;
        self.render_owner = None;
        self.surface_active = false;
        self.raw_window = None;
        self.xcomponent = None;
        self.rect = Rect::default();
        // Clear only the main-window (key 0) rect: release_render_owner tears down the
        // main window's DefaultXComponent render surface. Sub-window rects (key >0) are
        // owned by their own Float sub-window lifetimes and cleared via separate paths.
        // NOTE: deactivate_surface intentionally does NOT reset window_rects — that
        // preserves the asymmetric semantics (only full release clears the rect cache).
        self.window_rects.remove(&0);
        self.avoid_areas.clear();
        Some(surface_was_active)
    }

    pub fn content_rect(&self) -> Rect {
        self.rect
    }

    /// Per-window rect lookup. Returns Rect::default() for an unregistered window id
    /// (e.g. before the first windowRectChange callback fires) — same fallback semantics
    /// as the old single-field window_rect (design.md D4).
    pub fn window_rect_for(&self, window_id: i64) -> Rect {
        self.window_rects
            .get(&window_id)
            .copied()
            .unwrap_or_default()
    }

    /// Per-window rect setter. Called by the `window_rect_change` lifecycle closure
    /// (lifecycle.rs) with the windowId parsed from the ArkTS-wrapped options.
    pub fn set_window_rect(&mut self, window_id: i64, rect: Rect) {
        self.window_rects.insert(window_id, rect);
    }

    pub fn avoid_area(&self, area_type: AvoidAreaType) -> Option<AvoidArea> {
        self.avoid_areas.get(&area_type).copied()
    }

    pub fn avoid_areas(&self) -> HashMap<AvoidAreaType, AvoidArea> {
        self.avoid_areas.clone()
    }

    pub fn native_window(&self) -> Option<RawWindow> {
        self.raw_window
    }

    pub fn scale(&self) -> f32 {
        default_display_scaled_density()
    }

    /// Physical dimensions of the default display, in pixels.
    ///
    /// This is the real screen size — as opposed to `content_rect()`/`window_rect_for()`,
    /// which return the *window's own* rect. Consumers that need the screen size
    /// (e.g. the windowing backend's `MonitorHandle::size()` for window centering) must use this,
    /// otherwise computations like positioner `Center` collapse to ~(0,0) because
    /// the window rect is smaller than itself.
    pub fn display_size(&self) -> (u32, u32) {
        (
            default_display_width().max(0) as u32,
            default_display_height().max(0) as u32,
        )
    }

    /// Default display refresh rate (Hz) from OHOS DisplayManager.
    /// See openspec ohos-monitor-real-values.
    pub fn refresh_rate(&self) -> u32 {
        default_display_refresh_rate() as u32
    }

    /// Default display physical width (px) from OHOS DisplayManager.
    /// Returns 0 if the query fails (callers should fall back to content_rect).
    pub fn display_width(&self) -> u32 {
        default_display_width() as u32
    }

    /// Default display physical height (px) from OHOS DisplayManager.
    /// Returns 0 if the query fails (callers should fall back to content_rect).
    pub fn display_height(&self) -> u32 {
        default_display_height() as u32
    }

    pub fn init_context(&self) -> AbilityInitContext {
        self.init_context.clone()
    }

    pub fn set_init_context(&mut self, context: AbilityInitContext) {
        self.init_context = context;
    }

    // ─── Session-state accessors (issue #87 major-9; migrated from module statics) ───

    pub(crate) fn store_want_parameters(&mut self, json: &str) {
        self.want_parameters = json.to_string();
    }

    pub(crate) fn take_want_parameters(&mut self) -> String {
        std::mem::take(&mut self.want_parameters)
    }

    pub(crate) fn store_initial_want_uri(&mut self, uri: &str) {
        self.initial_want_uri = uri.to_string();
    }

    pub(crate) fn take_initial_want_uri(&mut self) -> String {
        std::mem::take(&mut self.initial_want_uri)
    }

    /// `is_continuation == true` writes both the flag and the payload (passed
    /// through verbatim — the wantParam schema is an application-level contract).
    /// `is_continuation == false` clears both: a plain relaunch must not observe
    /// the previous session's continuation payload.
    pub(crate) fn store_continuation(&mut self, is_continuation: bool, parameters_json: &str) {
        self.continuation_restore = is_continuation;
        self.continuation_data = if is_continuation {
            parameters_json.to_string()
        } else {
            String::new()
        };
    }

    pub(crate) fn is_continuation_restore(&self) -> bool {
        self.continuation_restore
    }

    pub(crate) fn take_continuation_data(&mut self) -> String {
        std::mem::take(&mut self.continuation_data)
    }
}

type EventLoop = Arc<RefCell<Option<Box<dyn FnMut(Event)>>>>;
type BackPressInterceptor = Arc<RefCell<Option<Box<dyn FnMut() -> bool>>>>;

/// Transport endpoints owned by one NativeAbility/module session. This lifetime is deliberately
/// independent from the module's optional DefaultXComponent render surface.
struct ActiveBridgeSession {
    owner: String,
    runtime: BridgeRuntime,
    main_thread_endpoint: MainThreadBridgeEndpoint,
}

#[derive(Clone)]
pub struct OpenHarmonyApp {
    pub(crate) inner: Arc<RwLock<OpenHarmonyAppInner>>,
    pub(crate) event_loop: EventLoop,
    pub(crate) back_press_interceptor: BackPressInterceptor,
    pub(crate) ime: Arc<RefCell<Option<IME>>>,
    bridge_session: Arc<RwLock<Option<ActiveBridgeSession>>>,
    bridge_plugins: Arc<BridgePluginRegistry>,
    is_keyboard_show: Arc<Mutex<bool>>,
}

impl Debug for OpenHarmonyApp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenHarmonyApp")
            .field("id", &self.inner.read().unwrap().id)
            .finish()
    }
}

impl PartialEq for OpenHarmonyApp {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.inner, &other.inner)
    }
}

impl Eq for OpenHarmonyApp {}

impl std::hash::Hash for OpenHarmonyApp {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        Arc::as_ptr(&self.inner).hash(state);
    }
}

impl PartialOrd for OpenHarmonyApp {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for OpenHarmonyApp {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        let self_id = self.inner.read().unwrap().id;
        let other_id = other.inner.read().unwrap().id;
        self_id.cmp(&other_id)
    }
}

impl OpenHarmonyApp {
    pub fn new() -> Self {
        Self {
            #[allow(clippy::arc_with_non_send_sync)]
            inner: Arc::new(RwLock::new(OpenHarmonyAppInner::new())),
            #[allow(clippy::arc_with_non_send_sync)]
            event_loop: Arc::new(RefCell::new(None)),
            #[allow(clippy::arc_with_non_send_sync)]
            back_press_interceptor: Arc::new(RefCell::new(None)),
            #[allow(clippy::arc_with_non_send_sync)]
            ime: Arc::new(RefCell::new(None)),
            bridge_session: Arc::new(RwLock::new(None)),
            bridge_plugins: Arc::new(BridgePluginRegistry::default()),
            is_keyboard_show: Arc::new(Mutex::new(false)),
        }
    }

    pub fn save(&self, state: Vec<u8>) {
        self.inner.write().unwrap().save(state);
    }

    pub fn load(&self) -> Option<Vec<u8>> {
        self.inner.read().unwrap().load()
    }

    pub fn set_frame_rate(&self, min: i32, max: i32, expected: i32) {
        self.inner
            .read()
            .unwrap()
            .set_frame_rate(min, max, expected);
    }

    #[doc(hidden)]
    pub fn set_init_context(&self, context: AbilityInitContext) {
        self.inner.write().unwrap().set_init_context(context);
    }

    pub fn init_context(&self) -> AbilityInitContext {
        self.inner.read().unwrap().init_context()
    }

    pub fn module_name(&self) -> Option<String> {
        self.init_context().module_name
    }

    pub fn base_path(&self) -> Option<String> {
        self.init_context().base_path
    }

    pub fn pref_path(&self) -> Option<String> {
        self.init_context().pref_path
    }

    pub fn preferred_locales(&self) -> Option<String> {
        self.init_context().preferred_locales
    }

    // ─── Session-state facades (issue #87 major-9) ───
    // Mirror the old module-static free functions (lock-poisoning degrades to a
    // default instead of unwinding; the NAPI/lifecycle writers call these from
    // inside already-tolerant callback contexts).

    /// Stores the latest `want.parameters` JSON from `onNewWant`.
    pub fn store_want_parameters(&self, json: &str) {
        if let Ok(mut inner) = self.inner.write() {
            inner.store_want_parameters(json);
        }
    }

    /// Takes the latest `want.parameters` JSON (draining the stored value).
    /// Consumed by the `plugin-deep-link` facade (`DeepLinkClient`).
    pub fn take_want_parameters(&self) -> String {
        self.inner
            .write()
            .ok()
            .map(|mut inner| inner.take_want_parameters())
            .unwrap_or_default()
    }

    /// Stores the initial `want.uri` from `onCreate` (cold start).
    pub fn store_initial_want_uri(&self, uri: &str) {
        if let Ok(mut inner) = self.inner.write() {
            inner.store_initial_want_uri(uri);
        }
    }

    /// Takes the initial `want.uri` from `onCreate` (draining the stored value).
    /// Consumed by the `plugin-deep-link` facade to surface the cold-start deep link.
    pub fn take_initial_want_uri(&self) -> String {
        self.inner
            .write()
            .ok()
            .map(|mut inner| inner.take_initial_want_uri())
            .unwrap_or_default()
    }

    /// Stores the continuation signal from a lifecycle callback
    /// (see `OpenHarmonyAppInner::store_continuation` for the clear-on-false contract).
    pub fn store_continuation(&self, is_continuation: bool, parameters_json: &str) {
        if let Ok(mut inner) = self.inner.write() {
            inner.store_continuation(is_continuation, parameters_json);
        }
    }

    /// Returns whether the current launch is an app-continuation restore.
    /// Peek-only. Consumed by the `plugin-continuation` facade (`ContinuationClient`).
    pub fn is_continuation_restore(&self) -> bool {
        self.inner
            .read()
            .ok()
            .map(|inner| inner.is_continuation_restore())
            .unwrap_or(false)
    }

    /// Takes the continuation payload JSON (draining the stored value).
    /// Consumed by the `plugin-continuation` facade (`ContinuationClient`).
    pub fn take_continuation_data(&self) -> String {
        self.inner
            .write()
            .ok()
            .map(|mut inner| inner.take_continuation_data())
            .unwrap_or_default()
    }

    pub(crate) fn begin_render(&self, owner: &str, xcomponent: XComponent) -> Result<()> {
        let bridge_active = self
            .bridge_session
            .read()
            .map_err(|_| Error::from_reason("Failed to read native module bridge session"))?
            .is_some();
        if !bridge_active {
            return Err(Error::from_reason(
                "A DefaultXComponent cannot render outside an active NativeAbility module session",
            ));
        }
        let mut inner = self
            .inner
            .write()
            .map_err(|_| Error::from_reason("Failed to claim native render owner"))?;
        inner.claim_render_owner(owner)?;
        inner.xcomponent = Some(xcomponent);
        Ok(())
    }

    pub(crate) fn activate_render_surface(
        &self,
        owner: &str,
        raw_window: Option<RawWindow>,
        rect: Rect,
    ) -> bool {
        self.inner
            .write()
            .map(|mut inner| inner.activate_surface(owner, raw_window, rect))
            .unwrap_or(false)
    }

    pub(crate) fn update_render_surface_rect(&self, owner: &str, rect: Rect) -> bool {
        self.inner
            .write()
            .map(|mut inner| inner.update_surface_rect(owner, rect))
            .unwrap_or(false)
    }

    pub(crate) fn is_render_surface_active(&self, owner: &str) -> bool {
        self.inner
            .read()
            .map(|inner| inner.owns_render(owner) && inner.surface_active)
            .unwrap_or(false)
    }

    pub(crate) fn deactivate_render_surface(&self, owner: &str) -> bool {
        let deactivated = self
            .inner
            .write()
            .map(|mut inner| inner.deactivate_surface(owner))
            .unwrap_or(false);
        if deactivated {
            self.ime.borrow_mut().take();
        }
        deactivated
    }

    /// Releases one generated `#[ability]` render. A stale owner is ignored, so delayed cleanup
    /// from an old DefaultXComponent cannot clear a replacement component's native state.
    #[doc(hidden)]
    pub fn release_render(&self, owner: &str) {
        let surface_was_active = self
            .inner
            .write()
            .ok()
            .and_then(|mut inner| inner.release_render_owner(owner));
        let Some(surface_was_active) = surface_was_active else {
            return;
        };
        self.ime.borrow_mut().take();
        if surface_was_active {
            self.dispatch_surface_destroy();
        }
    }

    pub(crate) fn dispatch_surface_destroy(&self) {
        if let Some(ref mut handler) = *self.event_loop.borrow_mut() {
            handler(Event::SurfaceDestroy);
        }
    }

    /// Returns the generic ArkTS bridge for this native module.
    ///
    /// The runtime is initialized with the NativeAbility/module session, before any
    /// DefaultXComponent is required. Calls can be made from a worker thread; they are always
    /// marshalled back to ArkTS through a ThreadsafeFunction. Individual plugins still enforce
    /// their declared Ability, WindowStage, or UIContext readiness.
    pub fn bridge(&self) -> Result<BridgeRuntime> {
        self.bridge_session
            .read()
            .map_err(|_| Error::from_reason("Failed to read bridge runtime"))?
            .as_ref()
            .map(|session| session.runtime.clone())
            .ok_or_else(|| {
                Error::from_reason(
                    "Bridge runtime is not ready. Call it during an active NativeAbility session.",
                )
            })
    }

    /// Schedules a Rust closure onto the ArkTS/N-API main thread.
    ///
    /// UI and ArkTS work should normally use [`Self::bridge`]'s typed plugin calls. This helper
    /// is for a small Rust-side state transition that must observe main-thread affinity.
    pub fn main_thread(&self) -> Result<MainThreadScheduler> {
        Ok(self.bridge()?.main_thread())
    }

    /// Runs a synchronous bridge call while the caller owns the current N-API main-thread `Env`.
    ///
    /// A `BridgeMainThread` cannot be cloned or sent to a worker. In particular,
    /// `MainThreadScheduler::run` does not provide this capability because it does not carry a
    /// scoped N-API environment.
    pub fn with_main_thread_bridge<T>(
        &self,
        env: &Env,
        operation: impl FnOnce(BridgeMainThread<'_>) -> Result<T>,
    ) -> Result<T> {
        let bridge = self
            .bridge_session
            .read()
            .map_err(|_| Error::from_reason("Failed to read main-thread bridge"))?;
        let endpoint = bridge
            .as_ref()
            .map(|session| &session.main_thread_endpoint)
            .ok_or_else(|| {
                Error::from_reason(
                "Synchronous bridge is not ready. Call it during an active NativeAbility session.",
            )
            })?;
        operation(BridgeMainThread::new(env, endpoint))
    }

    /// Registers a Rust facade for ArkTS-originated events and lifecycle notifications.
    ///
    /// Register during the `#[ability]` initializer, before UI rendering starts. Registration is
    /// keyed by `BridgePlugin::ID`, so duplicate contracts fail deterministically.
    pub fn register_plugin<P>(&self, plugin: P) -> Result<()>
    where
        P: BridgePlugin,
    {
        self.bridge_plugins.register(plugin)
    }

    /// Returns the concrete Rust plugin instance registered for this native module.
    pub fn registered_plugin<P>(&self) -> Result<Option<Arc<P>>>
    where
        P: BridgePlugin,
    {
        self.bridge_plugins.registered::<P>()
    }

    /// Structural plugin contracts configured by this native module. Used by generated startup
    /// code so ArkTS can select matching factories without exposing module routing to plugins or
    /// application registration.
    #[doc(hidden)]
    pub fn bridge_plugin_declarations(&self) -> Result<Vec<BridgePluginDeclaration>> {
        self.bridge_plugins.declarations()
    }

    #[doc(hidden)]
    pub fn dispatch_bridge_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<napi_ohos::bindgen_prelude::Unknown<'env>> {
        self.bridge_plugins.dispatch_main_thread_event(event)
    }

    #[doc(hidden)]
    pub fn dispatch_plugin_lifecycle(&self, event: PluginLifecycleEvent) -> Result<()> {
        self.bridge_plugins.dispatch_lifecycle(event)
    }

    pub(crate) fn begin_bridge_session(
        &self,
        owner: &str,
        runtime: BridgeRuntime,
        main_thread_endpoint: MainThreadBridgeEndpoint,
    ) -> Result<()> {
        if owner.is_empty() {
            return Err(Error::from_reason("Bridge session owner must not be empty"));
        }
        let mut session = self
            .bridge_session
            .write()
            .map_err(|_| Error::from_reason("Failed to claim bridge session"))?;
        if session.is_some() {
            return Err(Error::from_reason(
                "This native module already belongs to an active NativeAbility bridge session",
            ));
        }
        *session = Some(ActiveBridgeSession {
            owner: owner.to_owned(),
            runtime,
            main_thread_endpoint,
        });
        Ok(())
    }

    /// Releases only the matching Ability/module transport. A delayed stale teardown cannot
    /// clear endpoints installed for a later session.
    #[doc(hidden)]
    pub fn release_bridge_session(&self, owner: &str) {
        let released = self.bridge_session.write().ok().and_then(|mut session| {
            if session.as_ref().map(|active| active.owner.as_str()) != Some(owner) {
                return None;
            }
            session.take()
        });
        if released.is_some() {
            if let Ok(mut inner) = self.inner.write() {
                inner.set_init_context(AbilityInitContext::default());
            }
        }
    }

    pub fn show_keyboard(&self) {
        let _guard = self
            .is_keyboard_show
            .lock()
            .expect("Failed to lock is_keyboard_show");
        if let Some(ime) = self.ime.borrow().as_ref() {
            ime.show_keyboard();
        }
    }
    pub fn hide_keyboard(&self) {
        let _guard = self
            .is_keyboard_show
            .lock()
            .expect("Failed to lock is_keyboard_show");
        if let Some(ime) = self.ime.borrow().as_ref() {
            ime.hide_keyboard();
        }
    }
    pub fn create_waker(&self) -> OpenHarmonyWaker {
        self.inner.read().unwrap().create_waker()
    }
    pub fn config(&self) -> Configuration {
        self.inner.read().unwrap().config()
    }
    pub fn content_rect(&self) -> Rect {
        self.inner.read().unwrap().content_rect()
    }

    /// Cached main-window decoration (title bar) height in physical px.
    /// Latched on surface events only — see `OpenHarmonyAppInner::decor_height`.
    /// tao's inner_size/set_inner_size/inner_position must read this instead of
    /// live-diffing window_rect − content_rect (async update race).
    pub fn decor_height(&self) -> i32 {
        self.inner
            .read()
            .map(|inner| inner.decor_height)
            .unwrap_or(0)
    }

    /// Register a listener fired whenever the latched main-window decor height
    /// changes (see `OpenHarmonyAppInner::decor_change_callbacks`). Returns an
    /// id for `remove_decor_change_callback`. The listener runs on the thread
    /// that latched the decor, with the app RwLock held — it must not call back
    /// into OpenHarmonyApp APIs (deadlock); channel sends / atomics only.
    pub fn register_decor_change_callback(
        &self,
        listener: std::sync::Arc<dyn Fn(i32) -> bool + Send + Sync>,
    ) -> u64 {
        self.inner
            .write()
            .map(|mut inner| {
                let id = inner.next_decor_cb_id;
                inner.next_decor_cb_id += 1;
                inner.decor_change_callbacks.push((id, listener));
                id
            })
            .unwrap_or(u64::MAX)
    }

    /// Remove a previously registered decor-change listener by id.
    pub fn remove_decor_change_callback(&self, id: u64) {
        if let Ok(mut inner) = self.inner.write() {
            inner
                .decor_change_callbacks
                .retain(|(cb_id, _)| *cb_id != id);
        }
    }

    /// Per-window rect lookup (key = windowId; 0 = main window). See
    /// OpenHarmonyAppInner::window_rect_for. Used by tao's inner_size/outer_position/etc
    /// so each window reads its own rect instead of sharing a single field.
    pub fn window_rect_for(&self, window_id: i64) -> Rect {
        self.inner.read().unwrap().window_rect_for(window_id)
    }

    /// Per-window rect setter. Called from the lifecycle closure with the windowId
    /// parsed from the ArkTS-wrapped windowRectChange options.
    pub fn set_window_rect(&self, window_id: i64, rect: Rect) {
        self.inner.write().unwrap().set_window_rect(window_id, rect);
    }

    /// Last known cursor position in physical px (vp stored by the ArkTS
    /// `MainPage.onMouse` handler × current scale). Issue #87 major-10: the
    /// f64-bit-packed `CURSOR_POSITION_X/Y` statics are an implementation
    /// detail — consumers read them through this method instead of unpacking
    /// the bits by hand.
    pub fn cursor_position(&self) -> (f64, f64) {
        let scale = self.scale() as f64;
        (
            f64::from_bits(CURSOR_POSITION_X.load(std::sync::atomic::Ordering::Relaxed)) * scale,
            f64::from_bits(CURSOR_POSITION_Y.load(std::sync::atomic::Ordering::Relaxed)) * scale,
        )
    }

    /// Decor (title-bar) height to compensate for the given window, in physical px.
    ///
    /// Invariant: window 0 is the one UIAbility main window; every id > 0 is a
    /// Float sub-window (created via `create_os_window`, ids handed out from 1).
    /// Float sub-windows ship their own title bar (FloatPage) and have no system
    /// title bar, so their compensation is 0; the main window gets the cached
    /// latched decor (see [`Self::decor_height`]).
    pub fn decor_height_for(&self, window_id: i64) -> i32 {
        if window_id == 0 {
            self.decor_height().max(0)
        } else {
            0
        }
    }

    /// Inner (content-area) rect for the given window, in physical px, with the
    /// decor compensation applied internally (issue #87 major-10 — consumers no
    /// longer hand-roll it). The window rect comes from the WM
    /// (`windowRectChange`), the content offset from the XComponent surface,
    /// and the title-bar inset from the cached decor — all read under ONE lock
    /// so the three can't tear.
    ///
    /// Semantics:
    /// - `left/top` = window position + content offset (+ decor on the main window)
    /// - `width` = window width (the title bar only affects height)
    /// - `height` = window height − decor, saturating (≥ 0)
    pub fn inner_rect_for(&self, window_id: i64) -> Rect {
        self.inner
            .read()
            .map(|inner| {
                let window = inner.window_rect_for(window_id);
                let content = inner.content_rect();
                let decor = if window_id == 0 {
                    inner.decor_height
                } else {
                    0
                };
                Rect {
                    left: window.left + content.left,
                    top: window.top + content.top + decor,
                    width: window.width,
                    height: (window.height as u32).saturating_sub(decor.max(0) as u32) as i32,
                }
            })
            .unwrap_or_default()
    }

    /// Outer (WM) rect for the given window, in physical px — the raw
    /// `windowRectChange` payload; `(0,0,0,0)` before the first callback fires.
    pub fn outer_rect_for(&self, window_id: i64) -> Rect {
        self.window_rect_for(window_id)
    }

    pub fn avoid_area(&self, area_type: AvoidAreaType) -> Option<AvoidArea> {
        self.inner.read().unwrap().avoid_area(area_type)
    }

    pub fn avoid_areas(&self) -> HashMap<AvoidAreaType, AvoidArea> {
        self.inner.read().unwrap().avoid_areas()
    }
    pub fn native_window(&self) -> Option<RawWindow> {
        self.inner.read().unwrap().native_window()
    }

    /// Get current app scale
    pub fn scale(&self) -> f32 {
        self.inner.read().unwrap().scale()
    }

    /// Physical dimensions of the default display, in pixels (real screen size,
    /// not the window's own rect). See `OpenHarmonyAppInner::display_size`.
    pub fn display_size(&self) -> (u32, u32) {
        self.inner.read().unwrap().display_size()
    }

    /// Default display refresh rate (Hz) from OHOS DisplayManager.
    pub fn refresh_rate(&self) -> u32 {
        self.inner.read().unwrap().refresh_rate()
    }

    /// Default display physical width (px) from OHOS DisplayManager.
    pub fn display_width(&self) -> u32 {
        self.inner.read().unwrap().display_width()
    }

    /// Default display physical height (px) from OHOS DisplayManager.
    pub fn display_height(&self) -> u32 {
        self.inner.read().unwrap().display_height()
    }

    /// Get an updater handle for checking and installing updates via AppGallery.
    ///
    /// Core-privileged OHOS capability (not Tauri-shaped).
    ///
    /// First-class OHOS ability exposed on par with `RuntimeInitArgs.app`.
    /// Intentionally NOT facade-ized: the API has no Tauri shape (pure OHOS
    /// platform capability). Precedent: `OpenHarmonyApp::updater()`.
    ///
    /// Returns `Result<Updater>` (breaking change, 2026-08-21): the handle now
    /// holds a `BridgeRuntime` resolved from the active session, replacing the
    /// former global TSFN transport which was never wired up.
    #[cfg(feature = "updater")]
    pub fn updater(&self) -> Result<super::updater::Updater> {
        super::updater::Updater::new(self)
    }

    // ── Fault injection facade (coverage testing only) ─────────────────────────
    //
    // Feature-gated: when `fault-injection` is off, these methods do not exist.
    // `set_fault_rule` auto-enables the registry on first call (idempotent).

    #[cfg(feature = "fault-injection")]
    pub async fn set_fault_rule(&self, rule: crate::FaultRuleWire) -> Result<()> {
        let client = self.bridge()?.client();
        // Enable the registry (idempotent — safe to call on every set_rule).
        client
            .call_fault_injection::<crate::FaultNoopRequest, crate::FaultInjectionAck>(
                "enable",
                crate::FaultNoopRequest {},
            )
            .await?;
        client
            .call_fault_injection::<crate::FaultRuleWire, crate::FaultInjectionAck>(
                "set-rule", rule,
            )
            .await?;
        Ok(())
    }

    #[cfg(feature = "fault-injection")]
    pub async fn clear_fault_rules(&self) -> Result<()> {
        let client = self.bridge()?.client();
        client
            .call_fault_injection::<crate::FaultNoopRequest, crate::FaultInjectionAck>(
                "clear",
                crate::FaultNoopRequest {},
            )
            .await?;
        Ok(())
    }

    pub fn run_loop<F: FnMut(Event) + 'static>(&self, event_handle: F) {
        if HAS_EVENT.load(std::sync::atomic::Ordering::SeqCst) {
            return;
        }

        // The handler is required to be `'static` (no borrows of `self` or other
        // non-'static data), so it can be stored in the `Box<dyn FnMut(Event)>`
        // slot without any lifetime erasure. The `HAS_EVENT` guard ensures
        // `run_loop` is called exactly once and the app outlives all event
        // dispatch.
        let static_handler: Box<dyn FnMut(Event) + 'static> = Box::new(event_handle);
        self.event_loop.replace(Some(static_handler));
        HAS_EVENT.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// Register back press interceptor. Return `true` to intercept back action, `false` to pass through.
    pub fn on_back_press_intercept<F: FnMut() -> bool + 'static>(&self, interceptor: F) {
        self.back_press_interceptor
            .replace(Some(Box::new(interceptor)));
    }

    /// Get back press interceptor result
    /// Returns true to intercept back press, false to pass through
    pub fn get_back_press_interceptor(&self) -> bool {
        self.back_press_interceptor
            .borrow_mut()
            .as_mut()
            .map(|h| h())
            .unwrap_or(true)
    }
}

impl Default for OpenHarmonyApp {
    fn default() -> Self {
        Self::new()
    }
}

// SAFETY: `OpenHarmonyApp` is logically main-thread-affine. The `!Send`/`!Sync`
// auto-derivation comes solely from `OpenHarmonyAppInner`'s native handle fields
// (`raw_window: Option<RawWindow>`, `xcomponent: Option<XComponent>`) and
// `ime: Arc<RefCell<Option<IME>>>`. Soundness invariants upheld:
//
// 1. The `OpenHarmonyApp` is wrapped in an `Arc`; clones may be moved to and
//    shared across threads, but the native handle fields are only ever
//    dereferenced on the NAPI main thread (where the XComponent/surface
//    callbacks and IME are valid).
// 2. Worker threads that resolve async bridge commands are marshalled back to
//    the main thread via TSFN callbacks; `get_main_thread_env()` is a
//    thread-local that returns `None` off the main thread, so worker contexts
//    never touch native handles directly.
// 3. All interior mutability is provided by `Arc<RwLock>`/`Arc<RefCell>`/
//    `Arc<Mutex>` guards — there is no `&mut` aliasing of `OpenHarmonyAppInner`.
//
// This impl cannot be removed yet: `tauri/crates/tauri/src/ohos.rs:18` holds a
// `static APP: Mutex<Option<OpenHarmonyApp>>` (requires `Send`), and
// `crates/derive/src/lib.rs:85` constructs a `LazyLock<OpenHarmonyApp>` (requires
// `Send + Sync`). Fully eliminating the unsafe impl would require splitting the
// native handles out of `OpenHarmonyAppInner` into a main-thread-only /
// thread-local structure — tracked as future work.
unsafe impl Send for OpenHarmonyApp {}
unsafe impl Sync for OpenHarmonyApp {}

#[napi]
pub fn is_desktop_device() -> bool {
    cfg!(desktop)
}

// ─── Process-level globals (NAPI-entry-point state) ─────────────────────────────
// PROCESS-LEVEL SINGLE-SESSION ASSUMPTION (issue #87 major-9): every static in
// this section is written by a `#[napi]` free function — an entry point with no
// receiver, so the state must live at module scope. The NAPI writer receives no
// app handle from ArkTS, which is why these CANNOT migrate into
// `OpenHarmonyAppInner` like the want/continuation session state did. They are
// correct under a single UIAbility instance per process; under multiple
// concurrent UIAbility instances the events interleave in one shared queue.
// Do not add new statics here without an equivalent NAPI constraint.

/// Global queue for pending window close requests from ArkTS.
/// When ArkTS intercepts a close-window URL, it pushes the OHOS window ID here
/// instead of directly destroying the window. The runtime event loop drains this
/// queue and processes closes through the proper Rust lifecycle
/// (close-requested → destroyed lifecycle, defined by the embedding runtime).
static PENDING_WINDOW_CLOSES: Mutex<Vec<i32>> = Mutex::new(Vec::new());

/// NAPI function called from ArkTS to request a window close.
/// This queues the OHOS window ID for processing by the Rust event loop,
/// ensuring proper lifecycle events (close-requested, destroyed) are emitted.
///
/// Timing: ArkTS calls this synchronously before `destroyWindow()` (async).
/// The Rust event loop drains the queue at the start of the next iteration,
/// processing window IDs before the async OHOS destruction completes.
/// The Rust side only uses the ID to look up the matching window —
/// it never accesses the OHOS window object directly, so destroyed windows are safe.
#[napi]
pub fn notify_window_close(window_id: i32) {
    match PENDING_WINDOW_CLOSES.lock() {
        Ok(mut queue) => queue.push(window_id),
        Err(poisoned) => {
            log::warn!(
                "[OHOS] PENDING_WINDOW_CLOSES mutex poisoned, recovering. window_id={}",
                window_id
            );
            poisoned.into_inner().push(window_id);
        }
    }
    // Wake the embedding runtime's event loop so it drains the queue promptly.
    // Without this, a sub-window close produces no `MainEvent` to drive the next
    // iteration, so the queued close (and the downstream `CloseRequested` →
    // `Destroyed` events) would sit undrained indefinitely. The main-window
    // path wakes via `tao::EventLoopProxy::send_event` → `waker.wake()`; this
    // mirrors that for the NAPI-driven sub-window path. `OpenHarmonyWaker::new()`
    // reads the global `WAKER` live at `wake()` time (see `waker.rs`), so it is
    // safe even though `create_lifecycle_handle` may not have run yet — a no-op
    // wake leaves the close queued for a later iteration.
    OpenHarmonyWaker::new().wake();
}

/// Drain all pending window close requests.
/// Called by the runtime event loop to process queued closes.
///
/// OHOS close-window events carry the real OS window ID via this queue,
/// because the event system does not propagate window identity through the
/// normal event channel. The runtime drains this queue each iteration and
/// matches the IDs to its internal window registry.
pub fn drain_pending_window_closes() -> Vec<i32> {
    PENDING_WINDOW_CLOSES
        .lock()
        .map(|mut q| q.drain(..).collect())
        .unwrap_or_default()
}

/// ─── Cursor position tracking ─────────────────────────────────────────────
/// ArkTS `MainPage.onMouse` calls `update_cursor_position` via NAPI because the
/// NDK `DispatchMouseEvent` path does not fire while the cursor is over the
/// WebView (which covers the window). tao's `cursor_position()` reads these
/// atomics. Dropped during the pluginize refactor (restored from 5941dfb).

/// Last known cursor X position, in vp relative to the MainPage component
/// (f64 stored as u64 bits). Read through [`OpenHarmonyApp::cursor_position`].
pub(crate) static CURSOR_POSITION_X: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Last known cursor Y position, in vp relative to the MainPage component
/// (f64 stored as u64 bits). Read through [`OpenHarmonyApp::cursor_position`].
pub(crate) static CURSOR_POSITION_Y: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// NAPI function called from the ArkTS `onMouse` handler (Move/Press) to
/// update the tracked cursor position. Coordinates are MainPage-relative vp.
#[napi]
pub fn update_cursor_position(x: f64, y: f64) {
    CURSOR_POSITION_X.store(x.to_bits(), std::sync::atomic::Ordering::Relaxed);
    CURSOR_POSITION_Y.store(y.to_bits(), std::sync::atomic::Ordering::Relaxed);
}

/// Global queue for pending window status changes from ArkTS
/// (`windowStatusChange` callbacks — maximize/minimize/fullscreen/floating).
/// The runtime event loop drains this queue and feeds each (window_id, status)
/// into tao's `apply_window_status` mirror bits.
/// Ported from upstream PR#45 (fc8c3cf/a052d3f): status sync via NAPI direct call
/// (not the old ArkHelper channel), so the port is verbatim.
static PENDING_WINDOW_STATUS: Mutex<Vec<(i32, i32)>> = Mutex::new(Vec::new());

/// NAPI function called from ArkTS `windowStatusChange` callbacks to report a
/// window status change. Queues (window_id, status) for the Rust event loop.
///
/// `status` is the raw OHOS `WindowStatusType` value (transparently forwarded):
/// FULL_SCREEN=1, MAXIMIZE=2, MINIMIZE=3, FLOATING=4, SPLIT_SCREEN=5.
/// Semantic decoding happens on the tao side (`apply_window_status`); this layer
/// only transports the integer.
#[napi]
pub fn notify_window_status(window_id: i32, status: i32) {
    match PENDING_WINDOW_STATUS.lock() {
        Ok(mut queue) => queue.push((window_id, status)),
        Err(poisoned) => {
            log::warn!(
                "[OHOS] PENDING_WINDOW_STATUS mutex poisoned, recovering. window_id={} status={}",
                window_id,
                status
            );
            poisoned.into_inner().push((window_id, status));
        }
    }
}

/// Drain all pending window status changes.
/// Called by tauri-runtime-wry event loop (alongside `drain_pending_window_closes`)
/// to回灌 system window status into tao mirror bits.
pub fn drain_pending_window_status() -> Vec<(i32, i32)> {
    PENDING_WINDOW_STATUS
        .lock()
        .map(|mut q| q.drain(..).collect())
        .unwrap_or_default()
}

#[derive(Clone)]
pub struct SaveSaver<'a> {
    pub(crate) app: &'a OpenHarmonyApp,
}

impl<'a> SaveSaver<'a> {
    pub fn save(&self, state: Vec<u8>) {
        self.app.save(state);
    }
}

#[derive(Clone)]
pub struct SaveLoader<'a> {
    pub(crate) app: &'a OpenHarmonyApp,
}

impl<'a> SaveLoader<'a> {
    pub fn load(&self) -> Option<Vec<u8>> {
        self.app.load()
    }
}

// --- app-continuation source-side snapshot (onContinue save) ---

/// Source-side continuation snapshot, pre-registered by the application via
/// `setContinuationData` and read synchronously by the ArkTS `onContinue`
/// lifecycle callback when the system initiates a migration.
///
/// Peek-only: a cancelled migration must leave it intact so a retry reads the
/// same value. A fresh `set` overwrites.
pub(crate) static CONTINUATION_SNAPSHOT: Mutex<String> = Mutex::new(String::new());

/// Stores the source-side continuation snapshot (overwrite semantics).
///
/// `""` clears the snapshot (an empty snapshot makes `onContinue` refuse the
/// migration with MISMATCH). The production caller is the `plugin-continuation`
/// facade's `ContinuationClient::set_continuation_data`.
pub fn store_continue_snapshot(snapshot: &str) {
    if let Ok(mut snap) = CONTINUATION_SNAPSHOT.lock() {
        *snap = snapshot.to_string();
    } else {
        crate::error!("continuation snapshot mutex poisoned in store");
    }
}

/// Returns the source-side continuation snapshot without consuming it
/// (peek-only). Read by the ArkTS `onContinue` callback via the
/// `read_continue_snapshot` NAPI export below.
pub fn peek_continue_snapshot() -> String {
    CONTINUATION_SNAPSHOT
        .lock()
        .map(|s| s.clone())
        .unwrap_or_default()
}

/// NAPI function called from the ArkTS `onContinue` lifecycle callback to
/// synchronously read the source-side continuation snapshot (pre-registered
/// via `setContinuationData`). `onContinue` is a synchronous callback, so the
/// read must be a plain NAPI call — no Promise, no bridge round-trip. Empty
/// string means "nothing registered" (the caller refuses with MISMATCH).
#[napi]
pub fn read_continue_snapshot() -> String {
    peek_continue_snapshot()
}

/// Tests for the app-continuation global statics.
#[cfg(test)]
mod continuation_tests {
    use super::*;

    #[test]
    fn test_take_continuation_data_drains() {
        let app = OpenHarmonyApp::new();
        app.store_continuation(true, r#"{"scrollOffset":120,"route":"/article/42"}"#);
        assert_eq!(
            app.take_continuation_data(),
            r#"{"scrollOffset":120,"route":"/article/42"}"#
        );
        // Second take is empty (draining semantics).
        assert_eq!(app.take_continuation_data(), "");
        // Flag survives the data take (peek does not drain).
        assert!(app.is_continuation_restore());
    }

    #[test]
    fn test_non_continuation_launch_clears_stale_payload() {
        let app = OpenHarmonyApp::new();
        app.store_continuation(true, r#"{"stale":true}"#);
        // A plain relaunch stores isContinuation=false — must clear both.
        app.store_continuation(false, r#"{}"#);
        assert!(!app.is_continuation_restore());
        assert_eq!(app.take_continuation_data(), "");
    }

    #[test]
    fn test_is_continuation_restore_idempotent() {
        let app = OpenHarmonyApp::new();
        app.store_continuation(true, r#"{"a":1}"#);
        assert!(app.is_continuation_restore());
        assert!(app.is_continuation_restore());
        assert!(app.is_continuation_restore());
        // Data still intact after repeated peeks.
        assert_eq!(app.take_continuation_data(), r#"{"a":1}"#);
    }

    #[test]
    fn test_session_state_is_per_app_instance() {
        // Issue #87 major-9: the migrated state rides the app instance, so two
        // app handles no longer share one process-level slot.
        let app_a = OpenHarmonyApp::new();
        let app_b = OpenHarmonyApp::new();
        app_a.store_continuation(true, r#"{"app":"a"}"#);
        app_b.store_want_parameters(r#"{"app":"b"}"#);
        assert!(app_a.is_continuation_restore());
        assert!(!app_b.is_continuation_restore());
        assert_eq!(app_a.take_continuation_data(), r#"{"app":"a"}"#);
        assert_eq!(app_b.take_continuation_data(), "");
        assert_eq!(app_b.take_want_parameters(), r#"{"app":"b"}"#);
        assert_eq!(app_a.take_want_parameters(), "");
    }

    // ─── CONTINUATION_SNAPSHOT stays process-level (NAPI reader) ───
    // These tests share the one static, so serialize them explicitly.
    static SERIALIZE: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn lock() -> std::sync::MutexGuard<'static, ()> {
        SERIALIZE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[test]
    fn test_continue_snapshot_peek_does_not_drain() {
        let _guard = lock();
        store_continue_snapshot(r#"{"route":"/editor","draft":42}"#);
        // Repeated peeks (a cancelled migration retried) read the same value.
        assert_eq!(
            peek_continue_snapshot(),
            r#"{"route":"/editor","draft":42}"#
        );
        assert_eq!(
            peek_continue_snapshot(),
            r#"{"route":"/editor","draft":42}"#
        );
        // Clean up for other tests sharing the static.
        store_continue_snapshot("");
    }

    #[test]
    fn test_continue_snapshot_overwrites() {
        let _guard = lock();
        store_continue_snapshot("first");
        store_continue_snapshot("second");
        assert_eq!(peek_continue_snapshot(), "second");
        // Clean up for other tests sharing the static.
        store_continue_snapshot("");
    }

    #[test]
    fn test_continue_snapshot_empty_clears() {
        let _guard = lock();
        store_continue_snapshot("value");
        // Empty string clears (onContinue refuses with MISMATCH on empty).
        store_continue_snapshot("");
        assert_eq!(peek_continue_snapshot(), "");
    }
}

/// Tests for the want.parameters / initial want.uri session state
/// (migrated from module statics, issue #87 major-9).
#[cfg(test)]
mod want_parameters_tests {
    use super::*;

    #[test]
    fn test_want_parameters_store_take_overwrite() {
        let app = OpenHarmonyApp::new();
        app.store_want_parameters(r#"{"key":"value","num":42}"#);
        assert_eq!(app.take_want_parameters(), r#"{"key":"value","num":42}"#);

        app.store_want_parameters(r#"{"source":"widget"}"#);
        assert_eq!(app.take_want_parameters(), r#"{"source":"widget"}"#);
        assert_eq!(app.take_want_parameters(), "");

        assert_eq!(app.take_want_parameters(), "");

        app.store_want_parameters(r#"{"first":1}"#);
        app.store_want_parameters(r#"{"second":2}"#);
        assert_eq!(app.take_want_parameters(), r#"{"second":2}"#);
    }

    #[test]
    fn test_initial_want_uri_store_take() {
        let app = OpenHarmonyApp::new();
        app.store_initial_want_uri("myapp://cold-start");
        assert_eq!(app.take_initial_want_uri(), "myapp://cold-start");
        // Draining: second take is empty.
        assert_eq!(app.take_initial_want_uri(), "");
    }
}

#[cfg(test)]
mod tests {
    use super::OpenHarmonyAppInner;
    use crate::{update_cursor_position, AvoidArea, AvoidAreaType, CURSOR_POSITION_X, CURSOR_POSITION_Y, Rect};

    #[test]
    fn render_owner_rejects_overlap_and_ignores_stale_surface_callbacks() {
        let mut inner = OpenHarmonyAppInner::new();
        inner.claim_render_owner("owner-a").unwrap();
        assert!(inner.claim_render_owner("owner-b").is_err());
        assert!(!inner.activate_surface("owner-b", None, Rect::default()));
        assert!(inner.activate_surface("owner-a", None, Rect::default()));
        assert_eq!(inner.release_render_owner("owner-b"), None);
        assert_eq!(inner.release_render_owner("owner-a"), Some(true));

        inner.claim_render_owner("owner-b").unwrap();
        assert!(inner.activate_surface("owner-b", None, Rect::default()));
        assert!(!inner.deactivate_surface("owner-a"));
        assert_eq!(inner.release_render_owner("owner-a"), None);
        assert!(inner.owns_render("owner-b"));
        assert!(inner.surface_active);
    }

    #[test]
    fn save_then_load_round_trips() {
        // Issue #87 major-3 regression: load() used to always return None because
        // save_state was never set true by save().
        let mut inner = OpenHarmonyAppInner::new();
        assert_eq!(inner.load(), None);
        inner.save(vec![1, 2, 3]);
        assert_eq!(inner.load(), Some(vec![1, 2, 3]));
        // load is peek-only: repeated loads return the same bytes.
        assert_eq!(inner.load(), Some(vec![1, 2, 3]));
        inner.save(vec![4]);
        assert_eq!(inner.load(), Some(vec![4]));
    }

    #[test]
    fn surface_recreation_keeps_the_same_render_owner() {
        let mut inner = OpenHarmonyAppInner::new();
        inner.claim_render_owner("owner").unwrap();
        assert!(inner.activate_surface("owner", None, Rect::default()));
        assert!(inner.deactivate_surface("owner"));
        assert!(inner.owns_render("owner"));
        assert!(inner.activate_surface("owner", None, Rect::default()));
        assert_eq!(inner.release_render_owner("owner"), Some(true));
    }

    #[test]
    fn releasing_a_component_clears_its_window_scoped_cache() {
        let mut inner = OpenHarmonyAppInner::new();
        inner.claim_render_owner("owner").unwrap();
        // Per-window rect cache is keyed by windowId; 0 = main window. The main window's
        // surface is torn down by release_render_owner, so key 0 must be cleared by it.
        inner.window_rects.insert(
            0,
            Rect {
                top: 1,
                left: 2,
                width: 3,
                height: 4,
            },
        );
        inner
            .avoid_areas
            .insert(AvoidAreaType::Keyboard, AvoidArea::default());

        assert_eq!(inner.release_render_owner("owner"), Some(false));
        // release_render_owner clears key 0 (main window); sub-window rects would persist
        // until their own destruction path runs. Assert key 0 is gone.
        assert!(inner.window_rects.get(&0).is_none());
        assert!(inner.avoid_areas.is_empty());
    }

    #[test]
    fn decor_height_latches_only_plausible_surface_diffs() {
        let mut inner = OpenHarmonyAppInner::new();
        inner.claim_render_owner("owner").unwrap();
        inner.window_rects.insert(
            0,
            Rect {
                top: 0,
                left: 0,
                width: 2090,
                height: 1394,
            },
        );
        // Surface event: content 146px shorter than the window → latch 146.
        assert!(inner.activate_surface(
            "owner",
            None,
            Rect {
                top: 0,
                left: 0,
                width: 2090,
                height: 1248,
            }
        ));
        assert_eq!(inner.decor_height, 146);

        // Garbage diffs (surface mid-relayout while the WM rect already moved, or
        // vice versa) are rejected — the cache keeps the last plausible value.
        assert!(inner.update_surface_rect(
            "owner",
            Rect {
                top: 0,
                left: 0,
                width: 2090,
                height: 570,
            }
        ));
        assert_eq!(inner.decor_height, 146, "824px diff must be rejected");
        assert!(inner.update_surface_rect(
            "owner",
            Rect {
                top: 0,
                left: 0,
                width: 2090,
                height: 1468,
            }
        ));
        assert_eq!(inner.decor_height, 146, "negative diff must be rejected");

        // Decorations hidden (fullscreen / setDecorations(false)): surface fills
        // the window exactly → latch 0.
        assert!(inner.update_surface_rect(
            "owner",
            Rect {
                top: 0,
                left: 0,
                width: 2090,
                height: 1394,
            }
        ));
        assert_eq!(inner.decor_height, 0);

        // No main-window rect yet (before the first windowRectChange): the latch
        // is a no-op and keeps the previous value.
        inner.window_rects.remove(&0);
        assert!(inner.update_surface_rect(
            "owner",
            Rect {
                top: 0,
                left: 0,
                width: 2090,
                height: 1248,
            }
        ));
        assert_eq!(inner.decor_height, 0);
    }

    #[test]
    fn update_cursor_position_stores_vp_coordinates() {
        use std::sync::atomic::Ordering;
        update_cursor_position(10.5, 20.25);
        assert_eq!(
            f64::from_bits(CURSOR_POSITION_X.load(Ordering::Relaxed)),
            10.5
        );
        assert_eq!(
            f64::from_bits(CURSOR_POSITION_Y.load(Ordering::Relaxed)),
            20.25
        );
    }

    #[test]
    fn decor_change_callbacks_fire_only_on_real_changes() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::{Arc, Mutex};
        let mut inner = OpenHarmonyAppInner::new();
        inner.claim_render_owner("owner").unwrap();
        inner.window_rects.insert(
            0,
            Rect {
                top: 0,
                left: 0,
                width: 2090,
                height: 1394,
            },
        );

        let seen: Arc<Mutex<Vec<i32>>> = Arc::new(Mutex::new(vec![]));
        // Listener A: stays registered, records every value.
        let calls_a = Arc::new(AtomicUsize::new(0));
        let seen_a = seen.clone();
        let a = {
            let calls_a = calls_a.clone();
            Arc::new(move |decor: i32| -> bool {
                calls_a.fetch_add(1, Ordering::SeqCst);
                seen_a.lock().unwrap().push(decor);
                true
            })
        };
        // Listener B: one-shot — removes itself after the first fire.
        let calls_b = Arc::new(AtomicUsize::new(0));
        let seen_b = seen.clone();
        let b = {
            let calls_b = calls_b.clone();
            Arc::new(move |decor: i32| -> bool {
                calls_b.fetch_add(1, Ordering::SeqCst);
                seen_b.lock().unwrap().push(decor);
                false
            })
        };
        inner.decor_change_callbacks.push((0, a));
        inner.decor_change_callbacks.push((1, b));
        inner.next_decor_cb_id = 2;

        // Latch 146 → both listeners fire once with the new value.
        assert!(inner.activate_surface(
            "owner",
            None,
            Rect {
                top: 0,
                left: 0,
                width: 2090,
                height: 1248
            },
        ));
        assert_eq!(inner.decor_height, 146);
        assert_eq!(calls_a.load(Ordering::SeqCst), 1);
        assert_eq!(calls_b.load(Ordering::SeqCst), 1);

        // Same value again (surface rect re-delivered with the same diff): no
        // listener fires, one-shot B is already gone.
        assert!(inner.update_surface_rect(
            "owner",
            Rect {
                top: 0,
                left: 0,
                width: 2090,
                height: 1248
            },
        ));
        assert_eq!(calls_a.load(Ordering::SeqCst), 1);
        assert_eq!(calls_b.load(Ordering::SeqCst), 1);

        // Transient garbage (824px diff): rejected, no notification.
        assert!(inner.update_surface_rect(
            "owner",
            Rect {
                top: 0,
                left: 0,
                width: 2090,
                height: 570
            },
        ));
        assert_eq!(calls_a.load(Ordering::SeqCst), 1);

        // Real change (decorations hidden → 0): only A remains and fires.
        assert!(inner.update_surface_rect(
            "owner",
            Rect {
                top: 0,
                left: 0,
                width: 2090,
                height: 1394
            },
        ));
        assert_eq!(inner.decor_height, 0);
        assert_eq!(calls_a.load(Ordering::SeqCst), 2);
        assert_eq!(calls_b.load(Ordering::SeqCst), 1);
        assert_eq!(*seen.lock().unwrap(), vec![146, 146, 0]);
        assert_eq!(
            inner.decor_change_callbacks.len(),
            1,
            "one-shot listener must be removed"
        );
    }
}
