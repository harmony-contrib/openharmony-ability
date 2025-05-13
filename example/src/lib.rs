use napi_derive_ohos::napi;
use ohos_hilog_binding::hilog_info;
use openharmony_ability::{Event, InputEvent, OpenHarmonyApp};
use openharmony_ability_derive::ability;

// test add more napi method
#[napi]
pub fn handle_change() -> napi_ohos::Result<()> {
    Ok(())
}

#[ability]
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
