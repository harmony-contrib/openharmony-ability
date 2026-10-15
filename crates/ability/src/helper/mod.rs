use std::sync::atomic::{AtomicBool, Ordering};
use std::{cell::RefCell, rc::Rc};

use napi_ohos::Env;

thread_local! {
    static MAIN_THREAD_ENV: Rc<RefCell<Option<Env>>> = Rc::new(RefCell::new(None));
}

/// Process-level flag: the XComponent render entry has run at least once and
/// recorded the NAPI main thread in [`MAIN_THREAD_ENV`].
///
/// Set by [`set_main_thread_env`] and never cleared — when the ability is
/// rebuilt, `render()` re-runs on the same NAPI main thread, so setting it
/// again is idempotent. The thread-local is only visible on the main thread
/// itself; this flag lets every other thread distinguish "the render entry
/// ran on some other thread" ([`MainThreadStatus::Worker`]) from "the render
/// entry has not run at all" ([`MainThreadStatus::Uninitialized`]).
static MAIN_THREAD_ENV_INITIALIZED: AtomicBool = AtomicBool::new(false);

pub fn set_main_thread_env(env: Env) {
    // Publish the process-level signal first: once the render entry is
    // running, every other thread is definitively a worker, even if it
    // classifies itself before the thread-local write below completes.
    MAIN_THREAD_ENV_INITIALIZED.store(true, Ordering::Release);
    MAIN_THREAD_ENV.with(|rc| {
        *rc.borrow_mut() = Some(env);
    });
}

/// Tri-state classification of the calling thread against the app's NAPI main
/// thread, based on the authoritative render-entry signal recorded by
/// [`set_main_thread_env`] (the XComponent `render` entry runs on the ArkUI
/// main thread and is the only place that signal is written).
///
/// This replaces first-webview-builder heuristics for sync-vs-async dispatch
/// decisions: a heuristic that records "the thread that built the first
/// webview" as main misclassifies direct-wry embedders that build their first
/// webview on a worker thread (Eulogizethesun/tauri#145).
pub enum MainThreadStatus {
    /// The caller is the NAPI main thread: the XComponent render entry ran on
    /// this very thread and its `Env` is recorded in the thread-local.
    Main,
    /// The render entry has run on some other thread, so the caller is
    /// definitely not the main thread. Blocking on a TSFN response is safe —
    /// the main thread can pump it while we wait.
    Worker,
    /// The render entry has not run yet (or never will — e.g. a pure
    /// subwindow app whose main page never loads). The caller may be either
    /// the main thread or a worker thread, so blocking on a TSFN response is
    /// unsafe: the thread that would pump the response is unproven.
    Uninitialized,
}

/// Classify the calling thread against the NAPI main thread using the
/// render-entry signal (see [`MainThreadStatus`]).
pub fn main_thread_status() -> MainThreadStatus {
    let on_render_thread = MAIN_THREAD_ENV.with(|rc| rc.borrow().is_some());
    if on_render_thread {
        MainThreadStatus::Main
    } else if MAIN_THREAD_ENV_INITIALIZED.load(Ordering::Acquire) {
        MainThreadStatus::Worker
    } else {
        MainThreadStatus::Uninitialized
    }
}

/// Boolean convenience wrapper over [`main_thread_status`].
///
/// Returns `true` only when the caller is the NAPI main thread that ran the
/// XComponent render entry. Before the render entry has run this returns
/// `false` even on the eventual main thread; when the not-yet-run case needs
/// distinct handling, prefer the tri-state [`main_thread_status`].
pub fn is_main_thread() -> bool {
    matches!(main_thread_status(), MainThreadStatus::Main)
}

/// Get a handle to the main thread env.
/// Only returns Some when called from the main thread where set_main_thread_env was called.
///
/// `#[doc(hidden)]` (issue #87 major-10): this exposes raw NAPI machinery that
/// upper layers (tao/tauri) currently need for TSFN-adjacent calls, but it is
/// not part of the supported API surface — do not build new features on it.
#[doc(hidden)]
pub fn get_main_thread_env() -> Rc<RefCell<Option<Env>>> {
    MAIN_THREAD_ENV.with(Rc::clone)
}

/// Whether this build targets the OHOS desktop (PC/2in1) form factor
/// (`OHOS_DEVICE_TYPE=desktop` at build time).
///
/// Compiled from this crate's build-script cfg — `cargo:rustc-cfg` only
/// applies to the crate whose build script emits it, so dependents (tao,
/// wry) cannot see `cfg(desktop)`/`cfg(mobile)` themselves; this query is
/// how they gate desktop-only behavior (e.g. tao's multi-UIAbility spawn)
/// without duplicating the env-var logic in their own build scripts. The
/// semantics match `tauri_utils::platform::is_mobile_target` (which drives
/// the tauri lib's `cfg(desktop)`/`cfg(mobile)` aliases): both read the
/// same `OHOS_DEVICE_TYPE`, so the form answer is consistent across
/// layers.
///
/// On non-OHOS targets neither cfg is set (the build script only emits
/// them for `target_env = "ohos"`), so this returns false — call sites in
/// tao/wry are `cfg(target_env = "ohos")`-gated and never observe that
/// value.
pub fn is_desktop_form() -> bool {
    cfg!(desktop)
}
