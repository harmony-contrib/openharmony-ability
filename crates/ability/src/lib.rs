mod app;
mod area;
mod bridge;
mod configuration;
mod draw;
mod error;
mod event;
mod helper;
mod input;
mod lifecycle;
mod memory;
mod node;
mod render;
mod stage;
mod waker;

pub use helper::*;

#[cfg(feature = "account")]
mod account;

#[cfg(feature = "updater")]
mod updater;

#[cfg(feature = "process")]
mod process;

#[cfg(feature = "fault-injection")]
mod fault_injection;

pub mod version;

#[cfg(feature = "window")]
pub mod window;


#[cfg(feature = "clipboard")]
pub mod clipboard;

#[cfg(feature = "global_shortcut")]
pub mod global_shortcut;

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
pub use bridge::*;
pub use configuration::*;
pub use draw::*;
pub use error::*;
pub use event::*;
pub use input::*;
pub use lifecycle::*;
pub use memory::*;
pub use node::*;
pub use render::*;
pub use stage::*;
pub use waker::*;

#[cfg(feature = "account")]
pub use account::*;

#[cfg(feature = "updater")]
pub use updater::*;

#[cfg(feature = "process")]
pub use process::*;

#[cfg(feature = "fault-injection")]
pub use fault_injection::*;

pub use version::*;

#[cfg(feature = "window")]
pub use window::*;

/// Re-exported for [`impl_bridge_napi_type!`](crate::impl_bridge_napi_type) expansions in
/// application/plugin crates.
#[doc(hidden)]
pub use napi_ohos;

#[cfg(feature = "global_shortcut")]
pub use global_shortcut::{ShortcutEvent, ShortcutKey, ShortcutModifier, ShortcutState};

// re-export arkui and avoid the need to import it in the lib.rs
pub use napi_ohos::Either;
pub use ohos_arkui_binding as arkui;
pub use ohos_ime_binding as ime;
pub use ohos_xcomponent_binding as xcomponent;
