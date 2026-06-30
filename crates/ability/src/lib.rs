mod app;
mod area;
mod autostart;
mod configuration;
mod draw;
mod error;
mod event;
mod helper;
mod input;
mod lifecycle;
mod memory;
mod render;
mod resource;
mod stage;
mod waker;

#[cfg(feature = "statusbar")]
pub mod statusbar;

#[cfg(feature = "updater")]
mod updater;

pub mod version;

#[cfg(feature = "window")]
pub mod window;

#[cfg(feature = "webview")]
mod webview;

#[cfg(feature = "menu")]
pub mod menu;

#[cfg(feature = "clipboard")]
pub mod clipboard;

// ─── Logging macros (gated behind "log" feature) ───
// When the feature is on, delegate to the `log` crate (backed by ohos-hilog-binding on OHOS).
// When off, expand to no-ops — zero overhead, no dependency on `log`.

#[cfg(feature = "log")]
#[macro_export]
macro_rules! error {
    ($($arg:tt)*) => { ::log::error!($($arg)*) }
}
#[cfg(not(feature = "log"))]
#[macro_export]
macro_rules! error {
    ($($arg:tt)*) => {};
}

#[cfg(feature = "log")]
#[macro_export]
macro_rules! info {
    ($($arg:tt)*) => { ::log::info!($($arg)*) }
}
#[cfg(not(feature = "log"))]
#[macro_export]
macro_rules! info {
    ($($arg:tt)*) => {};
}

#[cfg(feature = "log")]
#[macro_export]
macro_rules! warn {
    ($($arg:tt)*) => { ::log::warn!($($arg)*) }
}
#[cfg(not(feature = "log"))]
#[macro_export]
macro_rules! warn {
    ($($arg:tt)*) => {};
}

#[cfg(feature = "log")]
#[macro_export]
macro_rules! debug {
    ($($arg:tt)*) => { ::log::debug!($($arg)*) }
}
#[cfg(not(feature = "log"))]
#[macro_export]
macro_rules! debug {
    ($($arg:tt)*) => {};
}

// ─── Re-exports ───

pub use app::*;
pub use area::*;
pub use autostart::*;
pub use configuration::*;
pub use draw::*;
pub use error::*;
pub use event::*;
pub use helper::*;
pub use input::*;
pub use lifecycle::*;
pub use memory::*;
pub use render::*;
pub use resource::*;
pub use stage::*;
pub use waker::*;

#[cfg(feature = "statusbar")]
pub use statusbar::*;

#[cfg(feature = "updater")]
pub use updater::*;

pub use version::*;

#[cfg(feature = "window")]
pub use window::*;

#[cfg(feature = "webview")]
pub use webview::*;

#[cfg(feature = "menu")]
pub use menu::{
    on_menu_request, on_popup_request,
    start_menu_forwarder, start_popup_forwarder,
    MenuRequestData, PopupRequestData,
    popup_context_menu, set_menu_json,
    menu_event_receiver, popup_request_receiver, menu_request_receiver,
    send_menu_event,
    set_menubar_visible, is_menubar_visible, notify_menubar_visibility,
};

#[cfg(feature = "clipboard")]
pub use clipboard::{clipboard_write_image, init_clipboard_tsfn};

// re-export arkui and avoid the need to import it in the lib.rs
pub use napi_ohos::Either;
pub use ohos_arkui_binding as arkui;
pub use ohos_ime_binding as ime;
pub use ohos_resource_manager_binding as resource_manager;
pub use ohos_xcomponent_binding as xcomponent;

#[cfg(feature = "webview")]
pub use ohos_web_binding as native_web;
