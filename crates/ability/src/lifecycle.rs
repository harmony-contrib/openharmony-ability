use std::sync::Arc;

use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{Function, FunctionCallContext, JsObjectValue, Object},
    Env, Result,
};

use crate::{
    AvoidArea, AvoidAreaInfo, AvoidAreaType, BridgePluginDeclaration, ContentRect, Event,
    OpenHarmonyApp, PluginLifecycleEvent, Rect, SaveLoader, SaveSaver, Size, StageEventType,
};

#[napi(object)]
/// ArkTS-side environment callbacks (`EnvironmentCallback` pair).
pub struct EnvironmentCallback<'a> {
    /// Invoked when device configuration changes (language, color mode, ...).
    pub on_configuration_updated: Function<'a, (), ()>,
    /// Invoked when the system memory level changes.
    pub on_memory_level: Function<'a, i32, ()>,
}

#[napi(object)]
/// ArkTS-side ability / window-stage lifecycle callback bundle.
pub struct WindowStageEventCallback<'a> {
    /// Invoked when the window stage is created.
    pub on_window_stage_create: Function<'a, (), ()>,
    /// Invoked when the window stage is destroyed.
    pub on_window_stage_destroy: Function<'a, (), ()>,
    /// Invoked on ability create; receives the launch parameter string.
    pub on_ability_create: Function<'a, String, ()>,
    /// Invoked on ability destroy.
    pub on_ability_destroy: Function<'a, (), ()>,
    /// Invoked when the system asks the ability to save its state.
    pub on_ability_save_state: Function<'a, (), ()>,
    /// Invoked when the system asks the ability to restore saved state.
    pub on_ability_restore_state: Function<'a, (), ()>,
    /// Invoked on window stage show/hide/active/inactive transitions.
    pub on_window_stage_event: Function<'a, i32, ()>,
    /// Invoked on window resize; receives the wrapped size object.
    pub on_window_size_change: Function<'a, Object<'a>, ()>,
    /// Invoked on content-rect change; receives the wrapped rect object.
    pub on_window_rect_change: Function<'a, Object<'a>, ()>,
    /// Invoked when an avoid area changes; receives the wrapped area object.
    pub on_avoid_area_change: Function<'a, Object<'a>, ()>,
    /// Invoked on `onNewWant` (deep link); receives the wrapped want object.
    pub on_new_want: Function<'a, Object<'a>, ()>,
    /// Invoked on ability create; receives the full want object.
    pub on_ability_create_with_want: Function<'a, Object<'a>, ()>,
    /// PC/2in1 pre-close probe (UIAbility.onPrepareToTerminateAsync). Returns
    /// `true` to CANCEL this termination (the app stays alive), `false` to
    /// allow it (the system proceeds to the normal destroy chain).
    pub on_prepare_to_terminate: Function<'a, (), bool>,
}

#[napi(object)]
/// ArkTS-side keyboard callbacks.
pub struct KeyboardCallback<'a> {
    /// Invoked when the soft keyboard height changes (px; 0 = hidden).
    pub on_keyboard_height_change: Function<'a, i32, ()>,
}

#[napi(object)]
/// Top-level lifecycle bundle the ArkTS entry hands to the Rust runtime.
pub struct ApplicationLifecycle<'a> {
    /// Plugin declarations to register into the bridge registry.
    pub bridge_plugins: Vec<BridgePluginDeclaration>,
    /// Environment callback pair (configuration / memory level).
    pub environment_callback: EnvironmentCallback<'a>,
    /// Ability / window-stage callback bundle.
    pub window_stage_event_callback: WindowStageEventCallback<'a>,
    /// Keyboard callback bundle.
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

