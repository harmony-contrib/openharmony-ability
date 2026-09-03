//! App continuation facade (passive restore side).
//!
//! OHOS app continuation is lifecycle-driven: on the target device the system
//! launches the ability with `launchParam.launchReason === CONTINUATION` and the
//! source device's `wantParam` in `want.parameters`. `NativeAbility.onCreate` /
//! `onNewWant` forward that signal (as the boolean `isContinuation`, never a raw
//! enum number) into the lifecycle closures, which store it in Rust-side global
//! statics — the same pattern the deep-link cold-start path uses.
//!
//! This facade is a **pure synchronous** reader of those statics: no bridge
//! plugin, no ArkTS action, no main-thread dispatch. Active migration (source
//! device initiating hand-off) is system-UI-exclusive on OHOS and is not
//! covered. Source-side state saving goes through
//! [`ContinuationClient::set_continuation_data`]: the snapshot is stored here
//! and read synchronously by the ArkTS `onContinue` callback (via the
//! `read_continue_snapshot` NAPI export) when the system initiates a migration.

use openharmony_ability::OpenHarmonyApp;

// ── Client facade ─────────────────────────────────────────────────────────────

/// Sync facade for app-continuation restore queries.
///
/// Zero-cost: holds no bridge handle and performs no ArkTS round-trips. The
/// continuation signal is captured by the lifecycle callbacks in
/// `onAbilityCreateWithWant`, which runs AFTER the embedding runtime's entry
/// (`module.init` builds and runs the Tauri app first) — queries made from a
/// plugin `setup`/initialize hook during a continuation cold start still read
/// `false`/`""`. JS callers are unaffected (webviews load much later); Rust
/// callers must query after setup completes.
#[derive(Clone, Copy, Debug, Default)]
pub struct ContinuationClient {}

impl ContinuationClient {
    /// Returns whether the current launch is an app-continuation restore.
    ///
    /// Peek-only: idempotent and does not consume
    /// [`take_continuation_data`](Self::take_continuation_data).
    pub fn is_continuation_restore(&self) -> bool {
        openharmony_ability::is_continuation_restore()
    }

    /// Returns the continuation payload JSON (`want.parameters` from the source
    /// device), then clears it.
    ///
    /// Draining: the second call returns `""`. An empty string also means the
    /// launch was not a continuation restore. The JSON is passed through
    /// verbatim — the wantParam schema is an application-level contract; parse
    /// it on the JS consumer side.
    pub fn take_continuation_data(&self) -> String {
        openharmony_ability::take_continuation_data()
    }

    /// Pre-registers the source-side continuation snapshot (overwrite).
    ///
    /// The application calls this **while running** on the source device; the
    /// ArkTS `onContinue` callback later reads the snapshot synchronously and
    /// forwards it as `wantParam.continuationData`. `""` clears the snapshot
    /// (an empty snapshot makes `onContinue` refuse the migration with
    /// MISMATCH). Peek-only on read: a cancelled migration leaves the snapshot
    /// intact for a retry. No size validation here — the 96 KiB wantParam
    /// budget is enforced at the JS command layer (`set_continuation_data`).
    pub fn set_continuation_data(&self, data: String) {
        openharmony_ability::store_continue_snapshot(&data);
    }
}

pub trait ContinuationExt {
    /// Returns the continuation facade for this app.
    ///
    /// Cannot fail: unlike bridge-backed facades there is no bridge handle to
    /// acquire, so no `Result` wrapper.
    fn continuation(&self) -> ContinuationClient;
}

impl ContinuationExt for OpenHarmonyApp {
    fn continuation(&self) -> ContinuationClient {
        ContinuationClient {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn continuation_client_is_sync_and_zero_sized() {
        fn assert_sync<T: Sync>() {}
        assert_sync::<ContinuationClient>();
        assert_eq!(std::mem::size_of::<ContinuationClient>(), 0);
    }

    #[test]
    fn facade_delegates_to_statics() {
        // Delegate wiring only — static state semantics are covered by the
        // continuation_tests module in openharmony-ability (app.rs).
        let client = ContinuationClient {};
        let before = client.is_continuation_restore();
        openharmony_ability::store_continuation(true, r#"{"probe":1}"#);
        assert!(client.is_continuation_restore());
        assert_eq!(client.take_continuation_data(), r#"{"probe":1}"#);
        // Restore prior state so parallel tests are unaffected.
        openharmony_ability::store_continuation(before, "");
    }

    #[test]
    fn facade_snapshot_delegates_and_does_not_drain() {
        let client = ContinuationClient {};
        let before = openharmony_ability::peek_continue_snapshot();
        client.set_continuation_data("snapshot-probe".to_string());
        // Repeated reads see the same value (peek, not drain).
        assert_eq!(openharmony_ability::peek_continue_snapshot(), "snapshot-probe");
        assert_eq!(openharmony_ability::peek_continue_snapshot(), "snapshot-probe");
        // Restore prior state so parallel tests are unaffected.
        client.set_continuation_data(before);
    }
}
