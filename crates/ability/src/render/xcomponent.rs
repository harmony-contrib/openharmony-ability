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

    xcomponent.on_surface_created(move |xc_raw, win| {
        let size = xc_raw.size(win).unwrap();
        let offset = xc_raw.offset(win).unwrap();
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

        // We need to create IME instance when app is focused.
        let ime = IME::new(Default::default());
        *on_surface_created_app.ime.borrow_mut() = Some(ime);

        if let Some(b_ime) = insert_text_app.ime.borrow().as_ref() {
            // // run in other thread
            b_ime.insert_text(|s| {
                insert_text_callback_tsfn.call(s, NonBlocking);
            });
            b_ime.on_status_change(|s| {
                on_ime_hide_callback_tsfn.call(s.into(), NonBlocking);
            });
            b_ime.on_backspace(|len| {
                on_backspace_callback_tsfn.call(len, NonBlocking);
            });
            b_ime.on_enter(|key| {
                on_ime_enter_callback_tsfn.call(key as i32, NonBlocking);
            });
        }

        {
            if let Some(ref mut h) = *on_surface_created_app.event_loop.borrow_mut() {
                h(Event::SurfaceCreate)
            }
        }

        let inner_redraw_app = redraw_app.clone();
        let inner_redraw_owner = on_surface_created_owner.clone();
        xc.on_frame_callback(move |_xcomponent, _time, _time_stamp| {
            if !inner_redraw_app.is_render_surface_active(&inner_redraw_owner) {
                return Ok(());
            }
            if let Some(ref mut h) = *inner_redraw_app.event_loop.borrow_mut() {
                h(Event::WindowRedraw(IntervalInfo {
                    time_stamp: _time_stamp as _,
                    target_time_stamp: _time as _,
                }))
            }
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
        let size = xc.size(win).unwrap();
        let offset = xc.offset(win).unwrap();
        if on_surface_changed_app.update_render_surface_rect(
            &on_surface_changed_owner,
            Rect {
                top: offset.y as _,
                left: offset.x as _,
                width: size.width as _,
                height: size.height as _,
            },
        ) {
            if let Some(ref mut h) = *on_surface_changed_app.event_loop.borrow_mut() {
                h(Event::WindowResize(Size {
                    width: size.width as _,
                    height: size.height as _,
                }))
            }
        }
        Ok(())
    });

    let on_touch_event_app = app.clone();
    let on_touch_event_owner = render_owner.clone();
    xcomponent.on_touch_event(move |_, _, data| {
        if !on_touch_event_app.is_render_surface_active(&on_touch_event_owner) {
            return Ok(());
        }
        if let Some(ref mut h) = *on_touch_event_app.event_loop.borrow_mut() {
            h(Event::Input(InputEvent::TouchEvent(data)))
        }
        Ok(())
    });

    let on_key_event_app = app.clone();
    let on_key_event_owner = render_owner.clone();
    let _ = xcomponent.on_key_event(move |_, _, data| {
        if !on_key_event_app.is_render_surface_active(&on_key_event_owner) {
            return Ok(());
        }
        if let Some(ref mut h) = *on_key_event_app.event_loop.borrow_mut() {
            h(Event::Input(InputEvent::KeyEvent(data)));
        }
        Ok(())
    });

    let on_mouse_event_app = app.clone();
    let on_mouse_event_owner = render_owner.clone();
    xcomponent.on_mouse_event(move |_, _, data| {
        if !on_mouse_event_app.is_render_surface_active(&on_mouse_event_owner) {
            return Ok(());
        }
        if let Some(ref mut h) = *on_mouse_event_app.event_loop.borrow_mut() {
            h(Event::Input(InputEvent::MouseEvent(data)));
        }
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
