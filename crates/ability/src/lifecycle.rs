use std::sync::Arc;

use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{Function, JsObjectValue, Object},
    Env, Result,
};

use crate::{
    AvoidArea, AvoidAreaInfo, AvoidAreaType, BridgePluginDeclaration, ContentRect, Event,
    OpenHarmonyApp, PluginLifecycleEvent, Rect, SaveLoader, SaveSaver, Size, StageEventType, WAKER,
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
    pub on_window_size_change: Function<'a, Object<'a>, ()>,
    pub on_window_rect_change: Function<'a, Object<'a>, ()>,
    pub on_avoid_area_change: Function<'a, Object<'a>, ()>,
    pub on_new_want: Function<'a, Object<'a>, ()>,
    pub on_ability_create_with_want: Function<'a, Object<'a>, ()>,
}

#[napi(object)]
pub struct KeyboardCallback<'a> {
    pub on_keyboard_height_change: Function<'a, i32, ()>,
}

#[napi(object)]
pub struct ApplicationLifecycle<'a> {
    pub bridge_plugins: Vec<BridgePluginDeclaration>,
    pub environment_callback: EnvironmentCallback<'a>,
    pub window_stage_event_callback: WindowStageEventCallback<'a>,
    pub keyboard_event_callback: KeyboardCallback<'a>,
}

fn parse_rect(rect: Object<'_>) -> Result<Rect> {
    let top = rect.get_named_property::<i32>("top")?;
    let left = rect.get_named_property::<i32>("left")?;
    let width = rect.get_named_property::<i32>("width")?;
    let height = rect.get_named_property::<i32>("height")?;
    Ok(Rect {
        top,
        left,
        width,
        height,
    })
}

