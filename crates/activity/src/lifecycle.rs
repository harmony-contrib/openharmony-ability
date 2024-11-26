use std::cell::RefCell;

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Function, CallContext, JsObject, Result};

use crate::{event, App, ContentRect, Event, Rect, Size};

#[napi(object)]
pub struct EnvironmentCallback<'a> {
    pub on_configuration_updated: Function<'a, (), ()>,
    pub on_memory_level: Function<'a, i32, ()>,
}

#[napi(object)]
pub struct WindowStageEventCallback<'a> {
    pub on_window_stage_create: Function<'a, (), ()>,
    pub on_window_stage_destroy: Function<'a, (), ()>,
    pub on_ability_create: Function<'a, (), ()>,
    pub on_ability_destroy: Function<'a, (), ()>,
    pub on_ability_save_state: Function<'a, (), ()>,
    pub on_window_stage_event: Function<'a, i32, ()>,
    pub on_window_size_change: Function<'a, JsObject, ()>,
    pub on_window_rect_change: Function<'a, JsObject, ()>,
}

#[napi(object)]
pub struct ApplicationLifecycle<'a> {
    pub environment_callback: EnvironmentCallback<'a>,
    pub window_stage_event_callback: WindowStageEventCallback<'a>,
}

/// create lifecycle object and return to arkts
pub fn create_lifecycle_handle(
    ctx: CallContext,
    app: RefCell<App>,
) -> Result<ApplicationLifecycle> {
    let env = ctx.env;

    let memory_level_app = app.clone();
    let on_memory_level: Function<'_, i32, ()> =
        env.create_function_from_closure("memory_level", move |_ctx| {
            let event = memory_level_app.borrow();
            if let Some(h) = *event.event_loop.borrow() {
                h(Event::LowMemory)
            }
            Ok(())
        })?;

    let configuration_updated_app = app.clone();
    let on_configuration_updated =
        env.create_function_from_closure("configuration_updated", move |ctx| {
            let configuration = ctx.first_arg::<JsObject>()?;
            let language = configuration.get_named_property::<String>("config")?;
            let color_mode = configuration.get_named_property::<i32>("colorMode")?;
            let direction = configuration.get_named_property::<i32>("direction")?;
            let screen_density = configuration.get_named_property::<i32>("screenDensity")?;
            let display_id = configuration.get_named_property::<i32>("displayId")?;
            let has_pointer_device =
                configuration.get_named_property::<bool>("hasPointerDevice")?;
            let font_size_scale = configuration.get_named_property::<f64>("fontSizeScale")?;
            let font_weight_scale = configuration.get_named_property::<f64>("fontWeightScale")?;
            let mcc = configuration.get_named_property::<String>("mcc")?;
            let mnc = configuration.get_named_property::<String>("mnc")?;
            let event = configuration_updated_app.borrow();
            if let Some(h) = *event.event_loop.borrow() {
                h(Event::ConfigChanged(crate::Configuration {
                    language,
                    color_mode: color_mode.into(),
                    direction: direction.into(),
                    screen_density: screen_density.into(),
                    display_id,
                    has_pointer_device,
                    font_size_scale,
                    font_weight_scale,
                    mcc,
                    mnc,
                }))
            }
            Ok(())
        })?;

    let window_stage_event_app = app.clone();
    let window_stage_event = env.create_function_from_closure("window_stage_event", move |_| {
        let event = window_stage_event_app.borrow();
        if let Some(h) = *event.event_loop.borrow() {
            h(Event::LostFocus)
        }
        Ok(())
    })?;

    let window_size_app = app.clone();
    let window_resize = env.create_function_from_closure("window_resize", move |ctx| {
        let size = ctx.first_arg::<JsObject>()?;
        let width = size.get_named_property::<i32>("width")?;
        let height = size.get_named_property::<i32>("height")?;
        let event: std::cell::Ref<'_, App> = window_size_app.borrow();
        if let Some(h) = *event.event_loop.borrow() {
            h(Event::WindowResize(Size { width, height }))
        }
        Ok(())
    })?;

    let window_rect_app = app.clone();

    let window_rect_change =
        env.create_function_from_closure("window_rect_change", move |ctx| {
            let options = ctx.first_arg::<JsObject>()?;
            let reason = options.get_named_property::<i32>("reason")?;
            let rect = options.get_named_property::<JsObject>("rect")?;
            let top = rect.get_named_property::<i32>("top")?;
            let left = rect.get_named_property::<i32>("left")?;
            let width = rect.get_named_property::<i32>("width")?;
            let height = rect.get_named_property::<i32>("height")?;
            let event = window_rect_app.borrow();

            if let Some(h) = *event.event_loop.borrow() {
                h(Event::ContentRectChange(ContentRect {
                    reason: reason.into(),
                    rect: Rect {
                        top,
                        left,
                        width,
                        height,
                    },
                }))
            }
            Ok(())
        })?;

    let on_window_stage_create_app = app.clone();
    let on_window_stage_create =
        env.create_function_from_closure("on_ability_create", move |ctx| {
            let event = on_window_stage_create_app.borrow();
            if let Some(h) = *event.event_loop.borrow() {
                h(Event::WindowCreate)
            }
            Ok(())
        })?;

    let on_window_stage_destroy_app = app.clone();
    let on_window_stage_destroy =
        env.create_function_from_closure("on_window_stage_destroy", move |_ctx| {
            let event = on_window_stage_destroy_app.borrow();
            if let Some(h) = *event.event_loop.borrow() {
                h(Event::WindowDestroy)
            }
            Ok(())
        })?;

    let on_ability_create_app = app.clone();
    let on_ability_create = env.create_function_from_closure("on_ability_create", move |_ctx| {
        let event = on_ability_create_app.borrow();
        if let Some(h) = *event.event_loop.borrow() {
            h(Event::Start)
        }
        Ok(())
    })?;

    let on_ability_destroy_app = app.clone();
    let on_ability_destroy =
        env.create_function_from_closure("on_ability_destroy", move |_ctx| {
            let event = on_ability_destroy_app.borrow();
            if let Some(h) = *event.event_loop.borrow() {
                h(Event::Destroy)
            }
            Ok(())
        })?;

    let on_ability_save_state_app = app.clone();
    let on_ability_save_state =
        env.create_function_from_closure("on_ability_save_state", move |_ctx| {
            let event = on_ability_save_state_app.borrow();
            if let Some(h) = *event.event_loop.borrow() {
                h(Event::SaveState)
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
            on_ability_save_state,
            on_window_rect_change: window_rect_change,
            on_window_size_change: window_resize,
            on_window_stage_event: window_stage_event,
        },
    })
}
