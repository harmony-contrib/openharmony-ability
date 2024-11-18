use std::{cell::RefCell, rc::Rc};

use napi_ohos::JsObject;

#[derive(Clone)]
pub struct App {
    pub(crate) event_loop: Rc<RefCell<Option<fn() -> ()>>>,

    pub(crate) ability: Rc<RefCell<Option<JsObject>>>,
    pub(crate) window: Rc<RefCell<Option<JsObject>>>,
}

impl App {
    pub fn new() -> Self {
        App {
            event_loop: Rc::new(RefCell::new(None)),
            ability: Rc::new(RefCell::new(None)),
            window: Rc::new(RefCell::new(None)),
        }
    }

    pub fn config() {}

    pub fn run_loop(&self, event_handle: fn() -> ()) {
        *self.event_loop.borrow_mut() = Some(event_handle);
    }
    
}
