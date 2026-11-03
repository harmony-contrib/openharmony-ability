//! OpenHarmony ability runtime: the Rust half of a native ability module.
//!
//! The `#[ability]` derive (crate `openharmony_ability_derive`) generates the
//! N-API entry around an [`OpenHarmonyApp`] facade; this crate supplies the
//! facade and its supporting surfaces - the ArkTS<->Rust bridge
//! ([`BridgePlugin`] / [`BridgeRuntime`]), lifecycle and event plumbing,
//! input/IME, display and window geometry, and the plugin ecosystem
//! (`openharmony_ability_plugin_*` crates) built on the bridge contracts.

mod app;
mod area;
mod bridge;
mod configuration;
mod display;
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
// When off, expand to no-ops - zero overhead, no dependency on `log`.

/// Logs at error level (delegates to `log::error!`; no-op without the `log` feature).
#[cfg(feature = "log")]
#[macro_export]
macro_rules! error {
    ($($arg:tt)*) => { ::log::error!($($arg)*) }
}
/// Logs at error level (no-op without the `log` feature).
#[cfg(not(feature = "log"))]
#[macro_export]
macro_rules! error {
    ($($arg:tt)*) => {};
}

/// Logs at info level (delegates to `log::info!`; no-op without the `log` feature).
#[cfg(feature = "log")]
#[macro_export]
macro_rules! info {
    ($($arg:tt)*) => { ::log::info!($($arg)*) }
}
/// Logs at info level (no-op without the `log` feature).
#[cfg(not(feature = "log"))]
#[macro_export]
macro_rules! info {
    ($($arg:tt)*) => {};
}

/// Logs at warn level (delegates to `log::warn!`; no-op without the `log` feature).
#[cfg(feature = "log")]
#[macro_export]
macro_rules! warn {
    ($($arg:tt)*) => { ::log::warn!($($arg)*) }
}
/// Logs at warn level (no-op without the `log` feature).
#[cfg(not(feature = "log"))]
#[macro_export]
macro_rules! warn {
    ($($arg:tt)*) => {};
}

/// Logs at debug level (delegates to `log::debug!`; no-op without the `log` feature).
#[cfg(feature = "log")]
#[macro_export]
macro_rules! debug {
    ($($arg:tt)*) => { ::log::debug!($($arg)*) }
}
/// Logs at debug level (no-op without the `log` feature).
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
pub use display::*;
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
