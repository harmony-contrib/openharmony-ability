use napi_ohos::bindgen_prelude::*;
use napi_ohos::threadsafe_function::{ThreadsafeCallContext, ThreadsafeFunction, ThreadsafeFunctionCallMode};
use std::sync::Mutex;

use crate::get_helper;
use super::types::{
    StatusBarIcon, StatusBarItem, StatusBarMenuItem,
};
use super::validate::{validate_hover_tips, validate_menus, validate_status_bar_item};

fn log_to_js(env: &Env, msg: &str) {
    let _: std::result::Result<(), _> = env.run_script(format!("console.info('{}')", msg.replace('\'', "\\'")));
}

// ─── Data structs for cross-thread transfer via TSFN ───

struct AddStatusBarData {
    white: Option<Vec<u8>>,
    black: Option<Vec<u8>>,
    icon_size: u32,
    ability_name: String,
    title: String,
    height: u32,
    module_name: Option<String>,
    loading_status: Option<bool>,
    menu_json: Option<String>,
    hover_tips: Option<String>,
}

struct UpdateIconData {
    white: Option<Vec<u8>>,
    black: Option<Vec<u8>>,
    icon_size: u32,
}

struct UpdateMenuData {
    menu_json: String,
}

struct UpdateTipsData {
    tips: String,
}

struct PredefinedActionData {
    action: String,
}

// ─── TSFN type aliases ───

