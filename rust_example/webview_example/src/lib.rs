use std::cell::RefCell;

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Function, Env, Error, JsObject, Ref};
use ohos_hilog_binding::hilog_info;
use openharmony_ability::{native_web, Event, InputEvent, OpenHarmonyApp, WebViewBuilder};
use openharmony_ability_derive::ability;

thread_local! {
    static WEBVIEW_ID: RefCell<Option<Ref<JsObject>>> = RefCell::new(None);
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

    let w = webview.clone();

    webview.on_controller_attach(move || {
        hilog_info!(format!("ohos-rs macro on_controller_attach").as_str());
        w.register_js_api("test", "test", |_, _| {
            hilog_info!(format!("ohos-rs macro register_js_api").as_str());
        });
    });

    webview.on_page_begin(|| {
        hilog_info!(format!("ohos-rs macro on_page_begin").as_str());
    });

    webview.on_page_end(|| {
        hilog_info!(format!("ohos-rs macro on_page_end").as_str());
    });

    let rr = Ref::new(env, &*webview.inner())?;

    WEBVIEW_ID.with(|w| {
        w.replace(Some(rr));
    });
    Ok(())
}

#[napi]
pub fn set_background_color(env: &Env, color: String) -> napi_ohos::Result<()> {
    WEBVIEW_ID.with(|w| {
        if let Some(webview) = w.borrow().as_ref() {
            let c = webview.get_value(env).unwrap();
            let set_background_color_js_function = c
                .get_named_property::<Function<'_, String, ()>>("setBackgroundColor")
                .unwrap();
            set_background_color_js_function
                .call(color.to_string())
                .unwrap();
        }
    });
    Ok(())
}

#[napi]
pub fn set_visible(env: &Env, visible: bool) -> napi_ohos::Result<()> {
    WEBVIEW_ID.with(|w| {
        if let Some(webview) = w.borrow().as_ref() {
            let c = webview.get_value(env).unwrap();
            let set_visible_js_function = c
                .get_named_property::<Function<'_, bool, ()>>("setVisible")
                .unwrap();
            set_visible_js_function.call(visible).unwrap();
        }
    });
    Ok(())
}

#[ability(webview)]
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
