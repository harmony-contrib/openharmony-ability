use std::{
    cell::Cell,
    cell::RefCell,
    collections::HashMap,
    fmt::Debug,
    rc::Rc,
    sync::{
        atomic::{AtomicBool, AtomicI64},
        Arc, Mutex, RwLock,
    },
};

use futures_channel::oneshot;
use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{CallbackContext, Function, JsObjectValue, Object, Unknown},
    threadsafe_function::ThreadsafeFunctionCallMode,
    Error, Result,
};
use ohos_arkui_binding::XComponent;
use ohos_display_binding::default_display_scaled_density;
use ohos_ime_binding::IME;
use ohos_xcomponent_binding::RawWindow;

use crate::{
    get_helper, get_main_thread_env, get_permission_request_tsfn,
    resource::{
        resource_manager as global_resource_manager,
        set_resource_manager as set_global_resource_manager,
    },
    unknown_to_permission_promise, AbilityError, AvoidArea, AvoidAreaType, Configuration, Event,
    OpenHarmonyWaker, PermissionRequest, PermissionRequestCode, PermissionRequestOutput, Rect,
    ResourceManager, WAKER,
};

static ID: AtomicI64 = AtomicI64::new(0);

pub(crate) static HAS_EVENT: AtomicBool = AtomicBool::new(false);

const DEFAULT_AVOID_AREA_TYPES: [AvoidAreaType; 5] = [
    AvoidAreaType::System,
    AvoidAreaType::Cutout,
    AvoidAreaType::SystemGesture,
    AvoidAreaType::Keyboard,
    AvoidAreaType::NavigationIndicator,
];

fn parse_rect_from_object(rect: Object<'_>) -> Option<Rect> {
    let top = rect.get_named_property::<i32>("top").ok()?;
    let left = rect.get_named_property::<i32>("left").ok()?;
    let width = rect.get_named_property::<i32>("width").ok()?;
    let height = rect.get_named_property::<i32>("height").ok()?;
    Some(Rect {
        top,
        left,
        width,
        height,
    })
}

