use ohos_hilog_binding::hilog_info;
use openharmony_activity::App;
use openharmony_activity_derive::activity;

#[activity]
fn openharmony_app(app: &App) {
    app.run_loop(|| hilog_info!("ohos-rs macro"));
}
