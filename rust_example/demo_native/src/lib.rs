#![allow(dead_code)]

mod login_bridge;
mod main_thread_bridge;
mod raw_bridge;

use std::{
    borrow::Cow,
    sync::{
        atomic::{AtomicBool, Ordering},
        LazyLock, Mutex, RwLock,
    },
};

use futures_channel::oneshot;
use napi_derive_ohos::napi;
use napi_ohos::{Env, Error, Result};
use ohos_hilog_binding::hilog_info;
use openharmony_ability::{Event, InputEvent, OpenHarmonyApp};
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_files::{dialog_type, FileDialogFilter, FileDialogOptions, FilesExt};
use openharmony_ability_plugin_permission::PermissionExt;
use openharmony_ability_plugin_url::UrlExt;
use openharmony_ability_plugin_webview::{
    WebviewBridgePlugin, WebviewCallbacksBuilder, WebviewClient, WebviewCreateRequest,
    WebviewDownloadStartResponse, WebviewExt, WebviewJavascriptProxyBuilder, WebviewProtocol,
    WebviewProtocolOptions,
};

static INNER_APP: LazyLock<RwLock<Option<OpenHarmonyApp>>> = LazyLock::new(|| RwLock::new(None));
static PERMISSION_REQUESTED: AtomicBool = AtomicBool::new(false);
static MAIN_THREAD_DEMO_REQUESTED: AtomicBool = AtomicBool::new(false);
static BACK_PRESS_INTERCEPT_ENABLED: AtomicBool = AtomicBool::new(true);

#[derive(Default)]
struct DemoWebviewBindings {
    callbacks: bool,
    proxy: bool,
    protocol: bool,
}

static WEBVIEW_BINDINGS: LazyLock<Mutex<DemoWebviewBindings>> =
    LazyLock::new(|| Mutex::new(DemoWebviewBindings::default()));

const WEB_TAG: &str = "demo_webview";
const WEBVIEW_SLOT: &str = "webview-panel";
const WEB_SCHEME: &str = "demoweb";
const WEB_URL: &str = "demoweb://index";
const INDEX: &str = include_str!("index.html");

fn current_app() -> Result<OpenHarmonyApp> {
    INNER_APP
        .read()
        .unwrap()
        .as_ref()
        .cloned()
        .ok_or_else(|| Error::from_reason("OpenHarmony app not initialized"))
}

/// Installs each persistent demo declaration only after that declaration succeeds. The mutex
/// prevents two rapid UI clicks from enqueueing duplicate proxies while still allowing a failed
/// protocol declaration to be retried on the next click.
fn ensure_demo_webview_bindings(client: &WebviewClient) -> Result<()> {
    let mut bindings = WEBVIEW_BINDINGS
        .lock()
        .map_err(|_| Error::from_reason("Failed to lock demo WebView binding state"))?;

    if !bindings.callbacks {
        WebviewCallbacksBuilder::new(WEB_TAG)
            .on_navigation_request(|request| {
                hilog_info!(format!("WebView navigation request => {}", request.url).as_str());
                false
            })
            .on_download_start(|request| {
                hilog_info!(format!(
                    "WebView download start => url={}, temp_path={:?}",
                    request.url, request.temp_path
                )
                .as_str());
                WebviewDownloadStartResponse::allow(request.temp_path)
            })
            .on_download_end(|event| {
                hilog_info!(format!(
                    "WebView download end => url={}, temp_path={:?}, success={}",
                    event.url, event.temp_path, event.success
                )
                .as_str());
            })
            .on_title_change(|event| {
                hilog_info!(format!("WebView title => {}", event.title).as_str());
            })
            .build()?;
        bindings.callbacks = true;
    }

    if !bindings.proxy {
        WebviewJavascriptProxyBuilder::new(WEB_TAG, "test")
            .add_method("test", |_tag, arguments| {
                hilog_info!(format!("WebView window.test.test => {arguments:?}").as_str());
            })
            .build()?;
        bindings.proxy = true;
    }

    if !bindings.protocol {
        client.custom_protocol(WEB_TAG, WEB_SCHEME, |_url, _request, _is_main_frame| {
            let body: Cow<'static, [u8]> = Cow::Borrowed(INDEX.as_bytes());
            http::Response::builder()
                .status(200)
                .header("content-type", "text/html; charset=utf-8")
                .body(body)
                .ok()
        })?;
        bindings.protocol = true;
    }
    Ok(())
}

