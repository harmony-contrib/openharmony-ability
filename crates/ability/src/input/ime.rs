use napi_derive_ohos::napi;
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
    ThreadsafeFunction<PreviewTextEventData, (), PreviewTextEventData, Status, false>,
    ThreadsafeFunction<bool, (), bool, Status, false>,
    ThreadsafeFunction<i32, (), i32, Status, false>,
    ThreadsafeFunction<i32, (), i32, Status, false>,
    ThreadsafeFunction<SelectionEventData, (), SelectionEventData, Status, false>,
    ThreadsafeFunction<i32, (), i32, Status, false>,
);

#[napi(object)]
pub struct SelectionEventData {
    pub start: i32,
    pub end: i32,
}

#[napi(object)]
#[derive(Clone)]
pub struct PreviewTextEventData {
    pub text: String,
    pub start: i32,
    pub end: i32,
}

fn dispatch_ime_input(app: &OpenHarmonyApp, owner: &str, event: InputEvent) {
    if let Some(ref mut handler) = *app.event_loop.borrow_mut() {
        match app.render_window_id(owner) {
            Some(0) => handler(Event::Input(event)),
            Some(window_id) => handler(Event::SubWindowInput { window_id, event }),
            None => {}
        }
    }
}

fn numeric_ime_callback(
    env: &Env,
    app: OpenHarmonyApp,
    owner: String,
    name: &str,
    event: fn(i32) -> ImeEvent,
) -> Result<ThreadsafeFunction<i32, (), i32, Status, false>> {
    let callback: Function<i32, ()> = env.create_function_from_closure(name, move |ctx| {
        if app.is_render_surface_active(&owner) {
            if let Ok(value) = ctx.first_arg::<i32>() {
                dispatch_ime_input(&app, &owner, InputEvent::Ime(event(value)));
            }
        }
        Ok(())
    })?;
    callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()
}

pub fn ime_ts_fn(env: &Env, app: OpenHarmonyApp, render_owner: String) -> Result<ImeCallback> {
    let extend_action = numeric_ime_callback(
        env,
        app.clone(),
        render_owner.clone(),
        "ime_extend_action_callback",
        |value| ImeEvent::ExtendActionEvent(ohos_ime_binding::Action::from(value as u32)),
    )?;
    let selection_app = app.clone();
    let selection_owner = render_owner.clone();
    let selection: Function<SelectionEventData, ()> =
        env.create_function_from_closure("ime_selection_callback", move |ctx| {
            if selection_app.is_render_surface_active(&selection_owner) {
                if let Ok(value) = ctx.first_arg::<SelectionEventData>() {
                    dispatch_ime_input(
                        &selection_app,
                        &selection_owner,
                        InputEvent::Ime(ImeEvent::SelectionEvent {
                            start: value.start,
                            end: value.end,
                        }),
                    );
                }
            }
            Ok(())
        })?;
    let selection = selection
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;
    let delete_forward = numeric_ime_callback(
        env,
        app.clone(),
        render_owner.clone(),
        "ime_delete_forward_callback",
        ImeEvent::DeleteForwardEvent,
    )?;
    let move_cursor = numeric_ime_callback(
        env,
        app.clone(),
        render_owner.clone(),
        "ime_move_cursor_callback",
        |value| ImeEvent::MoveCursorEvent(ohos_ime_binding::Direction::from(value as u32)),
    )?;
    let on_preview_app = app.clone();
    let on_preview_owner = render_owner.clone();
    let preview_callback: Function<PreviewTextEventData, ()> =
        env.create_function_from_closure("ime_preview_callback", move |ctx| {
            if !on_preview_app.is_render_surface_active(&on_preview_owner) {
                return Ok(());
            }
            let Some(data) = ctx.first_arg::<PreviewTextEventData>().ok() else {
                crate::warn!("ime_preview_callback: invalid preview, dropping event");
                return Ok(());
            };
            dispatch_ime_input(
                &on_preview_app,
                &on_preview_owner,
                InputEvent::Ime(ImeEvent::PreviewTextEvent {
                    text: data.text,
                    start: data.start,
                    end: data.end,
                }),
            );
            Ok(())
        })?;
    let preview_callback_tsfn = preview_callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let on_finish_app = app.clone();
    let on_finish_owner = render_owner.clone();
    let finish_callback: Function<bool, ()> =
        env.create_function_from_closure("ime_finish_preview_callback", move |_ctx| {
            if on_finish_app.is_render_surface_active(&on_finish_owner) {
                dispatch_ime_input(
                    &on_finish_app,
                    &on_finish_owner,
                    InputEvent::Ime(ImeEvent::FinishPreviewEvent),
                );
            }
            Ok(())
        })?;
    let finish_callback_tsfn = finish_callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

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
            dispatch_ime_input(
                &on_insert_text_app,
                &on_insert_text_owner,
                InputEvent::Ime(ImeEvent::TextInputEvent(TextInputEventData { text: s })),
            );
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
            dispatch_ime_input(
                &on_ime_hide_app,
                &on_ime_hide_owner,
                InputEvent::Ime(ImeEvent::ImeStatusEvent(status)),
            );
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
            dispatch_ime_input(
                &on_backspace_app,
                &on_backspace_owner,
                InputEvent::Ime(ImeEvent::BackspaceEvent(value)),
            );
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
            dispatch_ime_input(
                &on_ime_enter_app,
                &on_ime_enter_owner,
                InputEvent::Ime(ImeEvent::EnterEvent(value)),
            );
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
        preview_callback_tsfn,
        finish_callback_tsfn,
        delete_forward,
        move_cursor,
        selection,
        extend_action,
    ))
}
