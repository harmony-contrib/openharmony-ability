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
    bridge::MainThreadBridgeEndpoint,
    resource::{
        resource_manager as global_resource_manager,
        set_resource_manager as set_global_resource_manager,
    },
    AvoidArea, AvoidAreaType, BridgeMainThread, BridgeMainThreadEvent, BridgePlugin,
    BridgePluginRegistry, BridgeRuntime, Configuration, Event, MainThreadScheduler,
    OpenHarmonyWaker, PluginLifecycleEvent, Rect, ResourceManager, WAKER,
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

    pub fn resource_manager(&self) -> Option<ResourceManager> {
        global_resource_manager()
    }

    pub fn set_resource_manager(&mut self, resource_manager: Option<ResourceManager>) {
        set_global_resource_manager(resource_manager);
    }
}

type EventLoop = Arc<RefCell<Option<Box<dyn FnMut(Event) + Sync + Send>>>>;
type BackPressInterceptor = Arc<RefCell<Option<Box<dyn FnMut() -> bool + Sync + Send>>>>;

#[derive(Clone)]
pub struct OpenHarmonyApp {
    pub(crate) inner: Arc<RwLock<OpenHarmonyAppInner>>,
    pub(crate) event_loop: EventLoop,
    pub(crate) back_press_interceptor: BackPressInterceptor,
    pub(crate) ime: Arc<RefCell<Option<IME>>>,
    bridge_runtime: Arc<RwLock<Option<BridgeRuntime>>>,
    bridge_main_thread: Arc<RwLock<Option<MainThreadBridgeEndpoint>>>,
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
            bridge_runtime: Arc::new(RwLock::new(None)),
            bridge_main_thread: Arc::new(RwLock::new(None)),
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

    pub fn resource_manager(&self) -> Option<ResourceManager> {
        global_resource_manager()
    }

    /// Returns the generic ArkTS bridge for this native module.
    ///
    /// The runtime is initialized when the module is rendered. Calls can be made from a worker
    /// thread; they are always marshalled back to ArkTS through a ThreadsafeFunction.
    pub fn bridge(&self) -> Result<BridgeRuntime> {
        self.bridge_runtime
            .read()
            .map_err(|_| Error::from_reason("Failed to read bridge runtime"))?
            .as_ref()
            .cloned()
            .ok_or_else(|| {
                Error::from_reason(
                    "Bridge runtime is not ready. Call it after the NativeAbility XComponent is rendered.",
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
            .bridge_main_thread
            .read()
            .map_err(|_| Error::from_reason("Failed to read main-thread bridge"))?;
        let endpoint = bridge.as_ref().ok_or_else(|| {
            Error::from_reason(
                "Synchronous bridge is not ready. Call it after the NativeAbility XComponent is rendered.",
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

    pub(crate) fn set_bridge_bindings(
        &self,
        runtime: BridgeRuntime,
        main_thread_endpoint: MainThreadBridgeEndpoint,
    ) {
        if let Ok(mut guard) = self.bridge_runtime.write() {
            guard.replace(runtime);
        }
        if let Ok(mut guard) = self.bridge_main_thread.write() {
            guard.replace(main_thread_endpoint);
        }
    }

    #[doc(hidden)]
    pub fn set_resource_manager(&self, resource_manager: Option<ResourceManager>) {
        self.inner
            .write()
            .unwrap()
            .set_resource_manager(resource_manager);
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
