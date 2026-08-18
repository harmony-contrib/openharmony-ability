use std::{
    cell::RefCell,
    collections::HashMap,
    fmt::Debug,
    sync::{
        atomic::{AtomicBool, AtomicI64},
        Arc, Mutex, RwLock,
    },
    thread::ThreadId,
};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Object, Env, Error, Result};
use ohos_arkui_binding::XComponent;
use ohos_display_binding::default_display_scaled_density;
use ohos_ime_binding::IME;
use ohos_xcomponent_binding::RawWindow;

use crate::{
    bridge::{BridgePluginRegistry, MainThreadBridgeEndpoint},
    waker::WAKER,
    AvoidArea, AvoidAreaType, BridgeMainThread, BridgeMainThreadEvent, BridgePlugin,
    BridgePluginDeclaration, BridgeRuntime, Configuration, Event, MainThreadScheduler,
    OpenHarmonyWaker, PluginLifecycleEvent, Rect,
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
        })
    }
}

#[derive(Clone)]
pub(crate) struct OpenHarmonyAppInner {
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
        self.save_state = true;
    }

    pub fn create_waker(&self) -> OpenHarmonyWaker {
        let waker = (*WAKER).read().ok().and_then(|guard| (*guard).clone());
        OpenHarmonyWaker::new(waker)
    }

    pub fn config(&self) -> Configuration {
        self.configuration.clone()
    }

    pub fn set_frame_rate(&self, min: i32, max: i32, expected: i32) {
        if let Some(xcomponent) = self.xcomponent.as_ref() {
            if let Err(error) = xcomponent
                .native_xcomponent()
                .set_frame_rate(min, max, expected)
            {
                crate::log::warn(&format!("Failed to set frame rate: {error}"));
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

type EventHandler = Box<dyn FnMut(Event) + Send + 'static>;
type EventLoop = Arc<Mutex<Option<EventHandler>>>;
type BackPressHandler = Box<dyn FnMut() -> bool + Send + 'static>;
type BackPressInterceptor = Arc<Mutex<Option<BackPressHandler>>>;

/// A slot bound to the thread that created it — in practice the ArkTS/N-API main thread, where
/// `OpenHarmonyApp` is constructed during module initialization.
///
/// The wrapped platform object (`IME`) is only ever created and used inside main-thread platform
/// callbacks. Cross-thread access is rejected at runtime instead of racing, which is what makes
/// the `Send`/`Sync` implementations below sound: no other thread can ever reach the inner
/// `RefCell`.
pub(crate) struct MainThreadCell<T> {
    owner: ThreadId,
    value: RefCell<Option<T>>,
}

impl<T> MainThreadCell<T> {
    fn new() -> Self {
        Self {
            owner: std::thread::current().id(),
            value: RefCell::new(None),
        }
    }

    fn is_owner_thread(&self) -> bool {
        std::thread::current().id() == self.owner
    }

    /// Runs `f` with a shared borrow of the slot. Returns `None` off the owner thread.
    pub(crate) fn with_ref<R>(&self, f: impl FnOnce(Option<&T>) -> R) -> Option<R> {
        if !self.is_owner_thread() {
            return None;
        }
        Some(f(self.value.borrow().as_ref()))
    }

    /// Replaces the slot content. Returns `false` off the owner thread.
    pub(crate) fn set(&self, value: T) -> bool {
        if !self.is_owner_thread() {
            return false;
        }
        *self.value.borrow_mut() = Some(value);
        true
    }

    /// Clears the slot. Returns `None` off the owner thread or when the slot was empty.
    pub(crate) fn take(&self) -> Option<T> {
        if !self.is_owner_thread() {
            return None;
        }
        self.value.borrow_mut().take()
    }
}

// SAFETY: every access path checks the owning thread first, so the non-`Sync` interior can never
// be observed concurrently and the wrapped value never actually moves to another thread.
unsafe impl<T> Send for MainThreadCell<T> {}
unsafe impl<T> Sync for MainThreadCell<T> {}

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
    pub(crate) ime: Arc<MainThreadCell<IME>>,
    bridge_session: Arc<RwLock<Option<ActiveBridgeSession>>>,
    bridge_plugins: Arc<BridgePluginRegistry>,
}

impl Debug for OpenHarmonyApp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let id = self.inner.read().map(|inner| inner.id).unwrap_or(-1);
        f.debug_struct("OpenHarmonyApp").field("id", &id).finish()
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
        // Pointer identity keeps `Ord` consistent with `PartialEq`/`Hash` without taking locks.
        Arc::as_ptr(&self.inner).cmp(&Arc::as_ptr(&other.inner))
    }
}

impl OpenHarmonyApp {
    pub fn new() -> Self {
        Self {
            #[allow(clippy::arc_with_non_send_sync)]
            inner: Arc::new(RwLock::new(OpenHarmonyAppInner::new())),
            event_loop: Arc::new(Mutex::new(None)),
            back_press_interceptor: Arc::new(Mutex::new(None)),
            ime: Arc::new(MainThreadCell::new()),
            bridge_session: Arc::new(RwLock::new(None)),
            bridge_plugins: Arc::new(BridgePluginRegistry::default()),
        }
    }

