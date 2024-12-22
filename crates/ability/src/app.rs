use std::{cell::RefCell, rc::Rc};

use ohos_ime_binding::IME;
use ohos_xcomponent_binding::RawWindow;

use crate::{Configuration, Event, InputEvent, OpenHarmonyWaker, Rect, TextInputEventData, WAKER};

pub struct OpenHarmonyApp {
    pub(crate) event_loop: Rc<RefCell<Option<Box<dyn FnMut(Event)>>>>,
    pub(crate) ime: Rc<RefCell<IME>>,
    pub(crate) raw_window: Rc<RefCell<Option<RawWindow>>>,

    state: Rc<RefCell<Vec<u8>>>,
    save_state: RefCell<bool>,
    frame_rate: RefCell<u32>,
    configuration: RefCell<Configuration>,
    rect: RefCell<Rect>,
}

impl PartialEq for OpenHarmonyApp {
    fn eq(&self, other: &Self) -> bool {
        Rc::ptr_eq(&self.event_loop, &other.event_loop)
            && Rc::ptr_eq(&self.ime, &other.ime)
            && Rc::ptr_eq(&self.raw_window, &other.raw_window)
            && *self.state.borrow() == *other.state.borrow()
            && *self.save_state.borrow() == *other.save_state.borrow()
            && *self.frame_rate.borrow() == *other.frame_rate.borrow()
    }
}

impl Eq for OpenHarmonyApp {}

impl std::hash::Hash for OpenHarmonyApp {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        Rc::as_ptr(&self.event_loop).hash(state);
        Rc::as_ptr(&self.ime).hash(state);
        Rc::as_ptr(&self.raw_window).hash(state);
        self.state.borrow().hash(state);
        self.save_state.borrow().hash(state);
        self.frame_rate.borrow().hash(state);
    }
}

impl OpenHarmonyApp {
    pub fn new() -> Self {
        let ime = IME::new(Default::default());
        OpenHarmonyApp {
            event_loop: Rc::new(RefCell::new(None)),
            state: Rc::new(RefCell::new(Vec::new())),
            raw_window: Rc::new(RefCell::new(None)),
            save_state: RefCell::new(false),
            frame_rate: RefCell::new(60),
            ime: Rc::new(RefCell::new(ime)),
            configuration: RefCell::new(Configuration::default()),
            rect: RefCell::new(Rect::default()),
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
        Configuration::default()
    }

    pub fn content_rect(&self) -> Rect {
        Rect::default()
    }

    pub fn native_window(&self) -> Option<RawWindow> {
        self.raw_window.borrow().clone()
    }

    /// register event loop
    pub fn run_loop<'a, F: FnMut(Event) -> () + 'a>(&self, mut event_handle: F) {
        let handler = Box::new(move |event| {
            event_handle(event);
        });

        // 使用 unsafe 将生命周期扩展为 'static
        let static_handler = unsafe {
            std::mem::transmute::<Box<dyn FnMut(Event) + 'a>, Box<dyn FnMut(Event) + 'static>>(
                handler,
            )
        };

        self.event_loop.replace(Some(static_handler));

        let e = self.event_loop.clone();

        let ime = self.ime.borrow();
        ime.insert_text(move |data| {
            if let Some(h) = e.borrow_mut().as_mut() {
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
            event_loop: self.event_loop.clone(),
            state: self.state.clone(),
            raw_window: self.raw_window.clone(),
            save_state: self.save_state.clone(),
            frame_rate: self.frame_rate.clone(),
            ime: self.ime.clone(),
            configuration: self.configuration.clone(),
            rect: self.rect.clone(),
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
