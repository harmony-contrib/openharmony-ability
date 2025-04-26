use napi_ohos::{Error, Result};
use ohos_arkui_binding::{ArkUIHandle, RootNode, XComponent};
use ohos_ime_binding::IME;

use crate::{Event, InputEvent, IntervalInfo, OpenHarmonyApp, TextInputEventData};

/// create lifecycle object and return to arkts
pub fn render(slot: ArkUIHandle, app: OpenHarmonyApp) -> Result<RootNode> {
    let mut root = RootNode::new(slot);
    let xcomponent_native = XComponent::new().map_err(|e| Error::from_reason(e.reason))?;

    let xcomponent = xcomponent_native.native_xcomponent();

    let xc = xcomponent.clone();

    let on_surface_created_app = app.clone();
    let redraw_app = app.clone();
    xcomponent.on_surface_created(move |_, _| {
        {
            let raw_window = xc.native_window();
            on_surface_created_app.inner.write().unwrap().raw_window = raw_window;
            // We need to create IME instance when app is foucsed
            let ime = IME::new(Default::default());
            let insert_text_app = on_surface_created_app.clone();
            ime.insert_text(move |s| {
                if let Some(ref mut h) = *insert_text_app.event_loop.borrow_mut() {
                    h(Event::Input(InputEvent::TextInputEvent(
                        TextInputEventData { text: s },
                    )))
                }
            });
            on_surface_created_app.ime.replace(Some(ime));
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

    let on_touch_event_app = app.clone();
    xcomponent.on_touch_event(move |_, _, data| {
        if let Some(ref mut h) = *on_touch_event_app.event_loop.borrow_mut() {
            h(Event::Input(InputEvent::TouchEvent(data)))
        }
        Ok(())
    });

    xcomponent.register_callback()?;

    root.mount(xcomponent_native)
        .map_err(|e| Error::from_reason(e.reason))?;

    Ok(root)
}
