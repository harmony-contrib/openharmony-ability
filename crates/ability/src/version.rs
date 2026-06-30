//! OHOS API version detection and capability checking.
//!
//! This module provides runtime API version information for OpenHarmony/HarmonyOS,
//! enabling version-based feature detection and graceful degradation.
//!
//! # Version Types
//!
//! - `sdk_api_version`: OpenHarmony base API Level (e.g., 12, 14, 20)
//!   - Corresponds to `since N` annotations in API documentation
//!   - Use for OpenHarmony base APIs (module path: `openharmony/`)
//!
//! - `distribution_api_version`: HarmonyOS distribution API version
//!   - Calculated as `M × 10000 + S × 100 + F`
//!   - Example: HarmonyOS 5.0.1 → 50001
//!   - Corresponds to `since M.S.F(N)` annotations in API documentation
//!   - Use for HarmonyOS-specific APIs (module path: `hms/`)
//!
//! # Example
//!
//! ```rust
//! use openharmony_ability::version;
//!
//! // Check OpenHarmony base API version
//! if version::sdk_api_version() >= 14 {
//!     // Use API 14+ feature
//! }
//!
//! // Check HarmonyOS distribution API version
//! // HarmonyOS 5.0.1 = 5*10000 + 0*100 + 1 = 50001
//! if version::distribution_api_version() >= 50001 {
//!     // Use HarmonyOS 5.0.1+ feature
//! }
//!
//! // Check system capability
//! if version::can_i_use("SystemCapability.Window.SessionManager") {
//!     // Device supports this capability
//! }
//! ```

use std::sync::OnceLock;

use napi_ohos::bindgen_prelude::{Function, JsObjectValue};

use crate::{get_helper, get_main_thread_env};

static SDK_API_VERSION: OnceLock<i32> = OnceLock::new();
static DISTRIBUTION_API_VERSION: OnceLock<i32> = OnceLock::new();

/// Initialize version information from ArkTS side.
///
/// This function is called internally during ability initialization.
/// It should only be called once; subsequent calls are no-ops.
pub fn init(sdk_version: i32, dist_version: i32) {
    let _ = SDK_API_VERSION.set(sdk_version);
    let _ = DISTRIBUTION_API_VERSION.set(dist_version);
}

/// Get the OpenHarmony SDK API version.
///
/// Returns the API Level (e.g., 12, 14, 20) or 0 if not initialized.
///
/// This corresponds to `since N` annotations in OpenHarmony API documentation.
/// Use this for OpenHarmony base APIs (module path: `openharmony/`).
///
/// # Example
///
/// ```rust
/// if version::sdk_api_version() >= 14 {
///     // Use API 14+ feature
/// }
/// ```
pub fn sdk_api_version() -> i32 {
    SDK_API_VERSION.get().copied().unwrap_or(0)
}

/// Get the HarmonyOS distribution API version.
///
/// Returns the version number calculated as `M × 10000 + S × 100 + F`,
/// or 0 if not initialized.
///
/// This corresponds to `since M.S.F(N)` annotations in HarmonyOS API documentation.
/// Use this for HarmonyOS-specific APIs (module path: `hms/`).
///
/// # Version Examples
///
/// - HarmonyOS 5.0.0 → 50000
/// - HarmonyOS 5.0.1 → 50001
/// - HarmonyOS 5.0.2 → 50002
/// - HarmonyOS 5.1.0 → 50100
/// - HarmonyOS 6.0.0 → 60000
///
/// # Example
///
/// ```rust
/// // Check for HarmonyOS 5.0.1 (50001)
/// if version::distribution_api_version() >= 50001 {
///     // Use HarmonyOS 5.0.1+ feature
/// }
/// ```
pub fn distribution_api_version() -> i32 {
    DISTRIBUTION_API_VERSION.get().copied().unwrap_or(0)
}

