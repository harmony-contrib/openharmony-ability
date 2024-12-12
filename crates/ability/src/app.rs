use std::{cell::RefCell, rc::Rc};

use ohos_ime_binding::IME;

use crate::{Event, InputEvent, TextInputEventData};

#[derive(Clone)]
pub struct App {
    pub(crate) event_loop: Rc<RefCell<Option<fn(Event) -> ()>>>,
    pub(crate) ime: Rc<RefCell<IME>>,

    state: Rc<RefCell<Vec<u8>>>,
    save_state: RefCell<bool>,
    frame_rate: RefCell<u32>,
}

impl App {
    pub fn new() -> Self {
        let ime = IME::new(Default::default());
        App {
            event_loop: Rc::new(RefCell::new(None)),
            state: Rc::new(RefCell::new(Vec::new())),
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
        *self.state.borrow_mut() = state;
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

    /// register event loop
    pub fn run_loop(&self, event_handle: fn(event: Event) -> ()) {
        *self.event_loop.borrow_mut() = Some(event_handle);

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
    pub(crate) app: RefCell<App>,
}

impl SaveSaver {
    pub fn save(&self, state: Vec<u8>) {
        self.app.borrow().save(state);
    }
}

pub struct SaveLoader {
    pub(crate) app: RefCell<App>,
}

impl SaveLoader {
    pub fn load(&self) -> Option<Vec<u8>> {
        self.app.borrow().load()
    }
}
