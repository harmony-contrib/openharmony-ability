//! Native modal prompts scoped to an application window.
use super::{validate_window_id, WindowBridgePlugin, WindowClient};
use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{impl_bridge_napi_type, BridgeCallOptions};

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowPromptAnchor {
    /// Horizontal position in the target window's content, in logical vp units.
    pub x: f64,
    /// Vertical position in the target window's content, in logical vp units.
    pub y: f64,
}
impl_bridge_napi_type!(WindowPromptAnchor, "ohos.window.PromptAnchor");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowPromptRequest {
    pub window_id: i64,
    pub message: String,
    pub detail: Option<String>,
    /// 0 information, 1 warning, 2 critical.
    pub level: u32,
    pub buttons: Vec<String>,
    pub cancel_index: Option<u32>,
    /// Optional content-local position in logical vp units, not physical px or screen coordinates.
    pub anchor: Option<WindowPromptAnchor>,
}
impl_bridge_napi_type!(WindowPromptRequest, "ohos.window.PromptRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowPromptResponse {
    pub index: u32,
}
impl_bridge_napi_type!(WindowPromptResponse, "ohos.window.PromptResponse");

impl WindowPromptRequest {
    fn validate(&self) -> Result<()> {
        validate_window_id(self.window_id)?;
        if self.anchor.as_ref().is_some_and(|anchor| {
            !anchor.x.is_finite() || !anchor.y.is_finite() || anchor.x < 0.0 || anchor.y < 0.0
        }) || self.level > 2
            || self.buttons.is_empty()
            || self.buttons.len() > 128
            || self.buttons.iter().any(|label| label.trim().is_empty())
            || self
                .cancel_index
                .is_some_and(|index| index as usize >= self.buttons.len())
        {
            return Err(Error::from_reason(
                "invalid window prompt level, buttons, or cancel index",
            ));
        }
        Ok(())
    }
}

impl WindowClient {
    pub async fn show_prompt(&self, request: WindowPromptRequest) -> Result<u32> {
        request.validate()?;
        let count = request.buttons.len();
        let response = self
            .bridge
            .call_async::<WindowBridgePlugin, WindowPromptRequest, WindowPromptResponse>(
                "show-prompt",
                request,
                BridgeCallOptions::default().with_timeout_ms(300_000),
            )
            .await?;
        if response.index as usize >= count {
            return Err(Error::from_reason(
                "prompt returned an invalid button index",
            ));
        }
        Ok(response.index)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;
    #[test]
    fn prompt_contract_and_cancellation() {
        assert_eq!(WindowPromptAnchor::TYPE_NAME, "ohos.window.PromptAnchor");
        assert_eq!(WindowPromptRequest::TYPE_NAME, "ohos.window.PromptRequest");
        assert_eq!(
            WindowPromptResponse::TYPE_NAME,
            "ohos.window.PromptResponse"
        );
        let mut request = WindowPromptRequest {
            window_id: 0,
            message: "Save?".into(),
            detail: None,
            level: 1,
            buttons: vec!["Save".into(), "Cancel".into()],
            cancel_index: Some(1),
            anchor: None,
        };
        assert!(request.validate().is_ok());
        request.anchor = Some(WindowPromptAnchor {
            x: f64::NAN,
            y: 0.0,
        });
        assert!(request.validate().is_err());
        request.anchor = None;
        request.cancel_index = Some(2);
        assert!(request.validate().is_err());
        request.cancel_index = None;
        request.buttons.clear();
        assert!(request.validate().is_err());
    }
}
