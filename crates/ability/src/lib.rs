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

pub mod version;

#[cfg(feature = "window")]
pub mod window;

// ─── Logging macros (gated behind "log" feature) ───
// When the feature is on, delegate to the `log` crate facade.
// When off, expand to no-ops — zero overhead, no dependency on `log`.

#[cfg(feature = "log")]
#[macro_export]
macro_rules! error {
    ($($arg:tt)*) => { ::log::error!($($arg)*) }
}
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

#[cfg(feature = "log")]
#[macro_export]
macro_rules! info {
    ($($arg:tt)*) => { ::log::info!($($arg)*) }
}
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

#[cfg(feature = "log")]
#[macro_export]
macro_rules! warn {
    ($($arg:tt)*) => { ::log::warn!($($arg)*) }
}
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

#[cfg(feature = "log")]
#[macro_export]
macro_rules! debug {
    ($($arg:tt)*) => { ::log::debug!($($arg)*) }
}
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
pub use ohos_ime_binding as ime;
pub use ohos_xcomponent_binding as xcomponent;
