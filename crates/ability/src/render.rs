use std::cell::RefCell;

use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::Function, threadsafe_function::ThreadsafeFunctionCallMode, CallContext, Error,
    JsObject, Result,
};
use ohos_arkui_binding::{ArkUIHandle, RootNode, XComponent};

use crate::{OpenHarmonyApp, Event, InputEvent, IntervalInfo};

#[napi(object)]
pub struct Render<'a> {
    pub on_frame: Function<'a, (), ()>,
}

/// create lifecycle object and return to arkts
pub fn render(ctx: CallContext, app: RefCell<OpenHarmonyApp>) -> Result<(RootNode, Render)> {
    let slot = ctx.get::<ArkUIHandle>(0)?;
    let callback = ctx.get::<Function<(), ()>>(1)?;

    let tsfn = callback.build_threadsafe_function().build()?;

    let mut root = RootNode::new(slot);
    let xcomponent_native = XComponent::new().map_err(|e| Error::from_reason(e.reason))?;

    let xcomponent = xcomponent_native.native_xcomponent();

    let raw_window = xcomponent.native_window();
    app.borrow_mut().raw_window.replace(raw_window);

    let surface_create_app = app.clone();
    xcomponent.on_surface_created(move |_, _| {
        tsfn.call((), ThreadsafeFunctionCallMode::NonBlocking);
        let event = surface_create_app.borrow();
        if let Some(h) = event.event_loop.borrow().as_ref() {
            h(Event::SurfaceCreate)
        }
        Ok(())
    });

    let surface_destroy_app = app.clone();
    xcomponent.on_surface_destroyed(move |_, _| {
        let event = surface_destroy_app.borrow();
        if let Some(h) = event.event_loop.borrow().as_ref() {
            h(Event::SurfaceDestroy)
        }
        Ok(())
    });

    let touch_event_app = app.clone();
    xcomponent.on_touch_event(move |_, _, data| {
        let event = touch_event_app.borrow();
        if let Some(h) = event.event_loop.borrow().as_ref() {
            h(Event::Input(InputEvent::TouchEvent(data)))
        }
        Ok(())
    });

    xcomponent.register_callback()?;

    let key_event_app = app.clone();
    xcomponent.on_key_event(move |_, _, data| {
        let event = key_event_app.borrow();
        if let Some(h) = event.event_loop.borrow().as_ref() {
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

    let frame_app = app.clone();
    let on_frame = ctx
        .env
        .create_function_from_closure("on_frame", move |ctx| {
            let info = ctx.first_arg::<JsObject>()?;
            let time = info.get_named_property::<i64>("timestamp")?;
            let target_time = info.get_named_property::<i64>("targetTimestamp")?;
            let event = frame_app.borrow();
            if let Some(h) = event.event_loop.borrow().as_ref() {
                h(Event::WindowRedraw(IntervalInfo {
                    time_stamp: time,
                    target_time_stamp: target_time,
                }))
            }
            Ok(())
        })?;

    Ok((root, Render { on_frame }))
}