/// Reads the UIAbility window id that ArkTS appends to lifecycle callbacks
/// (design.md D3/D8, openspec multi-uiability-windows).
///
/// The id arrives as the trailing numeric argument of each callback: index 0 for
/// callbacks without a payload, index 1 when the first argument is the payload
/// object. A missing, null, or non-number argument degrades to the primary
/// window (0) so an outdated HAR caller keeps the single-instance behavior.
fn window_id_arg(ctx: &FunctionCallContext<'_>, index: usize) -> i64 {
    ctx.get::<Option<i64>>(index).ok().flatten().unwrap_or(0)
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
        // Install the TSFN into the app's per-app waker slot (design.md D10,
        // openspec multi-uiability-windows - replaces the old process-global
        // WAKER). Every OpenHarmonyWaker handle created via `create_waker`
        // reads this slot live at wake() time.
        let tsfn = Arc::new(tsfn);
        {
            let mut guard = waker_app
                .waker
                .write()
                .map_err(|_| napi_ohos::Error::from_reason("Failed to write app waker slot"))?;
            guard.replace(tsfn.clone());
        }
        // Process-level alias for NAPI free fns without an app handle
        // (notify_window_close → wake_installed_app). Exact under the NG4
        // one-app-per-process invariant; see waker.rs.
        crate::waker::install_app_waker_alias(tsfn);
    }

    let on_memory_level_app = app.clone();
    let on_memory_level: Function<'_, i32, ()> =
        env.create_function_from_closure("memory_level", move |ctx| {
            let level = ctx.first_arg::<i32>()?;
            let window_id = window_id_arg(&ctx, 1);
            let _ = on_memory_level_app
                .dispatch_plugin_lifecycle(PluginLifecycleEvent::MemoryLevel { window_id, level });
            if window_id == 0 {
                if let Some(ref mut h) = *on_memory_level_app.event_loop.borrow_mut() {
                    h(Event::LowMemory)
                }
            }
            Ok(())
        })?;

    let on_configuration_updated = make_on_configuration_updated(env, app.clone())?;

    let window_stage_event = make_on_window_stage_event(env, app.clone())?;

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
    // { windowId, reason, rect, drawable? } - see make_on_window_rect_change.
    let window_rect_change = make_on_window_rect_change(env, app.clone())?;

    let avoid_area_change = make_on_avoid_area_change(env, app.clone())?;

    let on_window_stage_create_app = app.clone();
    let on_window_stage_create =
        env.create_function_from_closure("on_ability_create", move |ctx| {
            let window_id = window_id_arg(&ctx, 0);
            let _ = on_window_stage_create_app
                .dispatch_plugin_lifecycle(PluginLifecycleEvent::WindowStageCreated { window_id });
            if window_id == 0 {
                if let Some(ref mut h) = *on_window_stage_create_app.event_loop.borrow_mut() {
                    h(Event::WindowCreate)
                }
            }
            Ok(())
        })?;

    let on_window_stage_destroy_app = app.clone();
    let on_window_stage_destroy =
        env.create_function_from_closure("on_window_stage_destroy", move |ctx| {
            let window_id = window_id_arg(&ctx, 0);
            let _ = on_window_stage_destroy_app.dispatch_plugin_lifecycle(
                PluginLifecycleEvent::WindowStageDestroyed { window_id },
            );
            // Phase 4 (design.md D5): dispatch per-window - a spawned instance's
            // stage teardown reaches its own tao window (CloseRequested +
            // Destroyed for that id) so tauri-runtime-wry cleans the window
            // store entry; the primary (0) keeps its historical exit-chain
            // semantics unchanged.
            if let Some(ref mut h) = *on_window_stage_destroy_app.event_loop.borrow_mut() {
                h(Event::WindowDestroy { window_id })
            }
            Ok(())
        })?;

    let on_ability_create_app = app.clone();
    let on_ability_create: Function<'_, String, ()> =
        env.create_function_from_closure("on_ability_create", move |ctx| {
            let restored_state = ctx.first_arg::<String>().unwrap_or_default();
            let window_id = window_id_arg(&ctx, 1);
            let _ = on_ability_create_app.dispatch_plugin_lifecycle(
                PluginLifecycleEvent::AbilityCreated {
                    window_id,
                    restored_state,
                },
            );
            if window_id == 0 {
                if let Some(ref mut h) = *on_ability_create_app.event_loop.borrow_mut() {
                    h(Event::Create)
                }
            }
            Ok(())
        })?;

    let on_ability_destroy_app = app.clone();
    let on_ability_destroy =
        env.create_function_from_closure("on_ability_destroy", move |ctx| {
            let window_id = window_id_arg(&ctx, 0);
            let _ = on_ability_destroy_app
                .dispatch_plugin_lifecycle(PluginLifecycleEvent::AbilityDestroyed { window_id });
            // D13 teardown: drop every remaining per-window registry entry for
            // this destroyed instance (handshake, want storage, label map,
            // rects). Runs after the plugin dispatch so bridge plugins observe
            // the event before their per-window state disappears.
            on_ability_destroy_app.unregister_ui_ability_state(window_id);
            // The critical Phase-3 gate (design.md D8 / OQ4): a spawned instance
            // closing must NOT run the process exit chain - only the primary
            // instance's destroy ends the app.
            if window_id == 0 {
                if let Some(ref mut h) = *on_ability_destroy_app.event_loop.borrow_mut() {
                    h(Event::Destroy)
                }
            }
            Ok(())
        })?;

    // PC/2in1 pre-close probe (onPrepareToTerminateAsync, issue
    // Eulogizethesun/tauri#103). Synchronous by necessity: the answer must be
    // returned to ArkTS before the callback returns. The tao event handler
    // runs inline on this (UI) thread - same as onAbilityDestroy - so the
    // ExitRequested dispatch + prevent decision complete before the
    // is_prevented() read below. The TerminateAnswer lives on this closure's
    // stack for the duration of the h(...) call only.
    let on_prepare_to_terminate_app = app.clone();
    let on_prepare_to_terminate: Function<'_, (), bool> =
        env.create_function_from_closure("prepare_to_terminate", move |_ctx| {
            let answer = crate::TerminateAnswer::new();
            if let Some(ref mut h) = *on_prepare_to_terminate_app.event_loop.borrow_mut() {
                h(Event::PrepareToTerminate { answer: &answer })
            }
            Ok(answer.is_prevented())
        })?;

    let on_ability_restore_state_app = app.clone();

    let on_ability_restore_state =
        env.create_function_from_closure("on_ability_restore_state", move |ctx| {
            let window_id = window_id_arg(&ctx, 0);
            if window_id == 0 {
                let save_loader = SaveLoader {
                    app: &on_ability_restore_state_app,
                };

                if let Some(ref mut h) = *on_ability_restore_state_app.event_loop.borrow_mut() {
                    h(Event::Resume(save_loader))
                }
            }
            Ok(())
        })?;

    let on_ability_save_state_app = app.clone();
    let on_ability_save_state =
        env.create_function_from_closure("on_ability_save_state", move |ctx| {
            let window_id = window_id_arg(&ctx, 0);
            if window_id == 0 {
                let save_saver = SaveSaver {
                    app: &on_ability_save_state_app,
                };

                if let Some(ref mut h) = *on_ability_save_state_app.event_loop.borrow_mut() {
                    h(Event::SaveState(save_saver))
                }
            }
            Ok(())
        })?;

    let keyboard_event_callback_app = app.clone();
    let keyboard_event_callback =
        env.create_function_from_closure("keyboard_event_callback", move |ctx| {
            let event_type = ctx.first_arg::<i32>()?;
            let window_id = window_id_arg(&ctx, 1);
            if window_id == 0 {
                if let Some(ref mut h) = *keyboard_event_callback_app.event_loop.borrow_mut() {
                    h(Event::KeyboardEvent(event_type))
                }
            }
            Ok(())
        })?;

    let on_new_want_app = app.clone();
    let on_new_want = env.create_function_from_closure("on_new_want", move |ctx| {
        let data = ctx.first_arg::<Object>()?;
        let window_id = window_id_arg(&ctx, 1);
        let uri = data.get_named_property::<String>("uri")?;
        let parameters_json = data.get_named_property::<String>("parametersJson")?;
        crate::app::store_want_parameters(window_id, &parameters_json);
        if window_id == 0 {
            // isContinuation is optional-with-fallback: missing or wrong type
            // (older HAR payload) degrades to false rather than failing the callback.
            // Continuation statics are primary-instance-only (NG5 defers
            // multi-instance continuation): a spawned instance's new want must not
            // clear the primary's pending continuation payload.
            let is_continuation = data
                .get_named_property::<bool>("isContinuation")
                .unwrap_or(false);
            crate::app::store_continuation(is_continuation, &parameters_json);
            if let Some(ref mut h) = *on_new_want_app.event_loop.borrow_mut() {
                h(Event::NewWant { uri })
            }
        }
        // For a spawned instance (window_id > 0) the parameters are stored
        // per-id above, but `Event::NewWant` is NOT dispatched: there is a
        // single event loop and no per-window new-want routing. A warm-start
        // deep link into a spawned instance is therefore recorded (readable
        // via take_want_parameters_for_window) but raises no event - a known
        // limitation tracked as design.md NG8 (openspec
        // multi-uiability-windows).
        Ok(())
    })?;

    let on_ability_create_with_want =
        env.create_function_from_closure("on_ability_create_with_want", move |ctx| {
            let data = ctx.first_arg::<Object>()?;
            let window_id = window_id_arg(&ctx, 1);
            let uri = data.get_named_property::<String>("uri")?;
            crate::app::store_initial_want_uri(window_id, &uri);
            if window_id == 0 {
                // Continuation fields are optional-with-fallback: missing or wrong
                // type (older HAR payload) degrades to false / empty rather than
                // failing the callback. Continuation storage stays
                // primary-instance-only (NG5): a spawned instance's cold start must
                // not clear the primary's pending continuation payload.
                let is_continuation = data
                    .get_named_property::<bool>("isContinuation")
                    .unwrap_or(false);
                let parameters_json = data
                    .get_named_property::<String>("parametersJson")
                    .unwrap_or_default();
                crate::app::store_continuation(is_continuation, &parameters_json);
            }
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
            on_prepare_to_terminate,
        },
        keyboard_event_callback: KeyboardCallback {
            on_keyboard_height_change: keyboard_event_callback,
        },
    })
}

