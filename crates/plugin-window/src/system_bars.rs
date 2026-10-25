//! Status-bar presentation on the component's actual window (API 12).
use super::{validate_window_id, WindowAcknowledgement, WindowClient};
use napi_derive_ohos::napi;
use napi_ohos::Result;
use openharmony_ability::impl_bridge_napi_type;

/// Status-bar settings; zero selects the component's window.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowStatusBarRequest {
    /// Window ID, or zero for the component's window.
    pub window_id: i64,
    /// Whether the status bar is visible.
    pub enabled: bool,
    /// White text/icons when true, black when false.
    pub light_content: bool,
    /// Optional background, in ARGB.
    pub background: Option<u32>,
    /// Animate visibility changes.
    pub animated: bool,
}
impl_bridge_napi_type!(WindowStatusBarRequest, "ohos.window.StatusBarRequest");

impl WindowStatusBarRequest {
    fn validate(&self) -> Result<()> {
        validate_window_id(self.window_id)
    }
}

impl WindowClient {
    /// Applies status-bar presentation to the resolved window using API 12.
    /// Completes after both platform operations, preserving navigation-bar state.
    /// The SDK applies these settings to supported fullscreen/maximized main windows.
    pub async fn set_status_bar(&self, request: WindowStatusBarRequest) -> Result<()> {
        request.validate()?;
        self.call::<_, WindowAcknowledgement>("set-status-bar", request)
            .await?
            .ensure()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;
    #[test]
    fn status_bar_ids_are_nonnegative_javascript_safe_integers() {
        let mut request = WindowStatusBarRequest {
            window_id: 0,
            enabled: true,
            light_content: false,
            background: Some(u32::MAX),
            animated: false,
        };
        for id in [0, 1, super::super::MAX_SAFE_JAVASCRIPT_INTEGER] {
            request.window_id = id;
            assert!(request.validate().is_ok());
        }
        for id in [
            -1,
            i64::MIN,
            super::super::MAX_SAFE_JAVASCRIPT_INTEGER + 1,
            i64::MAX,
        ] {
            request.window_id = id;
            assert!(request.validate().is_err());
        }
    }
    #[test]
    fn status_bar_contract_is_stable() {
        assert_eq!(
            WindowStatusBarRequest::TYPE_NAME,
            "ohos.window.StatusBarRequest"
        );
    }
}