    pub fn save(&self, state: Vec<u8>) {
        self.inner.write().unwrap().save(state);
    }

    pub fn load(&self) -> Option<Vec<u8>> {
        self.inner.read().unwrap().load()
    }

    /// Installs state recovered from the platform's saved Want so that `Event::Resume` and
    /// `Event::Create` handlers can read it through [`SaveLoader::load`].
    pub(crate) fn restore_saved_state(&self, state: Vec<u8>) {
        if let Ok(mut inner) = self.inner.write() {
            inner.save(state);
        } else {
            crate::log::warn("Failed to restore saved state: application state is poisoned");
        }
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
            self.ime.take();
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
        self.ime.take();
        if surface_was_active {
            self.dispatch_surface_destroy();
        }
    }

    pub(crate) fn dispatch_surface_destroy(&self) {
        self.emit_event(Event::SurfaceDestroy);
    }

    /// Delivers one event to the `run_loop` handler. Events originate from main-thread platform
    /// callbacks; a reentrant emit (an event raised while the handler is still running) is
    /// dropped with a log instead of deadlocking.
    pub(crate) fn emit_event(&self, event: Event<'_>) {
        match self.event_loop.try_lock() {
            Ok(mut guard) => {
                if let Some(handler) = guard.as_mut() {
                    handler(event);
                }
            }
            Err(_) => {
                crate::log::warn(&format!(
                    "Dropped '{}' event: the run_loop handler is already running or poisoned",
                    event.as_str()
                ));
            }
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

    /// Shows the soft keyboard. The IME is a main-thread platform object, so this is a no-op
    /// (with a warning) when called from any other thread.
    pub fn show_keyboard(&self) {
        let dispatched = self.ime.with_ref(|ime| {
            if let Some(ime) = ime {
                ime.show_keyboard();
            }
        });
        if dispatched.is_none() {
            crate::log::warn("show_keyboard is only available on the ArkTS main thread");
        }
    }

    /// Hides the soft keyboard. The IME is a main-thread platform object, so this is a no-op
    /// (with a warning) when called from any other thread.
    pub fn hide_keyboard(&self) {
        let dispatched = self.ime.with_ref(|ime| {
            if let Some(ime) = ime {
                ime.hide_keyboard();
            }
        });
        if dispatched.is_none() {
            crate::log::warn("hide_keyboard is only available on the ArkTS main thread");
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

    /// Registers the application's event handler. Events are delivered on the ArkTS/N-API main
    /// thread. The handler must be `'static` because it outlives the registering call; it must be
    /// `Send` because it is installed from the module-initialization thread and later invoked
    /// from main-thread platform callbacks.
    ///
    /// Returns an error when a handler is already installed for this native module; the
    /// framework never silently ignores or replaces application event routing.
    pub fn run_loop<F>(&self, event_handle: F) -> Result<()>
    where
        F: FnMut(Event) + Send + 'static,
    {
        if HAS_EVENT.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return Err(Error::from_reason(
                "run_loop was already called for this native module",
            ));
        }

        let mut guard = self.event_loop.lock().map_err(|_| {
            Error::from_reason("Failed to install the run_loop handler: event loop is poisoned")
        })?;
        *guard = Some(Box::new(event_handle));
        Ok(())
    }

    /// Register back press interceptor. Return `true` to intercept back action, `false` to pass through.
    pub fn on_back_press_intercept<F>(&self, interceptor: F)
    where
        F: FnMut() -> bool + Send + 'static,
    {
        if let Ok(mut guard) = self.back_press_interceptor.lock() {
            *guard = Some(Box::new(interceptor));
        } else {
            crate::log::warn("Failed to install the back-press interceptor: lock is poisoned");
        }
    }

    /// Runs the registered back-press interceptor.
    ///
    /// Returns `false` (let ArkUI perform its default back navigation) when no interceptor has
    /// been registered, so applications keep the platform back behavior until they opt in.
    pub fn get_back_press_interceptor(&self) -> bool {
        match self.back_press_interceptor.try_lock() {
            Ok(mut guard) => guard.as_mut().map(|h| h()).unwrap_or(false),
            Err(_) => false,
        }
    }
}

impl Default for OpenHarmonyApp {
    fn default() -> Self {
        Self::new()
    }
}

// SAFETY: `OpenHarmonyApp` is a bundle of `Arc` handles whose shared state is individually
// protected: `event_loop` and `back_press_interceptor` are `Mutex`-guarded `Send` closures,
// `ime` is a `MainThreadCell` that rejects cross-thread access at runtime, and the bridge
// session/plugin registries use `RwLock`. The remaining non-auto-`Send` members are the
// `RawWindow`/`XComponent` handles inside `inner`: `RawWindow` is an opaque `OHNativeWindow`
// pointer that OpenHarmony explicitly supports handing to render threads (EGL/Vulkan), and the
// `XComponent` handle is only mutated from main-thread surface callbacks behind the `RwLock`.
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
