//! Framework-level device version information.
//!
//! The `#[ability]` macro initializes these values from the ArkTS `AbilityInitContext`
//! (`deviceInfo.sdkApiVersion` / `deviceInfo.distributionOSApiVersion`) during `init`.
//! The values are process-wide and read from any Rust thread.
//!
//! Interactive capability queries (`canIUse`, desktop detection) live in the
//! `plugin-version` capability package, never in the core.

use std::sync::OnceLock;

static SDK_API_VERSION: OnceLock<i32> = OnceLock::new();
static DISTRIBUTION_API_VERSION: OnceLock<i32> = OnceLock::new();

/// Initializes version information from the ArkTS side. Called by the `#[ability]` macro
/// during `init`; subsequent calls are no-ops (first call wins).
pub fn init(sdk_version: i32, dist_version: i32) {
    let _ = SDK_API_VERSION.set(sdk_version);
    let _ = DISTRIBUTION_API_VERSION.set(dist_version);
}

/// OpenHarmony base API Level (e.g., 12, 14, 20) or 0 when not initialized.
/// Corresponds to `since N` annotations in OpenHarmony API documentation.
pub fn sdk_api_version() -> i32 {
    SDK_API_VERSION.get().copied().unwrap_or(0)
}

/// HarmonyOS distribution API version as `M × 10000 + S × 100 + F`
/// (e.g. HarmonyOS 5.0.1 → 50001) or 0 when not initialized.
pub fn distribution_api_version() -> i32 {
    DISTRIBUTION_API_VERSION.get().copied().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::{distribution_api_version, init, sdk_api_version};

    #[test]
    fn version_init_is_idempotent() {
        init(20, 50001);
        let sdk = sdk_api_version();
        let dist = distribution_api_version();
        init(99, 99999);
        assert_eq!(sdk_api_version(), sdk, "first init wins");
        assert_eq!(distribution_api_version(), dist, "first init wins");
    }

    #[test]
    fn version_returns_zero_before_init() {
        let sdk = sdk_api_version();
        let dist = distribution_api_version();
        assert!(sdk >= 0);
        assert!(dist >= 0);
    }
}