/// create lifecycle object and return to arkts
pub fn create_lifecycle_handle<'a>(
    env: &'a Env,
    app: OpenHarmonyApp,
) -> Result<ApplicationLifecycle<'a>> {
    let bridge_plugins = app.bridge_plugin_declarations()?;
    let waker_app = app.clone();
    let waker: Function<'_, (), ()> = env.create_function_from_closure("waker", move |_ctx| {
        if let Some(ref mut h) = *waker_app.event_loop.borrow_mut() {
            h(Event::UserEvent)
        }

        Ok(())
    })?;

    let tsfn = waker
        .build_threadsafe_function()
        // false matches every other TSFN in this crate (issue #87 minor-1);
        // the closure always returns Ok(()) so the callee-handled error-first
        // argument was never observed.
        .callee_handled::<false>()
        .build()?;

    {
        let mut guard = (*WAKER)
            .write()
            .map_err(|_| napi_ohos::Error::from_reason("Failed to write WAKER"))?;

        guard.replace(Arc::new(tsfn));
    }

    let on_memory_level_app = app.clone();
    let on_memory_level: Function<'_, i32, ()> =
        env.create_function_from_closure("memory_level", move |ctx| {
            let level = ctx.first_arg::<i32>()?;
            let _ = on_memory_level_app
                .dispatch_plugin_lifecycle(PluginLifecycleEvent::MemoryLevel { level });
            if let Some(ref mut h) = *on_memory_level_app.event_loop.borrow_mut() {
                h(Event::LowMemory)
            }
            Ok(())
        })?;

    let configuration_updated_app = app.clone();
    let on_configuration_updated =
        env.create_function_from_closure("configuration_updated", move |ctx| {
            let configuration = ctx.first_arg::<Object>()?;
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
            let _ = configuration_updated_app
                .dispatch_plugin_lifecycle(PluginLifecycleEvent::ConfigurationUpdated);
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
            let _ = window_stage_event_app
                .dispatch_plugin_lifecycle(PluginLifecycleEvent::WindowStageEvent { event_type });

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

    // Phase 3 (design.md D6 / task 3.5): ArkTS wraps onWindowSizeChange options as
    // { windowId, width, height }. We read windowId here so tao's run_loop can route
    // WindowResize to the originating window instead of always the main window.
    // windowId is read with a fallback to 0 (main window): a registration path that
    // does not yet wrap the options degrades to the old main-window behavior rather
    // than failing the callback (same tolerance as window_rect_change above).
    let window_resize_app = app.clone();
    let window_resize = env.create_function_from_closure("window_resize", move |ctx| {
        let size = ctx.first_arg::<Object>()?;
        let width = size.get_named_property::<i32>("width")?;
        let height = size.get_named_property::<i32>("height")?;
        let window_id = size.get_named_property::<i64>("windowId").unwrap_or(0);

        if let Some(ref mut h) = *window_resize_app.event_loop.borrow_mut() {
            h(Event::WindowResize {
                window_id,
                size: Size { width, height },
            })
        }
        Ok(())
    })?;

    // TODO: we may can remove it
    // Phase 2 (design.md D2/D4): the ArkTS side wraps windowRectChange options as
    // { windowId, reason, rect }. We read windowId here and route the rect into the
    // per-window HashMap (set_window_rect) instead of the old shared single field.
    // windowId is read with a fallback to 0 (main window): some registration points may
    // not yet wrap the options (e.g. a path added later) — degrading to the old main-
    // window behavior is preferable to erroring out the whole callback.
    let window_rect_app = app.clone();
    let window_rect_change =
        env.create_function_from_closure("window_rect_change", move |ctx| {
            let options = ctx.first_arg::<Object>()?;
            let reason = options.get_named_property::<i32>("reason")?;
            let rect = parse_rect(options.get_named_property::<Object>("rect")?)?;
            // windowId is optional-with-fallback: missing or wrong type degrades to 0
            // (main window) rather than failing the callback.
            let window_id = options.get_named_property::<i64>("windowId").unwrap_or(0);
            window_rect_app.set_window_rect(window_id, rect);

            if let Some(ref mut h) = *window_rect_app.event_loop.borrow_mut() {
                h(Event::ContentRectChange(ContentRect {
                    reason: reason.into(),
                    rect,
                    window_id,
                }))
            }
            Ok(())
        })?;

    let avoid_area_change_app = app.clone();
    let avoid_area_change = env.create_function_from_closure("avoid_area_change", move |ctx| {
        let options = ctx.first_arg::<Object>()?;
        let area_type = AvoidAreaType::from(options.get_named_property::<i32>("type")?);
        let area = options.get_named_property::<Object>("area")?;
        let visible = area.get_named_property::<bool>("visible")?;
        let avoid_area = AvoidArea {
            visible,
            left_rect: parse_rect(area.get_named_property::<Object>("leftRect")?)?,
            top_rect: parse_rect(area.get_named_property::<Object>("topRect")?)?,
            right_rect: parse_rect(area.get_named_property::<Object>("rightRect")?)?,
            bottom_rect: parse_rect(area.get_named_property::<Object>("bottomRect")?)?,
        };

        {
            let mut inner = avoid_area_change_app.inner.write().unwrap();
            inner.avoid_areas.insert(area_type, avoid_area);
        }

        if let Some(ref mut h) = *avoid_area_change_app.event_loop.borrow_mut() {
            h(Event::AvoidAreaChange(AvoidAreaInfo {
                area_type,
                area: avoid_area,
            }))
        }
        Ok(())
    })?;

    let on_window_stage_create_app = app.clone();
    let on_window_stage_create =
        env.create_function_from_closure("on_ability_create", move |_ctx| {
            let _ = on_window_stage_create_app
                .dispatch_plugin_lifecycle(PluginLifecycleEvent::WindowStageCreated);
            if let Some(ref mut h) = *on_window_stage_create_app.event_loop.borrow_mut() {
                h(Event::WindowCreate)
            }
            Ok(())
        })?;

    let on_window_stage_destroy_app = app.clone();
    let on_window_stage_destroy =
        env.create_function_from_closure("on_window_stage_destroy", move |_ctx| {
            let _ = on_window_stage_destroy_app
                .dispatch_plugin_lifecycle(PluginLifecycleEvent::WindowStageDestroyed);
            if let Some(ref mut h) = *on_window_stage_destroy_app.event_loop.borrow_mut() {
                h(Event::WindowDestroy)
            }
            Ok(())
        })?;

    let on_ability_create_app = app.clone();
    let on_ability_create: Function<'_, String, ()> =
        env.create_function_from_closure("on_ability_create", move |ctx| {
            let restored_state = ctx.first_arg::<String>().unwrap_or_default();
            let _ = on_ability_create_app
                .dispatch_plugin_lifecycle(PluginLifecycleEvent::AbilityCreated { restored_state });
            if let Some(ref mut h) = *on_ability_create_app.event_loop.borrow_mut() {
                h(Event::Create)
            }
            Ok(())
        })?;

    let on_ability_destroy_app = app.clone();
    let on_ability_destroy =
        env.create_function_from_closure("on_ability_destroy", move |_ctx| {
            let _ = on_ability_destroy_app
                .dispatch_plugin_lifecycle(PluginLifecycleEvent::AbilityDestroyed);
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

    let keyboard_event_callback_app = app.clone();
    let keyboard_event_callback =
        env.create_function_from_closure("keyboard_event_callback", move |ctx| {
            let event_type = ctx.first_arg::<i32>()?;
            if let Some(ref mut h) = *keyboard_event_callback_app.event_loop.borrow_mut() {
                h(Event::KeyboardEvent(event_type))
            }
            Ok(())
        })?;

    let on_new_want_app = app.clone();
    let on_new_want = env.create_function_from_closure("on_new_want", move |ctx| {
        let data = ctx.first_arg::<Object>()?;
        let uri = data.get_named_property::<String>("uri")?;
        let parameters_json = data.get_named_property::<String>("parametersJson")?;
        // Session state rides the app instance now (issue #87 major-9).
        on_new_want_app.store_want_parameters(&parameters_json);
        // isContinuation is optional-with-fallback: missing or wrong type
        // (older HAR payload) degrades to false rather than failing the callback.
        let is_continuation = data
            .get_named_property::<bool>("isContinuation")
            .unwrap_or(false);
        on_new_want_app.store_continuation(is_continuation, &parameters_json);
        if let Some(ref mut h) = *on_new_want_app.event_loop.borrow_mut() {
            h(Event::NewWant { uri })
        }
        Ok(())
    })?;

    let on_ability_create_with_want_app = app.clone();
    let on_ability_create_with_want =
        env.create_function_from_closure("on_ability_create_with_want", move |ctx| {
            let data = ctx.first_arg::<Object>()?;
            let uri = data.get_named_property::<String>("uri")?;
            on_ability_create_with_want_app.store_initial_want_uri(&uri);
            // Continuation fields are optional-with-fallback: missing or wrong
            // type (older HAR payload) degrades to false / empty rather than
            // failing the callback.
            let is_continuation = data
                .get_named_property::<bool>("isContinuation")
                .unwrap_or(false);
            let parameters_json = data
                .get_named_property::<String>("parametersJson")
                .unwrap_or_default();
            on_ability_create_with_want_app.store_continuation(is_continuation, &parameters_json);
            Ok(())
        })?;

    Ok(ApplicationLifecycle {
        bridge_plugins,
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
            on_avoid_area_change: avoid_area_change,
            on_window_stage_event: window_stage_event,
            on_new_want,
            on_ability_create_with_want,
        },
        keyboard_event_callback: KeyboardCallback {
            on_keyboard_height_change: keyboard_event_callback,
        },
    })
}
