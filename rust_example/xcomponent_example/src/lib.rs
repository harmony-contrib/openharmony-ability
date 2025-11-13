use std::sync::{LazyLock, RwLock};

use ohos_hilog_binding::hilog_info;
use openharmony_ability::{Event, InputEvent, OpenHarmonyApp};
use openharmony_ability_derive::ability;

#[allow(dead_code)]
static INNER_APP: LazyLock<RwLock<Option<OpenHarmonyApp>>> = LazyLock::new(|| RwLock::new(None));

#[ability]
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
