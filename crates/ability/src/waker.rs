//! Event-loop waker for the OHOS runtime integration layer.
//!
//! This module provides the [`OpenHarmonyWaker`] — a cheap, `Clone` handle to
//! the app's waker slot, a `ThreadsafeFunction` that, when called from any
//! thread, schedules a no-op callback on the NAPI main thread, waking the
//! event loop. The slot lives on `OpenHarmonyApp` (one per app instance —
//! multi-UIAbility instances share one app and one event loop by design,
//! openspec multi-uiability-windows D10/NG4), is installed once during
//! ability lifecycle setup (`lifecycle.rs`), and is read live by `wake()`
//! whenever the embedding runtime's event-loop proxy needs to wake the main
//! thread.
//!
//! Role: runtime integration layer infrastructure. The event loop proxy needs
//! a cross-thread wake mechanism; OHOS NAPI TSFN is the only available primitive.
//! All access is main-thread-only for writes; `wake()` is callable from any
//! thread (TSFN by construction).
//!
//! # Why `wake()` reads the slot live (not a construction-time snapshot)
//!
//! The slot is populated by `create_lifecycle_handle` (lifecycle.rs), which runs
//! *after* the embedding runtime's entry point that constructs the event-loop proxy (and thus
//! calls `create_waker`) during the `#[ability]` `init` sequence. A snapshot
//! captured at construction time would therefore be `None` permanently — `wake()`
//! would be a silent no-op, the runtime's user-event variant would never fire, and async
//! plugin command responses (resolved on tokio worker threads →
//! `send_user_message` non-main-thread branch → `proxy.send_event` + `wake()`)
//! would never be drained on the main thread → JS Promises never settle →
//! 5000ms test timeouts. Reading the slot live at `wake()` time sidesteps the
//! ordering: by the time any worker-thread command resolves, lifecycle setup
//! has long since populated the slot.

use std::sync::{Arc, RwLock};

use napi_ohos::{
    threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode},
    Status,
};

/// Per-app waker storage: `None` until `create_lifecycle_handle` installs the
/// TSFN. Shared by every `OpenHarmonyWaker` clone (and by lifecycle.rs's
/// writer); `Arc<RwLock<…>>` keeps the handle `Send + Sync` by construction —
/// `ThreadsafeFunction` is callable from any thread, so no manual
/// `unsafe impl` is needed.
///
/// callee_handled = false, matching every other TSFN in this crate (window/mod.rs,
/// ime.rs, bridge/mod.rs) — issue #87 minor-1. The waker closure provably always
/// returns Ok(()), so the error-first null argument the `true` variant passes is
/// never observed by anyone.
pub type WakerSlot = Arc<RwLock<Option<Arc<ThreadsafeFunction<(), (), (), Status, false>>>>>;

/// Process-level alias of the installed TSFN, kept in sync by
/// `create_lifecycle_handle` (it writes the app's per-app slot and this alias
/// with the same `Arc`). Exists solely for NAPI free functions that have no
/// `OpenHarmonyApp` handle (e.g. `notify_window_close`) but must still wake
/// the event loop. Under NG4 (openspec multi-uiability-windows) one app/one
/// event loop exists per process, so the alias is exact; last-writer-wins if
/// that invariant is ever broken.
static INSTALLED_APP_WAKER: RwLock<Option<Arc<ThreadsafeFunction<(), (), (), Status, false>>>> =
    RwLock::new(None);

/// Record the installed TSFN into the process-level alias. Called from
/// `create_lifecycle_handle` alongside the per-app slot write.
pub(crate) fn install_app_waker_alias(tsfn: Arc<ThreadsafeFunction<(), (), (), Status, false>>) {
    if let Ok(mut guard) = INSTALLED_APP_WAKER.write() {
        guard.replace(tsfn);
    }
}

/// Wake the (single, NG4) app's event loop from a context with no
/// `OpenHarmonyApp` handle. No-op when lifecycle setup has not run yet —
/// the caller's event stays queued and is drained by a later wake.
pub fn wake_installed_app() {
    let tsfn = INSTALLED_APP_WAKER.read().ok().and_then(|guard| guard.clone());
    if let Some(waker) = tsfn {
        waker.call((), ThreadsafeFunctionCallMode::NonBlocking);
    }
}

#[derive(Clone)]
pub struct OpenHarmonyWaker {
    slot: WakerSlot,
}

impl OpenHarmonyWaker {
    pub fn new(slot: WakerSlot) -> Self {
        Self { slot }
    }

    pub fn wake(&self) {
        // Read the slot live rather than using a construction-time snapshot.
        // Clone the `Arc<TSFN>` out and drop the read guard before calling, so
        // we never hold the lock across the (non-blocking) TSFN call.
        let tsfn = self
            .slot
            .read()
            .ok()
            .and_then(|guard| guard.clone());
        match tsfn {
            Some(waker) => {
                // callee_handled=false call(): the raw value, no Result wrapper
                // (see the WakerSlot doc above).
                waker.call((), ThreadsafeFunctionCallMode::NonBlocking);
            }
            None => {
                // Slot not yet populated (lifecycle setup incomplete) or the
                // lock is poisoned. No-op — the caller's event stays queued in
                // the `user_events_sender` mpsc and will be drained once a
                // subsequent wake (with the slot populated) fires.
            }
        }
    }
}
