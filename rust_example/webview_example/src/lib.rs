use std::cell::RefCell;

use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{Function, JsObjectValue, Object},
    Env,
};
use ohos_hilog_binding::hilog_info;
use openharmony_ability::{
    native_web::WebProxyBuilder, Event, InputEvent, OpenHarmonyApp, WebViewBuilder,
};
use openharmony_ability_derive::ability;

thread_local! {
    static WEBVIEW_ID: RefCell<Option<Object<'static>>> = RefCell::new(None);
}

const INDEX: &str = include_str!("index.html");

// test add more napi method
#[napi]
pub fn handle_change(env: &Env) -> napi_ohos::Result<()> {
    let web_tag = String::from("webview_example");

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
        hilog_info!(format!("ohos-rs macro on_controller_attach").as_str());
        let _ = WebProxyBuilder::new(web_tag.clone(), "test".to_string())
            .add_method("test", |_web_tag: String, args: Vec<String>| {
                hilog_info!(format!("ohos-rs macro test: {:?}", args).as_str());
            })
            .build()
            .unwrap();
    });

    let _ = webview.on_page_begin(|| {
        hilog_info!(format!("ohos-rs macro on_page_begin").as_str());
    });

    let _ = webview.on_page_end(|| {
        hilog_info!(format!("ohos-rs macro on_page_end").as_str());
    });

    let ret = unsafe { std::mem::transmute(webview.inner().get_value(env)?) };

    WEBVIEW_ID.with(|w| {
        w.replace(Some(ret));
    });

    Ok(())
}

#[napi]
pub fn set_background_color(env: &Env, color: String) -> napi_ohos::Result<()> {
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
pub fn set_visible(env: &Env, visible: bool) -> napi_ohos::Result<()> {
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
    app.run_loop(|types| match types {
        Event::Input(k) => match k {
            InputEvent::ImeEvent(s) => {
                hilog_info!(format!("ohos-rs macro input_text: {:?}", s).as_str());
            }
            _ => {
                hilog_info!(format!("ohos-rs macro input:").as_str());
            }
        },
        Event::WindowRedraw(_) => {
            // hilog_info!(format!("ohos-rs macro window_redraw").as_str());
        }
        _ => {
            hilog_info!(format!("ohos-rs macro: {:?}", types.as_str()).as_str());
        }
    });
}
