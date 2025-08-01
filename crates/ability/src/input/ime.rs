use napi_ohos::{
    bindgen_prelude::Function, threadsafe_function::ThreadsafeFunction, Env, Result, Status,
};
use ohos_ime_binding::KeyboardStatus;

use crate::{Event, OpenHarmonyApp};

use super::{ImeEvent, InputEvent, TextInputEventData};

pub fn ime_ts_fn(
    env: &Env,
    app: OpenHarmonyApp,
) -> Result<(
    ThreadsafeFunction<String, (), String, Status, false>,
    ThreadsafeFunction<u32, (), u32, Status, false>,
    ThreadsafeFunction<i32, (), i32, Status, false>,
)> {
    // insert event
    let on_insert_text_app = app.clone();
    let insert_text_callback: Function<String, ()> =
        env.create_function_from_closure("ime_insert_callback", move |ctx| {
            let s = ctx.first_arg::<String>().unwrap();
            if let Some(ref mut h) = *on_insert_text_app.event_loop.borrow_mut() {
                h(Event::Input(InputEvent::ImeEvent(
                    ImeEvent::TextInputEvent(TextInputEventData { text: s }),
                )))
            }
            Ok(())
        })?;

    let insert_text_callback_tsfn = insert_text_callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    // keyboard status event
    let on_ime_hide_app = app.clone();
    let on_ime_hide_callback: Function<u32, ()> =
        env.create_function_from_closure("ime_hide_callback", move |ctx| {
            let value = ctx.first_arg::<u32>().unwrap();
            if let Some(ref mut h) = *on_ime_hide_app.event_loop.borrow_mut() {
                h(Event::Input(InputEvent::ImeEvent(
                    ImeEvent::ImeStatusEvent(KeyboardStatus::from(value)),
                )))
            }
            Ok(())
        })?;

    let on_ime_hide_callback_tsfn = on_ime_hide_callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let on_backspace_app = app.clone();
    let on_backspace_callback: Function<i32, ()> =
        env.create_function_from_closure("on_backspace_callback", move |ctx| {
            let value = ctx.first_arg::<i32>().unwrap();
            if let Some(ref mut h) = *on_backspace_app.event_loop.borrow_mut() {
                h(Event::Input(InputEvent::ImeEvent(
                    ImeEvent::BackspaceEvent(value),
                )))
            }
            Ok(())
        })?;

    let on_backspace_callback_tsfn = on_backspace_callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    Ok((
        insert_text_callback_tsfn,
        on_ime_hide_callback_tsfn,
        on_backspace_callback_tsfn,
    ))
}
