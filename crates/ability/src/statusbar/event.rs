use crossbeam_channel::{Receiver, Sender};
use napi_ohos::bindgen_prelude::*;
use std::sync::OnceLock;

use super::types::StatusBarClickEvent;
use crate::{get_helper, get_main_thread_env};

static ICON_CLICK_CHANNEL: OnceLock<(Sender<StatusBarClickEvent>, Receiver<StatusBarClickEvent>)> =
    OnceLock::new();

static MENU_CLICK_CHANNEL: OnceLock<(Sender<StatusBarClickEvent>, Receiver<StatusBarClickEvent>)> =
    OnceLock::new();

fn icon_click_channel() -> &'static (Sender<StatusBarClickEvent>, Receiver<StatusBarClickEvent>) {
    ICON_CLICK_CHANNEL.get_or_init(crossbeam_channel::unbounded)
}

fn menu_click_channel() -> &'static (Sender<StatusBarClickEvent>, Receiver<StatusBarClickEvent>) {
    MENU_CLICK_CHANNEL.get_or_init(crossbeam_channel::unbounded)
}

pub fn icon_click_sender() -> &'static Sender<StatusBarClickEvent> {
    &icon_click_channel().0
}

pub fn menu_click_sender() -> &'static Sender<StatusBarClickEvent> {
    &menu_click_channel().0
}

pub fn icon_click_receiver() -> &'static Receiver<StatusBarClickEvent> {
    &icon_click_channel().1
}

pub fn menu_click_receiver() -> &'static Receiver<StatusBarClickEvent> {
    &menu_click_channel().1
}

pub fn register_icon_click_handler() -> Result<()> {
    let env_rc = get_main_thread_env();
    let env_guard = env_rc.borrow();
    let env = env_guard
        .as_ref()
        .ok_or_else(|| Error::from_reason("Main thread env not available"))?;

    let helper_rc = unsafe { get_helper() };
    let helper_guard = helper_rc.borrow();
    let helper_ref = helper_guard
        .as_ref()
        .ok_or_else(|| Error::from_reason("Helper not initialized"))?;

    let mut helper_obj = helper_ref.get_value(env)?;

    let sender = icon_click_channel().0.clone();

    let callback: Function<'_, Object<'_>, ()> = env.create_function_from_closure(
        "on_status_bar_icon_click",
        move |ctx: FunctionCallContext| {
            let event_data: Object = ctx.first_arg()?;

            if let Ok(Some(data)) = event_data.get::<Object>("data") {
                if let Ok(Some(click_type)) = data.get::<String>("iconClickType") {
                    let event = StatusBarClickEvent::IconClick { click_type };
                    let _ = sender.send(event);
                }
            }

            Ok(())
        },
    )?;

    helper_obj.set("_onIconClick", callback)?;

    Ok(())
}

pub fn register_menu_click_handler() -> Result<()> {
    let env_rc = get_main_thread_env();
    let env_guard = env_rc.borrow();
    let env = env_guard
        .as_ref()
        .ok_or_else(|| Error::from_reason("Main thread env not available"))?;

    let helper_rc = unsafe { get_helper() };
    let helper_guard = helper_rc.borrow();
    let helper_ref = helper_guard
        .as_ref()
        .ok_or_else(|| Error::from_reason("Helper not initialized"))?;

    let mut helper_obj = helper_ref.get_value(env)?;

    let sender = menu_click_channel().0.clone();

    let callback: Function<'_, Object<'_>, ()> = env.create_function_from_closure(
        "on_right_menu_click",
        move |ctx: FunctionCallContext| {
            let event_data: Object = ctx.first_arg()?;

            if let Ok(Some(data)) = event_data.get::<Object>("data") {
                if let Ok(Some(menu_code)) = data.get::<String>("menuCode") {
                    let event = StatusBarClickEvent::MenuClick { menu_code };
                    let _ = sender.send(event);
                }
            }

            Ok(())
        },
    )?;

    helper_obj.set("_onMenuClick", callback)?;

    Ok(())
}

pub fn unregister_icon_click_handler() -> Result<()> {
    let env_rc = get_main_thread_env();
    let env_guard = env_rc.borrow();
    let env = env_guard
        .as_ref()
        .ok_or_else(|| Error::from_reason("Main thread env not available"))?;

    let helper_rc = unsafe { get_helper() };
    let helper_guard = helper_rc.borrow();
    let helper_ref = helper_guard
        .as_ref()
        .ok_or_else(|| Error::from_reason("Helper not initialized"))?;

    let helper_obj = helper_ref.get_value(env)?;

    let unregister_fn: Function<'_, (String,), ()> =
        helper_obj.get_named_property("unregisterIconClickHandler")?;
    unregister_fn.call(("statusBarIconClick".to_string(),))?;

    Ok(())
}

pub fn unregister_menu_click_handler() -> Result<()> {
    let env_rc = get_main_thread_env();
    let env_guard = env_rc.borrow();
    let env = env_guard
        .as_ref()
        .ok_or_else(|| Error::from_reason("Main thread env not available"))?;

    let helper_rc = unsafe { get_helper() };
    let helper_guard = helper_rc.borrow();
    let helper_ref = helper_guard
        .as_ref()
        .ok_or_else(|| Error::from_reason("Helper not initialized"))?;

    let helper_obj = helper_ref.get_value(env)?;

    let unregister_fn: Function<'_, (String,), ()> =
        helper_obj.get_named_property("unregisterMenuClickHandler")?;
    unregister_fn.call(("rightMenuClick".to_string(),))?;

    Ok(())
}
