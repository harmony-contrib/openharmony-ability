use std::{
    fmt::Debug,
    sync::{atomic::AtomicI64, Arc, LazyLock, Mutex, RwLock},
};

use ohos_ime_binding::IME;
use ohos_xcomponent_binding::RawWindow;

use crate::{
    helper::Helper, Configuration, Event, InputEvent, OpenHarmonyWaker, Rect, TextInputEventData,
    WAKER,
};

static ID: AtomicI64 = AtomicI64::new(0);

pub static EVENT: LazyLock<Arc<RwLock<Option<Box<dyn Fn(Event) + Sync + Send>>>>> =
    LazyLock::new(|| Arc::new(RwLock::new(None)));

#[derive(Clone)]
pub struct OpenHarmonyAppInner {
    pub(crate) ime: IME,
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
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {}
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
        let ime = IME::new(Default::default());
        let id = ID.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        OpenHarmonyAppInner {
            ime,
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

    pub fn show_keyboard(&self) {
        self.ime.show_keyboard();
    }

    pub fn hide_keyboard(&self) {
        self.ime.hide_keyboard();
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

    /// register event loop
    pub fn run_loop<'a, F: Fn(Event) -> () + 'a>(&self, event_handle: F) {

        // self.event_loop.replace(Some(static_handler));

        // let e = self.event_loop.clone();

        // let ime = self.ime.borrow();
        // ime.insert_text(move |data| {
        //     if let Some(ref mut h) = *e.borrow_mut() {
        //         h(Event::Input(InputEvent::TextInputEvent(
        //             TextInputEventData { text: data },
        //         )));
        //     }
        // });
    }
}

#[derive(Debug)]
pub struct OpenHarmonyApp {
    pub(crate) inner: Arc<RwLock<OpenHarmonyAppInner>>,
}

impl Clone for OpenHarmonyApp {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
        }
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

impl Drop for OpenHarmonyApp {
    fn drop(&mut self) {
        println!("drop app");
    }
}

impl OpenHarmonyApp {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(OpenHarmonyAppInner::new())),
        }
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
        self.inner.read().unwrap().show_keyboard();
    }
    pub fn hide_keyboard(&self) {
        self.inner.read().unwrap().hide_keyboard();
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
    pub fn scale(&self) -> f32 {
        self.inner.read().unwrap().scale()
    }

    pub fn run_loop<'a, F: Fn(Event) -> () + 'a>(&self, event_handle: F) {
        let weak_inner = Arc::downgrade(&self.inner);

        let static_handler = unsafe {
            std::mem::transmute::<Box<dyn Fn(Event) + 'a>, Box<dyn Fn(Event) + 'static + Sync + Send>>(
                Box::new(move |event| {
                    if let Some(inner) = weak_inner.upgrade() {
                        // Use the inner object safely here
                        let inner_read = inner.read().unwrap();
                        // Call the event handler with the event
                        event_handle(event);
                    }
                }),
            )
        };

        let mut guard = EVENT.write().expect("Failed to write EVENT");
        *guard = Some(static_handler);
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
