use std::sync::Arc;

use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{Function, JsObjectValue, Object},
    Env, Result,
};

use crate::{
    waker::WAKER, AvoidArea, AvoidAreaInfo, AvoidAreaType, BridgePluginDeclaration, ContentRect,
    Event, OpenHarmonyApp, PluginLifecycleEvent, Rect, SaveLoader, SaveSaver, Size, StageEventType,
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
    pub on_ability_new_want: Function<'a, String, ()>,
    pub on_ability_destroy: Function<'a, (), ()>,
    /// Returns the hex-encoded application state saved by the `Event::SaveState` handler; ArkTS
    /// persists it into the platform Want and returns it through `on_ability_create` on restore.
    pub on_ability_save_state: Function<'a, (), String>,
    pub on_window_stage_event: Function<'a, i32, ()>,
    pub on_window_size_change: Function<'a, Object<'a>, ()>,
    pub on_window_rect_change: Function<'a, Object<'a>, ()>,
    pub on_avoid_area_change: Function<'a, Object<'a>, ()>,
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

/// Forwards one lifecycle transition to the plugin registry, surfacing subscriber failures in
/// hilog instead of silently discarding them.
fn dispatch_plugin_lifecycle(app: &OpenHarmonyApp, event: PluginLifecycleEvent) {
    if let Err(error) = app.dispatch_plugin_lifecycle(event.clone()) {
        crate::log::warn(&format!(
            "Plugin lifecycle event {event:?} reported an error: {error}"
        ));
    }
}

/// Saved state travels through the platform Want as a string, so the application's bytes are
/// hex-encoded for a lossless round trip.
fn encode_saved_state(state: &[u8]) -> String {
    let mut encoded = String::with_capacity(state.len() * 2);
    for byte in state {
        encoded.push_str(&format!("{byte:02x}"));
    }
    encoded
}

fn decode_saved_state(state: &str) -> Option<Vec<u8>> {
    if state.is_empty() || !state.len().is_multiple_of(2) {
        return None;
    }
    let bytes = state.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks_exact(2) {
        let text = std::str::from_utf8(pair).ok()?;
        decoded.push(u8::from_str_radix(text, 16).ok()?);
    }
    Some(decoded)
}

/// create lifecycle object and return to arkts
pub fn create_lifecycle_handle<'a>(
    env: &'a Env,
    app: OpenHarmonyApp,
) -> Result<ApplicationLifecycle<'a>> {
    let bridge_plugins = app.bridge_plugin_declarations()?;
    let waker_app = app.clone();
    let waker: Function<'_, (), ()> = env.create_function_from_closure("waker", move |_ctx| {
        waker_app.emit_event(Event::UserEvent);
        Ok(())
    })?;

    let tsfn = waker
        .build_threadsafe_function()
        .callee_handled::<true>()
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
            dispatch_plugin_lifecycle(
                &on_memory_level_app,
                PluginLifecycleEvent::MemoryLevel { level },
            );
            on_memory_level_app.emit_event(Event::LowMemory);
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
            if let Ok(mut inner) = configuration_updated_app.inner.write() {
                inner.configuration = configuration.clone();
            } else {
                crate::log::warn("Failed to cache the updated configuration: state is poisoned");
            }
            dispatch_plugin_lifecycle(
                &configuration_updated_app,
                PluginLifecycleEvent::ConfigurationUpdated,
            );
            configuration_updated_app.emit_event(Event::ConfigChanged(configuration));
            Ok(())
        })?;

    let window_stage_event_app = app.clone();
    let window_stage_event =
        env.create_function_from_closure("window_stage_event", move |ctx| {
            let event_type = ctx.first_arg::<i32>()?;
            dispatch_plugin_lifecycle(
                &window_stage_event_app,
                PluginLifecycleEvent::WindowStageEvent { event_type },
            );

            let state_event = StageEventType::from(event_type);
            let event = match state_event {
                StageEventType::Shown => Event::Start,
                StageEventType::Active => Event::GainedFocus,
                StageEventType::Inactive => Event::LostFocus,
                StageEventType::Hidden => Event::Stop,
                StageEventType::Resumed => Event::Resume(SaveLoader {
                    app: &window_stage_event_app,
                }),
                StageEventType::Paused => Event::Pause,
            };
            window_stage_event_app.emit_event(event);
            Ok(())
        })?;

    // TODO: we may can remove it
    let window_resize_app = app.clone();
    let window_resize = env.create_function_from_closure("window_resize", move |ctx| {
        let size = ctx.first_arg::<Object>()?;
        let width = size.get_named_property::<i32>("width")?;
        let height = size.get_named_property::<i32>("height")?;

        window_resize_app.emit_event(Event::WindowResize(Size { width, height }));
        Ok(())
    })?;

    // TODO: we may can remove it
    let window_rect_app = app.clone();
    let window_rect_change =
        env.create_function_from_closure("window_rect_change", move |ctx| {
            let options = ctx.first_arg::<Object>()?;
            let reason = options.get_named_property::<i32>("reason")?;
            let rect = parse_rect(options.get_named_property::<Object>("rect")?)?;
            if let Ok(mut inner) = window_rect_app.inner.write() {
                inner.window_rect = rect;
            } else {
                crate::log::warn("Failed to cache the updated window rect: state is poisoned");
            }

            window_rect_app.emit_event(Event::ContentRectChange(ContentRect {
                reason: reason.into(),
                rect,
            }));
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

        if let Ok(mut inner) = avoid_area_change_app.inner.write() {
            inner.avoid_areas.insert(area_type, avoid_area);
        } else {
            crate::log::warn("Failed to cache the updated avoid area: state is poisoned");
        }

        avoid_area_change_app.emit_event(Event::AvoidAreaChange(AvoidAreaInfo {
            area_type,
            area: avoid_area,
        }));
        Ok(())
    })?;

    let on_window_stage_create_app = app.clone();
    let on_window_stage_create =
        env.create_function_from_closure("on_window_stage_create", move |_ctx| {
            dispatch_plugin_lifecycle(
                &on_window_stage_create_app,
                PluginLifecycleEvent::WindowStageCreated,
            );
            on_window_stage_create_app.emit_event(Event::WindowCreate);
            Ok(())
        })?;

    let on_window_stage_destroy_app = app.clone();
    let on_window_stage_destroy =
        env.create_function_from_closure("on_window_stage_destroy", move |_ctx| {
            dispatch_plugin_lifecycle(
                &on_window_stage_destroy_app,
                PluginLifecycleEvent::WindowStageDestroyed,
            );
            on_window_stage_destroy_app.emit_event(Event::WindowDestroy);
            Ok(())
        })?;

    let on_ability_create_app = app.clone();
    let on_ability_create: Function<'_, String, ()> =
        env.create_function_from_closure("on_ability_create", move |ctx| {
            let restored_state = ctx.first_arg::<String>().unwrap_or_default();
            if let Some(state) = decode_saved_state(&restored_state) {
                on_ability_create_app.restore_saved_state(state);
            }
            dispatch_plugin_lifecycle(
                &on_ability_create_app,
                PluginLifecycleEvent::AbilityCreated { restored_state },
            );
            on_ability_create_app.emit_event(Event::Create);
            Ok(())
        })?;

    let on_ability_new_want_app = app.clone();
    let on_ability_new_want: Function<'_, String, ()> =
        env.create_function_from_closure("on_ability_new_want", move |ctx| {
            let uri = ctx.first_arg::<String>().unwrap_or_default();
            on_ability_new_want_app.emit_event(Event::NewWant(uri));
            Ok(())
        })?;

    let on_ability_destroy_app = app.clone();
    let on_ability_destroy =
        env.create_function_from_closure("on_ability_destroy", move |_ctx| {
            dispatch_plugin_lifecycle(
                &on_ability_destroy_app,
                PluginLifecycleEvent::AbilityDestroyed,
            );
            on_ability_destroy_app.emit_event(Event::Destroy);
            Ok(())
        })?;

    let on_ability_save_state_app = app.clone();
    let on_ability_save_state: Function<'_, (), String> =
        env.create_function_from_closure("on_ability_save_state", move |_ctx| {
            on_ability_save_state_app.emit_event(Event::SaveState(SaveSaver {
                app: &on_ability_save_state_app,
            }));
            // The handler above stores its bytes synchronously through `SaveSaver::save`; the
            // encoded snapshot is returned to ArkTS for persistence into the platform Want.
            let state = on_ability_save_state_app
                .load()
                .map(|state| encode_saved_state(&state))
                .unwrap_or_default();
            Ok(state)
        })?;

    let keyboard_event_callback_app = app.clone();
    let keyboard_event_callback =
        env.create_function_from_closure("keyboard_event_callback", move |ctx| {
            let event_type = ctx.first_arg::<i32>()?;
            keyboard_event_callback_app.emit_event(Event::KeyboardEvent(event_type));
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
            on_ability_new_want,
            on_ability_destroy,
            on_ability_save_state,
            on_window_rect_change: window_rect_change,
            on_window_size_change: window_resize,
            on_avoid_area_change: avoid_area_change,
            on_window_stage_event: window_stage_event,
        },
        keyboard_event_callback: KeyboardCallback {
            on_keyboard_height_change: keyboard_event_callback,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::{decode_saved_state, encode_saved_state};

    #[test]
    fn saved_state_round_trips_through_the_want_string() {
        let state = vec![0x00, 0x01, 0x7f, 0x80, 0xff];
        let encoded = encode_saved_state(&state);
        assert_eq!(encoded, "00017f80ff");
        assert_eq!(decode_saved_state(&encoded), Some(state));
    }

    #[test]
    fn saved_state_decoding_rejects_non_framework_strings() {
        assert_eq!(decode_saved_state(""), None);
        assert_eq!(decode_saved_state("abc"), None);
        assert_eq!(decode_saved_state("zz"), None);
        assert_eq!(decode_saved_state("業務"), None);
    }
}
