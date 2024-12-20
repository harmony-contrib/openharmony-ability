use std::{cell::RefCell, rc::Rc};

use ohos_ime_binding::IME;
use ohos_xcomponent_binding::RawWindow;

use crate::{Event, InputEvent, OpenHarmonyWaker, TextInputEventData, WAKER};

#[derive(Clone)]
pub struct OpenHarmonyApp {
    pub(crate) event_loop: Rc<RefCell<Option<fn(Event) -> ()>>>,
    pub(crate) ime: Rc<RefCell<IME>>,
    pub(crate) raw_window: Rc<RefCell<Option<RawWindow>>>,

    state: Rc<RefCell<Vec<u8>>>,
    save_state: RefCell<bool>,
    frame_rate: RefCell<u32>,
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

    pub fn native_window(&self) -> Option<RawWindow> {
        self.raw_window.borrow().clone()
    }

    /// register event loop
    pub fn run_loop(&self, event_handle: fn(event: Event) -> ()) {
        self.event_loop.replace(Some(event_handle));

        let e = self.event_loop.borrow().clone();

        let ime = self.ime.borrow();
        ime.insert_text(move |data| {
            if let Some(h) = e {
                h(Event::Input(InputEvent::TextInputEvent(
                    TextInputEventData { text: data },
                )));
            }
        });
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
