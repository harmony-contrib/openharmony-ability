//! Event-loop waker for the OHOS runtime integration layer.
//!
//! This module provides the `OpenHarmonyWaker` — a `ThreadsafeFunction` wrapper
//! that, when called from any thread, schedules a no-op callback on the NAPI
//! main thread, waking the event loop. The `WAKER` global stores the TSFN
//! singleton, initialized once during ability lifecycle setup (`lifecycle.rs`)
//! and read live by `OpenHarmonyWaker::wake()` whenever the embedding runtime's
//! event-loop proxy needs to wake the main thread.
//!
//! Role: runtime integration layer infrastructure. The event loop proxy needs
//! a cross-thread wake mechanism; OHOS NAPI TSFN is the only available primitive.
//! All access is main-thread-only; the global is accepted as a persistent
//! integration seam.
//!
//! # Why `wake()` reads `WAKER` live (not a construction-time snapshot)
//!
//! `WAKER` is populated by `create_lifecycle_handle` (lifecycle.rs), which runs
//! *after* the embedding runtime's entry point that constructs the event-loop proxy (and thus
//! calls `create_waker`) during the `#[ability]` `init` sequence. A snapshot
//! captured at construction time would therefore be `None` permanently — `wake()`
//! would be a silent no-op, the runtime's user-event variant would never fire, and async
//! plugin command responses (resolved on tokio worker threads →
//! `send_user_message` non-main-thread branch → `proxy.send_event` + `wake()`)
//! would never be drained on the main thread → JS Promises never settle →
//! 5000ms test timeouts. Reading `WAKER` live at `wake()` time sidesteps the
//! ordering: by the time any worker-thread command resolves, lifecycle setup
//! has long since populated `WAKER`.

use std::sync::{Arc, LazyLock, RwLock};

use napi_ohos::{
    threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode},
    Status,
};

// callee_handled = false, matching every other TSFN in this crate (window/mod.rs,
// ime.rs, bridge/mod.rs) — issue #87 minor-1. The waker closure provably always
// returns Ok(()), so the error-first null argument the `true` variant passes is
// never observed by anyone.
type WakerType = LazyLock<RwLock<Option<Arc<ThreadsafeFunction<(), (), (), Status, false>>>>>;

pub(crate) static WAKER: WakerType = LazyLock::new(|| RwLock::new(None));

#[derive(Clone)]
pub struct OpenHarmonyWaker;

// Safety: `OpenHarmonyWaker` carries no data; its only operation reads the
// `Sync` `WAKER` global and calls a `ThreadsafeFunction` (callable from any
// thread by construction).
unsafe impl Send for OpenHarmonyWaker {}
unsafe impl Sync for OpenHarmonyWaker {}

impl OpenHarmonyWaker {
    pub fn new() -> Self {
        Self
    }

    pub fn wake(&self) {
        // Read `WAKER` live rather than using a construction-time snapshot.
        // Clone the `Arc<TSFN>` out and drop the read guard before calling, so
        // we never hold the lock across the (non-blocking) TSFN call.
        let tsfn = (*WAKER).read().ok().and_then(|guard| guard.clone());
        match tsfn {
            Some(waker) => {
                // callee_handled=false call(): the raw value, no Result wrapper
                // (see the WakerType note above).
                waker.call((), ThreadsafeFunctionCallMode::NonBlocking);
            }
            None => {
                // `WAKER` not yet populated (lifecycle setup incomplete) or the
                // lock is poisoned. No-op — the caller's event stays queued in
                // the `user_events_sender` mpsc and will be drained once a
                // subsequent wake (with `WAKER` populated) fires.
            }
        }
    }
}
