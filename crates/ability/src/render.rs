use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::Function, threadsafe_function::ThreadsafeFunctionCallMode, Env, Error,
    JsObject, Result,
};
use ohos_arkui_binding::{ArkUIHandle, RootNode, XComponent};
use ohos_ime_binding::IME;

use crate::{Event, InputEvent, IntervalInfo, OpenHarmonyApp, TextInputEventData};

#[napi(object)]
pub struct Render<'a> {
    pub on_frame: Function<'a, (), ()>,
}

/// create lifecycle object and return to arkts
pub fn render<'a>(
    env: &'a Env,
    slot: ArkUIHandle,
    callback: Function<'a, (), ()>,
    app: OpenHarmonyApp,
) -> Result<(RootNode, Render<'a>)> {
    let tsfn = callback.build_threadsafe_function().build()?;

    let mut root = RootNode::new(slot);
    let xcomponent_native = XComponent::new().map_err(|e| Error::from_reason(e.reason))?;

    let xcomponent = xcomponent_native.native_xcomponent();

    let xc = xcomponent.clone();

    let on_surface_created_app = app.clone();
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
        tsfn.call((), ThreadsafeFunctionCallMode::NonBlocking);
        if let Some(ref mut h) = *on_surface_created_app.event_loop.borrow_mut() {
            h(Event::SurfaceCreate)
        }
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

    let on_key_event_app = app.clone();
    xcomponent.on_key_event(move |_, _, data| {
        if let Some(ref mut h) = *on_key_event_app.event_loop.borrow_mut() {
            h(Event::Input(InputEvent::KeyEvent(data)))
        }
        Ok(())
    })?;

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

    root.mount(xcomponent_native)
        .map_err(|e| Error::from_reason(e.reason))?;

    let on_frame_app = app.clone();
    let on_frame = env.create_function_from_closure("on_frame", move |ctx| {
        let info = ctx.first_arg::<JsObject>()?;
        let time = info.get_named_property::<i64>("timestamp")?;
        let target_time = info.get_named_property::<i64>("targetTimestamp")?;

        if let Some(ref mut h) = *on_frame_app.event_loop.borrow_mut() {
            h(Event::WindowRedraw(IntervalInfo {
                time_stamp: time,
                target_time_stamp: target_time,
            }))
        }
        Ok(())
    })?;

    Ok((root, Render { on_frame }))
}
