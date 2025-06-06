#[cfg(feature = "webview")]
mod web;

#[cfg(feature = "webview")]
pub use web::*;

#[cfg(not(feature = "webview"))]
mod xcomponent;

#[cfg(not(feature = "webview"))]
pub use xcomponent::*;
