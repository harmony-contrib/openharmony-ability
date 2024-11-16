use std::{cell::RefCell, rc::Rc};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Function, Env};

use crate::App;

#[napi(object)]
pub struct ApplicationLifecycle<'a> {
    pub on_ability_foreground: Function<'a, (), ()>,
}

/// create lifecycle object and return to arkts
pub fn create_lifecycle_handle(env: &Env, app: Rc<RefCell<App>>) -> ApplicationLifecycle {
    let foreground = env
        .create_function_from_closure("on_ability_foreground", move |_ctx| {
            let app = app.borrow();
            let handle = app.event_loop.borrow_mut();
            if let Some(h) = *handle {
                h()
            }
            Ok(())
        })
        .unwrap();
    ApplicationLifecycle {
        on_ability_foreground: foreground,
    }
}
