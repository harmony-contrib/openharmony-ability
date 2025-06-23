use std::cell::RefCell;

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Function, Env, JsObject, Ref};
use ohos_hilog_binding::hilog_info;
use openharmony_ability::{create_webview_with_id, Event, InputEvent, OpenHarmonyApp};
use openharmony_ability_derive::ability;

thread_local! {
    static WEBVIEW_ID: RefCell<Option<Ref<JsObject>>> = RefCell::new(None);
}

// test add more napi method
#[napi]
pub fn handle_change(env: &Env) -> napi_ohos::Result<()> {
    let webview = create_webview_with_id("https://www.baidu.com", "1")?;

    let rr = Ref::new(env, &webview.inner)?;

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
            hilog_info!(format!("ohos-rs macro window_redraw").as_str());
        }
        _ => {
            hilog_info!(format!("ohos-rs macro: {:?}", types.as_str()).as_str());
        }
    });
}
