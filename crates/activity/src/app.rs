use std::{cell::RefCell, rc::Rc};

use crate::Event;

#[derive(Clone)]
pub struct App {
    pub(crate) event_loop: Rc<RefCell<Option<fn(Event) -> ()>>>,

    pub(crate) state: Rc<RefCell<Vec<u8>>>,
    pub(crate) save_state: bool,
}

impl App {
    pub fn new() -> Self {
        App {
            event_loop: Rc::new(RefCell::new(None)),
            state: Rc::new(RefCell::new(Vec::new())),
            save_state: false,
        }
    }

    /// load current app state
    pub fn load(&self) -> Option<Vec<u8>> {
        if self.save_state {
            Some(self.state.borrow().clone())
        } else {
            None
        }
    }

    /// save current app state
    pub fn save(&self, state: Vec<u8>) {
        *self.state.borrow_mut() = state;
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