#[napi]
pub async fn demo_request_permission_from_main_thread() -> Result<Vec<i32>> {
    if MAIN_THREAD_DEMO_REQUESTED.swap(true, Ordering::SeqCst) {
        hilog_info!("main-thread demo request already triggered");
        return Ok(vec![]);
    }

    let results = current_app()?
        .request_permission("ohos.permission.MICROPHONE")
        .await?;
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

/// Worker -> TSFN -> ArkTS async plugin -> Rust future.
#[napi]
pub async fn demo_plugin_login() -> Result<String> {
    let bridge = current_app()?.bridge()?;
    let (sender, receiver) = oneshot::channel::<std::result::Result<String, String>>();

    std::thread::Builder::new()
        .name("bridge-login-worker".to_owned())
        .spawn(move || {
            let result = futures_executor::block_on(login_bridge::login_from_worker(bridge))
                .map_err(|error| error.to_string());
            let _ = sender.send(result);
        })
        .map_err(|error| Error::from_reason(format!("Failed to start login worker: {error}")))?;

    receiver
        .await
        .map_err(|_| Error::from_reason("Login worker stopped before returning a result"))?
        .map_err(Error::from_reason)
}

/// Synchronous plugins remain scoped to the N-API main-thread `Env`.
#[napi]
pub fn demo_plugin_sync_context(env: &Env) -> Result<String> {
    main_thread_bridge::inspect_from_napi_main_thread(&current_app()?, env)
}

/// `String` travels as the named `std.string` N-API type, without JSON serialization.
#[napi]
pub async fn demo_plugin_string() -> Result<String> {
    raw_bridge::echo_string(current_app()?.bridge()?, "hello from Rust").await
}

/// Bytes travel through the bridge as a Uint8Array, not a JSON number array or Base64 string.
#[napi]
pub async fn demo_plugin_bytes() -> Result<Vec<u8>> {
    raw_bridge::reverse_bytes(current_app()?.bridge()?, vec![1, 2, 3, 4]).await
}

/// A `#[napi(object)]` value crosses the bridge directly and keeps its explicit `demo.Profile`
/// type identity at the ArkTS plugin boundary.
#[napi]
pub async fn demo_plugin_profile() -> Result<raw_bridge::DemoProfile> {
    raw_bridge::bump_profile(
        current_app()?.bridge()?,
        raw_bridge::DemoProfile {
            user_id: "demo-user-1001".to_owned(),
            visit_count: 41,
        },
    )
    .await
}

#[napi]
pub fn toggle_back_press_intercept() -> bool {
    let current = BACK_PRESS_INTERCEPT_ENABLED.load(Ordering::SeqCst);
    let next = !current;
    BACK_PRESS_INTERCEPT_ENABLED.store(next, Ordering::SeqCst);
    hilog_info!(format!("back press intercept set to: {next}").as_str());
    next
}

/// Creates a WebView through the WebView plugin. The ArkTS plugin mounts only into the named
/// business-owned BridgeNodeHost slot; it does not touch DefaultXComponent internals.
#[napi]
pub async fn create_demo_webview() -> Result<()> {
    let client = current_app()?.webview()?;
    ensure_demo_webview_bindings(&client)?;
    client
        .create(
            WebviewCreateRequest::new(WEB_TAG)
                .slot_id(WEBVIEW_SLOT)
                .transparent(true)
                .url(WEB_URL),
        )
        .await?;
    Ok(())
}

/// Proves the Rust → WebView JavaScript path. The bridge waits for `onControllerAttached` before
/// calling ArkTS `WebviewController.runJavaScript`.
#[napi]
pub async fn evaluate_demo_webview_script() -> Result<String> {
    current_app()?
        .webview()?
        .handle(WEB_TAG, WEBVIEW_SLOT)
        .evaluate_script("document.title")
        .await?
        .ok_or_else(|| Error::from_reason("WebView JavaScript returned no value"))
}

#[napi]
pub async fn set_background_color(color: String) -> Result<()> {
    current_app()?
        .webview()?
        .handle(WEB_TAG, WEBVIEW_SLOT)
        .set_background_color(color)
        .await
}

#[napi]
pub async fn set_visible(visible: bool) -> Result<()> {
    current_app()?
        .webview()?
        .handle(WEB_TAG, WEBVIEW_SLOT)
        .set_visible(visible)
        .await
}

#[ability]
fn openharmony_app(app: OpenHarmonyApp) {
    INNER_APP.write().unwrap().replace(app.clone());
    WebviewProtocol::register(
        WEB_SCHEME,
        WebviewProtocolOptions::Standard
            | WebviewProtocolOptions::CorsEnabled
            | WebviewProtocolOptions::CspBypassing
            | WebviewProtocolOptions::FetchEnabled
            | WebviewProtocolOptions::CodeCacheEnabled,
    )
    .expect("demo WebView scheme declaration must precede engine initialization");
    if let Err(error) = app.register_plugin(login_bridge::DemoLoginPlugin) {
        hilog_info!(format!("failed to register demo.login facade: {error}").as_str());
    }
    if let Err(error) = app.register_plugin(main_thread_bridge::DemoMainThreadPlugin) {
        hilog_info!(format!("failed to register demo.main-thread facade: {error}").as_str());
    }
    if let Err(error) = app.register_plugin(raw_bridge::DemoTypedPlugin) {
        hilog_info!(format!("failed to register demo.raw facade: {error}").as_str());
    }
    app.register_plugin(WebviewBridgePlugin)
        .expect("demo WebView facade must be registered");
    if let Err(error) = app.register_plugin(openharmony_ability_plugin_url::UrlBridgePlugin) {
        hilog_info!(format!("failed to register url facade: {error}").as_str());
    }
    if let Err(error) = app.register_plugin(openharmony_ability_plugin_files::FilesBridgePlugin) {
        hilog_info!(format!("failed to register files facade: {error}").as_str());
    }
    hilog_info!(format!(
        "init context => module={:?}, base={:?}, pref={:?}, locales={:?}",
        app.module_name(),
        app.base_path(),
        app.pref_path(),
        app.preferred_locales()
    )
    .as_str());

    app.on_back_press_intercept(|| {
        let intercept = BACK_PRESS_INTERCEPT_ENABLED.load(Ordering::SeqCst);
        hilog_info!(format!("on_back_press_intercept => {intercept}").as_str());
        intercept
    });

    app.clone().run_loop(move |event| match event {
        Event::SurfaceCreate => {
            hilog_info!("ohos-rs surface_create");
            if !PERMISSION_REQUESTED.swap(true, Ordering::SeqCst) {
                let app_for_permission = app.clone();
                std::thread::spawn(move || {
                    let result = futures_executor::block_on(
                        app_for_permission.request_permission(vec!["ohos.permission.CAMERA"]),
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
                        Err(error) => {
                            hilog_info!(format!("permission request failed: {error}").as_str());
                        }
                    }
                });
            }
        }
        Event::Input(input) => match input {
            InputEvent::ImeEvent(text) => {
                hilog_info!(format!("ohos-rs input_text: {text:?}").as_str());
            }
            InputEvent::MouseEvent(mouse) => {
                hilog_info!(format!("ohos-rs mouse: {mouse:?}").as_str());
            }
            _ => {
                hilog_info!("ohos-rs input");
            }
        },
        Event::WindowRedraw(_) => {
            hilog_info!("ohos-rs window_redraw");
        }
        event => {
            hilog_info!(format!("ohos-rs: {}", event.as_str()).as_str());
        }
    });
}

/// PR #65 capability demo: open an external URL through `ohos.url`.
#[napi]
pub async fn demo_open_url() -> Result<()> {
    current_app()?.open_url("https://www.openharmony.cn").await
}

/// PR #65 capability demo: open-file dialog through `ohos.files`.
#[napi]
pub async fn demo_file_dialog_open() -> Result<Vec<String>> {
    let options = FileDialogOptions::new(dialog_type::OPEN_FILE)
        .allow_many(true)
        .filters(vec![
            FileDialogFilter::new().name("Text").pattern("txt;md"),
            FileDialogFilter::new().name("Images").pattern("png;jpg"),
        ]);
    let response = current_app()?.show_file_dialog(options).await?;
    Ok(response.files)
}

/// PR #65 capability demo: save-file dialog through `ohos.files`.
#[napi]
pub async fn demo_file_dialog_save() -> Result<Vec<String>> {
    let options = FileDialogOptions::new(dialog_type::SAVE_FILE)
        .default_location("file://docs")
        .filters(vec![FileDialogFilter::new().name("PDF").pattern("pdf")]);
    let response = current_app()?.show_file_dialog(options).await?;
    Ok(response.files)
}
