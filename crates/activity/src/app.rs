use std::{cell::RefCell, rc::Rc};

#[derive(Clone)]
pub struct App {
    pub(crate) event_loop: Rc<RefCell<Option<fn() -> ()>>>,
}

impl App {
    pub fn new() -> Self {
        App {
            event_loop: Rc::new(RefCell::new(None)),
        }
    }

    pub fn config() {}

    pub fn run_loop(&self, event_handle: fn() -> ()) {
        *self.event_loop.borrow_mut() = Some(event_handle);
    }
    
}
