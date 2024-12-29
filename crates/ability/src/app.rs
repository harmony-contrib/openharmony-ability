use std::{cell::RefCell, fmt::Debug, rc::Rc, sync::atomic::AtomicI64};

use ohos_ime_binding::IME;
use ohos_xcomponent_binding::RawWindow;

use crate::{
    helper::Helper, Configuration, Event, InputEvent, OpenHarmonyWaker, Rect, TextInputEventData,
    WAKER,
};

static ID: AtomicI64 = AtomicI64::new(0);

pub struct OpenHarmonyApp {
    pub(crate) event_loop: Rc<RefCell<Option<Box<dyn FnMut(Event)>>>>,
    pub(crate) ime: Rc<RefCell<IME>>,
    pub(crate) raw_window: Rc<RefCell<Option<RawWindow>>>,

    state: Rc<RefCell<Vec<u8>>>,
    save_state: Rc<RefCell<bool>>,
    frame_rate: Rc<RefCell<u32>>,
    id: i64,
    pub(crate) helper: Rc<RefCell<Helper>>,
    pub(crate) configuration: Rc<RefCell<Configuration>>,
    pub(crate) rect: Rc<RefCell<Rect>>,
}

impl PartialEq for OpenHarmonyApp {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

impl Eq for OpenHarmonyApp {}

impl std::hash::Hash for OpenHarmonyApp {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        Rc::as_ptr(&self.event_loop).hash(state);
        Rc::as_ptr(&self.ime).hash(state);
        Rc::as_ptr(&self.raw_window).hash(state);
        Rc::as_ptr(&self.state).hash(state);
        Rc::as_ptr(&self.save_state).hash(state);
        Rc::as_ptr(&self.frame_rate).hash(state);
    }
}

impl PartialOrd for OpenHarmonyApp {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.id.cmp(&other.id))
    }
}

impl Ord for OpenHarmonyApp {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.id.cmp(&other.id)
    }
}

impl Debug for OpenHarmonyApp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenHarmonyApp")
            .field("id", &self.id)
            .finish()
    }
}

impl OpenHarmonyApp {
    pub fn new() -> Self {
        let ime = IME::new(Default::default());
        let id = ID.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        OpenHarmonyApp {
            event_loop: Rc::new(RefCell::new(None)),
            state: Rc::new(RefCell::new(Vec::new())),
            raw_window: Rc::new(RefCell::new(None)),
            save_state: Rc::new(RefCell::new(false)),
            frame_rate: Rc::new(RefCell::new(60)),
            helper: Rc::new(RefCell::new(Helper::default())),
            ime: Rc::new(RefCell::new(ime)),
            configuration: Rc::new(RefCell::new(Configuration::default())),
            rect: Rc::new(RefCell::new(Rect::default())),
            id,
        }
    }

    /// load current app state
    pub fn load(&self) -> Option<Vec<u8>> {
        if *self.save_state.borrow() {
            Some(self.state.borrow().clone())
        } else {
            None
        }
    }

    /// save current app state
    pub fn save(&self, state: Vec<u8>) {
        self.state.replace(state);
    }

    pub fn set_frame_rate(&self, frame_rate: u32) {
        self.frame_rate.replace(frame_rate);
    }

    pub fn show_keyboard(&self) {
        self.ime.borrow().show_keyboard();
    }

    pub fn hide_keyboard(&self) {
        self.ime.borrow().hide_keyboard();
    }

    pub fn create_waker(&self) -> OpenHarmonyWaker {
        let guard = (&*WAKER).read().expect("Failed to read WAKER");
        OpenHarmonyWaker::new((*guard).clone())
    }

    pub fn config(&self) -> Configuration {
        self.configuration.borrow().clone()
    }

    pub fn content_rect(&self) -> Rect {
        self.rect.borrow().clone()
    }

    pub fn native_window(&self) -> Option<RawWindow> {
        self.raw_window.borrow().clone()
    }

    pub fn scale(&self) -> f32 {
        self.helper.borrow().scale()
    }

    /// register event loop
    pub fn run_loop<'a, F: FnMut(Event) -> () + 'a>(&self, event_handle: F) {
        let static_handler = unsafe {
            std::mem::transmute::<Box<dyn FnMut(Event) + 'a>, Box<dyn FnMut(Event) + 'static>>(
                Box::new(event_handle),
            )
        };

        self.event_loop.replace(Some(static_handler));

        let e = self.event_loop.clone();

        let ime = self.ime.borrow();
        ime.insert_text(move |data| {
            if let Some(ref mut h) = *e.borrow_mut() {
                h(Event::Input(InputEvent::TextInputEvent(
                    TextInputEventData { text: data },
                )));
            }
        });
    }
}

unsafe impl Send for OpenHarmonyApp {}
unsafe impl Sync for OpenHarmonyApp {}

impl Clone for OpenHarmonyApp {
    fn clone(&self) -> Self {
        OpenHarmonyApp {
            event_loop: Rc::clone(&self.event_loop),
            state: Rc::clone(&self.state),
            raw_window: Rc::clone(&self.raw_window),
            save_state: Rc::clone(&self.save_state),
            frame_rate: Rc::clone(&self.frame_rate),
            ime: Rc::clone(&self.ime),
            configuration: Rc::clone(&self.configuration),
            rect: Rc::clone(&self.rect),
            helper: Rc::clone(&self.helper),
            id: self.id.clone()
        }
    }
}

pub struct SaveSaver {
    pub(crate) app: RefCell<OpenHarmonyApp>,
}

impl SaveSaver {
    pub fn save(&self, state: Vec<u8>) {
        self.app.borrow().save(state);
    }
}

pub struct SaveLoader {
    pub(crate) app: RefCell<OpenHarmonyApp>,
}

impl SaveLoader {
    pub fn load(&self) -> Option<Vec<u8>> {
        self.app.borrow().load()
    }
}
