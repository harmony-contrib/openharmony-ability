use std::{
    cell::Cell,
    cell::RefCell,
    fmt::Debug,
    rc::Rc,
    sync::{
        atomic::{AtomicBool, AtomicI64},
        Arc, Mutex, RwLock,
    },
};

use futures_channel::oneshot;
use napi_ohos::{
    bindgen_prelude::{CallbackContext, Function, JsObjectValue, Unknown},
    threadsafe_function::ThreadsafeFunctionCallMode,
    Error, Result,
};
use ohos_arkui_binding::XComponent;
use ohos_display_binding::default_display_scaled_density;
use ohos_ime_binding::IME;
use ohos_xcomponent_binding::RawWindow;

use crate::{
    get_helper, get_main_thread_env, get_permission_request_tsfn, unknown_to_permission_promise,
    AbilityError, Configuration, Event, OpenHarmonyWaker, PermissionRequest, PermissionRequestCode,
    PermissionRequestOutput, Rect, WAKER,
};

static ID: AtomicI64 = AtomicI64::new(0);

pub(crate) static HAS_EVENT: AtomicBool = AtomicBool::new(false);

#[derive(Clone)]
pub struct OpenHarmonyAppInner {
    pub(crate) raw_window: Option<RawWindow>,
    pub(crate) xcomponent: Option<XComponent>,

    state: Vec<u8>,
    save_state: bool,
    id: i64,
    pub(crate) configuration: Configuration,
    pub(crate) rect: Rect,
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

    pub fn native_window(&self) -> Option<RawWindow> {
        self.raw_window
    }

    pub fn scale(&self) -> f32 {
        default_display_scaled_density()
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

#[derive(Clone)]
pub struct OpenHarmonyApp {
    pub(crate) inner: Arc<RwLock<OpenHarmonyAppInner>>,
    pub(crate) event_loop: EventLoop,
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
            .zip(codes.into_iter())
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
