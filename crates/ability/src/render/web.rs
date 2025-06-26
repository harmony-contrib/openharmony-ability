use std::sync::LazyLock;

use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{FnArgs, Function},
    Env, JsObject, Ref, Result,
};
use ohos_display_soloist_binding::DisplaySoloist;

use crate::{set_helper, set_main_thread_env, Event, IntervalInfo, OpenHarmonyApp};

static DISPLAY_SOLOIST: LazyLock<DisplaySoloist> = LazyLock::new(|| {
    let display_soloist = DisplaySoloist::new(true);
    display_soloist
});

#[napi(object)]
pub struct WebViewComponentEventCallback<'a> {
    pub on_component_created: Function<'a, (), ()>,
    pub on_component_destroyed: Function<'a, (), ()>,
}

pub fn render<'a>(
    env: &'a Env,
    helper: JsObject,
    app: OpenHarmonyApp,
) -> Result<WebViewComponentEventCallback<'a>> {
    let h = Ref::new(env, &helper)?;

    set_helper(h);
    set_main_thread_env(env.clone());

    let on_frame_app = app.clone();
    let on_frame_callback: Function<'_, FnArgs<(i64, i64)>, ()> = env
        .create_function_from_closure("webviewFrameCallback", move |ctx| {
            // first arg is error, second is time, third is time_stamp
            // we need to ignore the error
            let time = ctx.get::<i64>(1)?;
            let time_stamp = ctx.get::<i64>(2)?;
            if let Some(ref mut h) = *on_frame_app.event_loop.borrow_mut() {
                h(Event::WindowRedraw(IntervalInfo {
                    time_stamp: time_stamp,
                    target_time_stamp: time,
                }))
            }
            Ok(())
        })?;

    let on_frame_callback_tsfn = on_frame_callback
        .build_threadsafe_function()
        .callee_handled::<true>()
        .build()?;

    let on_component_created_app = app.clone();
    let on_component_created_callback: Function<'_, (), ()> =
        env.create_function_from_closure("webviewCreateCallback", move |_ctx| {
            {
                if let Some(ref mut h) = *on_component_created_app.event_loop.borrow_mut() {
                    h(Event::SurfaceCreate)
                }
            }

            // vsync should be called in the event loop after the surface is created
            DISPLAY_SOLOIST.on_frame(|time, time_stamp| {
                on_frame_callback_tsfn.call(
                    Ok((time, time_stamp).into()),
                    napi_ohos::threadsafe_function::ThreadsafeFunctionCallMode::NonBlocking,
                );
            });

            Ok(())
        })?;

    let on_component_destroyed_app = app.clone();
    let on_component_destroyed_callback: Function<'_, (), ()> =
        env.create_function_from_closure("webviewDestroyCallback", move |_ctx| {
            if let Some(ref mut h) = *on_component_destroyed_app.event_loop.borrow_mut() {
                h(Event::SurfaceDestroy)
            }
            DISPLAY_SOLOIST.stop();
            Ok(())
        })?;

    Ok(WebViewComponentEventCallback {
        on_component_created: on_component_created_callback,
        on_component_destroyed: on_component_destroyed_callback,
    })
}
