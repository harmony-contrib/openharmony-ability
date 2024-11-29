use std::{cell::RefCell, rc::Rc};

use crate::Event;

#[derive(Clone)]
pub struct App {
    pub(crate) event_loop: Rc<RefCell<Option<fn(Event) -> ()>>>,

    state: Rc<RefCell<Vec<u8>>>,
    save_state: RefCell<bool>,
    frame_rate: RefCell<u32>,
}

impl App {
    pub fn new() -> Self {
        App {
            event_loop: Rc::new(RefCell::new(None)),
            state: Rc::new(RefCell::new(Vec::new())),
            save_state: RefCell::new(false),
            frame_rate: RefCell::new(60),
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

    /// register event loop
    pub fn run_loop(&self, event_handle: fn(event: Event) -> ()) {
        *self.event_loop.borrow_mut() = Some(event_handle);
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
