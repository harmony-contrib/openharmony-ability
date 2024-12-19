use ohos_hilog_binding::hilog_info;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;

#[ability]
fn openharmony_app(app: OpenHarmonyApp) {
    app.run_loop(|types| {
        hilog_info!(format!("ohos-rs macro: {:?}", types.as_str()).as_str());
    });
}
