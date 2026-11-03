use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    fmt::Debug,
    sync::{atomic::AtomicI64, Arc, LazyLock, Mutex, RwLock},
};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Object, Env, Error, Result};
use ohos_arkui_binding::XComponent;
use ohos_display_binding::{
    default_display_height, default_display_refresh_rate, default_display_scaled_density,
    default_display_width,
};
use ohos_ime_binding::IME;
use ohos_xcomponent_binding::{KeyEventData, RawWindow};

use crate::{
    bridge::MainThreadBridgeEndpoint, AvoidArea, AvoidAreaType, BridgeMainThread,
    BridgeMainThreadEvent, BridgePlugin, BridgePluginDeclaration, BridgePluginRegistry,
    BridgeRuntime, Configuration, Event, InputEvent, MainThreadScheduler, OpenHarmonyWaker,
    PluginLifecycleEvent, Rect, WakerSlot,
};

static ID: AtomicI64 = AtomicI64::new(0);

#[napi(object)]
#[derive(Clone, Debug, Default)]
/// Initialization context pushed by the ArkTS entry during `openharmony()`.
pub struct AbilityInitContext {
    /// Ability-scoped base directory (ArkTS `context.filesDir` domain).
    pub base_path: Option<String>,
    /// Preferences directory for key-value stores (ArkTS `preferences` domain).
    pub pref_path: Option<String>,
    /// Comma-separated preferred locale list from the system.
    pub preferred_locales: Option<String>,
    /// HAP module name the ability belongs to.
    pub module_name: Option<String>,
    /// OpenHarmony SDK API level of the running device.
    pub sdk_api_version: Option<i32>,
    /// HarmonyOS distribution API version (`M*10000 + S*100 + F`).
    #[napi(js_name = "distributionOSApiVersion")]
    pub distribution_api_version: Option<i32>,
}