fn make_on_configuration_updated<'a>(
    env: &'a Env,
    app: OpenHarmonyApp,
) -> Result<Function<'a, (), ()>> {
    let configuration_updated_app = app;
    env.create_function_from_closure("configuration_updated", move |ctx| {
        let configuration = ctx.first_arg::<Object>()?;
        let window_id = window_id_arg(&ctx, 1);
        let language = configuration.get_named_property::<String>("language")?;
        let color_mode = configuration.get_named_property::<i32>("colorMode")?;
        let direction = configuration.get_named_property::<i32>("direction")?;
        let screen_density = configuration.get_named_property::<i32>("screenDensity")?;
        let display_id = configuration.get_named_property::<i32>("displayId")?;
        let has_pointer_device = configuration.get_named_property::<bool>("hasPointerDevice")?;
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
        // The cached configuration and the app-level Event::ConfigChanged stay
        // primary-instance-driven (R10: app-level dispatch keeps WindowId(0));
        // OHOS notifies every live instance, so the primary's copy suffices.
        if window_id == 0 {
            configuration_updated_app
                .inner
                .write()
                .unwrap()
                .configuration = configuration.clone();
            if let Some(ref mut h) = *configuration_updated_app.event_loop.borrow_mut() {
                h(Event::ConfigChanged(configuration))
            }
        }
        let _ = configuration_updated_app
            .dispatch_plugin_lifecycle(PluginLifecycleEvent::ConfigurationUpdated { window_id });
        Ok(())
    })
}

