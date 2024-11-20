use std::{cell::RefCell, rc::Rc};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Function, CallContext, JsObject, Result};
use ohos_arkui_binding::ArkUIHandle;

use crate::App;

#[napi(object)]
pub struct EnvironmentCallback<'a> {
    pub on_configuration_updated: Function<'a, (), ()>,
    pub on_memory_level: Function<'a, (), ()>,
}

#[napi(object)]
pub struct WindowStageEventCallback<'a> {
    pub on_window_stage_create: Function<'a, (), ()>,
    pub on_window_stage_destroy: Function<'a, (), ()>,
    pub on_ability_create: Function<'a, (), ()>,
    pub on_ability_destroy: Function<'a, (), ()>,
}

#[napi(object)]
pub struct ApplicationLifecycle<'a> {
    pub environment_callback: EnvironmentCallback<'a>,
    pub window_stage_event_callback: WindowStageEventCallback<'a>,
}

/// create lifecycle object and return to arkts
pub fn create_lifecycle_handle(
    ctx: CallContext,
    app: Rc<RefCell<App>>,
) -> Result<ApplicationLifecycle> {
    let slot = ctx.get::<ArkUIHandle>(0)?;
    let env = ctx.env;

    let memory_level_app = app.clone();
    let on_memory_level = env.create_function_from_closure("memory_level", move |_ctx| {
        let event = memory_level_app.borrow();
        if let Some(h) = *event.event_loop.borrow() {
            h()
        }
        Ok(())
    })?;

    let configuration_updated_app = app.clone();
    let on_configuration_updated =
        env.create_function_from_closure("configuration_updated", move |_ctx| {
            let event = configuration_updated_app.borrow();
            if let Some(h) = *event.event_loop.borrow() {
                h()
            }
            Ok(())
        })?;

    let on_window_stage_create_app = app.clone();
    let on_window_stage_create =
        env.create_function_from_closure("on_ability_create", move |ctx| {
            let ability = ctx.first_arg::<JsObject>()?;

            let on_handle: Function<(String, Function<(), ()>), ()> =
                ability.get_named_property("on")?;

            let app = on_window_stage_create_app.borrow();
            (*app.ability.borrow_mut()) = Some(ability);
            let window_stage_event_handle = app.event_loop.clone();

            let window_stage_event =
                ctx.env
                    .create_function_from_closure("window_stage_event", move |_| {
                        if let Some(h) = *window_stage_event_handle.borrow_mut() {
                            h()
                        }
                        Ok(())
                    })?;
            let event_func_name = String::from("windowStageEvent");
            on_handle.call((event_func_name, window_stage_event))?;

            let window_size_handle = app.event_loop.clone();
            let window_resize =
                ctx.env
                    .create_function_from_closure("window_resize", move |_| {
                        if let Some(h) = *window_size_handle.borrow_mut() {
                            h()
                        }
                        Ok(())
                    })?;

            let window_size_func_name = String::from("windowSizeChange");
            on_handle.call((window_size_func_name, window_resize))?;

            let window_rect_handle = app.event_loop.clone();
            let window_rect_change =
                ctx.env
                    .create_function_from_closure("window_rect_change", move |_| {
                        if let Some(h) = *window_rect_handle.borrow_mut() {
                            h()
                        }
                        Ok(())
                    })?;

            let window_rect_func_name = String::from("windowRectChange");
            on_handle.call((window_rect_func_name, window_rect_change))?;

            let ability_handle = app.event_loop.clone();
            if let Some(h) = *ability_handle.borrow_mut() {
                h()
            }
            Ok(())
        })?;

    let on_window_stage_destroy_app = app.clone();
    let on_window_stage_destroy =
        env.create_function_from_closure("on_window_stage_destroy", move |_ctx| {
            let event = on_window_stage_destroy_app.borrow();
            if let Some(h) = *event.event_loop.borrow() {
                h()
            }
            Ok(())
        })?;

    let on_ability_create_app = app.clone();
    let on_ability_create = env.create_function_from_closure("on_ability_create", move |_ctx| {
        let event = on_ability_create_app.borrow();
        if let Some(h) = *event.event_loop.borrow() {
            h()
        }
        Ok(())
    })?;

    let on_ability_destroy_app = app.clone();
    let on_ability_destroy =
        env.create_function_from_closure("on_ability_destroy", move |_ctx| {
            let event = on_ability_destroy_app.borrow();
            if let Some(h) = *event.event_loop.borrow() {
                h()
            }
            Ok(())
        })?;

    Ok(ApplicationLifecycle {
        environment_callback: EnvironmentCallback {
            on_configuration_updated,
            on_memory_level,
        },
        window_stage_event_callback: WindowStageEventCallback {
            on_window_stage_create,
            on_window_stage_destroy,
            on_ability_create,
            on_ability_destroy,
        },
    })
}
