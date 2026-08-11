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
use ohos_display_binding::default_display_scaled_density;
use ohos_ime_binding::IME;
use ohos_xcomponent_binding::RawWindow;

use crate::{
    bridge::MainThreadBridgeEndpoint, AvoidArea, AvoidAreaType, BridgeMainThread,
    BridgeMainThreadEvent, BridgePlugin, BridgePluginRegistry, BridgeRuntime, Configuration, Event,
    MainThreadScheduler, OpenHarmonyWaker, PluginLifecycleEvent, Rect, WAKER,
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
    /// OpenHarmony base API Level provided by ArkTS `deviceInfo.sdkApiVersion`.
    pub sdk_api_version: Option<i32>,
    /// HarmonyOS distribution version provided by ArkTS `deviceInfo.distributionOSApiVersion`.
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
    pub(crate) window_rect: Rect,
    pub(crate) avoid_areas: HashMap<AvoidAreaType, AvoidArea>,
    pub(crate) init_context: AbilityInitContext,
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
            window_rect: Default::default(),
            avoid_areas: HashMap::new(),
            init_context: AbilityInitContext::default(),
        }
    }

    /// load current app state
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
    }

    pub fn create_waker(&self) -> OpenHarmonyWaker {
        let guard = (*WAKER).read().expect("Failed to read WAKER");
        OpenHarmonyWaker::new((*guard).clone())
    }

    pub fn config(&self) -> Configuration {
        self.configuration.clone()
    }

    pub fn set_frame_rate(&self, min: i32, max: i32, expected: i32) {
        if let Some(xcomponent) = self.xcomponent.as_ref() {
            xcomponent
                .native_xcomponent()
                .set_frame_rate(min, max, expected)
                .expect("Failed to set frame rate");
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
        self.window_rect = Rect::default();
        self.avoid_areas.clear();
        Some(surface_was_active)
    }

    pub fn content_rect(&self) -> Rect {
        self.rect
    }

    pub fn window_rect(&self) -> Rect {
        self.window_rect
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

    pub fn init_context(&self) -> AbilityInitContext {
        self.init_context.clone()
    }

    pub fn set_init_context(&mut self, context: AbilityInitContext) {
        self.init_context = context;
    }
}

type EventLoop = Arc<RefCell<Option<Box<dyn FnMut(Event) + Sync + Send>>>>;
type BackPressInterceptor = Arc<RefCell<Option<Box<dyn FnMut() -> bool + Sync + Send>>>>;

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

    pub fn window_rect(&self) -> Rect {
        self.inner.read().unwrap().window_rect()
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

    pub fn run_loop<'a, F: FnMut(Event) + 'a>(&self, mut event_handle: F) {
        if HAS_EVENT.load(std::sync::atomic::Ordering::SeqCst) {
            return;
        }

        let static_handler = unsafe {
            std::mem::transmute::<
                Box<dyn FnMut(Event) + 'a>,
                Box<dyn FnMut(Event) + 'static + Sync + Send>,
            >(Box::new(move |event| {
                event_handle(event);
            }))
        };

        self.event_loop.replace(Some(static_handler));
        HAS_EVENT.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// Register back press interceptor. Return `true` to intercept back action, `false` to pass through.
    pub fn on_back_press_intercept<'a, F: FnMut() -> bool + 'a>(&self, interceptor: F) {
        let static_handler = unsafe {
            std::mem::transmute::<
                Box<dyn FnMut() -> bool + 'a>,
                Box<dyn FnMut() -> bool + 'static + Sync + Send>,
            >(Box::new(interceptor))
        };

        self.back_press_interceptor.replace(Some(static_handler));
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

// TODO: Can we remove this?
unsafe impl Send for OpenHarmonyApp {}
unsafe impl Sync for OpenHarmonyApp {}

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

/// Latest `want.parameters` JSON from `onNewWant` (deep-link / URL scheme).
static WANT_PARAMETERS: Mutex<String> = Mutex::new(String::new());

/// Initial `want.uri` from `onCreate` (cold start).
static INITIAL_WANT_URI: Mutex<String> = Mutex::new(String::new());

pub(crate) fn store_want_parameters(json: &str) {
    if let Ok(mut params) = WANT_PARAMETERS.lock() {
        *params = json.to_string();
    }
}

/// Returns the latest `want.parameters` JSON string from `onNewWant`, then clears it.
pub fn take_want_parameters() -> String {
    WANT_PARAMETERS
        .lock()
        .map(|mut p| std::mem::take(&mut *p))
        .unwrap_or_default()
}

pub(crate) fn store_initial_want_uri(uri: &str) {
    if let Ok(mut u) = INITIAL_WANT_URI.lock() {
        *u = uri.to_string();
    }
}

/// Returns the initial `want.uri` from `onCreate` (cold start), then clears it.
pub fn take_initial_want_uri() -> String {
    INITIAL_WANT_URI
        .lock()
        .map(|mut u| std::mem::take(&mut *u))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::OpenHarmonyAppInner;
    use crate::{AvoidArea, AvoidAreaType, Rect};

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
        inner.window_rect = Rect {
            top: 1,
            left: 2,
            width: 3,
            height: 4,
        };
        inner
            .avoid_areas
            .insert(AvoidAreaType::Keyboard, AvoidArea::default());

        assert_eq!(inner.release_render_owner("owner"), Some(false));
        assert_eq!(inner.window_rect, Rect::default());
        assert!(inner.avoid_areas.is_empty());
    }
}