fn parse_avoid_area_options(options: Object<'_>) -> Option<(AvoidAreaType, AvoidArea)> {
    let area_type = AvoidAreaType::from(options.get_named_property::<i32>("type").ok()?);
    let area = options.get_named_property::<Object>("area").ok()?;
    let avoid_area = AvoidArea {
        visible: area.get_named_property::<bool>("visible").ok()?,
        left_rect: parse_rect_from_object(area.get_named_property::<Object>("leftRect").ok()?)?,
        top_rect: parse_rect_from_object(area.get_named_property::<Object>("topRect").ok()?)?,
        right_rect: parse_rect_from_object(area.get_named_property::<Object>("rightRect").ok()?)?,
        bottom_rect: parse_rect_from_object(area.get_named_property::<Object>("bottomRect").ok()?)?,
    };
    Some((area_type, avoid_area))
}

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

    pub fn exit(&self, code: i32) -> Result<()> {
        let ret = unsafe { get_helper() };
        if let Some(h) = ret.borrow().as_ref() {
            // Try to get main thread env
            if let Some(env) = get_main_thread_env().borrow().as_ref() {
                let ret = h.get_value(env)?;
                let exit_func = ret.get_named_property::<Function<'_, i32, ()>>("exit")?;
                exit_func.call(code)?;
            } else {
                return Err(Error::from_reason(
                    AbilityError::OnlyRunWithMainThread("exit".to_string()).to_string(),
                ));
            }
        }
        Ok(())
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

    fn fetch_avoid_area_from_helper(
        &self,
        area_type: AvoidAreaType,
    ) -> Option<(AvoidAreaType, AvoidArea)> {
        let helper = unsafe { get_helper() };
        let helper_borrow = helper.borrow();
        let helper_ref = helper_borrow.as_ref()?;
        let env = get_main_thread_env();
        let env_borrow = env.borrow();
        let env_ref = env_borrow.as_ref()?;
        let helper_object = helper_ref.get_value(env_ref).ok()?;
        let get_window_avoid_area = helper_object
            .get_named_property::<Function<'_, i32, Object<'_>>>("getWindowAvoidArea")
            .ok()?;
        let options = get_window_avoid_area.call(i32::from(area_type)).ok()?;
        parse_avoid_area_options(options)
    }

    fn ensure_avoid_area_cached(&self, area_type: AvoidAreaType) {
        if self.inner.read().unwrap().avoid_area(area_type).is_some() {
            return;
        }
        if let Some((fetched_type, area)) = self.fetch_avoid_area_from_helper(area_type) {
            self.inner
                .write()
                .unwrap()
                .avoid_areas
                .insert(fetched_type, area);
        }
    }

    fn ensure_avoid_areas_cached(&self) {
        if !self.inner.read().unwrap().avoid_areas.is_empty() {
            return;
        }
        for area_type in DEFAULT_AVOID_AREA_TYPES {
            self.ensure_avoid_area_cached(area_type);
        }
    }

    pub fn avoid_area(&self, area_type: AvoidAreaType) -> Option<AvoidArea> {
        self.ensure_avoid_area_cached(area_type);
        self.inner.read().unwrap().avoid_area(area_type)
    }

    pub fn avoid_areas(&self) -> HashMap<AvoidAreaType, AvoidArea> {
        self.ensure_avoid_areas_cached();
        self.inner.read().unwrap().avoid_areas()
    }
    pub fn native_window(&self) -> Option<RawWindow> {
        self.inner.read().unwrap().native_window()
    }

    /// Get current app scale
    pub fn scale(&self) -> f32 {
        self.inner.read().unwrap().scale()
    }

    /// Exit current app with code
    pub fn exit(&self, code: i32) {
        self.inner.read().unwrap().exit(code).unwrap();
    }

    /// Request one or more runtime permissions through ArkTS helper.
    /// Returns each requested permission and the corresponding request result code.
    /// ! Don't call this function from main thread with block_on.
    pub async fn request_permission<P>(&self, permission: P) -> Result<Vec<PermissionRequestCode>>
    where
        P: Into<PermissionRequest>,
    {
        let request = permission.into();
        let requested_permissions = request.permissions();
        let input = request.into_input();

        let permission_tsfn = get_permission_request_tsfn().ok_or_else(|| {
            Error::from_reason("requestPermission threadsafe function is not initialized")
        })?;

        let (tx, rx) = oneshot::channel::<Result<PermissionRequestOutput>>();
        let status = permission_tsfn.call_with_return_value(
            input,
            ThreadsafeFunctionCallMode::NonBlocking,
            move |result, _| {
                match result {
                    Ok(value) => {
                        let tx_cell = Rc::new(Cell::new(Some(tx)));
                        let tx_in_catch = tx_cell.clone();
                        let promise = unknown_to_permission_promise(value)?;
                        promise
                            .then(move |ctx| {
                                if let Some(sender) = tx_cell.replace(None) {
                                    let _ = sender.send(Ok(ctx.value));
                                }
                                Ok(())
                            })?
                            .catch(move |ctx: CallbackContext<Unknown>| {
                                if let Some(sender) = tx_in_catch.replace(None) {
                                    let _ = sender.send(Err(ctx.value.into()));
                                }
                                Ok(())
                            })?;
                    }
                    Err(err) => {
                        let _ = tx.send(Err(err));
                    }
                }

                Ok(())
            },
        );

        if status != napi_ohos::Status::Ok {
            return Err(Error::from_reason(format!(
                "call requestPermission failed with status: {:?}",
                status
            )));
        }

        let output = rx
            .await
            .map_err(|_| Error::from_reason("requestPermission callback receiver dropped"))??;

        let codes = match output {
            napi_ohos::Either::A(code) => vec![code],
            napi_ohos::Either::B(codes) => codes,
        };

        if requested_permissions.len() != codes.len() {
            return Err(Error::from_reason(format!(
                "requestPermission result length mismatch: requested {}, got {}",
                requested_permissions.len(),
                codes.len()
            )));
        }

        Ok(requested_permissions
            .into_iter()
            .zip(codes)
            .map(|(permission, code)| PermissionRequestCode { permission, code })
            .collect())
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
