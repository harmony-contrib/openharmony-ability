use ohos_hilog_binding::hilog_info;
use openharmony_activity::App;
use openharmony_activity_derive::activity;

#[activity]
fn openharmony_app(app: App) {
    app.run_loop(|types| {
        hilog_info!(format!("ohos-rs macro: {:?}", types.as_str()).as_str());
        hilog_info!("ohos-rs macro");
    });
}