type TrayTsfnAdd = ThreadsafeFunction<
    AddStatusBarData,
    (),
    FnArgs<(Object<'static>, f64, Object<'static>, Option<Vec<Vec<Object<'static>>>>, Option<String>)>,
    Status,
    false,
>;
type TrayTsfnRemove = ThreadsafeFunction<(), (), (), Status, false>;
type TrayTsfnUpdateIcon = ThreadsafeFunction<UpdateIconData, (), FnArgs<(Object<'static>, u32)>, Status, false>;
type TrayTsfnUpdateMenu = ThreadsafeFunction<UpdateMenuData, (), FnArgs<(Vec<Vec<Object<'static>>>,)>, Status, false>;
type TrayTsfnUpdateTips = ThreadsafeFunction<UpdateTipsData, (), FnArgs<(String,)>, Status, false>;
type TrayTsfnPredefined = ThreadsafeFunction<PredefinedActionData, (), FnArgs<(String,)>, Status, false>;

static TSFN_ADD: Mutex<Option<TrayTsfnAdd>> = Mutex::new(None);
static TSFN_REMOVE: Mutex<Option<TrayTsfnRemove>> = Mutex::new(None);
static TSFN_UPDATE_ICON: Mutex<Option<TrayTsfnUpdateIcon>> = Mutex::new(None);
static TSFN_UPDATE_MENU: Mutex<Option<TrayTsfnUpdateMenu>> = Mutex::new(None);
static TSFN_UPDATE_TIPS: Mutex<Option<TrayTsfnUpdateTips>> = Mutex::new(None);
static TSFN_PREDEFINED: Mutex<Option<TrayTsfnPredefined>> = Mutex::new(None);

/// Initialize all tray ThreadsafeFunctions. Must be called on ArkTS main thread.
pub fn init_tray_tsfn(env: &Env) -> Result<()> {
    let helper_obj = {
        let helper_rc = unsafe { get_helper() };
        let helper_guard = helper_rc.borrow();
        let helper_ref = helper_guard
            .as_ref()
            .ok_or_else(|| Error::from_reason("Helper not initialized"))?;
        helper_ref.get_value(env)?
    };

    log_to_js(env, "[StatusBar] init_tray_tsfn: got helper_obj, creating TSFNs...");

    // Register event callbacks on helper object via event.rs
    // (register_icon_click_handler/register_menu_click_handler set _onIconClick/_onMenuClick)
    if let Err(e) = super::event::register_icon_click_handler() {
        log_to_js(env, &format!("[StatusBar] register_icon_click_handler failed: {}", e));
    } else {
        log_to_js(env, "[StatusBar] register_icon_click_handler OK");
    }
    if let Err(e) = super::event::register_menu_click_handler() {
        log_to_js(env, &format!("[StatusBar] register_menu_click_handler failed: {}", e));
    } else {
        log_to_js(env, "[StatusBar] register_menu_click_handler OK");
    }

    let add_fn: Function<
        '_,
        (Object<'_>, f64, Object<'_>, Option<Vec<Vec<Object<'_>>>>, Option<String>),
        (),
    > = helper_obj
        .get_named_property("addToStatusBarWithRgba")
        .map_err(|e| Error::from_reason(format!("addToStatusBarWithRgba not found: {}", e)))?;

    let add_tsfn = add_fn
        .build_threadsafe_function::<AddStatusBarData>()
        .callee_handled::<false>()
        .build_callback(move |ctx: ThreadsafeCallContext<AddStatusBarData>| {
            build_add_args(ctx.env, ctx.value).map(|args| FnArgs { data: args })
        })?;

    let update_icon_fn: Function<'_, (Object<'_>, u32), ()> = helper_obj
        .get_named_property("updateStatusBarIconWithRgba")
        .map_err(|e| Error::from_reason(format!("updateStatusBarIconWithRgba not found: {}", e)))?;

    let update_icon_tsfn = update_icon_fn
        .build_threadsafe_function::<UpdateIconData>()
        .callee_handled::<false>()
        .build_callback(move |ctx: ThreadsafeCallContext<UpdateIconData>| {
            build_update_icon_args(ctx.env, ctx.value).map(|args| FnArgs { data: args })
        })?;

    let update_menu_fn: Function<'_, (Vec<Vec<Object<'_>>>,), ()> = helper_obj
        .get_named_property("updateStatusBarMenu")
        .map_err(|e| Error::from_reason(format!("updateStatusBarMenu not found: {}", e)))?;

    let update_menu_tsfn = update_menu_fn
        .build_threadsafe_function::<UpdateMenuData>()
        .callee_handled::<false>()
        .build_callback(move |ctx: ThreadsafeCallContext<UpdateMenuData>| {
            build_update_menu_args(ctx.env, ctx.value).map(|args| FnArgs { data: args })
        })?;

    let update_tips_fn: Function<'_, (String,), ()> = helper_obj
        .get_named_property("updateStatusBarHoverTips")
        .map_err(|e| Error::from_reason(format!("updateStatusBarHoverTips not found: {}", e)))?;

    let update_tips_tsfn = update_tips_fn
        .build_threadsafe_function::<UpdateTipsData>()
        .callee_handled::<false>()
        .build_callback(move |ctx: ThreadsafeCallContext<UpdateTipsData>| {
            Ok(FnArgs { data: (ctx.value.tips,) })
        })?;

    let remove_fn: Function<'_, (), ()> = helper_obj
        .get_named_property("removeFromStatusBar")
        .map_err(|e| Error::from_reason(format!("removeFromStatusBar not found: {}", e)))?;

    let remove_tsfn = remove_fn
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build_callback(move |_ctx: ThreadsafeCallContext<()>| Ok(()))?;

    let predefined_fn: Function<'_, (String,), ()> = helper_obj
        .get_named_property("executePredefinedAction")
        .map_err(|e| Error::from_reason(format!("executePredefinedAction not found: {}", e)))?;

    let predefined_tsfn = predefined_fn
        .build_threadsafe_function::<PredefinedActionData>()
        .callee_handled::<false>()
        .build_callback(move |ctx: ThreadsafeCallContext<PredefinedActionData>| {
            Ok(FnArgs { data: (ctx.value.action,) })
        })?;

    *TSFN_ADD.lock().unwrap() = Some(add_tsfn);
    *TSFN_REMOVE.lock().unwrap() = Some(remove_tsfn);
    *TSFN_UPDATE_ICON.lock().unwrap() = Some(update_icon_tsfn);
    *TSFN_UPDATE_MENU.lock().unwrap() = Some(update_menu_tsfn);
    *TSFN_UPDATE_TIPS.lock().unwrap() = Some(update_tips_tsfn);
    *TSFN_PREDEFINED.lock().unwrap() = Some(predefined_tsfn);

    Ok(())
}

// ─── TSFN callback helpers (run on ArkTS main thread) ───

fn build_add_args(env: Env, data: AddStatusBarData) -> Result<(Object<'static>, f64, Object<'static>, Option<Vec<Vec<Object<'static>>>>, Option<String>)> {
    let mut icons_rgba = Object::new(&env)?;
    if let Some(white) = data.white {
        icons_rgba.set("white", Uint8Array::new(white))?;
    }
    if let Some(black) = data.black {
        icons_rgba.set("black", Uint8Array::new(black))?;
    }

    let mut qo_obj = Object::new(&env)?;
    qo_obj.set("abilityName", &data.ability_name)?;
    qo_obj.set("title", if data.title.is_empty() { "App" } else { &data.title })?;
    qo_obj.set("height", data.height as f64)?;
    if let Some(module_name) = &data.module_name {
        qo_obj.set("moduleName", module_name.as_str())?;
    }
    if let Some(loading) = data.loading_status {
        qo_obj.set("loadingStatus", loading)?;
    }

    let menu_obj: Option<Vec<Vec<Object<'static>>>> = data.menu_json
        .as_ref()
        .map(|json| {
            let menus: Vec<Vec<StatusBarMenuItem>> = match serde_json::from_str(json) {
                Ok(m) => m,
                Err(e) => {
                    crate::error!("[StatusBar] menu JSON parse error in build_add_args: {}", e);
                    Vec::new()
                }
            };
            menus.iter().map(|group| {
                group.iter()
                    .filter_map(|item| build_menu_item_object_static(&env, item).ok())
                    .collect()
            }).collect()
        });

    Ok((icons_rgba, data.icon_size as f64, qo_obj, menu_obj, data.hover_tips))
}

fn build_update_icon_args(env: Env, data: UpdateIconData) -> Result<(Object<'static>, u32)> {
    let mut icons_rgba = Object::new(&env)?;
    if let Some(white) = data.white {
        icons_rgba.set("white", Uint8Array::new(white))?;
    }
    if let Some(black) = data.black {
        icons_rgba.set("black", Uint8Array::new(black))?;
    }
    Ok((icons_rgba, data.icon_size))
}

fn build_update_menu_args(env: Env, data: UpdateMenuData) -> Result<(Vec<Vec<Object<'static>>>,)> {
    let groups: Vec<Vec<Object<'static>>> = {
        let menus: Vec<Vec<StatusBarMenuItem>> = match serde_json::from_str(&data.menu_json) {
            Ok(m) => m,
            Err(e) => {
                crate::error!("[StatusBar] menu JSON parse error in build_update_menu_args: {}", e);
                Vec::new()
            }
        };
        menus.iter().map(|group| {
            group.iter()
                .filter_map(|item| build_menu_item_object_static(&env, item).ok())
                .collect()
        }).collect()
    };
    Ok((groups,))
}

// ─── JS object builders ───
fn build_menu_item_object_static(env: &Env, item: &StatusBarMenuItem) -> Result<Object<'static>> {
    let mut obj = Object::new(env)?;
    obj.set("title", &item.title)?;

    if let Some(action) = &item.menu_action {
        let mut action_obj = Object::new(env)?;
        action_obj.set("abilityName", &action.ability_name)?;
        if let Some(module) = &action.module_name {
            action_obj.set("moduleName", module)?;
        }
        if let Some(notify) = &action.notify_only {
            action_obj.set("notifyOnly", *notify)?;
        }
        if let Some(code) = &action.menu_code {
            action_obj.set("menuCode", code)?;
        }
        obj.set("menuAction", action_obj)?;
    }

    if let Some(sub_menu) = &item.sub_menu {
        let sub_items: Vec<Object<'static>> = sub_menu
            .iter()
            .filter_map(|sub| {
                let mut sub_obj = Object::new(env).ok()?;
                sub_obj.set("subTitle", &sub.sub_title).ok()?;
                let mut action_obj = Object::new(env).ok()?;
                action_obj.set("abilityName", &sub.menu_action.ability_name).ok()?;
                if let Some(module) = &sub.menu_action.module_name {
                    action_obj.set("moduleName", module).ok()?;
                }
                if let Some(notify) = &sub.menu_action.notify_only {
                    action_obj.set("notifyOnly", *notify).ok()?;
                }
                if let Some(code) = &sub.menu_action.menu_code {
                    action_obj.set("menuCode", code).ok()?;
                }
                sub_obj.set("menuAction", action_obj).ok()?;
                if let Some(code) = &sub.menu_code {
                    sub_obj.set("menuCode", code).ok()?;
                }
                if let Some(options) = &sub.options {
                    let mut options_obj = Object::new(env).ok()?;
                    if let Some(icon) = &options.icon {
                        let mut icon_obj = Object::new(env).ok()?;
                        if let Some(white) = icon.white.borrow().as_ref() {
                            icon_obj.set("white", white).ok()?;
                        }
                        if let Some(black) = icon.black.borrow().as_ref() {
                            icon_obj.set("black", black).ok()?;
                        }
                        options_obj.set("icon", icon_obj).ok()?;
                    }
                    if let Some(selected) = &options.selected {
                        options_obj.set("selected", *selected).ok()?;
                    }
                    if let Some(rgba) = &options.icon_rgba {
                        options_obj.set("iconRgba", Uint8Array::new(rgba.clone())).ok()?;
                    }
                    if let Some(w) = &options.icon_width {
                        options_obj.set("iconWidth", *w).ok()?;
                    }
                    if let Some(h) = &options.icon_height {
                        options_obj.set("iconHeight", *h).ok()?;
                    }
                    sub_obj.set("options", options_obj).ok()?;
                }
                Some(sub_obj)
            })
            .collect();
        obj.set("subMenu", sub_items)?;
    }
    if let Some(code) = &item.menu_code {
        obj.set("menuCode", code)?;
    }

    if let Some(options) = &item.options {
        let mut options_obj = Object::new(env)?;
        if let Some(icon) = &options.icon {
            let mut icon_obj = Object::new(env)?;
            if let Some(white) = icon.white.borrow().as_ref() {
                icon_obj.set("white", white)?;
            }
            if let Some(black) = icon.black.borrow().as_ref() {
                icon_obj.set("black", black)?;
            }
            options_obj.set("icon", icon_obj)?;
        }
        if let Some(selected) = &options.selected {
            options_obj.set("selected", *selected)?;
        }
        if let Some(rgba) = &options.icon_rgba {
            options_obj.set("iconRgba", Uint8Array::new(rgba.clone()))?;
        }
        if let Some(w) = &options.icon_width {
            options_obj.set("iconWidth", *w)?;
        }
        if let Some(h) = &options.icon_height {
            options_obj.set("iconHeight", *h)?;
        }
        obj.set("options", options_obj)?;
    }

    Ok(obj)
}

