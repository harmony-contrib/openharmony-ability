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

pub mod version;

#[cfg(feature = "window")]
pub mod window;

// ─── Logging macros (gated behind "log" feature) ───
// When the feature is on, delegate to the `log` crate facade.
// When off, expand to no-ops — zero overhead, no dependency on `log`.

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
    (target: $target:expr, $($arg:tt)*) => {{
        if false { let _ = $target; let _ = format_args!($($arg)*); }
    }};
    ($($arg:tt)*) => {{
        if false { let _ = format_args!($($arg)*); }
    }};
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
    (target: $target:expr, $($arg:tt)*) => {{
        if false { let _ = $target; let _ = format_args!($($arg)*); }
    }};
    ($($arg:tt)*) => {{
        if false { let _ = format_args!($($arg)*); }
    }};
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
    (target: $target:expr, $($arg:tt)*) => {{
        if false { let _ = $target; let _ = format_args!($($arg)*); }
    }};
    ($($arg:tt)*) => {{
        if false { let _ = format_args!($($arg)*); }
    }};
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
    (target: $target:expr, $($arg:tt)*) => {{
        if false { let _ = $target; let _ = format_args!($($arg)*); }
    }};
    ($($arg:tt)*) => {{
        if false { let _ = format_args!($($arg)*); }
    }};
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

pub use version::*;

#[cfg(feature = "window")]
pub use window::*;

/// Re-exported for [`impl_bridge_napi_type!`](crate::impl_bridge_napi_type) expansions in
/// application/plugin crates.
#[doc(hidden)]
pub use napi_ohos;

// re-export arkui and avoid the need to import it in the lib.rs
pub use napi_ohos::Either;
pub use ohos_arkui_binding as arkui;
pub use ohos_arkui_binding;
pub use ohos_device_binding as device;
// NOTE: `ohos_display_binding` is NOT re-exported as `display` here (upstream
// does this): this crate already defines its own `display` module
// (multi-display enumeration + positions, issue tauri#106), so the raw binding
// stays reachable through its own crate name.
pub use ohos_ime_binding as ime;
#[cfg(feature = "window")]
pub use ohos_window_manager_binding as window_manager;
pub use ohos_xcomponent_binding as xcomponent;
