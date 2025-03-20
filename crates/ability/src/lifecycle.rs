use std::sync::Arc;

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Function, Env, JsObject, Result};

use crate::{
    ArkHelper, ArkTSHelper, ContentRect, Event, OpenHarmonyApp, Rect, SaveLoader, SaveSaver, Size,
    StageEventType, WAKER,
};

#[napi(object)]
pub struct EnvironmentCallback<'a> {
    pub on_configuration_updated: Function<'a, (), ()>,
    pub on_memory_level: Function<'a, i32, ()>,
}

#[napi(object)]
pub struct WindowStageEventCallback<'a> {
    pub on_window_stage_create: Function<'a, (), ()>,
    pub on_window_stage_destroy: Function<'a, (), ()>,
    pub on_ability_create: Function<'a, String, ()>,
    pub on_ability_destroy: Function<'a, (), ()>,
    pub on_ability_save_state: Function<'a, (), ()>,
    pub on_ability_restore_state: Function<'a, (), ()>,
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
pub fn create_lifecycle_handle<'a>(
    env: &'a Env,
    helper: ArkTSHelper,
    app: OpenHarmonyApp,
) -> Result<ApplicationLifecycle<'a>> {
    let ark_helper = helper;
    let helper = ArkHelper::from_ark_ts_helper(ark_helper)?;

    app.inner.write().unwrap().helper.ark = Some(helper);

    let waker_app = app.clone();
    let waker: Function<'_, (), ()> = env.create_function_from_closure("waker", move |_ctx| {
        if let Some(ref mut h) = *waker_app.event_loop.borrow_mut() {
            h(Event::UserEvent)
        }

        Ok(())
    })?;

    let tsfn = waker
        .build_threadsafe_function()
        .callee_handled::<true>()
        .build()?;

    {
        let mut guard = (&*WAKER)
            .write()
            .map_err(|_| napi_ohos::Error::from_reason("Failed to write WAKER"))?;

        guard.replace(Arc::new(tsfn));
    }

    let on_memory_level_app = app.clone();
    let on_memory_level: Function<'_, i32, ()> =
        env.create_function_from_closure("memory_level", move |_ctx| {
            if let Some(ref mut h) = *on_memory_level_app.event_loop.borrow_mut() {
                h(Event::LowMemory)
            }
            Ok(())
        })?;

    let configuration_updated_app = app.clone();
    let on_configuration_updated =
        env.create_function_from_closure("configuration_updated", move |ctx| {
            let configuration = ctx.first_arg::<JsObject>()?;
            let language = configuration.get_named_property::<String>("language")?;
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

            let configuration = crate::Configuration {
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
            };
            configuration_updated_app
                .inner
                .write()
                .unwrap()
                .configuration = configuration.clone();
            let conf = configuration.clone();
            if let Some(ref mut h) = *configuration_updated_app.event_loop.borrow_mut() {
                h(Event::ConfigChanged(conf))
            }
            Ok(())
        })?;

    let window_stage_event_app = app.clone();
    let window_stage_event =
        env.create_function_from_closure("window_stage_event", move |ctx| {
            let event_type = ctx.first_arg::<i32>()?;

            if let Some(ref mut h) = *window_stage_event_app.event_loop.borrow_mut() {
                let state_event = StageEventType::from(event_type);
                let e = match state_event {
                    StageEventType::Shown => Event::Start,
                    StageEventType::Active => Event::GainedFocus,
                    StageEventType::Inactive => Event::LostFocus,
                    StageEventType::Hidden => Event::Stop,
                    StageEventType::Resumed => Event::Resume(SaveLoader {
                        app: &window_stage_event_app,
                    }),
                    StageEventType::Paused => Event::Pause,
                };
                h(e)
            }
            Ok(())
        })?;

    let window_resize_app = app.clone();
    let window_resize = env.create_function_from_closure("window_resize", move |ctx| {
        let size = ctx.first_arg::<JsObject>()?;
        let width = size.get_named_property::<i32>("width")?;
        let height = size.get_named_property::<i32>("height")?;

        if let Some(ref mut h) = *window_resize_app.event_loop.borrow_mut() {
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

            let rect = Rect {
                top,
                left,
                width,
                height,
            };
            window_rect_app.inner.write().unwrap().rect = rect;

            let rect = rect.clone();

            if let Some(ref mut h) = *window_rect_app.event_loop.borrow_mut() {
                h(Event::ContentRectChange(ContentRect {
                    reason: reason.into(),
                    rect,
                }))
            }
            Ok(())
        })?;

    let on_window_stage_create_app = app.clone();
    let on_window_stage_create =
        env.create_function_from_closure("on_ability_create", move |_ctx| {
            if let Some(ref mut h) = *on_window_stage_create_app.event_loop.borrow_mut() {
                h(Event::WindowCreate)
            }
            Ok(())
        })?;

    let on_window_stage_destroy_app = app.clone();
    let on_window_stage_destroy =
        env.create_function_from_closure("on_window_stage_destroy", move |_ctx| {
            if let Some(ref mut h) = *on_window_stage_destroy_app.event_loop.borrow_mut() {
                h(Event::WindowDestroy)
            }
            Ok(())
        })?;

    let on_ability_create_app = app.clone();
    let on_ability_create = env.create_function_from_closure("on_ability_create", move |_ctx| {
        if let Some(ref mut h) = *on_ability_create_app.event_loop.borrow_mut() {
            h(Event::Create)
        }
        Ok(())
    })?;

    let on_ability_destroy_app = app.clone();
    let on_ability_destroy =
        env.create_function_from_closure("on_ability_destroy", move |_ctx| {
            if let Some(ref mut h) = *on_ability_destroy_app.event_loop.borrow_mut() {
                h(Event::Destroy)
            }
            Ok(())
        })?;

    let on_ability_restore_state_app = app.clone();

    let on_ability_restore_state =
        env.create_function_from_closure("on_ability_restore_state", move |_ctx| {
            let save_loader = SaveLoader {
                app: &on_ability_restore_state_app,
            };

            if let Some(ref mut h) = *on_ability_restore_state_app.event_loop.borrow_mut() {
                h(Event::Resume(save_loader))
            }
            Ok(())
        })?;

    let on_ability_save_state_app = app.clone();
    let on_ability_save_state =
        env.create_function_from_closure("on_ability_save_state", move |_ctx| {
            let save_saver = SaveSaver {
                app: &on_ability_save_state_app,
            };

            if let Some(ref mut h) = *on_ability_save_state_app.event_loop.borrow_mut() {
                h(Event::SaveState(save_saver))
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
            on_ability_restore_state,
            on_window_rect_change: window_rect_change,
            on_window_size_change: window_resize,
            on_window_stage_event: window_stage_event,
        },
    })
}