// ─── Public API ───

pub fn add_to_status_bar(_app: &crate::OpenHarmonyApp, item: &StatusBarItem) -> Result<()> {
    validate_status_bar_item(item)?;

    let data = AddStatusBarData {
        white: item.icons.white.borrow().clone(),
        black: item.icons.black.borrow().clone(),
        icon_size: item.icons.size,
        ability_name: item.quick_operation.ability_name.clone(),
        title: item.quick_operation.title.clone(),
        height: item.quick_operation.height,
        module_name: item.quick_operation.module_name.clone(),
        loading_status: item.quick_operation.loading_status,
        menu_json: item.status_bar_group_menu.as_ref()
            .map(|m| serde_json::to_string(m).unwrap_or_default()),
        hover_tips: item.hover_tips.clone(),
    };

    let tsfn = TSFN_ADD.lock().unwrap();
    let tsfn = tsfn.as_ref()
        .ok_or_else(|| Error::from_reason("addToStatusBar TSFN not initialized"))?;
    tsfn.call(data, ThreadsafeFunctionCallMode::NonBlocking);
    Ok(())
}

pub fn remove_from_status_bar(_app: &crate::OpenHarmonyApp) -> Result<()> {
    let tsfn = TSFN_REMOVE.lock().unwrap();
    let tsfn = tsfn.as_ref()
        .ok_or_else(|| Error::from_reason("removeFromStatusBar TSFN not initialized"))?;
    tsfn.call((), ThreadsafeFunctionCallMode::NonBlocking);
    Ok(())
}

