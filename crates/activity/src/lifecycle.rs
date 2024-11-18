use std::{cell::RefCell, rc::Rc};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Function, Env, JsObject};

use crate::App;

#[napi(object)]
pub struct ApplicationLifecycle<'a> {
    pub on_ability_foreground: Function<'a, (), ()>,
    pub on_window_stage_create: Function<'a, (), ()>,
}

/// create lifecycle object and return to arkts
pub fn create_lifecycle_handle(env: &Env, app: Rc<RefCell<App>>) -> ApplicationLifecycle {
    let foreground_app = app.clone();
    let foreground = env
        .create_function_from_closure("on_ability_foreground", move |_ctx| {
            let app = foreground_app.borrow();
            let handle = app.event_loop.borrow_mut();
            if let Some(h) = *handle {
                h()
            }
            Ok(())
        })
        .unwrap();

    let on_window_stage_create_app = app.clone();
    let on_window_stage_create = env
        .create_function_from_closure("on_ability_create", move |ctx| {
            let ability = ctx.first_arg::<JsObject>()?;

            let on_handle: Function<(String, Function<(), ()>), ()> =
                ability.get_named_property("on")?;

            let app = on_window_stage_create_app.borrow();
            let handle = app.event_loop.clone();

            let on_handle_callback = ctx.env.create_function_from_closure("", move |_| {
                if let Some(h) = *handle.borrow_mut() {
                    h()
                }
                Ok(())
            })?;

            (*app.ability.borrow_mut()) = Some(ability);
            let event_name = String::from("windowStageEvent");
            on_handle.call((event_name, on_handle_callback))?;

            let ability_handle = app.event_loop.clone();
            if let Some(h) = *ability_handle.borrow_mut() {
                h()
            }
            Ok(())
        })
        .unwrap();
    ApplicationLifecycle {
        on_ability_foreground: foreground,
        on_window_stage_create,
    }
}
