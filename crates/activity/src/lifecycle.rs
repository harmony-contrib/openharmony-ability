use std::{
    cell::RefCell,
    rc::Rc,
    sync::{LazyLock, Mutex},
};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Function, CallContext, Error, JsObject, Result};
use ohos_arkui_binding::{ArkUIHandle, RootNode, XComponent};
use ohos_hilog_binding::hilog_info;

use crate::{App, ContentRect, Event, Rect, Size};

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
    pub on_ability_save_state: Function<'a, (), ()>,
}

#[napi(object)]
pub struct ApplicationLifecycle<'a> {
    pub environment_callback: EnvironmentCallback<'a>,
    pub window_stage_event_callback: WindowStageEventCallback<'a>,
}

static GL_CTX: LazyLock<Mutex<Option<RootNode>>> = LazyLock::new(|| Mutex::new(None));

/// create lifecycle object and return to arkts
pub fn create_lifecycle_handle(
    ctx: CallContext,
    app: Rc<RefCell<App>>,
) -> Result<ApplicationLifecycle> {
    let slot = ctx.get::<ArkUIHandle>(0)?;
    let mut this: JsObject = ctx.this_unchecked();
    let env = ctx.env;

    let mut root = RootNode::new(slot);
    {
        let mut gl_ctx_guard = GL_CTX.lock().unwrap();
        *gl_ctx_guard = Some(root);
    }
    // let mut this: This = ctx.this_unchecked();
    // ref the root avoid dropping
    // env.wrap(&mut this, root, None)?;
    let xcomponent_native = XComponent::new().map_err(|e| Error::from_reason(e.reason))?;

    let xcomponent = xcomponent_native.native_xcomponent();

    xcomponent.on_surface_created(|_, _| {
        hilog_info!("ohos-rs macro on_surface_created");
        Ok(())
    });

    xcomponent.register_callback()?;

    // TODO: on_frame_callback will crash if xcomponent is created by C API
    // TODO: System will provide a new method to add callback for redraw
    // let redraw_app = app.clone();
    // xcomponent.on_frame_callback(move |_xcomponent, _time, _time_stamp| {
    //     let event = redraw_app.borrow();
    //     if let Some(h) = *event.event_loop.borrow() {
    //         h(Event::WindowRedraw)
    //     }
    //     Ok(())
    // })?;

    {
        let mut gl_ctx_guard = GL_CTX.lock().unwrap();
        match &mut *gl_ctx_guard {
            Some(root) => {
                root.mount(xcomponent_native)
                    .map_err(|e| Error::from_reason(e.reason))?;
            }
            None => {}
        }
    }

    let memory_level_app = app.clone();
    let on_memory_level = env.create_function_from_closure("memory_level", move |_ctx| {
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
                            h(Event::LostFocus)
                        }
                        Ok(())
                    })?;
            let event_func_name = String::from("windowStageEvent");
            on_handle.call((event_func_name, window_stage_event))?;

            let window_size_handle = app.event_loop.clone();
            let window_resize = ctx.env.create_function_from_closure(
                "window_resize",
                move |window_resize_ctx| {
                    let size = window_resize_ctx.first_arg::<JsObject>()?;
                    let width = size.get_named_property::<i32>("width")?;
                    let height = size.get_named_property::<i32>("height")?;
                    if let Some(h) = *window_size_handle.borrow_mut() {
                        h(Event::WindowResize(Size { width, height }))
                    }
                    Ok(())
                },
            )?;

            let window_size_func_name = String::from("windowSizeChange");
            on_handle.call((window_size_func_name, window_resize))?;

            let window_rect_handle = app.event_loop.clone();
            let window_rect_change = ctx.env.create_function_from_closure(
                "window_rect_change",
                move |window_rect_change_ctx| {
                    let options = window_rect_change_ctx.first_arg::<JsObject>()?;
                    let reason = options.get_named_property::<i32>("reason")?;
                    let rect = options.get_named_property::<JsObject>("rect")?;
                    let top = rect.get_named_property::<i32>("top")?;
                    let left = rect.get_named_property::<i32>("left")?;
                    let width = rect.get_named_property::<i32>("width")?;
                    let height = rect.get_named_property::<i32>("height")?;

                    if let Some(h) = *window_rect_handle.borrow_mut() {
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
                },
            )?;

            let window_rect_func_name = String::from("windowRectChange");
            on_handle.call((window_rect_func_name, window_rect_change))?;

            let ability_handle = app.event_loop.clone();
            if let Some(h) = *ability_handle.borrow_mut() {
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
        },
    })
}
