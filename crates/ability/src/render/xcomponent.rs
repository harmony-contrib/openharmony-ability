use napi_ohos::threadsafe_function::ThreadsafeFunctionCallMode::NonBlocking;
use napi_ohos::{bindgen_prelude::ObjectRef, Env, Error, Result};
use ohos_arkui_binding::{ArkUIHandle, RootNode, XComponent};
use ohos_ime_binding::IME;

use crate::{
    input, set_helper, set_main_thread_env, Event, InputEvent, IntervalInfo, OpenHarmonyApp, Rect,
    Size,
};

/// create lifecycle object and return to arkts
pub fn render(
    env: &Env,
    helper: ObjectRef,
    slot: ArkUIHandle,
    app: OpenHarmonyApp,
) -> Result<RootNode> {
    set_helper(helper);
    set_main_thread_env(*env);

    let mut root = RootNode::new(slot);
    let xcomponent_native =
        XComponent::new().map_err(|e| Error::from_reason(e.reason.to_string()))?;

    {
        let mut inner = app.inner.write().unwrap();
        inner.xcomponent = Some(xcomponent_native.clone());
    }

    let xcomponent = xcomponent_native.native_xcomponent();

    let xc = xcomponent.clone();

    let on_surface_created_app = app.clone();
    let insert_text_app = app.clone();
    let redraw_app = app.clone();

    let (insert_text_callback_tsfn, on_ime_hide_callback_tsfn, on_backspace_callback_tsfn) =
        input::ime_ts_fn(env, app.clone())?;

    xcomponent.on_surface_created(move |xc_raw, win| {
        {
            let size = xc_raw.size(win).unwrap();
            let offset = xc_raw.offset(win).unwrap();
            on_surface_created_app.inner.write().unwrap().rect = Rect {
                top: offset.y as _,
                left: offset.x as _,
                width: size.width as _,
                height: size.height as _,
            };
        }
        {
            let raw_window = xc.native_window();
            on_surface_created_app.inner.write().unwrap().raw_window = raw_window;
            // We need to create IME instance when app is foucsed
            let ime = IME::new(Default::default());

            *on_surface_created_app.ime.borrow_mut() = Some(ime);
        }

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
        }

        {
            if let Some(ref mut h) = *on_surface_created_app.event_loop.borrow_mut() {
                h(Event::SurfaceCreate)
            }
        }

        let inner_redraw_app = redraw_app.clone();
        xc.on_frame_callback(move |_xcomponent, _time, _time_stamp| {
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
    xcomponent.on_surface_destroyed(move |_, _| {
        if let Some(ref mut h) = *on_surface_destroyed_app.event_loop.borrow_mut() {
            h(Event::SurfaceDestroy)
        }
        Ok(())
    });

    let on_surface_changed_app = app.clone();
    xcomponent.on_surface_changed(move |xc, win| {
        if let Some(ref mut h) = *on_surface_changed_app.event_loop.borrow_mut() {
            let size = xc.size(win).unwrap();
            let offset = xc.offset(win).unwrap();
            {
                on_surface_changed_app.inner.write().unwrap().rect = Rect {
                    top: offset.y as _,
                    left: offset.x as _,
                    width: size.width as _,
                    height: size.height as _,
                };
            }
            h(Event::WindowResize(Size {
                width: size.width as _,
                height: size.height as _,
            }))
        }
        Ok(())
    });

    let on_touch_event_app = app.clone();
    xcomponent.on_touch_event(move |_, _, data| {
        if let Some(ref mut h) = *on_touch_event_app.event_loop.borrow_mut() {
            h(Event::Input(InputEvent::TouchEvent(data)))
        }
        Ok(())
    });

    let on_key_event_app = app.clone();
    let _ = xcomponent.on_key_event(move |_, _, data| {
        if let Some(ref mut h) = *on_key_event_app.event_loop.borrow_mut() {
            h(Event::Input(InputEvent::KeyEvent(data)));
        }
        Ok(())
    });

    xcomponent.register_callback()?;

    root.mount(xcomponent_native)
        .map_err(|e| Error::from_reason(e.reason.to_string()))?;

    Ok(root)
}
