use std::{
    cell::RefCell,
    fmt::Debug,
    sync::{
        atomic::{AtomicBool, AtomicI64},
        Arc, Mutex, RwLock,
    },
};

use napi_ohos::{Error, Result};
use ohos_ime_binding::IME;
use ohos_xcomponent_binding::RawWindow;

use crate::{
    helper::Helper, Configuration, Event, OpenHarmonyWaker, Rect, WebViewInitData, Webview, WAKER,
};

static ID: AtomicI64 = AtomicI64::new(0);

pub(crate) static HAS_EVENT: AtomicBool = AtomicBool::new(false);

#[derive(Clone)]
pub struct OpenHarmonyAppInner {
    pub(crate) raw_window: Option<RawWindow>,

    state: Vec<u8>,
    save_state: bool,
    frame_rate: u32,
    id: i64,
    pub(crate) helper: Helper,
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
        Some(self.id.cmp(&other.id))
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

impl OpenHarmonyAppInner {
    pub fn new() -> Self {
        let id = ID.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        OpenHarmonyAppInner {
            raw_window: None,
            state: vec![],
            save_state: false,
            frame_rate: 60,
            id,
            helper: Helper::new(),
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

    pub fn set_frame_rate(&mut self, frame_rate: u32) {
        self.frame_rate = frame_rate;
    }

    pub fn create_waker(&self) -> OpenHarmonyWaker {
        let guard = (&*WAKER).read().expect("Failed to read WAKER");
        OpenHarmonyWaker::new((*guard).clone())
    }

    pub fn config(&self) -> Configuration {
        self.configuration.clone()
    }

    pub fn content_rect(&self) -> Rect {
        self.rect.clone()
    }

    pub fn native_window(&self) -> Option<RawWindow> {
        self.raw_window.clone()
    }

    pub fn scale(&self) -> f32 {
        self.helper.scale()
    }

    pub fn exit(&self, code: i32) {
        self.helper.exit(code);
    }

    #[cfg(feature = "webview")]
    pub fn create_webview(&self, url: &str) -> Result<Webview> {
        if let Some(ark) = self.helper.ark.borrow_mut().as_ref() {
            let webview = ark.create_webview.call(WebViewInitData {
                url: Some(url.to_string()),
                id: None,
                style: None,
            })?;
            return Ok(Webview::new(webview));
        }
        Err(Error::from_reason("Failed to create webview"))
    }

    #[cfg(feature = "webview")]
    pub fn create_webview_with_id(&self, url: &str, id: &str) -> Result<Webview> {
        if let Some(ark) = self.helper.ark.borrow_mut().as_ref() {
            ark.hello.call(()).map_err(|e| {
                e
            })?;

            let webview = ark.create_webview.call(WebViewInitData {
                url: Some(url.to_string()),
                id: Some(id.to_string()),
                style: None,
            })?;
            return Ok(Webview::new(webview));
        }
        Err(Error::from_reason("Failed to create webview"))
    }

    #[cfg(feature = "webview")]
    pub fn create_webview_with_option(&self, data: WebViewInitData) -> Result<Webview> {
        if let Some(ark) = self.helper.ark.borrow_mut().as_ref() {
            let webview = ark.create_webview.call(data)?;
            return Ok(Webview::new(webview));
        }
        Err(Error::from_reason("Failed to create webview"))
    }
}

#[derive(Clone)]
pub struct OpenHarmonyApp {
    pub(crate) inner: Arc<RwLock<OpenHarmonyAppInner>>,
    pub(crate) event_loop: Arc<RefCell<Option<Box<dyn FnMut(Event) + Sync + Send>>>>,
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
        let self_id = self.inner.read().unwrap().id;
        let other_id = other.inner.read().unwrap().id;
        Some(self_id.cmp(&other_id))
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
            inner: Arc::new(RwLock::new(OpenHarmonyAppInner::new())),
            event_loop: Arc::new(RefCell::new(None)),
            ime: Arc::new(RefCell::new(None)),
            is_keyboard_show: Arc::new(Mutex::new(false)),
        }
    }

    pub fn app_inner(&self) -> OpenHarmonyAppInner {
        self.inner.read().unwrap().clone()
    }

    pub fn save(&self, state: Vec<u8>) {
        self.inner.write().unwrap().save(state);
    }
    pub fn load(&self) -> Option<Vec<u8>> {
        self.inner.read().unwrap().load()
    }
    pub fn set_frame_rate(&self, frame_rate: u32) {
        self.inner.write().unwrap().set_frame_rate(frame_rate);
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
        self.inner.read().unwrap().exit(code);
    }

    pub fn run_loop<'a, F: FnMut(Event) -> () + 'a>(&self, mut event_handle: F) {
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
