use napi_ohos::threadsafe_function::ThreadsafeFunctionCallMode::NonBlocking;
use napi_ohos::{Env, Error, Result};
use ohos_arkui_binding::component::attribute::ArkUICommonAttribute;
use ohos_arkui_binding::{ArkUIHandle, RootNode, XComponent};
use ohos_ime_binding::IME;
use ohos_xcomponent_binding::{XComponentOffset, XComponentSize};

use crate::{
    input, set_main_thread_env, Event, InputEvent, IntervalInfo, OpenHarmonyApp, Rect, Size,
};

/// create lifecycle object and return to arkts
pub fn render(
    env: &Env,
    slot: ArkUIHandle,
    render_owner: String,
    app: OpenHarmonyApp,
) -> Result<RootNode> {
    set_main_thread_env(*env);

    // All eager `get_helper()` TSFN inits (statusbar tray, vibrancy, clipboard image,
    // updater, account, autostart, opener) have been removed. They were all dead
    // paths: `set_helper` is never called after the #[ability] derive refactor, so
    // every `get_helper()` returned None and these inits logged "ArkHelper not
    // initialized" on every startup (noise, not functional bugs). Consumers have
    // migrated to typed bridge facades (WindowClient / ClipboardClient /
    // AutostartClient / plugin-statusbar / plugin-menu) or still call legacy
    // top-level fns directly (app.updater / HuaweiAccount / opener::reveal_in_dir —
    // see decoupling task #6 B-group). Do NOT re-add eager `get_helper()` TSFN
    // inits here — new capability goes through bridge plugins.

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
        // NDK callback boundary: a panic here aborts the process (no unwinding
        // across "extern C"). Degrade to 0x0 + warn instead (issue #87 minor-2);
        // a subsequent on_surface_changed carries the real geometry.
        let size = xc_raw.size(win).unwrap_or_else(|e| {
            crate::warn!("on_surface_created: size() failed: {e:?}, degrading to 0x0");
            XComponentSize { width: 0, height: 0 }
        });
        let offset = xc_raw.offset(win).unwrap_or_else(|e| {
            crate::warn!("on_surface_created: offset() failed: {e:?}, degrading to 0,0");
            XComponentOffset { x: 0.0, y: 0.0 }
        });
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
        // NDK callback boundary: never panic (issue #87 minor-2). If the geometry
        // can't be read, skip this change event rather than dispatching a bogus
        // 0x0 WindowResize into tao — the next surface-changed callback carries
        // the real values.
        let size = match xc.size(win) {
            Ok(size) => size,
            Err(e) => {
                crate::warn!("on_surface_changed: size() failed: {e:?}, skipping rect update");
                return Ok(());
            }
        };
        let offset = match xc.offset(win) {
            Ok(offset) => offset,
            Err(e) => {
                crate::warn!("on_surface_changed: offset() failed: {e:?}, skipping rect update");
                return Ok(());
            }
        };
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
                // Phase 3 (design.md D6 / task 3.5): XComponent is the main window's
                // surface, so window_id is always 0. Carrying it explicitly lets tao's
                // run_loop route WindowResize uniformly (instead of a special-cased ZST).
                h(Event::WindowResize {
                    window_id: 0,
                    size: Size {
                        width: size.width as _,
                        height: size.height as _,
                    },
                })
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
            h(Event::Input(InputEvent::MouseEvent(data.into())));
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
