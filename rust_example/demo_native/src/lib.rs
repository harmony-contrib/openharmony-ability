#![allow(dead_code)]

use std::{
    cell::RefCell,
    sync::{
        atomic::{AtomicBool, Ordering},
        LazyLock, RwLock,
    },
};

use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{Function, JsObjectValue, Object},
    Env, Error, Result,
};
use ohos_hilog_binding::hilog_info;
use openharmony_ability::{
    native_web::WebProxyBuilder, Event, InputEvent, OpenHarmonyApp, WebViewBuilder,
};
use openharmony_ability_derive::ability;

static INNER_APP: LazyLock<RwLock<Option<OpenHarmonyApp>>> = LazyLock::new(|| RwLock::new(None));
static PERMISSION_REQUESTED: AtomicBool = AtomicBool::new(false);
static MAIN_THREAD_DEMO_REQUESTED: AtomicBool = AtomicBool::new(false);
static BACK_PRESS_INTERCEPT_ENABLED: AtomicBool = AtomicBool::new(true);

thread_local! {
    static WEBVIEW_ID: RefCell<Option<Object<'static>>> = const { RefCell::new(None) };
}

const WEB_TAG: &str = "demo_webview";
const INDEX: &str = include_str!("index.html");

#[napi]
pub async fn demo_request_permission_from_main_thread() -> Result<Vec<i32>> {
    if MAIN_THREAD_DEMO_REQUESTED.swap(true, Ordering::SeqCst) {
        hilog_info!("main-thread demo request already triggered");
        return Ok(vec![]);
    }

    let app = INNER_APP
        .read()
        .unwrap()
        .as_ref()
        .cloned()
        .ok_or_else(|| Error::from_reason("OpenHarmony app not initialized"))?;

    let results = app.request_permission("ohos.permission.MICROPHONE").await?;
    let mut codes = Vec::with_capacity(results.len());
    for item in results {
        hilog_info!(format!(
            "main-thread demo permission result => permission: {}, code: {}",
            item.permission, item.code
        )
        .as_str());
        codes.push(item.code);
    }

    Ok(codes)
}

#[napi]
pub fn toggle_back_press_intercept() -> bool {
    let current = BACK_PRESS_INTERCEPT_ENABLED.load(Ordering::SeqCst);
    let next = !current;
    BACK_PRESS_INTERCEPT_ENABLED.store(next, Ordering::SeqCst);
    hilog_info!(format!("back press intercept set to: {}", next).as_str());
    next
}

#[napi]
pub fn handle_change(env: &Env) -> napi_ohos::Result<()> {
    let web_tag = String::from(WEB_TAG);

    let webview = WebViewBuilder::new()
        .id(web_tag.clone())
        .html(INDEX)
        .build()?;

    webview
        .custom_protocol("wry", |url, req, is_main_frame| {
            hilog_info!(format!("ohos-rs macro custom_protocol: {:?}", url).as_str());
            hilog_info!(format!("ohos-rs macro custom_protocol: {:?}", req).as_str());
            hilog_info!(format!("ohos-rs macro custom_protocol: {:?}", is_main_frame).as_str());
            None
        })
        .map_err(|_| napi_ohos::Error::from_reason("custom_protocol error".to_string()))?;

    let _ = webview.on_controller_attach(move || {
        hilog_info!("ohos-rs macro on_controller_attach");
        let _ = WebProxyBuilder::new(web_tag.clone(), "test".to_string())
            .add_method("test", |_web_tag: String, args: Vec<String>| {
                hilog_info!(format!("ohos-rs macro test: {:?}", args).as_str());
            })
            .build()
            .unwrap();
    });

    let _ = webview.on_page_begin(|| {
        hilog_info!("ohos-rs macro on_page_begin");
    });

    let _ = webview.on_page_end(|| {
        hilog_info!("ohos-rs macro on_page_end");
    });

    let ret = unsafe { std::mem::transmute(webview.inner().get_value(env)?) };
    WEBVIEW_ID.with(|w| {
        w.replace(Some(ret));
    });

    Ok(())
}

#[napi]
pub fn set_background_color(_env: &Env, color: String) -> napi_ohos::Result<()> {
    WEBVIEW_ID.with(|w| {
        if let Some(webview) = w.borrow().as_ref() {
            let set_background_color_js_function = webview
                .get_named_property::<Function<'_, String, ()>>("setBackgroundColor")
                .unwrap();
            set_background_color_js_function.call(color).unwrap();
        }
    });
    Ok(())
}

#[napi]
pub fn set_visible(_env: &Env, visible: bool) -> napi_ohos::Result<()> {
    WEBVIEW_ID.with(|w| {
        if let Some(webview) = w.borrow().as_ref() {
            let set_visible_js_function = webview
                .get_named_property::<Function<'_, bool, ()>>("setVisible")
                .unwrap();
            set_visible_js_function.call(visible).unwrap();
        }
    });
    Ok(())
}

#[ability(webview, protocol = "wry,custom,other")]
fn openharmony_app(app: OpenHarmonyApp) {
    INNER_APP.write().unwrap().replace(app.clone());
    hilog_info!(format!(
        "init context => module={:?}, base={:?}, pref={:?}, locales={:?}",
        app.module_name(),
        app.base_path(),
        app.pref_path(),
        app.preferred_locales()
    )
    .as_str());

    let permission_app = app.clone();
    app.on_back_press_intercept(|| {
        let intercept = BACK_PRESS_INTERCEPT_ENABLED.load(Ordering::SeqCst);
        hilog_info!(format!("on_back_press_intercept => {}", intercept).as_str());
        intercept
    });

    app.run_loop(move |event| match event {
        Event::SurfaceCreate => {
            hilog_info!("ohos-rs macro surface_create");
            if !PERMISSION_REQUESTED.swap(true, Ordering::SeqCst) {
                let app_for_permission = permission_app.clone();
                std::thread::spawn(move || {
                    let permissions = vec!["ohos.permission.CAMERA"];
                    let result = futures_executor::block_on(
                        app_for_permission.request_permission(permissions),
                    );
                    match result {
                        Ok(results) => {
                            for item in results {
                                hilog_info!(format!(
                                    "permission request result => permission: {}, code: {}",
                                    item.permission, item.code
                                )
                                .as_str());
                            }
                        }
                        Err(err) => {
                            hilog_info!(format!("permission request failed: {}", err).as_str());
                        }
                    }
                });
            }
        }
        Event::Input(input) => match input {
            InputEvent::ImeEvent(text) => {
                hilog_info!(format!("ohos-rs macro input_text: {:?}", text).as_str());
            }
            _ => {
                hilog_info!("ohos-rs macro input:");
            }
        },
        Event::WindowRedraw(_) => {
            hilog_info!("ohos-rs macro window_redraw");
        }
        _ => {
            hilog_info!(format!("ohos-rs macro: {:?}", event.as_str()).as_str());
        }
    });
}
