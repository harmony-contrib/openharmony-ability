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
use openharmony_ability_plugin_app_control::AppControlExt;
use openharmony_ability_plugin_clipboard::ClipboardExt;
use openharmony_ability_plugin_menu::{
    item_kind, MenuExt, MenuItemData,
};
use openharmony_ability_plugin_permission::PermissionExt;
use openharmony_ability_plugin_statusbar::{
    QuickOperationData, StatusBarExt, StatusBarIconData, StatusBarItemData,
    StatusBarMenuItemData, StatusBarMenuActionData,
};
use openharmony_ability_plugin_updater::UpdaterExt;
use openharmony_ability_plugin_version::VersionExt;
use openharmony_ability_plugin_window::WindowExtMulti;
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
    if let Err(error) = app.register_plugin(openharmony_ability_plugin_menu::MenuBridgePlugin) {
        hilog_info!(format!("failed to register menu facade: {error}").as_str());
    }
    if let Err(error) =
        app.register_plugin(openharmony_ability_plugin_statusbar::StatusBarBridgePlugin)
    {
        hilog_info!(format!("failed to register statusbar facade: {error}").as_str());
    }
    if let Err(error) =
        app.register_plugin(openharmony_ability_plugin_updater::UpdaterBridgePlugin)
    {
        hilog_info!(format!("failed to register updater facade: {error}").as_str());
    }
    if let Err(error) =
        app.register_plugin(openharmony_ability_plugin_clipboard::ClipboardBridgePlugin)
    {
        hilog_info!(format!("failed to register clipboard facade: {error}").as_str());
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

/// PR #63 capability demo: menu system (menubar + popup) through `ohos.menu`.
#[napi]
pub async fn demo_menu_set_menubar() -> Result<()> {
    let file_menu = MenuItemData::new("demo.file", item_kind::SUBMENU)
        .text("File")
        .submenu(vec![
            MenuItemData::new("demo.file.open", item_kind::NORMAL).text("Open"),
            MenuItemData::new("demo.file.sep", item_kind::SEPARATOR),
            MenuItemData::new("demo.file.quit", item_kind::PREDEFINED)
                .predefined("quit")
                .accelerator("Ctrl+Q"),
        ]);
    let edit_menu = MenuItemData::new("demo.edit", item_kind::SUBMENU)
        .text("Edit")
        .submenu(vec![
            MenuItemData::new("demo.edit.copy", item_kind::PREDEFINED)
                .predefined("copy")
                .accelerator("Ctrl+C"),
            MenuItemData::new("demo.edit.paste", item_kind::PREDEFINED)
                .predefined("paste")
                .accelerator("Ctrl+V"),
        ]);
    current_app()?
        .set_menubar("main", vec![file_menu, edit_menu])
        .await
}

/// PR #63 capability demo: context popup menu at given coordinates.
#[napi]
pub async fn demo_menu_popup(x: f64, y: f64) -> Result<()> {
    let items = vec![
        MenuItemData::new("demo.popup.refresh", item_kind::NORMAL).text("Refresh"),
        MenuItemData::new("demo.popup.sep", item_kind::SEPARATOR),
        MenuItemData::new("demo.popup.inspect", item_kind::NORMAL).text("Inspect"),
    ];
    current_app()?.popup("main", Some(x), Some(y), items).await
}

/// PR #63 capability demo: system tray item with menu groups.
#[napi]
pub async fn demo_statusbar_add() -> Result<()> {
    // 16x16 RGBA white icon.
    let rgba: Vec<u8> = vec![255u8; 16 * 16 * 4];
    let item = StatusBarItemData {
        icons: StatusBarIconData {
            white_rgba: Some(rgba),
            black_rgba: None,
            size: 16,
        },
        quick_operation: QuickOperationData {
            ability_name: "EntryAbility".to_owned(),
            title: "demo app".to_owned(),
            height: 200,
            module_name: None,
            loading_status: None,
        },
        status_bar_group_menu: Some(vec![vec![StatusBarMenuItemData {
            title: "Open demo".to_owned(),
            menu_code: Some("demo.open".to_owned()),
            sub_menu: None,
            menu_action: Some(StatusBarMenuActionData {
                ability_name: "EntryAbility".to_owned(),
                module_name: None,
                menu_code: None,
                notify_only: Some(true),
            }),
            selected: None,
            icon_rgba: None,
            icon_width: None,
            icon_height: None,
        }]]),
        hover_tips: Some("demo tray".to_owned()),
    };
    current_app()?.add_to_status_bar(item).await
}

/// PR #63 capability demo: device version + capability queries.
#[napi]
pub fn demo_version_info(env: &Env) -> Result<String> {
    let app = current_app()?;
    let sdk = app.sdk_api_version(env)?;
    let dist = app.distribution_api_version(env)?;
    let desktop = app.is_desktop_device(env)?;
    let can_use = app.can_i_use(env, "SystemCapability.Window.SessionManager")?;
    Ok(format!("sdk={sdk}, dist={dist}, desktop={desktop}, window-session={can_use}"))
}

/// PR #63 capability demo: clipboard image write.
#[napi]
pub async fn demo_clipboard_write_image() -> Result<()> {
    // 2x2 opaque white RGBA block.
    let rgba = vec![255u8; 2 * 2 * 4];
    current_app()?.write_image(rgba, 2, 2).await
}

/// PR #63 capability demo: AppGallery update check.
#[napi]
pub async fn demo_updater_check() -> Result<Option<String>> {
    let result = current_app()?.check().await?;
    Ok(result.map(|r| format!("{} -> {}", r.current_version, r.version)))
}

/// PR #63 capability demo: create an OS sub-window through `ohos.window`.
#[napi]
pub fn demo_create_os_window(env: &Env) -> Result<i64> {
    let request = openharmony_ability_plugin_window::WindowCreateRequest {
        name: "demo_sub".to_owned(),
        width: 480,
        height: 320,
        x: 200,
        y: 200,
        decorations: true,
        transparent: false,
        background_color: None,
    };
    current_app()?.create_os_window(env, request)
}

/// PR #63 capability demo: restart the app (cooldown 3s).
#[napi]
pub fn demo_restart(env: &Env) -> Result<()> {
    current_app()?.restart(env)
}

/// PR #63 capability demo: switch color mode (0 dark / 1 light / 2 system).
#[napi]
pub fn demo_set_color_mode(env: &Env, mode: i32) -> Result<()> {
    current_app()?.set_color_mode(env, mode)
}
