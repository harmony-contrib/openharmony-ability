//! Internal framework logging backed by hilog.
//!
//! The framework must not silently drop errors that application code cannot observe.

pub(crate) fn warn(message: &str) {
    ohos_hilog_binding::warn(message);
}
