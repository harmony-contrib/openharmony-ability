use std::cell::RefCell;

use napi_ohos::{CallContext, Error, Result};
use ohos_arkui_binding::{ArkUIHandle, RootNode, XComponent};
use ohos_hilog_binding::hilog_info;

use crate::App;

/// create lifecycle object and return to arkts
pub fn render(
    ctx: CallContext,
    _app: RefCell<App>,
    root_node: &RefCell<Option<RootNode>>,
) -> Result<()> {
    let slot = ctx.get::<ArkUIHandle>(0)?;

    let root = RootNode::new(slot);
    root_node.replace_with(|_| Some(root));
    let xcomponent_native = XComponent::new().map_err(|e| Error::from_reason(e.reason))?;

    let xcomponent = xcomponent_native.native_xcomponent();

    xcomponent.on_surface_created(|_, _| {
        hilog_info!("ohos-rs macro on_surface_created");
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
