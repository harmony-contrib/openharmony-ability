use napi_ohos::{
    bindgen_prelude::Function, threadsafe_function::ThreadsafeFunction, Env, Result, Status,
};
use ohos_ime_binding::KeyboardStatus;

use crate::{Event, OpenHarmonyApp};

use super::{ImeEvent, InputEvent, TextInputEventData};

type ImeCallback = (
    ThreadsafeFunction<String, (), String, Status, false>,
    ThreadsafeFunction<u32, (), u32, Status, false>,
    ThreadsafeFunction<i32, (), i32, Status, false>,
    ThreadsafeFunction<i32, (), i32, Status, false>,
);

pub fn ime_ts_fn(env: &Env, app: OpenHarmonyApp, render_owner: String) -> Result<ImeCallback> {
    // insert event
    let on_insert_text_app = app.clone();
    let on_insert_text_owner = render_owner.clone();
    let insert_text_callback: Function<String, ()> =
        env.create_function_from_closure("ime_insert_callback", move |ctx| {
            if !on_insert_text_app.is_render_surface_active(&on_insert_text_owner) {
                return Ok(());
            }
            // TSFN callback (callee_handled=false): a panic here aborts the
            // process, and returning Err triggers napi_fatal_exception — equally
            // fatal. A malformed callback simply carries no event (issue #87 minor-2).
            let Some(s) = ctx.first_arg::<String>().ok() else {
                crate::warn!("ime_insert_callback: first_arg missing/invalid, dropping event");
                return Ok(());
            };
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
    let on_ime_hide_owner = render_owner.clone();
    let on_ime_hide_callback: Function<u32, ()> =
        env.create_function_from_closure("ime_hide_callback", move |ctx| {
            if !on_ime_hide_app.is_render_surface_active(&on_ime_hide_owner) {
                return Ok(());
            }
            // See ime_insert_callback: never panic/fatal across the TSFN boundary;
            // a missing arg carries no status event (defaulting to 0 would be
            // ambiguous under KeyboardStatus::from).
            let Some(value) = ctx.first_arg::<u32>().ok() else {
                crate::warn!("ime_hide_callback: first_arg missing/invalid, dropping event");
                return Ok(());
            };

            let status = KeyboardStatus::from(value);
            if matches!(status, KeyboardStatus::Hide) {
                // Keep native IME lifecycle aligned with hide callbacks.
                on_ime_hide_app.hide_keyboard();
            }
            if let Some(ref mut h) = *on_ime_hide_app.event_loop.borrow_mut() {
                h(Event::Input(InputEvent::ImeEvent(
                    ImeEvent::ImeStatusEvent(status),
                )))
            }
            Ok(())
        })?;

    let on_ime_hide_callback_tsfn = on_ime_hide_callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let on_backspace_app = app.clone();
    let on_backspace_owner = render_owner.clone();
    let on_backspace_callback: Function<i32, ()> =
        env.create_function_from_closure("on_backspace_callback", move |ctx| {
            if !on_backspace_app.is_render_surface_active(&on_backspace_owner) {
                return Ok(());
            }
            // See ime_insert_callback: never panic/fatal across the TSFN boundary.
            let Some(value) = ctx.first_arg::<i32>().ok() else {
                crate::warn!("on_backspace_callback: first_arg missing/invalid, dropping event");
                return Ok(());
            };
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

    let on_ime_enter_app = app.clone();
    let on_ime_enter_owner = render_owner;
    let on_ime_enter_callback: Function<i32, ()> =
        env.create_function_from_closure("on_ime_enter_callback", move |ctx| {
            if !on_ime_enter_app.is_render_surface_active(&on_ime_enter_owner) {
                return Ok(());
            }
            // See ime_insert_callback: never panic/fatal across the TSFN boundary.
            let Some(value) = ctx.first_arg::<i32>().ok() else {
                crate::warn!("on_ime_enter_callback: first_arg missing/invalid, dropping event");
                return Ok(());
            };
            if let Some(ref mut h) = *on_ime_enter_app.event_loop.borrow_mut() {
                h(Event::Input(InputEvent::ImeEvent(ImeEvent::EnterEvent(
                    value,
                ))))
            }
            Ok(())
        })?;

    let on_ime_enter_callback_tsfn = on_ime_enter_callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    Ok((
        insert_text_callback_tsfn,
        on_ime_hide_callback_tsfn,
        on_backspace_callback_tsfn,
        on_ime_enter_callback_tsfn,
    ))
}
