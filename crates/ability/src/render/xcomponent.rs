use napi_ohos::threadsafe_function::ThreadsafeFunctionCallMode::NonBlocking;
use napi_ohos::{Env, Error, Result};
use ohos_arkui_binding::component::attribute::ArkUICommonAttribute;
use ohos_arkui_binding::{ArkUIHandle, RootNode, XComponent};
use ohos_ime_binding::IME;

use crate::{input, Event, InputEvent, IntervalInfo, OpenHarmonyApp, Rect, Size};

/// create lifecycle object and return to arkts
pub fn render(
    env: &Env,
    slot: ArkUIHandle,
    render_owner: String,
    app: OpenHarmonyApp,
) -> Result<RootNode> {
    let mut root = RootNode::new(slot);
    let xcomponent_native =
        XComponent::new().map_err(|e| Error::from_reason(e.reason.to_string()))?;
    xcomponent_native
        .background_color(0x0000_0000)
        .map_err(|e| Error::from_reason(e.reason.to_string()))?;

    let xcomponent = xcomponent_native.native_xcomponent();

    let xc = xcomponent.clone();

    let on_surface_created_app = app.clone();
    let on_surface_created_owner = render_owner.clone();
    let insert_text_app = app.clone();
    let redraw_app = app.clone();

    let (
        insert_text_callback_tsfn,
        on_ime_hide_callback_tsfn,
        on_backspace_callback_tsfn,
        on_ime_enter_callback_tsfn,
    ) = input::ime_ts_fn(env, app.clone(), render_owner.clone())?;
    // The IME binding stores its callbacks in a process-global slot, so every registered closure
    // must own its transport instead of borrowing from this surface callback's environment.
    let insert_text_callback_tsfn = std::sync::Arc::new(insert_text_callback_tsfn);
    let on_ime_hide_callback_tsfn = std::sync::Arc::new(on_ime_hide_callback_tsfn);
    let on_backspace_callback_tsfn = std::sync::Arc::new(on_backspace_callback_tsfn);
    let on_ime_enter_callback_tsfn = std::sync::Arc::new(on_ime_enter_callback_tsfn);

    xcomponent.on_surface_created(move |xc_raw, win| {
        // Never unwind through this platform callback: propagate binding failures instead.
        let size = xc_raw.size(win)?;
        let offset = xc_raw.offset(win)?;
        let rect = Rect {
            top: offset.y as _,
            left: offset.x as _,
            width: size.width as _,
            height: size.height as _,
        };
        if !on_surface_created_app.activate_render_surface(
            &on_surface_created_owner,
            xc.native_window(),
            rect,
        ) {
            return Ok(());
        }

        // We need to create IME instance when app is focused. Surface callbacks always run on
        // the ArkTS main thread, which owns the IME cell.
        let ime = IME::new(Default::default());
        on_surface_created_app.ime.set(ime);

        insert_text_app.ime.with_ref(|ime| {
            if let Some(b_ime) = ime {
                // Each callback owns an `Arc` to its TSFN, making it a genuinely `'static`
                // closure: the IME binding keeps callbacks alive process-wide.
                let insert_tsfn = std::sync::Arc::clone(&insert_text_callback_tsfn);
                b_ime.insert_text(move |s| {
                    insert_tsfn.call(s, NonBlocking);
                });
                let status_tsfn = std::sync::Arc::clone(&on_ime_hide_callback_tsfn);
                b_ime.on_status_change(move |s| {
                    status_tsfn.call(s.into(), NonBlocking);
                });
                let backspace_tsfn = std::sync::Arc::clone(&on_backspace_callback_tsfn);
                b_ime.on_backspace(move |len| {
                    backspace_tsfn.call(len, NonBlocking);
                });
                let enter_tsfn = std::sync::Arc::clone(&on_ime_enter_callback_tsfn);
                b_ime.on_enter(move |key| {
                    enter_tsfn.call(key as i32, NonBlocking);
                });
            }
        });

        on_surface_created_app.emit_event(Event::SurfaceCreate);

        let inner_redraw_app = redraw_app.clone();
        let inner_redraw_owner = on_surface_created_owner.clone();
        xc.on_frame_callback(move |_xcomponent, _time, _time_stamp| {
            if !inner_redraw_app.is_render_surface_active(&inner_redraw_owner) {
                return Ok(());
            }
            inner_redraw_app.emit_event(Event::WindowRedraw(IntervalInfo {
                time_stamp: _time_stamp as _,
                target_time_stamp: _time as _,
            }));
            Ok(())
        })?;
        Ok(())
    });

    let on_surface_destroyed_app = app.clone();
    let on_surface_destroyed_owner = render_owner.clone();
    xcomponent.on_surface_destroyed(move |_, _| {
        if on_surface_destroyed_app.deactivate_render_surface(&on_surface_destroyed_owner) {
            on_surface_destroyed_app.dispatch_surface_destroy();
        }
        Ok(())
    });

    let on_surface_changed_app = app.clone();
    let on_surface_changed_owner = render_owner.clone();
    xcomponent.on_surface_changed(move |xc, win| {
        let size = xc.size(win)?;
        let offset = xc.offset(win)?;
        if on_surface_changed_app.update_render_surface_rect(
            &on_surface_changed_owner,
            Rect {
                top: offset.y as _,
                left: offset.x as _,
                width: size.width as _,
                height: size.height as _,
            },
        ) {
            on_surface_changed_app.emit_event(Event::WindowResize(Size {
                width: size.width as _,
                height: size.height as _,
            }));
        }
        Ok(())
    });

    let on_touch_event_app = app.clone();
    let on_touch_event_owner = render_owner.clone();
    xcomponent.on_touch_event(move |_, _, data| {
        if !on_touch_event_app.is_render_surface_active(&on_touch_event_owner) {
            return Ok(());
        }
        on_touch_event_app.emit_event(Event::Input(InputEvent::TouchEvent(data)));
        Ok(())
    });

    let on_key_event_app = app.clone();
    let on_key_event_owner = render_owner.clone();
    xcomponent.on_key_event(move |_, _, data| {
        if !on_key_event_app.is_render_surface_active(&on_key_event_owner) {
            return Ok(());
        }
        on_key_event_app.emit_event(Event::Input(InputEvent::KeyEvent(data)));
        Ok(())
    })?;

    let on_mouse_event_app = app.clone();
    let on_mouse_event_owner = render_owner.clone();
    xcomponent.on_mouse_event(move |_, _, data| {
        if !on_mouse_event_app.is_render_surface_active(&on_mouse_event_owner) {
            return Ok(());
        }
        on_mouse_event_app.emit_event(Event::Input(InputEvent::MouseEvent(data)));
        Ok(())
    })?;
    xcomponent.register_mouse_event_callback()?;

    xcomponent.register_callback()?;

    app.begin_render(&render_owner, xcomponent_native.clone())?;
    if let Err(error) = root.mount(xcomponent_native) {
        app.release_render(&render_owner);
        return Err(Error::from_reason(error.reason.to_string()));
    }

    Ok(root)
}
