//! Native modal prompts scoped to an application window.
use super::{validate_window_id, WindowBridgePlugin, WindowClient};
use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{impl_bridge_napi_type, BridgeCallOptions};

/// A system-owned prompt. Colors, typography, placement, and animation follow ArkUI.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowPromptRequest {
    pub window_id: i64,
    pub message: String,
    pub detail: Option<String>,
    pub buttons: Vec<String>,
    /// Button index returned for Back/Esc. Omit to require a button selection.
    pub cancel_index: Option<u32>,
    /// Also allow mask taps to select `cancel_index`. Requires a cancel index.
    pub cancel_on_touch_outside: bool,
}
impl_bridge_napi_type!(WindowPromptRequest, "ohos.window.PromptRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowPromptResponse {
    pub index: u32,
}
impl_bridge_napi_type!(WindowPromptResponse, "ohos.window.PromptResponse");

/// A modal prompt with an actual, interactive checkbox.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowPromptChoiceRequest {
    pub window_id: i64,
    pub message: String,
    pub detail: Option<String>,
    pub buttons: Vec<String>,
    pub cancel_index: Option<u32>,
    pub cancel_on_touch_outside: bool,
    pub checkbox_label: String,
    pub checkbox_checked: bool,
}
impl_bridge_napi_type!(WindowPromptChoiceRequest, "ohos.window.PromptChoiceRequest");
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowPromptChoiceResponse {
    pub index: u32,
    pub checked: bool,
}
impl_bridge_napi_type!(
    WindowPromptChoiceResponse,
    "ohos.window.PromptChoiceResponse"
);
impl WindowPromptChoiceRequest {
    fn validate(&self) -> Result<()> {
        if self.checkbox_label.trim().is_empty() {
            return Err(Error::from_reason("checkbox label must not be empty"));
        }
        WindowPromptRequest {
            window_id: self.window_id,
            message: self.message.clone(),
            detail: self.detail.clone(),
            buttons: self.buttons.clone(),
            cancel_index: self.cancel_index,
            cancel_on_touch_outside: self.cancel_on_touch_outside,
        }
        .validate()
    }
}

impl WindowPromptRequest {
    fn validate(&self) -> Result<()> {
        validate_window_id(self.window_id)?;
        if self.buttons.is_empty()
            || self.buttons.len() > 128
            || self.buttons.iter().any(|label| label.trim().is_empty())
            || self
                .cancel_index
                .is_some_and(|index| index as usize >= self.buttons.len())
            || (self.cancel_on_touch_outside && self.cancel_index.is_none())
        {
            return Err(Error::from_reason(
                "invalid window prompt buttons or cancellation policy",
            ));
        }
        Ok(())
    }
}

impl WindowClient {
    /// Returns the selected button and the final state of the native checkbox.
    pub async fn show_prompt_choice(
        &self,
        request: WindowPromptChoiceRequest,
    ) -> Result<WindowPromptChoiceResponse> {
        request.validate()?;
        let count = request.buttons.len();
        let response = self.bridge.call_async::<WindowBridgePlugin, WindowPromptChoiceRequest, WindowPromptChoiceResponse>("show-prompt-choice",request,BridgeCallOptions::default().with_timeout_ms(300_000)).await?;
        if response.index as usize >= count {
            return Err(Error::from_reason(
                "prompt returned an invalid button index",
            ));
        }
        Ok(response)
    }

    /// Shows a system alert (up to three buttons) or action sheet (more buttons).
    /// Returns the original button index after the system exit animation completes.
    /// Bridge cancellation invalidates callbacks. The system has no imperative
    /// close API, so a displayed prompt may remain until dismissed or its window closes.
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
        assert_eq!(
            WindowPromptChoiceRequest::TYPE_NAME,
            "ohos.window.PromptChoiceRequest"
        );
        assert_eq!(
            WindowPromptChoiceResponse::TYPE_NAME,
            "ohos.window.PromptChoiceResponse"
        );
        let mut choice = WindowPromptChoiceRequest {
            window_id: 0,
            message: "Save?".into(),
            detail: None,
            buttons: vec!["Save".into()],
            cancel_index: Some(0),
            cancel_on_touch_outside: false,
            checkbox_label: "Remember".into(),
            checkbox_checked: true,
        };
        assert!(choice.validate().is_ok());
        choice.checkbox_label.clear();
        assert!(choice.validate().is_err());
        assert_eq!(WindowPromptRequest::TYPE_NAME, "ohos.window.PromptRequest");
        assert_eq!(
            WindowPromptResponse::TYPE_NAME,
            "ohos.window.PromptResponse"
        );
        let mut request = WindowPromptRequest {
            window_id: 0,
            message: "Save?".into(),
            detail: None,
            buttons: vec!["Save".into(), "Cancel".into()],
            cancel_index: Some(1),
            cancel_on_touch_outside: false,
        };
        assert!(request.validate().is_ok());
        request.cancel_index = Some(2);
        assert!(request.validate().is_err());
        request.cancel_index = None;
        assert!(request.validate().is_ok());
        request.cancel_on_touch_outside = true;
        assert!(request.validate().is_err());
        request.cancel_index = Some(0);
        assert!(request.validate().is_ok());
        request.buttons.clear();
        assert!(request.validate().is_err());
    }
}