fn make_on_window_stage_event<'a>(
    env: &'a Env,
    app: OpenHarmonyApp,
) -> Result<Function<'a, i32, ()>> {
    let window_stage_event_app = app;
    env.create_function_from_closure("window_stage_event", move |ctx| {
        let event_type = ctx.first_arg::<i32>()?;
        let window_id = window_id_arg(&ctx, 1);
        let _ = window_stage_event_app.dispatch_plugin_lifecycle(
            PluginLifecycleEvent::WindowStageEvent {
                window_id,
                event_type,
            },
        );

        // Phase 4 (design.md D5): focus dispatches per-window - a spawned
        // instance's ACTIVE/INACTIVE reaches its own tao window (and when it
        // gains focus, the primary receives the matching LostFocus half of
        // the pair). The remaining stage events map to tao app-level events
        // (Resumed/Pause/...) with no window routing, so they stay
        // primary-only (window_id == 0).
        // #221: the conversion is fallible (TryFrom); an unrecognized code
        // (system upgrade / new event) is warned here at the call site and
        // the event is dropped instead of panicking the bridge thread.
        let state_event = match StageEventType::try_from(event_type) {
            Ok(e) => e,
            Err(v) => {
                crate::warn!("[ability] unknown StageEventType value {}, ignoring", v);
                return Ok(());
            }
        };
        let e = match state_event {
            StageEventType::Active => Event::GainedFocus { window_id },
            StageEventType::Inactive => Event::LostFocus { window_id },
            StageEventType::Shown if window_id == 0 => Event::Start,
            StageEventType::Hidden if window_id == 0 => Event::Stop,
            StageEventType::Resumed if window_id == 0 => Event::Resume(SaveLoader {
                app: &window_stage_event_app,
            }),
            StageEventType::Paused if window_id == 0 => Event::Pause,
            _ => return Ok(()),
        };
        if let Some(ref mut h) = *window_stage_event_app.event_loop.borrow_mut() {
            h(e)
        }
        Ok(())
    })
}