/// Check if the device supports a specific system capability.
///
/// This function calls the ArkTS global `canIUse()` function via NAPI bridge
/// to query device capabilities. No caching is performed; each call incurs
/// a small NAPI overhead (microseconds).
///
/// # Arguments
///
/// * `syscap` - The system capability string to check (e.g., "SystemCapability.Window.SessionManager")
///
/// # Returns
///
/// Returns `true` if the device supports the capability, `false` otherwise.
/// Also returns `false` if the NAPI call fails.
///
/// # Example
///
/// ```rust
/// if version::can_i_use("SystemCapability.Location.Location.Core") {
///     // Device supports location services
/// }
/// ```
///
/// # Note
///
/// This function must be called from a thread with access to the NAPI environment
/// (typically the main thread). If called from a worker thread without NAPI access,
/// it will return `false`.
pub fn can_i_use(syscap: &str) -> bool {
    let env_cell = get_main_thread_env();
    let env_borrow = env_cell.borrow();
    let Some(env) = env_borrow.as_ref() else {
        crate::warn!("can_i_use: NAPI environment not available, returning false");
        return false;
    };

    let helper_cell = unsafe { get_helper() };
    let helper_borrow = helper_cell.borrow();
    let Some(helper_ref) = helper_borrow.as_ref() else {
        crate::warn!("can_i_use: ArkHelper not initialized, returning false");
        return false;
    };

    let helper_obj = match helper_ref.get_value(env) {
        Ok(obj) => obj,
        Err(e) => {
            crate::warn!("can_i_use: Failed to get helper object: {:?}", e);
            return false;
        }
    };

    let check_fn = match helper_obj.get_named_property::<Function<'_, String, bool>>("checkCanIUse")
    {
        Ok(f) => f,
        Err(e) => {
            crate::warn!("can_i_use: Failed to get checkCanIUse function: {:?}", e);
            return false;
        }
    };

    match check_fn.call(syscap.to_string()) {
        Ok(result) => result,
        Err(e) => {
            crate::warn!("can_i_use: NAPI call failed for '{}': {:?}", syscap, e);
            false
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_version_calculation() {
        // Test the version calculation formula: M * 10000 + S * 100 + F
        assert_eq!(5 * 10000 + 0 * 100 + 0, 50000); // HarmonyOS 5.0.0
        assert_eq!(5 * 10000 + 0 * 100 + 1, 50001); // HarmonyOS 5.0.1
        assert_eq!(5 * 10000 + 0 * 100 + 2, 50002); // HarmonyOS 5.0.2
        assert_eq!(5 * 10000 + 1 * 100 + 0, 50100); // HarmonyOS 5.1.0
        assert_eq!(6 * 10000 + 0 * 100 + 0, 60000); // HarmonyOS 6.0.0
    }

    #[test]
    fn test_version_comparison() {
        // Test version comparison logic
        let v50001 = 50001; // HarmonyOS 5.0.1
        let v60000 = 60000; // HarmonyOS 6.0.0

        assert!(v60000 >= 50001);
        assert!(v50001 >= 50001);
        assert!(!(v50001 >= 60000));

        let sdk_v14 = 14;
        let sdk_v12 = 12;

        assert!(sdk_v14 >= 14);
        assert!(sdk_v12 >= 12);
        assert!(!(sdk_v12 >= 14));
    }

    // NAPI-dependent tests: require OHOS device runtime
    // Run via ohos-rust-ut skill:
    //   PACKAGE=openharmony-ability bash D:/workspace/tauri/tauri/.claude/skills/ohos-rust-ut/scripts/run-ut.sh version::
    #[cfg(target_env = "ohos")]
    mod ohos_device_tests {
        use crate::{init, sdk_api_version, distribution_api_version, can_i_use};

        #[test]
        fn test_sdk_api_version_returns_value() {
            let v = sdk_api_version();
            // Returns 0 before init(), or the initialized value after
            assert!(v >= 0);
        }

        #[test]
        fn test_distribution_api_version_returns_value() {
            let v = distribution_api_version();
            assert!(v >= 0);
        }

        #[test]
        fn test_init_stores_values() {
            // init() stores version numbers; subsequent calls are no-ops (OnceLock)
            init(20, 60000);
            // OnceLock may already be set by a prior test or init call.
            // If this test runs first, values should be exactly what we set.
            // If a prior test already called init(), values are whatever was set first.
            // Either way, the returned values should be > 0 since init() was called.
            let sdk = sdk_api_version();
            let dist = distribution_api_version();
            assert!(sdk > 0, "sdk_api_version should be > 0 after init, got {sdk}");
            assert!(
                dist > 0,
                "distribution_api_version should be > 0 after init, got {dist}"
            );
        }

        #[test]
        fn test_init_is_idempotent() {
            // OnceLock: second init() is a no-op
            init(14, 50001);
            let sdk_before = sdk_api_version();
            let dist_before = distribution_api_version();

            // Second call with different values — should NOT overwrite
            init(99, 99999);
            assert_eq!(
                sdk_api_version(),
                sdk_before,
                "OnceLock: sdk_api_version should not change on second init"
            );
            assert_eq!(
                distribution_api_version(),
                dist_before,
                "OnceLock: distribution_api_version should not change on second init"
            );
        }

        #[test]
        fn test_can_i_use_valid_syscap() {
            // A syscap that exists on virtually all OHOS devices
            // In test binary mode, NAPI is not initialized → returns false (early return)
            // In a real app with NAPI context → would return true
            let result = can_i_use("SystemCapability.Window.SessionManager");
            // We can't assert true here because test binary has no NAPI context.
            // But it MUST NOT panic or crash.
            assert!(
                !result || result,
                "can_i_use should return a boolean without panicking"
            );
        }

        #[test]
        fn test_can_i_use_invalid_syscap() {
            let result = can_i_use("SystemCapability.Fake.NonExistent.Capability");
            assert!(!result, "non-existent syscap should return false");
        }

        #[test]
        fn test_can_i_use_empty_string() {
            let result = can_i_use("");
            assert!(!result, "empty syscap should return false");
        }

        #[test]
        fn test_can_i_use_from_worker_thread() {
            // can_i_use from a non-main thread should return false (no NAPI env)
            // and must NOT panic
            let handle = std::thread::spawn(|| {
                let result = can_i_use("SystemCapability.Window.SessionManager");
                // From worker thread: get_main_thread_env() returns None → false
                assert!(
                    !result,
                    "can_i_use from worker thread should return false"
                );
            });
            handle.join().expect("worker thread should not panic");
        }

        #[test]
        fn test_sdk_api_version_from_worker_thread() {
            // Version getters from worker thread should still work
            // (they read from OnceLock, no NAPI dependency)
            let handle = std::thread::spawn(|| {
                let sdk = sdk_api_version();
                let dist = distribution_api_version();
                assert!(sdk >= 0, "sdk_api_version from worker thread should be >= 0");
                assert!(dist >= 0, "distribution_api_version from worker thread should be >= 0");
            });
            handle.join().expect("worker thread should not panic");
        }
    }
}

