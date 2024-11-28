use std::cell::RefCell;

use napi_ohos::{CallContext, Error, Result};
use ohos_arkui_binding::{ArkUIHandle, RootNode, XComponent};

use crate::{App, Event};

/// create lifecycle object and return to arkts
pub fn render(
    ctx: CallContext,
    app: RefCell<App>,
    root_node: &RefCell<Option<RootNode>>,
) -> Result<()> {
    let slot = ctx.get::<ArkUIHandle>(0)?;

    let root = RootNode::new(slot);
    root_node.replace_with(|_| Some(root));
    let xcomponent_native = XComponent::new().map_err(|e| Error::from_reason(e.reason))?;

    let xcomponent = xcomponent_native.native_xcomponent();

    let surface_create_app = app.clone();
    xcomponent.on_surface_created(move |_, _| {
        let event = surface_create_app.borrow();
        if let Some(h) = *event.event_loop.borrow() {
            h(Event::SurfaceCreate)
        }
        Ok(())
    });

    let surface_destroy_app = app.clone();
    xcomponent.on_surface_destroyed(move |_, _| {
        let event = surface_destroy_app.borrow();
        if let Some(h) = *event.event_loop.borrow() {
            h(Event::SurfaceDestroy)
        }
        Ok(())
    });

    xcomponent.register_callback()?;

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

    let mut r = root_node.borrow_mut();
    if let Some(root) = r.as_mut() {
        root.mount(xcomponent_native).unwrap();
    }

    Ok(())
}