impl AbilityInitContext {
    /// Decodes the init context from the ArkTS options object; missing keys
    /// yield `None` fields.
    ///
    /// # Errors
    /// Returns an error when a present property cannot be read as its expected type.
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
/// Per-process shared application state (the inner half of `OpenHarmonyApp`).
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
    /// Per-window rect cache keyed by windowId (0 = primary main window, >0 =
    /// sub-window or spawned UIAbility instance).
    /// Written by the `window_rect_change` lifecycle closure (lifecycle.rs) from ArkTS
    /// windowRectChange callbacks; read by tao's inner_size/outer_position/etc via
    /// `window_rect_for(window_id)`. See design.md D1/D4 (openspec change
    /// p1-window-state-per-window-rect).
    pub(crate) window_rects: HashMap<i64, Rect>,
    /// Per-window drawable (content-area) rect, physical px, pushed by the ArkTS
    /// `windowRectChange` handlers alongside the WM rect (issue Eulogizethesun/
    /// tauri#97). Source: `win.getWindowProperties().drawableRect` -- the system's
    /// own inner-rect snapshot (left/top relative to the window, size = drawable
    /// area), read synchronously inside the event handler so the two rects in one
    /// wrap can never tear. This replaced the former `decor_height` latched
    /// window-rect - content-rect diff, whose async-update races produced garbage
    /// decor (observed 824/770/292 instead of the real 146) and compounded
    /// through save/restore cycles into the shrinking-window bug. Consumers read
    /// it through `inner_rect_for(window_id)` -- never hand-roll the conversion.
    pub(crate) inner_rects: HashMap<i64, Rect>,
    pub(crate) avoid_areas: HashMap<AvoidAreaType, AvoidArea>,
    pub(crate) init_context: AbilityInitContext,
    // --- Session state (migrated from module-level statics, issue #87 major-9) ---
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
    /// Creates a zero-initialized inner state with a fresh app id.
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
            inner_rects: HashMap::new(),
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
        // gates on a save_state that is never set and always returns None --
        // the write side (ArkTS onSaveState -> Event::SaveState -> app.save)
        // was live while the read side silently produced nothing.
        self.save_state = true;
    }

    /// Returns the latest device configuration snapshot.
    pub fn config(&self) -> Configuration {
        self.configuration.clone()
    }

    /// Sets the XComponent frame rate range (min/max/expected FPS).
    ///
    /// No-op when no XComponent is mounted; failures are logged, not fatal.
    pub fn set_frame_rate(&self, min: i32, max: i32, expected: i32) {
        if let Some(xcomponent) = self.xcomponent.as_ref() {
            // Callable from embedding apps; a failure here must not abort the
            // process (issue #87 minor-2 -- this used to .expect).
            if let Err(e) = xcomponent
                .native_xcomponent()
                .set_frame_rate(min, max, expected)
            {
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

    fn activate_surface(&mut self, owner: &str, raw_window: Option<RawWindow>, rect: Rect) -> bool {
        if !self.owns_render(owner) || self.surface_active {
            return false;
        }
        self.raw_window = raw_window;
        self.rect = rect;
        self.surface_active = true;
        true
    }

    fn update_surface_rect(&mut self, owner: &str, rect: Rect) -> bool {
        if !self.owns_render(owner) || !self.surface_active {
            return false;
        }
        self.rect = rect;
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
        // Clear only the main-window (key 0) rects: release_render_owner tears down the
        // main window's DefaultXComponent render surface. Two families share the
        // key >0 space, with different lifecycles:
        // - Spawned UIAbility instances (NativeAbility onCreate reads a non-zero
        //   tauri_window_id from want.parameters) ARE cleaned up: their
        //   onAbilityDestroy path reaches unregister_ui_ability_state, which
        //   removes this id's entries from window_rects and inner_rects.
        // - True sub-window entries (key >0, WindowKind.SubWindow)
        //   persist: no destroy-notification path exists for them in
        //   this registry. The ArkTS side does notify the tao side
        //   (`notify_window_close` -> the downstream runtime's
        //   `Destroyed`), but that path has no hook into this
        //   registry's rect cleanup, so these entries persist. That is
        //   the known cross-repo limitation; the stale entries stay
        //   until the owning module's host is disposed.
        // NOTE: deactivate_surface intentionally does NOT reset either rect table
        // (neither window_rects nor inner_rects). That preserves the asymmetric
        // teardown semantics: surface deactivation clears no entries - the rect
        // tables are emptied only along their own lifecycles. The main-window
        // (id 0) entries are cleared by the full release below (the two
        // remove(&0) lines), the spawned UIAbility id entries by
        // unregister_ui_ability_state (see the bullet above), and the true
        // sub-window entries persist (the disclosed limitation noted above).
        self.window_rects.remove(&0);
        self.inner_rects.remove(&0);
        self.avoid_areas.clear();
        Some(surface_was_active)
    }

    /// Returns the primary window's content (safe-area-adjusted) rect.
    pub fn content_rect(&self) -> Rect {
        self.rect
    }

    /// Per-window rect lookup. Returns Rect::default() for an unregistered window id
    /// (e.g. before the first windowRectChange callback fires) -- same fallback semantics
    /// as the old single-field window_rect (design.md D4).
    pub fn window_rect_for(&self, window_id: i64) -> Rect {
        self.window_rects
            .get(&window_id)
            .copied()
            .unwrap_or_default()
    }

    /// Per-window outer-rect setter. Reached through `set_window_rects`
    /// (pair-in/pair-out with the drawable snapshot, review R14); kept public
    /// for direct snapshot manipulation in tests.
    pub fn set_window_rect(&mut self, window_id: i64, rect: Rect) {
        self.window_rects.insert(window_id, rect);
    }

    /// Per-window drawable-rect setter (issue Eulogizethesun/tauri#97). Called by
    /// the same `window_rect_change` lifecycle closure with the `drawable` field
    /// of the ArkTS wrap (`getWindowProperties().drawableRect`, pushed whenever
    /// the system reports a rect change). A missing/failed read never reaches
    /// this setter -- see `set_window_rects` for the pair-in/pair-out contract.
    pub fn set_inner_rect(&mut self, window_id: i64, rect: Rect) {
        self.inner_rects.insert(window_id, rect);
    }

    /// Store one rect-change event's outer AND drawable rects under the single
    /// `&mut self` borrow the caller already holds (issue Eulogizethesun/tauri#97
    /// review: two separate lock acquisitions could let a concurrent
    /// `inner_rect_for` read compose a NEW outer with a STALE/absent drawable).
    ///
    /// `drawable = None` (the wrap's drawableRect read failed -- see
    /// `set_inner_rect`) skips the update entirely: the previous outer AND
    /// drawable snapshots BOTH stay (pair-in/pair-out, review R14). Storing the
    /// new outer alone would let `inner_rect_for` compose a new origin with a
    /// stale offset/size (torn inner rect: wrong position after a decor change,
    /// stale size after a resize) until the next readable event. Skipping both
    /// keeps the pair consistently at the last readable event instead.
    pub fn set_window_rects(&mut self, window_id: i64, outer: Rect, drawable: Option<Rect>) {
        if let Some(rect) = drawable {
            self.set_window_rect(window_id, outer);
            self.set_inner_rect(window_id, rect);
        }
    }

    /// Inner (content-area) rect for the given window, physical px. Composes the
    /// WM rect with the pushed drawable snapshot -- see
    /// [`OpenHarmonyApp::inner_rect_for`] (the public wrapper) for the full
    /// semantics/fallback contract.
    pub fn inner_rect_for(&self, window_id: i64) -> Rect {
        let window = self.window_rect_for(window_id);
        match self.inner_rects.get(&window_id) {
            Some(drawable) => Rect {
                left: window.left + drawable.left,
                top: window.top + drawable.top,
                width: drawable.width,
                height: drawable.height,
            },
            None => window,
        }
    }

    /// Returns the latest avoid area of the given type, if reported.
    pub fn avoid_area(&self, area_type: AvoidAreaType) -> Option<AvoidArea> {
        self.avoid_areas.get(&area_type).copied()
    }

    /// Returns a snapshot of all reported avoid areas by type.
    pub fn avoid_areas(&self) -> HashMap<AvoidAreaType, AvoidArea> {
        self.avoid_areas.clone()
    }

    /// Returns the raw native window handle, if the surface is mounted.
    pub fn native_window(&self) -> Option<RawWindow> {
        self.raw_window
    }

    /// Returns the default display's scaled density (font scale basis).
    pub fn scale(&self) -> f32 {
        default_display_scaled_density()
    }

    /// Physical dimensions of the default display, in pixels.
    ///
    /// This is the real screen size -- as opposed to `content_rect()`/`window_rect_for()`,
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

    /// Returns the init context pushed by the ArkTS entry.
    pub fn init_context(&self) -> AbilityInitContext {
        self.init_context.clone()
    }

    /// Overwrites the init context (ArkTS entry may refresh it during setup).
    pub fn set_init_context(&mut self, context: AbilityInitContext) {
        self.init_context = context;
    }

    // --- Session-state accessors (issue #87 major-9; migrated from module statics) ---

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
    /// through verbatim -- the wantParam schema is an application-level contract).
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

/// Cloneable handle to one NativeAbility/module session's application state.
///
/// Clones share the same inner state (compared by `Arc` pointer identity);
/// this is the primary facade embedding apps use (`app.updater()`,
/// `app.bridge()`, `app.node()`, ...).
#[derive(Clone)]
pub struct OpenHarmonyApp {
    pub(crate) inner: Arc<RwLock<OpenHarmonyAppInner>>,
    pub(crate) event_loop: EventLoop,
    /// Per-app latch replacing the old process-global `HAS_EVENT` (design.md
    /// D10, openspec multi-uiability-windows): `run_loop` installs the event
    /// handler at most once per app. Shared through `Arc` so every clone of
    /// the app observes the same latch.
    pub(crate) event_loop_installed: Arc<Cell<bool>>,
    /// Per-app event-loop waker slot (design.md D10): populated by
    /// `create_lifecycle_handle`, read live by every `OpenHarmonyWaker` clone
    /// (see `waker.rs` for the live-read rationale).
    pub(crate) waker: WakerSlot,
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
    /// Creates a fresh app handle with no session state attached yet.
    pub fn new() -> Self {
        Self {
            #[allow(clippy::arc_with_non_send_sync)]
            inner: Arc::new(RwLock::new(OpenHarmonyAppInner::new())),
            #[allow(clippy::arc_with_non_send_sync)]
            event_loop: Arc::new(RefCell::new(None)),
            event_loop_installed: Arc::new(Cell::new(false)),
            waker: Arc::new(RwLock::new(None)),
            #[allow(clippy::arc_with_non_send_sync)]
            back_press_interceptor: Arc::new(RefCell::new(None)),
            #[allow(clippy::arc_with_non_send_sync)]
            ime: Arc::new(RefCell::new(None)),
            bridge_session: Arc::new(RwLock::new(None)),
            bridge_plugins: Arc::new(BridgePluginRegistry::default()),
            is_keyboard_show: Arc::new(Mutex::new(false)),
        }
    }

    /// Stores the app state saved via the ArkTS `onSaveState` chain.
    pub fn save(&self, state: Vec<u8>) {
        self.inner.write().unwrap().save(state);
    }

    /// Loads the previously saved app state (peek-only; `None` before first save).
    pub fn load(&self) -> Option<Vec<u8>> {
        self.inner.read().unwrap().load()
    }

    /// Sets the XComponent frame rate range (min/max/expected FPS).
    pub fn set_frame_rate(&self, min: i32, max: i32, expected: i32) {
        self.inner
            .read()
            .unwrap()
            .set_frame_rate(min, max, expected);
    }

    /// Overwrites the init context pushed by the ArkTS entry (test hook).
    #[doc(hidden)]
    pub fn set_init_context(&self, context: AbilityInitContext) {
        self.inner.write().unwrap().set_init_context(context);
    }

    /// Returns the init context pushed by the ArkTS entry.
    pub fn init_context(&self) -> AbilityInitContext {
        self.inner.read().unwrap().init_context()
    }

    /// Returns the HAP module name, when the ArkTS entry provided one.
    pub fn module_name(&self) -> Option<String> {
        self.init_context().module_name
    }

    /// Returns the ability-scoped base directory, when provided.
    pub fn base_path(&self) -> Option<String> {
        self.init_context().base_path
    }

    /// Returns the preferences directory, when provided.
    pub fn pref_path(&self) -> Option<String> {
        self.init_context().pref_path
    }

    /// Returns the system's preferred locale list, when provided.
    pub fn preferred_locales(&self) -> Option<String> {
        self.init_context().preferred_locales
    }

    // --- Session-state facades (issue #87 major-9) ---
    // Mirror the old module-static free functions (lock-poisoning degrades to a
    // default instead of unwinding; the NAPI/lifecycle writers call these from
    // inside already-tolerant callback contexts).

    /// Stores the latest `want.parameters` JSON from `onNewWant`.
    /// Test-only facade: production code goes through the module-level
    /// window-id-keyed free functions (same names, taking a leading
    /// `window_id`); kept for unit tests.
    pub fn store_want_parameters(&self, json: &str) {
        if let Ok(mut inner) = self.inner.write() {
            inner.store_want_parameters(json);
        }
    }

    /// Takes the latest `want.parameters` JSON (draining the stored value).
    /// Test-only facade: production code goes through the window-id-keyed free
    /// functions (`take_want_parameters_for_window` and siblings); kept for
    /// unit tests.
    pub fn take_want_parameters(&self) -> String {
        self.inner
            .write()
            .ok()
            .map(|mut inner| inner.take_want_parameters())
            .unwrap_or_default()
    }

    /// Stores the initial `want.uri` from `onCreate` (cold start).
    /// Test-only facade: production code goes through the module-level
    /// window-id-keyed free functions (same names, taking a leading
    /// `window_id`); kept for unit tests.
    pub fn store_initial_want_uri(&self, uri: &str) {
        if let Ok(mut inner) = self.inner.write() {
            inner.store_initial_want_uri(uri);
        }
    }

    /// Takes the initial `want.uri` from `onCreate` (draining the stored value).
    /// Test-only facade: production code goes through the window-id-keyed free
    /// functions (`take_initial_want_uri_for_window` and siblings); kept for
    /// unit tests.
    pub fn take_initial_want_uri(&self) -> String {
        self.inner
            .write()
            .ok()
            .map(|mut inner| inner.take_initial_want_uri())
            .unwrap_or_default()
    }

    /// Stores the continuation signal from a lifecycle callback
    /// (see `OpenHarmonyAppInner::store_continuation` for the clear-on-false contract).
    /// Test-only facade: production code goes through the module-level free
    /// function `store_continuation` (its doc is the public entry point, and
    /// external tests -- e.g. plugin-continuation -- must call it instead of
    /// this app-instance store); kept for unit tests.
    pub fn store_continuation(&self, is_continuation: bool, parameters_json: &str) {
        if let Ok(mut inner) = self.inner.write() {
            inner.store_continuation(is_continuation, parameters_json);
        }
    }

    /// Returns whether the current launch is an app-continuation restore.
    /// Peek-only. Test-only facade: production code goes through the
    /// module-level free functions (`is_continuation_restore` and siblings);
    /// kept for unit tests.
    pub fn is_continuation_restore(&self) -> bool {
        self.inner
            .read()
            .ok()
            .map(|inner| inner.is_continuation_restore())
            .unwrap_or(false)
    }

    /// Takes the continuation payload JSON (draining the stored value).
    /// Test-only facade: production code goes through the module-level free
    /// functions (`take_continuation_data` and siblings); kept for unit tests.
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

    /// Dispatches a synchronous ArkTS platform callback into the bridge
    /// main-thread endpoint (generated-code port; see `on_bridge_sync_event`).
    #[doc(hidden)]
    pub fn dispatch_bridge_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<napi_ohos::bindgen_prelude::Unknown<'env>> {
        self.bridge_plugins.dispatch_main_thread_event(event)
    }

    /// Forwards an ArkTS-only lifecycle transition (UI-context readiness) to
    /// the registered plugins (generated-code port; see `on_bridge_lifecycle`).
    #[doc(hidden)]
    pub fn dispatch_plugin_lifecycle(&self, event: PluginLifecycleEvent) -> Result<()> {
        self.bridge_plugins.dispatch_lifecycle(event)
    }

    /// Tears down every per-window registry entry for a destroyed UIAbility
    /// instance (design.md D13): the D7 handshake entry, the D9 want-URI
    /// storage, the label -> id registry and the cached window rects. Called
    /// from the `on_ability_destroy` lifecycle callback after
    /// `AbilityDestroyed` has been dispatched to bridge plugins (which drop
    /// the session partition themselves).
    ///
    /// Sub-windows never reach this path -- they are torn down through
    /// `notify_window_close` -> the downstream runtime's `Destroyed` --
    /// and window ids are monotonic (never reused), so removing by id
    /// cannot touch a live window. The primary (id 0) also passes
    /// through on process exit: harmless, its handshake entry never
    /// existed and `release_render_owner` already cleared its rect.
    ///
    /// The rect teardown is symmetric with `set_window_rects`' pair-in: the
    /// outer (`window_rects`) and drawable (`inner_rects`) snapshots for this
    /// id are removed together, and because ids are monotonic and never
    /// reused the paired removal cannot touch a live window.
    pub fn unregister_ui_ability_state(&self, window_id: i64) {
        let pending_len = crate::window::unregister_pending_ui_ability(window_id);
        remove_want_uri_storage(window_id);
        unregister_window_label(window_id);
        if let Ok(mut inner) = self.inner.write() {
            inner.window_rects.remove(&window_id);
            inner.inner_rects.remove(&window_id);
        }
        // Registry-size observability for the teardown path: log AFTER the
        // mutations and outside any lock (lock discipline -- see
        // set_ui_ability_waker). Debug level: per-window teardown is routine.
        let want_params_len = WANT_PARAMETERS.lock().map(|m| m.len()).unwrap_or(0);
        let want_uris_len = INITIAL_WANT_URI.lock().map(|m| m.len()).unwrap_or(0);
        crate::debug!(
            "unregister_ui_ability_state id={} — pending={} want_params={} want_uris={}",
            window_id,
            pending_len,
            want_params_len,
            want_uris_len
        );
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

    /// Shows the soft keyboard for the focused text input.
    ///
    /// Guards against re-entrant invocation with the `is_keyboard_show`
    /// mutex and is a no-op when no IME has been attached to this module
    /// (no `attach_ime` call from the generated entry or tests).
    pub fn show_keyboard(&self) {
        let _guard = self
            .is_keyboard_show
            .lock()
            .expect("Failed to lock is_keyboard_show");
        if let Some(ime) = self.ime.borrow().as_ref() {
            ime.show_keyboard();
        }
    }
    /// Hides the soft keyboard.
    ///
    /// Same re-entrancy guard and no-IME no-op behavior as
    /// [`OpenHarmonyApp::show_keyboard`].
    pub fn hide_keyboard(&self) {
        let _guard = self
            .is_keyboard_show
            .lock()
            .expect("Failed to lock is_keyboard_show");
        if let Some(ime) = self.ime.borrow().as_ref() {
            ime.hide_keyboard();
        }
    }
    /// Creates a [`OpenHarmonyWaker`] bound to this app's waker slot.
    ///
    /// The slot lives on the app wrapper rather than the inner state so
    /// that `wake()` always reads the *current* TSFN (live-read rationale
    /// in `waker.rs`); the returned handle stays valid across UIAbility
    /// restarts that swap the underlying `ThreadsafeFunction`.
    pub fn create_waker(&self) -> OpenHarmonyWaker {
        // The waker slot lives on the app (wrapper), not the inner state --
        // see `waker.rs` for the live-read rationale.
        OpenHarmonyWaker::new(self.waker.clone())
    }
    /// Returns the current UI configuration snapshot (color mode, direction,
    /// screen density, font scale).
    ///
    /// The snapshot is refreshed by the ArkTS `onConfigurationUpdate`
    /// callback; callers see the values from the most recent callback.
    pub fn config(&self) -> Configuration {
        self.inner.read().unwrap().config()
    }
    /// Returns the content rect of the primary window in physical px.
    ///
    /// Empty (`0,0,0,0`) until the first `windowRectChange` callback fires;
    /// per-window variants: [`OpenHarmonyApp::window_rect_for`].
    pub fn content_rect(&self) -> Rect {
        self.inner.read().unwrap().content_rect()
    }

    /// Per-window rect lookup (key = windowId; 0 = main window). See
    /// OpenHarmonyAppInner::window_rect_for. Used by tao's inner_size/outer_position/etc
    /// so each window reads its own rect instead of sharing a single field.
    pub fn window_rect_for(&self, window_id: i64) -> Rect {
        self.inner.read().unwrap().window_rect_for(window_id)
    }

    /// Store one rect-change event's outer rect AND drawable-rect snapshot for a
    /// window under ONE RwLock write acquisition (issue Eulogizethesun/tauri#97)
    /// -- the pair from a single event can never be observed torn by a concurrent
    /// `inner_rect_for`. `drawable = None` (the wrap's drawableRect read failed)
    /// skips both writes: the previous outer AND drawable snapshots stay
    /// (pair-in/pair-out, review R14). Called from the `window_rect_change`
    /// lifecycle closure with the windowId parsed from the ArkTS-wrapped options.
    pub fn set_window_rects(&self, window_id: i64, outer: Rect, drawable: Option<Rect>) {
        self.inner
            .write()
            .unwrap()
            .set_window_rects(window_id, outer, drawable);
    }

    /// Last known cursor position in physical px (screen-global vp fed by the
    /// ArkTS `onMouse` handlers x current scale -- ohos-cursor-passthrough D1).
    /// Issue #87 major-10: the f64-bit-packed `CURSOR_POSITION_X/Y` statics are
    /// an implementation detail -- consumers read them through this method
    /// instead of unpacking the bits by hand.
    ///
    /// Untracked fail-safe contract (ohos-cursor-passthrough D3; spec
    /// "cold start, never fed -> reject"): when NO feed was ever recorded the
    /// read is the typed
    /// [`CursorUntracked`] error -- NOT the (0,0) zero-init sentinel, which is
    /// indistinguishable from a real screen-origin feed and would let a
    /// hit-test "succeed" on garbage. `Ok` therefore always equals a real fed
    /// screen-global coordinate. tao maps the error to
    /// `ExternalError::NotSupported`; runtime-wry turns that into
    /// `FailedToGetCursorPosition`, so the tauri command -- and the JS
    /// `cursorPosition()` promise -- reject.
    pub fn cursor_position(&self) -> std::result::Result<(f64, f64), CursorUntracked> {
        // Memory-order discipline (task 2.1, mandatory): the Acquire load of
        // EVER_FED must precede the X/Y loads. Paired with the feed-side
        // ordering (X.store(Relaxed) -> Y.store(Relaxed) -> EVER_FED
        // .store(true, Release)) this guarantees: observing ever_fed=true
        // makes that feed's (and any earlier feed's) X/Y values visible to
        // this reader. Without it a concurrent first feed could yield
        // ever_fed=true with stale (0,0) X/Y -- returning the very sentinel
        // `Ok((0,0))` this contract removes.
        let ever_fed = EVER_FED.load(std::sync::atomic::Ordering::Acquire);
        // Explicit `std::result::Result` (same pattern as `set_cursor_grab`):
        // the napi `Result` alias in scope would wrap the error in
        // `napi::Error<CursorUntracked>` and demand an `AsRef<str>` bound --
        // this error stays a typed value for tao to map, it never crosses
        // the NAPI boundary itself.
        cursor_position_with(
            ever_fed,
            f64::from_bits(CURSOR_POSITION_X.load(std::sync::atomic::Ordering::Relaxed)),
            f64::from_bits(CURSOR_POSITION_Y.load(std::sync::atomic::Ordering::Relaxed)),
            self.scale(),
        )
    }

    /// Inner (content-area) rect for the given window, in physical px (issue
    /// Eulogizethesun/tauri#97). Composed from two system snapshots pushed by the
    /// same `windowRectChange` event -- the WM rect (outer) and the drawable rect
    /// (system-defined inner, position relative to the window) -- read under ONE lock so
    /// they can't tear. The former hand-rolled `window_rect - latched decor`
    /// conversion (and its estimate) is gone: the size/offset comes from the
    /// system's own drawableRect.
    ///
    /// Semantics:
    /// - `left/top` = window position + drawable offset (below the title bar on
    ///   decorated windows; (0,0) for sub-windows)
    /// - `width`/`height` = drawable (content) area size
    ///
    /// Fallback: the two snapshot tables are only written in pairs
    /// (`set_window_rects`, review R14) and the ArkTS side seeds them right
    /// after content load (review R13), so "outer present, drawable absent" is
    /// unreachable through the public API in production -- the `None` arm below
    /// stays as a defensive fallback for a future writer that seeds
    /// `window_rects` directly, returning the outer rect as-is (decor assumed
    /// 0). Before the first readable event both lookups return `(0,0,0,0)`. A
    /// runtime decor change that fires no windowRectChange leaves the snapshot
    /// stale until the next rect change; re-reading/re-setting inner size after
    /// such changes is the caller's responsibility (per issue #97, compensation
    /// duty belongs to the app).
    pub fn inner_rect_for(&self, window_id: i64) -> Rect {
        self.inner
            .read()
            .map(|inner| inner.inner_rect_for(window_id))
            .unwrap_or_default()
    }

    /// Outer (WM) rect for the given window, in physical px -- the raw
    /// `windowRectChange` payload; `(0,0,0,0)` before the first callback fires.
    pub fn outer_rect_for(&self, window_id: i64) -> Rect {
        self.window_rect_for(window_id)
    }

    /// Returns the latest system avoid-area snapshot for one area type.
    ///
    /// `None` before the ArkTS side has delivered any `onAvoidAreaChange`
    /// payload for `area_type`. The full map variant:
    /// [`OpenHarmonyApp::avoid_areas`].
    pub fn avoid_area(&self, area_type: AvoidAreaType) -> Option<AvoidArea> {
        self.inner.read().unwrap().avoid_area(area_type)
    }

    /// Returns the full latest avoid-area map (all known area types).
    ///
    /// Populated by ArkTS `onAvoidAreaChange` callbacks; see
    /// [`OpenHarmonyApp::avoid_area`] for the per-type accessor.
    pub fn avoid_areas(&self) -> HashMap<AvoidAreaType, AvoidArea> {
        self.inner.read().unwrap().avoid_areas()
    }
    /// Returns the raw native window handle registered by the render node.
    ///
    /// `None` before the XComponent surface is created (and after it is
    /// destroyed). The handle is only valid for use on the main thread.
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

    // -- Fault injection facade (coverage testing only) -------------------------
    //
    // Feature-gated: when `fault-injection` is off, these methods do not exist.
    // `set_fault_rule` auto-enables the registry on first call (idempotent).

    #[cfg(feature = "fault-injection")]
    pub async fn set_fault_rule(&self, rule: crate::FaultRuleWire) -> Result<()> {
        let client = self.bridge()?.client();
        // Enable the registry (idempotent -- safe to call on every set_rule).
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

    /// Installs the app-wide event loop handler and enters the loop.
    ///
    /// All UIAbility instances of one app share a single event loop by
    /// design (multi-UIAbility NG4): the first `run_loop` call wins and
    /// installs the handler; a second call on the same app logs an error
    /// and keeps the original handler (per-app latch, design.md D10 --
    /// replaces the old process-global silent no-op).
    ///
    /// The handler must be `'static` because it is stored in the
    /// `Box<dyn FnMut(Event)>` slot without lifetime erasure, so it cannot
    /// borrow from `self` or any non-`'static` data.
    pub fn run_loop<F: FnMut(Event) + 'static>(&self, event_handle: F) {
        // Per-app latch (design.md D10, openspec multi-uiability-windows --
        // replaces the old process-global HAS_EVENT silent no-op). All
        // UIAbility instances of one app share ONE event loop by design
        // (NG4): a second run_loop call means a caller mis-assumed one loop
        // per instance. Keep the first handler (the shared loop stays
        // coherent) but make the anomaly visible instead of silent.
        if self.event_loop_installed.get() {
            crate::error!(
                "run_loop called twice on the same OpenHarmonyApp — keeping the first \
                 handler (multi-UIAbility instances share one app/event loop, NG4)"
            );
            return;
        }

        // The handler is required to be `'static` (no borrows of `self` or other
        // non-'static data), so it can be stored in the `Box<dyn FnMut(Event)>`
        // slot without any lifetime erasure. The latch ensures `run_loop`
        // installs exactly one handler and the app outlives all event
        // dispatch.
        let static_handler: Box<dyn FnMut(Event) + 'static> = Box::new(event_handle);
        self.event_loop.replace(Some(static_handler));
        self.event_loop_installed.set(true);
    }

    /// Dispatch a key event into the tao event loop from the ArkTS pre-IME
    /// handler (issue Eulogizethesun/tauri#109).
    ///
    /// The NDK XComponent key callback is structurally unreachable in webview
    /// apps: the render node created by `render()` is never in the ArkUI focus
    /// chain (no `focusable(true)` -- official NAPI XComponent samples require
    /// it -- and the Web component grabs focus on load while overlaying the
    /// render surface), so `WindowEvent::KeyboardInput` never fired. ArkTS
    /// `onKeyPreIme` sees every key the web sees; this entry feeds them to
    /// the exact same `Event::Input` dispatch the NDK path uses
    /// (xcomponent.rs `on_key_event`), so tao's repeat detection, modifier
    /// tracking and keycode mapping all apply unchanged.
    pub fn dispatch_key_event(&self, data: KeyEventData) {
        if let Some(ref mut h) = *self.event_loop.borrow_mut() {
            // window_id = 0 (primary): MainPage.onKeyPreIme forwards pre-IME
            // keys only for the main window -- sub-UIAbility instances are
            // gated out upstream (no suppression shim -> double dispatch), so
            // this dispatch is always the primary's render surface.
            h(Event::Input {
                window_id: 0,
                input: InputEvent::KeyEvent(data),
            });
        }
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
//    `Arc<Mutex>` guards -- there is no `&mut` aliasing of `OpenHarmonyAppInner`.
//
// This impl cannot be removed yet: `tauri/crates/tauri/src/ohos.rs:33` holds a
// `static APP: Mutex<Option<OpenHarmonyApp>>` (requires `Send`), and
// `crates/derive/src/lib.rs:98-99` constructs a `LazyLock<OpenHarmonyApp>` (requires
// `Send + Sync`). Fully eliminating the unsafe impl would require splitting the
// native handles out of `OpenHarmonyAppInner` into a main-thread-only /
// thread-local structure -- tracked as future work.
unsafe impl Send for OpenHarmonyApp {}
unsafe impl Sync for OpenHarmonyApp {}

/// `true` when the host device is a 2-in-1 / PC-class OHOS device (as opposed
/// to a phone/tablet). The generated entry uses this to gate desktop-only
/// behaviors (e.g. tray-style window chrome); see the `#[ability]` derive.
#[napi]
pub fn is_desktop_device() -> bool {
    cfg!(desktop)
}

// --- Process-level globals (NAPI-entry-point state) -----------------------------
// PROCESS-LEVEL SINGLE-SESSION ASSUMPTION (issue #87 major-9): every static in
// this section is written by a `#[napi]` free function -- an entry point with no
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
/// (close-requested -> destroyed lifecycle, defined by the embedding runtime).
static PENDING_WINDOW_CLOSES: Mutex<Vec<i32>> = Mutex::new(Vec::new());

/// NAPI function called from ArkTS to request a window close.
/// This queues the OHOS window ID for processing by the Rust event loop,
/// ensuring proper lifecycle events (close-requested, destroyed) are emitted.
///
/// Timing: ArkTS calls this synchronously before `destroyWindow()` (async).
/// The Rust event loop drains the queue at the start of the next iteration,
/// processing window IDs before the async OHOS destruction completes.
/// The Rust side only uses the ID to look up the matching window --
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
    // iteration, so the queued close (and the downstream `CloseRequested` ->
    // `Destroyed` events) would sit undrained indefinitely. The main-window
    // path wakes via `tao::EventLoopProxy::send_event` -> `waker.wake()`; this
    // mirrors that for the NAPI-driven sub-window path. This free fn has no
    // `OpenHarmonyApp` handle (ArkTS callers only hold the native module), so
    // it goes through the process-level alias of the app's waker slot -- exact
    // under the NG4 one-app-per-process invariant (see waker.rs). A no-op
    // wake (lifecycle setup not yet run) leaves the close queued for a later
    // iteration.
    crate::waker::wake_installed_app();
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

// --- Cursor position tracking ---------------------------------------------
// ArkTS `onMouse` handlers (MainPage AND SubWindowPage -- ohos-cursor-passthrough
// D2) call `update_cursor_position` via NAPI because the NDK
// `DispatchMouseEvent` path does not fire while the cursor is over the
// WebView (which covers the window). tao's `cursor_position()` reads these
// atomics. Dropped during the pluginize refactor (restored from 5941dfb).

/// Last known cursor X position, in **screen-global vp** (f64 stored as u64
/// bits; ohos-cursor-passthrough D1 -- the fed value is the ArkUI event's
/// `displayX`/`globalDisplayX`, i.e. device-screen-frame, NOT
/// component-relative). Read through [`OpenHarmonyApp::cursor_position`].
pub(crate) static CURSOR_POSITION_X: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

/// Last known cursor Y position, in **screen-global vp** (f64 stored as u64
/// bits). Read through [`OpenHarmonyApp::cursor_position`].
pub(crate) static CURSOR_POSITION_Y: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

/// Whether ANY feed was ever recorded (ohos-cursor-passthrough D3). The
/// (0,0) zero-init of the X/Y statics is indistinguishable from a real
/// screen-origin feed, so "untracked" is carried by this flag instead: until
/// it is set, `cursor_position` fails with [`CursorUntracked`].
pub(crate) static EVER_FED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// NAPI function called from the ArkTS `onMouse` handlers (Move/Press) to
/// update the tracked cursor position. Coordinates are **screen-global vp**
/// (the event's `displayX`/`globalDisplayX` -- ohos-cursor-passthrough D1;
/// the NAPI signature is unchanged, only the value semantics were upgraded
/// from MainPage-component-relative to screen-global).
///
/// Memory-order discipline (task 2.1, mandatory): X -> Y -> EVER_FED(Release).
/// The Release store is placed AFTER the X/Y stores so a reader that
/// observes `ever_fed=true` (Acquire) also sees this feed's X/Y values --
/// without the ordering, a concurrent first feed could produce
/// `Ok((0,0))`, the exact sentinel the untracked contract removes. The X/Y
/// pair itself can still tear under concurrent feeds (new X with old Y);
/// that is a pre-existing property of the two-statics layout, the hit-test
/// tolerance absorbs it, and collapsing into a single packed atomic is the
/// documented alternative (not taken here).
#[napi]
pub fn update_cursor_position(x: f64, y: f64) {
    CURSOR_POSITION_X.store(x.to_bits(), std::sync::atomic::Ordering::Relaxed);
    CURSOR_POSITION_Y.store(y.to_bits(), std::sync::atomic::Ordering::Relaxed);
    EVER_FED.store(true, std::sync::atomic::Ordering::Release);
}

/// Typed "no feed ever recorded" error for [`OpenHarmonyApp::cursor_position`]
/// (ohos-cursor-passthrough D3). Unit-like by design: it carries no payload --
/// the only fact it encodes is "untracked" -- and tao maps it 1:1 onto
/// `ExternalError::NotSupported` (the section 1.5 error-conversion constraint: one
/// variant, no wrapping).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorUntracked;

/// Pure cursor read-out (ohos-cursor-passthrough 2.1): tracked feed ->
/// screen-global vp x scale = global physical px (the tao upstream semantic,
/// Windows `GetCursorPos`); never-fed -> typed [`CursorUntracked`] error.
/// Split from [`OpenHarmonyApp::cursor_position`] so both branches are UT-able
/// without touching the process statics (device UT constraint: OHOS UTs can
/// only exercise pure functions). `pub(crate)` -- the only cross-crate consumer
/// (tao) reads through `OpenHarmonyApp::cursor_position` and only needs
/// [`CursorUntracked`] public (audit round 1 suggestion).
pub(crate) fn cursor_position_with(
    ever_fed: bool,
    x_vp: f64,
    y_vp: f64,
    scale: f32,
) -> std::result::Result<(f64, f64), CursorUntracked> {
    if !ever_fed {
        return Err(CursorUntracked);
    }
    let s = scale as f64;
    Ok((x_vp * s, y_vp * s))
}

/// Global queue for pending window status changes from ArkTS
/// (`windowStatusChange` callbacks -- maximize/minimize/fullscreen/floating).
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
/// Called by tao's OHOS event loop (alongside `drain_pending_window_closes`)
/// to feed system window status back into tao mirror bits.
pub fn drain_pending_window_status() -> Vec<(i32, i32)> {
    PENDING_WINDOW_STATUS
        .lock()
        .map(|mut q| q.drain(..).collect())
        .unwrap_or_default()
}

/// Global queue for pending window focus transitions from ArkTS (#180(1):
/// `win.on('windowEvent')` WINDOW_ACTIVE/WINDOW_INACTIVE collection --
/// `windowFocusChange` is absent from the local SDK20 `@ohos.window.d.ets`
/// overload table, so the @since 20 `windowEvent` enum is the equivalent
/// signal). The runtime event loop drains this queue and feeds each
/// (window_id, focused) transition into tao's `LAST_FOCUSED_WINDOW_ID`
/// change-edge guard, which forwards to the existing focus paths and the
/// WindowStateMirror focused bit (p2 #173 write face).
static PENDING_WINDOW_FOCUS: Mutex<Vec<(i64, bool)>> = Mutex::new(Vec::new());

/// NAPI function called from ArkTS `windowEvent` handlers to report a window
/// focus transition (wire name `notifyWindowFocus` -- `#[napi]` camelCase,
/// mirroring `notify_window_status`). Queues (window_id, focused) for the Rust
/// event loop; de-duplication happens on the tao side (edge guard), this layer
/// only transports the raw transition.
#[napi]
pub fn notify_window_focus(window_id: i64, focused: bool) {
    match PENDING_WINDOW_FOCUS.lock() {
        Ok(mut queue) => queue.push((window_id, focused)),
        Err(poisoned) => {
            log::warn!(
                "[OHOS] PENDING_WINDOW_FOCUS mutex poisoned, recovering. window_id={} focused={}",
                window_id,
                focused
            );
            poisoned.into_inner().push((window_id, focused));
        }
    }
}

/// Drain all pending window focus transitions.
/// Called by the tao OHOS event loop (alongside `drain_pending_window_status`)
/// so sub-window focus edges reach the same mirror bits the stage path
/// uses (spec ohos-window-focus-state: both paths share one de-dup guard).
pub fn drain_pending_window_focus() -> Vec<(i64, bool)> {
    PENDING_WINDOW_FOCUS
        .lock()
        .map(|mut q| q.drain(..).collect())
        .unwrap_or_default()
}

/// Save-side handle passed with [`Event::SaveState`]; the handler stores the
/// state bytes the system should persist for this ability instance.
#[derive(Clone)]
pub struct SaveSaver<'a> {
    pub(crate) app: &'a OpenHarmonyApp,
}

impl<'a> SaveSaver<'a> {
    /// Stores the state bytes to persist for this ability instance.
    pub fn save(&self, state: Vec<u8>) {
        self.app.save(state);
    }
}

/// Load-side handle passed with [`Event::Resume`]; the handler reads the state
/// bytes persisted by a previous session (when restoring).
#[derive(Clone)]
pub struct SaveLoader<'a> {
    pub(crate) app: &'a OpenHarmonyApp,
}

impl<'a> SaveLoader<'a> {
    /// Loads the persisted state bytes, or `None` when nothing was saved.
    pub fn load(&self) -> Option<Vec<u8>> {
        self.app.load()
    }
}

// --- want.parameters storage (per UIAbility instance, design.md D9) ---

/// Latest `want.parameters` JSON per UIAbility instance, keyed by tauri window id
/// (0 = the process's first instance). `onNewWant` stores with the originating
/// instance's id so a spawned instance's deep link never overwrites the primary's.
pub(crate) static WANT_PARAMETERS: LazyLock<Mutex<HashMap<i64, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

pub(crate) fn store_want_parameters(window_id: i64, json: &str) {
    match WANT_PARAMETERS.lock() {
        Ok(mut params) => {
            params.insert(window_id, json.to_string());
        }
        Err(e) => crate::error!("WANT_PARAMETERS mutex poisoned in store: {}", e),
    }
}

/// Takes the `want.parameters` JSON stored for `window_id` (draining that entry).
///
/// Safe to call from any thread. The value is consumed (entry removed), so a
/// second call for the same instance returns `""` until the next `onNewWant`
/// stores a fresh value. Consumed by the `plugin-deep-link` facade
/// (`DeepLinkClient`).
pub fn take_want_parameters_for_window(window_id: i64) -> String {
    WANT_PARAMETERS
        .lock()
        .map(|mut p| p.remove(&window_id).unwrap_or_default())
        .unwrap_or_default()
}

/// Primary-instance (window id 0) variant of [`take_want_parameters_for_window`].
pub fn take_want_parameters() -> String {
    take_want_parameters_for_window(0)
}

// --- initial want.uri storage (per UIAbility instance, design.md D9) ---

/// Initial `want.uri` from cold-start `onCreate`, keyed by tauri window id.
pub(crate) static INITIAL_WANT_URI: LazyLock<Mutex<HashMap<i64, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

pub(crate) fn store_initial_want_uri(window_id: i64, uri: &str) {
    match INITIAL_WANT_URI.lock() {
        Ok(mut uris) => {
            uris.insert(window_id, uri.to_string());
        }
        Err(e) => crate::error!("INITIAL_WANT_URI mutex poisoned in store: {}", e),
    }
}

/// Takes the initial `want.uri` stored for `window_id` (draining that entry).
///
/// Safe to call from any thread. The value is consumed (entry removed), so a
/// second call for the same instance returns `""`. Consumed by the
/// `plugin-deep-link` facade (`DeepLinkClient`) to surface the cold-start deep
/// link of the calling window.
pub fn take_initial_want_uri_for_window(window_id: i64) -> String {
    INITIAL_WANT_URI
        .lock()
        .map(|mut u| u.remove(&window_id).unwrap_or_default())
        .unwrap_or_default()
}

/// Primary-instance (window id 0) variant of [`take_initial_want_uri_for_window`].
pub fn take_initial_want_uri() -> String {
    take_initial_want_uri_for_window(0)
}

/// Drops the want storage (both maps) for a destroyed UIAbility instance
/// (design.md D13). The lazy-take accessors above only drain on read, so an
/// instance that never queried its deep link would otherwise leak its entries.
/// Ids are never reused, so this cannot race a live instance.
fn remove_want_uri_storage(window_id: i64) {
    if let Ok(mut params) = WANT_PARAMETERS.lock() {
        params.remove(&window_id);
    }
    if let Ok(mut uris) = INITIAL_WANT_URI.lock() {
        uris.remove(&window_id);
    }
}

// --- window label -> id registry (deep-link per-instance resolution, D9) ---

/// Maps tauri window labels to their pre-allocated UIAbility window ids.
///
/// `start_ui_ability` records every label it spawns so the deep-link facade can
/// resolve a calling `Window`'s label back to its instance's want-URI storage.
/// The primary window is never inserted at runtime: `window_id_for_label`
/// resolves unknown labels to id 0 (`unwrap_or(0)`), which doubles as the
/// fallback for the un-spawned "main" label -- matching single-instance
/// behavior.
static WINDOW_ID_BY_LABEL: LazyLock<Mutex<HashMap<String, i64>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Records (or overwrites) the window id owned by `label`.
pub fn register_window_label(label: &str, window_id: i64) {
    match WINDOW_ID_BY_LABEL.lock() {
        Ok(mut labels) => {
            labels.insert(label.to_owned(), window_id);
        }
        Err(e) => crate::error!("WINDOW_ID_BY_LABEL mutex poisoned in store: {}", e),
    }
}

/// Resolves the window id previously registered for `label` (primary = 0 when
/// the label was never registered, matching single-instance behavior).
pub fn window_id_for_label(label: &str) -> i64 {
    WINDOW_ID_BY_LABEL
        .lock()
        .map(|labels| labels.get(label).copied().unwrap_or(0))
        .unwrap_or(0)
}

/// Removes the label -> id entry for a destroyed UIAbility instance (design.md
/// D13). The map is keyed by label, so scan for our id -- the registry holds at
/// most one entry per live spawned window.
///
/// Direction note (audit of the E4 plan): after removal, a late
/// `window_id_for_label` for the dead label resolves to 0 and would read the
/// primary's memo. A call arriving from a destroyed window's webview is
/// unreachable in practice, and keeping stale entries breaks the leak check.
pub fn unregister_window_label(window_id: i64) {
    if let Ok(mut labels) = WINDOW_ID_BY_LABEL.lock() {
        labels.retain(|_, id| *id != window_id);
    }
}

// --- app-continuation storage (launchReason === CONTINUATION restore) ---

/// Marks whether the current launch is an app-continuation restore.
///
/// Peek-only (never drained): queries are idempotent and can be repeated
/// without consuming the continuation payload.
pub(crate) static CONTINUATION_RESTORE: Mutex<bool> = Mutex::new(false);

/// Stores the continuation payload JSON (`want.parameters`) from a
/// continuation-restore launch (cold start `onCreate` or warm `onNewWant`).
pub(crate) static CONTINUATION_DATA: Mutex<String> = Mutex::new(String::new());

/// Stores the continuation signal from a lifecycle callback.
///
/// `is_continuation == true` writes both the flag and the payload (passed
/// through verbatim -- the wantParam schema is an application-level contract).
/// `is_continuation == false` clears both: the statics survive across Ability
/// instances, so a plain relaunch must not observe the previous session's
/// continuation payload.
///
/// Public (not `pub(crate)`) so the `plugin-continuation` crate's unit tests can
/// drive the statics; production callers are the lifecycle closures.
pub fn store_continuation(is_continuation: bool, parameters_json: &str) {
    if let (Ok(mut flag), Ok(mut data)) = (CONTINUATION_RESTORE.lock(), CONTINUATION_DATA.lock()) {
        *flag = is_continuation;
        *data = if is_continuation {
            parameters_json.to_string()
        } else {
            String::new()
        };
    } else {
        crate::error!("continuation mutex poisoned in store");
    }
}

/// Returns whether the current launch is an app-continuation restore.
///
/// Peek-only: does not consume [`take_continuation_data`], safe to call
/// repeatedly. Consumed by the `plugin-continuation` facade
/// (`ContinuationClient`).
pub fn is_continuation_restore() -> bool {
    CONTINUATION_RESTORE.lock().map(|f| *f).unwrap_or(false)
}

/// Takes the continuation payload JSON (draining the stored value).
///
/// Safe to call from any thread. The value is consumed (replaced with an empty
/// `String`), so a second call returns `""` -- empty also means the launch was
/// not a continuation restore. Consumed by the `plugin-continuation` facade
/// (`ContinuationClient`).
pub fn take_continuation_data() -> String {
    CONTINUATION_DATA
        .lock()
        .map(|mut d| std::mem::take(&mut *d))
        .unwrap_or_default()
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
/// read must be a plain NAPI call -- no Promise, no bridge round-trip. Empty
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
        // A plain relaunch stores isContinuation=false -- must clear both.
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

    // --- CONTINUATION_SNAPSHOT stays process-level (NAPI reader) ---
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

/// Tests for the per-instance WANT_PARAMETERS / INITIAL_WANT_URI maps and the
/// window label registry (design.md D9). Each test uses disjoint window ids so
/// the process-wide statics never race under the default parallel test runner.
#[cfg(test)]
mod want_parameters_tests {
    use super::*;

    #[test]
    fn test_want_parameters_store_take_overwrite() {
        store_want_parameters(0, r#"{"key":"value","num":42}"#);
        assert_eq!(
            take_want_parameters_for_window(0),
            r#"{"key":"value","num":42}"#
        );

        store_want_parameters(0, r#"{"source":"widget"}"#);
        assert_eq!(take_want_parameters_for_window(0), r#"{"source":"widget"}"#);
        assert_eq!(take_want_parameters_for_window(0), "");

        // The key-0 wrapper drains the same entry the wrapper-level callers use.
        assert_eq!(take_want_parameters(), "");

        store_want_parameters(0, r#"{"first":1}"#);
        store_want_parameters(0, r#"{"second":2}"#);
        assert_eq!(take_want_parameters_for_window(0), r#"{"second":2}"#);
    }

    #[test]
    fn want_parameters_are_isolated_per_window() {
        store_want_parameters(3, r#"{"window":3}"#);
        store_want_parameters(4, r#"{"window":4}"#);
        assert_eq!(take_want_parameters_for_window(4), r#"{"window":4}"#);
        // Window 3's entry survives window 4's drain.
        assert_eq!(take_want_parameters_for_window(3), r#"{"window":3}"#);
        assert_eq!(take_want_parameters_for_window(4), "");
    }

    #[test]
    fn initial_want_uri_is_isolated_per_window() {
        store_initial_want_uri(0, "app://primary");
        store_initial_want_uri(2, "app://second");
        assert_eq!(take_initial_want_uri_for_window(2), "app://second");
        assert_eq!(take_initial_want_uri_for_window(0), "app://primary");
        assert_eq!(take_initial_want_uri_for_window(0), "");
    }

    #[test]
    fn label_registry_resolves_registered_labels() {
        register_window_label("main", 0);
        register_window_label("secondary", 1);
        assert_eq!(window_id_for_label("secondary"), 1);
        assert_eq!(window_id_for_label("main"), 0);
        // Unknown labels fall back to the primary instance (single-instance behavior).
        assert_eq!(window_id_for_label("never-registered"), 0);
    }
}

#[cfg(test)]
mod tests {
    use super::OpenHarmonyAppInner;
    use crate::{
        cursor_position_with, update_cursor_position, AvoidArea, AvoidAreaType, CursorUntracked,
        Rect, CURSOR_POSITION_X, CURSOR_POSITION_Y,
    };

    #[test]
    fn d13_teardown_drops_per_window_registry_entries() {
        use crate::window::{
            is_ui_ability_stage_ready, register_pending_ui_ability, unregister_pending_ui_ability,
        };
        use crate::{register_window_label, window_id_for_label};

        // Pending-ability handshake: once torn down the id reads as unknown, and
        // unknown ids read as "ready" (see is_ui_ability_stage_ready) -- a future
        // spawn opens a fresh entry via register_pending_ui_ability.
        register_pending_ui_ability(11);
        assert!(!is_ui_ability_stage_ready(11));
        assert_eq!(unregister_pending_ui_ability(11), 0);
        assert!(is_ui_ability_stage_ready(11));
        // Tearing down an id that never existed is a no-op.
        assert_eq!(unregister_pending_ui_ability(404), 0);

        // Want storage: the D13 teardown drains entries the instance never read
        // (the lazy-take accessors only clear on read).
        super::store_want_parameters(11, "{}");
        super::store_initial_want_uri(11, "tauri://never-read");
        super::remove_want_uri_storage(11);
        assert_eq!(crate::take_want_parameters_for_window(11), "");
        assert_eq!(crate::take_initial_want_uri_for_window(11), "");

        // Label registry: removing our id leaves other labels untouched, and the
        // dead label resolves back to 0 (primary) -- see the direction note on
        // unregister_window_label.
        register_window_label("d13-spawned", 11);
        register_window_label("d13-other", 12);
        super::unregister_window_label(11);
        assert_eq!(window_id_for_label("d13-spawned"), 0);
        assert_eq!(window_id_for_label("d13-other"), 12);
    }

    #[test]
    fn ui_ability_teardown_pair_out_removes_both_rect_table_entries() {
        // Contract (release_render_owner note + unregister_ui_ability_state doc):
        // a spawned UIAbility instance's onAbilityDestroy path reaches
        // unregister_ui_ability_state, which removes that id's entries from the
        // per-window rect caches -- BOTH tables, pair-out symmetric with
        // set_window_rects' pair-in (outer + drawable go in together, so they
        // go out together). The rect entries are seeded through the
        // registry directly (same style as
        // releasing_a_component_clears_its_window_scoped_cache) because the
        // production writer is the windowRectChange lifecycle closure, which no
        // host test can drive.
        let app = super::OpenHarmonyApp::new();
        let spawned_id = 33;
        {
            let mut inner = app.inner.write().unwrap();
            inner.window_rects.insert(
                spawned_id,
                Rect {
                    top: 12,
                    left: 34,
                    width: 560,
                    height: 320,
                },
            );
            inner.inner_rects.insert(
                spawned_id,
                Rect {
                    top: 14,
                    left: 3,
                    width: 560,
                    height: 306,
                },
            );
            // A different spawned window's entries must survive this teardown
            // in BOTH tables (window ids are monotonic and removal is by id
            // only). Seeded as a near-miss pair (top/left transposed) and
            // pinned at value level, not presence-only.
            inner.window_rects.insert(
                34,
                Rect {
                    top: 1,
                    left: 2,
                    width: 3,
                    height: 4,
                },
            );
            inner.inner_rects.insert(
                34,
                Rect {
                    top: 2,
                    left: 1,
                    width: 3,
                    height: 4,
                },
            );
        }

        app.unregister_ui_ability_state(spawned_id);

        let inner = app.inner.read().unwrap();
        assert!(
            inner.window_rects.get(&spawned_id).is_none(),
            "unregister_ui_ability_state must remove the destroyed UIAbility's \
             window_rects entry (id {})",
            spawned_id
        );
        assert!(
            inner.inner_rects.get(&spawned_id).is_none(),
            "unregister_ui_ability_state must also remove the destroyed \
             UIAbility's inner_rects entry (id {}): set_window_rects writes \
             the outer+drawable pair into both tables together, so teardown \
             must clear them as a pair too (no bounded-leak dead entries)",
            spawned_id
        );
        assert_eq!(
            inner.window_rects.get(&34),
            Some(&Rect {
                top: 1,
                left: 2,
                width: 3,
                height: 4,
            }),
            "unregister_ui_ability_state must not touch other windows' \
             window_rects entries"
        );
        assert_eq!(
            inner.inner_rects.get(&34),
            Some(&Rect {
                top: 2,
                left: 1,
                width: 3,
                height: 4,
            }),
            "unregister_ui_ability_state must not touch other windows' \
             inner_rects entries"
        );
    }

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
    fn deactivating_a_surface_keeps_both_rect_tables() {
        // Pin for the release_render_owner NOTE: deactivate_surface clears the
        // surface-level fields only (raw_window/rect/surface_active) and
        // intentionally does NOT reset either rect table - window_rects and
        // inner_rects entries are emptied only along their own lifecycles
        // (release_render_owner for the main-window key 0,
        // unregister_ui_ability_state for spawned UIAbility ids). Seeded the
        // same way as ui_ability_teardown_pair_out_removes_both_rect_table_entries
        // because the production writer is the windowRectChange lifecycle
        // closure, which no host test can drive.
        let mut inner = OpenHarmonyAppInner::new();
        inner.claim_render_owner("owner").unwrap();
        assert!(inner.activate_surface("owner", None, Rect::default()));

        // Seed both tables with the main window (0) and a second window (2):
        // four entries total, all of which must survive deactivation.
        inner.window_rects.insert(
            0,
            Rect {
                top: 1,
                left: 2,
                width: 3,
                height: 4,
            },
        );
        inner.inner_rects.insert(
            0,
            Rect {
                top: 5,
                left: 6,
                width: 7,
                height: 8,
            },
        );
        inner.window_rects.insert(
            2,
            Rect {
                top: 11,
                left: 12,
                width: 13,
                height: 14,
            },
        );
        inner.inner_rects.insert(
            2,
            Rect {
                top: 15,
                left: 16,
                width: 17,
                height: 18,
            },
        );

        assert!(inner.deactivate_surface("owner"));

        // All four entries survive untouched in BOTH tables - pinned at value
        // level, not presence-only: deactivation must not remove, replace, or
        // overwrite any seeded entry.
        assert_eq!(
            inner.window_rects.get(&0),
            Some(&Rect {
                top: 1,
                left: 2,
                width: 3,
                height: 4,
            }),
            "deactivate_surface must not touch window_rects: the main-window \
             (id 0) entry is emptied only by release_render_owner"
        );
        assert_eq!(
            inner.inner_rects.get(&0),
            Some(&Rect {
                top: 5,
                left: 6,
                width: 7,
                height: 8,
            }),
            "deactivate_surface must not touch inner_rects: the main-window \
             (id 0) entry is emptied only by release_render_owner"
        );
        assert_eq!(
            inner.window_rects.get(&2),
            Some(&Rect {
                top: 11,
                left: 12,
                width: 13,
                height: 14,
            }),
            "deactivate_surface must not touch window_rects: the id 2 entry \
             is emptied only along its own teardown lifecycle"
        );
        assert_eq!(
            inner.inner_rects.get(&2),
            Some(&Rect {
                top: 15,
                left: 16,
                width: 17,
                height: 18,
            }),
            "deactivate_surface must not touch inner_rects: the id 2 entry \
             is emptied only along its own teardown lifecycle"
        );
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
        // release_render_owner clears key 0 (main window) only; sub-window
        // entries are not touched by it - spawned UIAbility ids are removed
        // only by unregister_ui_ability_state (their onAbilityDestroy path),
        // and true sub-window entries have no destroy-notification path in
        // this registry at all (see the NOTE above release_render_owner).
        // Assert key 0 is gone.
        assert!(inner.window_rects.get(&0).is_none());
        assert!(inner.avoid_areas.is_empty());
    }

    #[test]
    fn inner_rect_for_composes_outer_position_with_drawable_offset() {
        // Issue Eulogizethesun/tauri#97: inner reads come from the system's
        // drawableRect snapshot (pushed alongside the WM rect by the same
        // windowRectChange event), NOT from a window_rect - decor estimate.
        let mut inner = OpenHarmonyAppInner::new();
        inner.window_rects.insert(
            0,
            Rect {
                top: 76,
                left: 76,
                width: 2090,
                height: 1394,
            },
        );
        // Real reference-device shape: title bar 146px, content below it.
        inner.inner_rects.insert(
            0,
            Rect {
                top: 146,
                left: 0,
                width: 2090,
                height: 1248,
            },
        );
        assert_eq!(
            inner.inner_rect_for(0),
            Rect {
                top: 76 + 146,
                left: 76,
                width: 2090,
                height: 1248,
            }
        );
    }

    #[test]
    fn inner_rect_for_falls_back_to_outer_rect_before_first_drawable() {
        // Pins the DEFENSIVE fallback arm of inner_rect_for (None => outer).
        // Since review R14 the snapshot tables are only written in pairs via
        // set_window_rects, so "outer present, drawable absent" is unreachable
        // through production paths -- this seeds window_rects directly to pin
        // the arm for any future writer that does the same. Never a guessed
        // decor value.
        let mut inner = OpenHarmonyAppInner::new();
        inner.window_rects.insert(
            3,
            Rect {
                top: 10,
                left: 20,
                width: 800,
                height: 600,
            },
        );
        assert_eq!(
            inner.inner_rect_for(3),
            Rect {
                top: 10,
                left: 20,
                width: 800,
                height: 600,
            }
        );
        // And (0,0,0,0) for an entirely unobserved window, like the old default.
        assert_eq!(inner.inner_rect_for(7), Rect::default());
    }

    #[test]
    fn set_window_rects_with_missing_drawable_skips_outer_too() {
        // Review R14: a rect-change event whose drawableRect read failed
        // (drawable = None -- getWindowProperties threw, or the rect was
        // degenerate: minimized / content not loaded / abnormal state) must not
        // update the outer snapshot either. Storing the new outer alone would
        // let inner_rect_for compose a NEW origin with the STALE offset/size
        // (torn inner rect) until the next readable event.
        let mut inner = OpenHarmonyAppInner::new();
        // Reference-device shape (title bar 146px): a good pair first.
        inner.set_window_rects(
            2,
            Rect {
                top: 76,
                left: 76,
                width: 2090,
                height: 1394,
            },
            Some(Rect {
                top: 146,
                left: 0,
                width: 2090,
                height: 1248,
            }),
        );
        // Next event reports a moved+resized outer, but its drawableRect read
        // failed. Pair-in/pair-out: neither table moves.
        inner.set_window_rects(
            2,
            Rect {
                top: 100,
                left: 200,
                width: 640,
                height: 480,
            },
            None,
        );
        assert_eq!(
            inner.window_rect_for(2),
            Rect {
                top: 76,
                left: 76,
                width: 2090,
                height: 1394,
            }
        );
        assert_eq!(
            inner.inner_rect_for(2),
            Rect {
                top: 76 + 146,
                left: 76,
                width: 2090,
                height: 1248,
            }
        );
    }

    #[test]
    fn inner_rects_are_per_window_and_survive_main_surface_release_for_subwindows() {
        let mut inner = OpenHarmonyAppInner::new();
        inner.claim_render_owner("owner").unwrap();
        inner.set_inner_rect(
            0,
            Rect {
                top: 146,
                left: 0,
                width: 2090,
                height: 1248,
            },
        );
        inner.set_inner_rect(
            2,
            Rect {
                top: 0,
                left: 0,
                width: 760,
                height: 1100,
            },
        );
        // Seed the sub-window's outer rect too, with values distinct from the
        // drawable seed: a table swap would flip the two and the pins below
        // would catch it. width/height of the composed read come from the
        // drawable, so the pre-release composed asserts still hold.
        inner.set_window_rect(
            2,
            Rect {
                top: 40,
                left: 30,
                width: 800,
                height: 1200,
            },
        );
        assert_eq!(inner.inner_rect_for(2).width, 760_i32);
        assert_eq!(inner.inner_rect_for(2).height, 1_100_i32);
        // release_render_owner tears down the MAIN window surface: key 0's
        // cached rects go with it; sub-window snapshots are unaffected. Both
        // tables' sub-window entries are pinned at value level here, mirroring
        // the sibling survival tests.
        assert_eq!(inner.release_render_owner("owner"), Some(false));
        assert!(!inner.inner_rects.contains_key(&0));
        assert_eq!(
            inner.window_rects.get(&2),
            Some(&Rect {
                top: 40,
                left: 30,
                width: 800,
                height: 1_200,
            }),
            "release_render_owner must not touch sub-window window_rects entries"
        );
        assert_eq!(
            inner.inner_rects.get(&2),
            Some(&Rect {
                top: 0,
                left: 0,
                width: 760,
                height: 1_100,
            }),
            "release_render_owner must not touch sub-window inner_rects entries"
        );
        // Composed read pinned end-to-end: inner_rect_for offsets the drawable
        // origin by the outer rect (window {40,30} + drawable {0,0}) and takes
        // width/height from the drawable.
        assert_eq!(
            inner.inner_rect_for(2),
            Rect {
                top: 40,
                left: 30,
                width: 760,
                height: 1_100,
            }
        );
    }

    #[test]
    fn inner_rect_read_is_exactly_the_pushed_snapshot_no_estimate_arithmetic() {
        // Zero-drift guarantee for save/restore (issue #97 test requirement 3):
        // inner reads must reproduce the pushed system snapshot exactly -- there
        // is no estimate arithmetic between the snapshot and the read that
        // could accumulate error across cycles.
        let mut inner = OpenHarmonyAppInner::new();
        for cycle in 0_i32..8_i32 {
            let (w, h) = (1_000_i32 + cycle, 700_i32 - cycle);
            inner.window_rects.insert(
                0,
                Rect {
                    top: 76,
                    left: 76,
                    width: w,
                    height: h,
                },
            );
            inner.set_inner_rect(
                0,
                Rect {
                    top: 146,
                    left: 0,
                    width: w,
                    height: h - 146,
                },
            );
            let read = inner.inner_rect_for(0);
            assert_eq!((read.width, read.height), (w, h - 146_i32));
            // save->restore would push the same drawable back next cycle; the
            // read never feeds arithmetic that could shift it.
        }
    }

    #[test]
    fn update_cursor_position_stores_vp_coordinates() {
        use std::sync::atomic::Ordering;
        update_cursor_position(10.5, 20.25);
        assert_eq!(
            f64::from_bits(CURSOR_POSITION_X.load(Ordering::Relaxed)),
            10.5_f64
        );
        assert_eq!(
            f64::from_bits(CURSOR_POSITION_Y.load(Ordering::Relaxed)),
            20.25_f64
        );
    }

    /// UT for the tracked read-out branch (ohos-cursor-passthrough D1/D3, spec
    /// "main-window Move feed"): a fed screen-global vp coordinate x scale must
    /// come out as global physical px -- the tao upstream `cursor_position`
    /// semantic (Windows `GetCursorPos`). `ever_fed=true` -> `Ok`.
    #[test]
    fn cursor_position_with_tracked_feed_multiplies_scale_by_scale() {
        assert_eq!(
            cursor_position_with(true, 100.5, 50.25, 2.0),
            Ok((201.0_f64, 100.5_f64))
        );
    }

    /// UT for the untracked fail-safe contract (ohos-cursor-passthrough D3,
    /// spec "cold start, never fed -> reject"): with no feed ever recorded the
    /// read-out
    /// must be the typed `CursorUntracked` error -- NOT the (0,0) zero-init
    /// sentinel, which is indistinguishable from a real screen-origin feed
    /// and would let a hit-test "succeed" on garbage. Authoritative
    /// verification for the cold-start reject contract (the suite has no
    /// cold-start face: mouse interaction always precedes a suite run).
    #[test]
    fn cursor_position_with_untracked_feed_returns_untracked_error() {
        assert_eq!(
            cursor_position_with(false, 0.0, 0.0, 2.0),
            Err(CursorUntracked)
        );
    }

    /// UT guard-matrix negative bits (ohos-cursor-passthrough 1.1): the
    /// scale=1.0 identity branch, and a fed (0.0, 0.0) -- after a real feed
    /// the screen origin is a legal coordinate, not "untracked".
    #[test]
    fn cursor_position_with_scale_one_identity_and_fed_zero_is_legal() {
        assert_eq!(
            cursor_position_with(true, 100.5, 50.25, 1.0),
            Ok((100.5_f64, 50.25_f64))
        );
        assert_eq!(
            cursor_position_with(true, 0.0, 0.0, 2.0),
            Ok((0.0_f64, 0.0_f64))
        );
    }
}
