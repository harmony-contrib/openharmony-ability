#![allow(dead_code)]

use std::sync::{
    atomic::{AtomicBool, Ordering},
    LazyLock, RwLock,
};

use napi_ohos::{Error, Result};
use ohos_hilog_binding::hilog_info;
use openharmony_ability::{Event, InputEvent, OpenHarmonyApp};
use openharmony_ability_derive::ability;

static INNER_APP: LazyLock<RwLock<Option<OpenHarmonyApp>>> = LazyLock::new(|| RwLock::new(None));
static PERMISSION_REQUESTED: AtomicBool = AtomicBool::new(false);
static MAIN_THREAD_DEMO_REQUESTED: AtomicBool = AtomicBool::new(false);

#[napi_derive_ohos::napi]
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

#[ability]
fn openharmony_app(app: OpenHarmonyApp) {
    INNER_APP.write().unwrap().replace(app.clone());
    let permission_app = app.clone();

    app.run_loop(move |types| match types {
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