pub fn update_status_bar_icon(_app: &crate::OpenHarmonyApp, icon: &StatusBarIcon) -> Result<()> {
    let data = UpdateIconData {
        white: icon.white.borrow().clone(),
        black: icon.black.borrow().clone(),
        icon_size: icon.size,
    };

    let tsfn = TSFN_UPDATE_ICON.lock().unwrap();
    let tsfn = tsfn.as_ref()
        .ok_or_else(|| Error::from_reason("updateStatusBarIcon TSFN not initialized"))?;
    tsfn.call(data, ThreadsafeFunctionCallMode::NonBlocking);
    Ok(())
}

pub fn update_status_bar_menu(
    _app: &crate::OpenHarmonyApp,
    menus: &Vec<Vec<StatusBarMenuItem>>,
) -> Result<()> {
    validate_menus(menus)?;

    let data = UpdateMenuData {
        menu_json: serde_json::to_string(menus).unwrap_or_default(),
    };

    let tsfn = TSFN_UPDATE_MENU.lock().unwrap();
    let tsfn = tsfn.as_ref()
        .ok_or_else(|| Error::from_reason("updateStatusBarMenu TSFN not initialized"))?;
    tsfn.call(data, ThreadsafeFunctionCallMode::NonBlocking);
    Ok(())
}

pub fn update_hover_tips(_app: &crate::OpenHarmonyApp, tips: &str) -> Result<()> {
    validate_hover_tips(tips)?;

    let data = UpdateTipsData {
        tips: tips.to_string(),
    };

    let tsfn = TSFN_UPDATE_TIPS.lock().unwrap();
    let tsfn = tsfn.as_ref()
        .ok_or_else(|| Error::from_reason("updateHoverTips TSFN not initialized"))?;
    tsfn.call(data, ThreadsafeFunctionCallMode::NonBlocking);
    Ok(())
}

pub fn execute_predefined_action(action: &str) -> Result<()> {
    let data = PredefinedActionData {
        action: action.to_string(),
    };

    let tsfn = TSFN_PREDEFINED.lock().unwrap();
    let tsfn = tsfn.as_ref()
        .ok_or_else(|| Error::from_reason("executePredefinedAction TSFN not initialized"))?;
    tsfn.call(data, ThreadsafeFunctionCallMode::NonBlocking);
    Ok(())
}
