use std::sync::{LazyLock, RwLock};

use napi_derive_ohos::napi;
use ohos_hilog_binding::hilog_info;
use openharmony_ability::{Event, InputEvent, OpenHarmonyApp};
use openharmony_ability_derive::ability;

static INNER_APP: LazyLock<RwLock<Option<OpenHarmonyApp>>> = LazyLock::new(|| RwLock::new(None));

// test add more napi method
#[napi]
pub fn handle_change() -> napi_ohos::Result<()> {
    let guard = INNER_APP.read().unwrap();
    let app = guard.as_ref().unwrap();

    app.create_webview("https://www.baidu.com".to_string(), None, |id| {
        hilog_info!(format!("ohos-rs macro create_webview: {:?}", id).as_str());
    });
    Ok(())
}

#[ability(webview)]
fn openharmony_app(app: OpenHarmonyApp) {
    INNER_APP.write().unwrap().replace(app.clone());

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
