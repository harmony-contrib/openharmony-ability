//! OHOS API version, device form-factor, and SystemCapability detection.
//!
//! This module queries the OpenHarmony C NDK directly (`ohos-device-binding` and
//! `ohos-init-binding`), so version checks, device-type inspection, and `canIUse`
//! probes work synchronously on any thread without waiting for ArkTS initialization.
//!
//! # Version Types
//!
//! - `sdk_api_version`: OpenHarmony base API Level (e.g., 12, 14, 20)
//!   - Queries `OH_GetSdkApiVersion` (`@since 10`)
//!   - Corresponds to `since N` annotations in API documentation
//!   - Use for OpenHarmony base APIs (module path: `openharmony/`)
//!
//! - `distribution_api_version`: HarmonyOS distribution API version
//!   - Queries `OH_GetDistributionOSApiVersion` (`@since 10`)
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
//! // Probe a SystemCapability synchronously via NDK canIUse
//! if version::can_i_use("SystemCapability.Multimedia.Media.AVScreenCapture") {
//!     // Use screen capture capability
//! }
//! ```

/// Get the OpenHarmony SDK API version (`OH_GetSdkApiVersion`).
///
/// Returns the API Level (e.g., 12, 14, 20).
///
/// This corresponds to `since N` annotations in OpenHarmony API documentation.
/// Use this for OpenHarmony base APIs (module path: `openharmony/`).
///
/// # Example
///
/// ```rust
/// use openharmony_ability::version;
///
/// if version::sdk_api_version() >= 14 {
///     // Use API 14+ feature
/// }
/// ```
pub fn sdk_api_version() -> i32 {
    ohos_device_binding::sdk_api_version() as i32
}

/// Get the HarmonyOS distribution API version (`OH_GetDistributionOSApiVersion`).
///
/// Returns the version number calculated as `M × 10000 + S × 100 + F`.
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
/// use openharmony_ability::version;
///
/// // Check for HarmonyOS 5.0.1 (50001)
/// if version::distribution_api_version() >= 50001 {
///     // Use HarmonyOS 5.0.1+ feature
/// }
/// ```
pub fn distribution_api_version() -> i32 {
    ohos_device_binding::distribution_os_api_version() as i32
}

/// Get the first API version reported by the device (`OH_GetFirstApiVersion`).
pub fn first_api_version() -> i32 {
    ohos_device_binding::first_api_version() as i32
}

/// Get the runtime device type (`OH_GetDeviceType`), such as `"phone"`, `"tablet"`,
/// `"2in1"`, `"wearable"`, `"liteWearable"`, `"tv"`, or `"car"`.
pub fn device_type() -> Option<&'static str> {
    ohos_device_binding::device_type()
}

/// Synchronously query whether a `SystemCapability.*` identifier is supported
/// by the current device (`canIUse` NDK symbol, API 8+).
///
/// Returns `false` if `syscap` is empty or contains an interior NUL byte.
pub fn can_i_use(syscap: &str) -> bool {
    if syscap.is_empty() || syscap.contains('\0') {
        return false;
    }
    ohos_init_binding::canIUse(syscap)
}

#[cfg(test)]
mod tests {
    use super::{
        can_i_use, device_type, distribution_api_version, first_api_version, sdk_api_version,
    };

    #[test]
    fn test_version_calculation() {
        // Test the version calculation formula: M * 10000 + S * 100 + F
        let encode = |major: i32, minor: i32, fix: i32| major * 10000 + minor * 100 + fix;
        assert_eq!(encode(5, 0, 0), 50000); // HarmonyOS 5.0.0
        assert_eq!(encode(5, 0, 1), 50001); // HarmonyOS 5.0.1
        assert_eq!(encode(5, 0, 2), 50002); // HarmonyOS 5.0.2
        assert_eq!(encode(5, 1, 0), 50100); // HarmonyOS 5.1.0
        assert_eq!(encode(6, 0, 0), 60000); // HarmonyOS 6.0.0
    }

    #[test]
    fn test_version_comparison() {
        let v50001 = 50001; // HarmonyOS 5.0.1
        let v60000 = 60000; // HarmonyOS 6.0.0

        assert!(v60000 >= 50001);
        assert!(v50001 >= 50001);
        assert!(v50001 < 60000);

        let sdk_v14 = 14;
        let sdk_v12 = 12;

        assert!(sdk_v14 >= 14);
        assert!(sdk_v12 >= 12);
        assert!(sdk_v12 < 14);
    }

    #[test]
    fn rejects_empty_or_nul_syscap_without_panicking() {
        assert!(!can_i_use(""));
        assert!(!can_i_use("SystemCapability.Window\0.SessionManager"));
    }

    mod ohos_device_tests {
        use super::{device_type, distribution_api_version, first_api_version, sdk_api_version};

        #[test]
        fn test_sdk_api_version_returns_value() {
            let v = sdk_api_version();
            assert!(v >= 0);
        }

        #[test]
        fn test_distribution_api_version_returns_value() {
            let v = distribution_api_version();
            assert!(v >= 0);
        }

        #[test]
        fn test_first_api_version_and_device_type() {
            assert!(first_api_version() >= 0);
            if let Some(kind) = device_type() {
                assert!(!kind.is_empty());
            }
        }

        #[test]
        fn test_sdk_api_version_from_worker_thread() {
            let handle = std::thread::spawn(|| {
                let sdk = sdk_api_version();
                let dist = distribution_api_version();
                assert!(
                    sdk >= 0,
                    "sdk_api_version from worker thread should be >= 0"
                );
                assert!(
                    dist >= 0,
                    "distribution_api_version from worker thread should be >= 0"
                );
            });
            handle.join().expect("worker thread should not panic");
        }
    }
}