/// Builds `onWindowRectChange`. Phase 2 (design.md D2/D4): the ArkTS side wraps
/// windowRectChange options as { windowId, reason, rect, drawable? }. windowId
/// is read here and the rect pair is routed into the per-window HashMaps
/// (set_window_rects) instead of the old shared single field. windowId is read
/// with a fallback to 0 (main window): some registration points may not yet
/// wrap the options (e.g. a path added later) - degrading to the old
/// main-window behavior is preferable to erroring out the whole callback.
///
/// `drawable` (issue Eulogizethesun/tauri#97): the same event's
/// `getWindowProperties().drawableRect` snapshot (position relative to the
/// window + drawable-area size, px), read synchronously by the ArkTS handler.
/// Optional-with-skip: when the ArkTS read threw (window not yet created /
/// content not loaded) the field is absent - the last snapshot pair stays
/// (BOTH rects, review R14: set_window_rects skips the update entirely so a
/// new outer can never be composed with a stale drawable) until the next
/// successful one. Both rects are stored under ONE lock so a concurrent
/// inner_rect_for can never see a torn pair.
fn make_on_window_rect_change<'a>(
    env: &'a Env,
    app: OpenHarmonyApp,
) -> Result<Function<'a, Object<'a>, ()>> {
    let window_rect_app = app;
    env.create_function_from_closure("window_rect_change", move |ctx| {
        let options = ctx.first_arg::<Object>()?;
        let reason = options.get_named_property::<i32>("reason")?;
        let rect = parse_rect(options.get_named_property::<Object>("rect")?)?;
        // windowId is optional-with-fallback: missing or wrong type degrades to 0
        // (main window) rather than failing the callback.
        let window_id = options.get_named_property::<i64>("windowId").unwrap_or(0);
        let drawable = options
            .get_named_property::<Object>("drawable")
            .ok()
            .and_then(|drawable| parse_rect(drawable).ok());
        window_rect_app.set_window_rects(window_id, rect, drawable);

        if let Some(ref mut h) = *window_rect_app.event_loop.borrow_mut() {
            h(Event::ContentRectChange(ContentRect {
                reason: reason.into(),
                rect,
                window_id,
            }))
        }
        Ok(())
    })
}

fn make_on_avoid_area_change<'a>(
    env: &'a Env,
    app: OpenHarmonyApp,
) -> Result<Function<'a, Object<'a>, ()>> {
    let avoid_area_change_app = app;
    env.create_function_from_closure("avoid_area_change", move |ctx| {
        let options = ctx.first_arg::<Object>()?;
        let window_id = window_id_arg(&ctx, 1);
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

        // The avoid-area cache and Event::AvoidAreaChange remain primary-window scoped
        // until per-window avoid areas land (same known-limitation family as NG7).
        // Sub-window registrations from the existing sub-window path call back
        // without the trailing id, degrade to 0, and keep their current behavior.
        if window_id == 0 {
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
        }
        Ok(())
    })
}
