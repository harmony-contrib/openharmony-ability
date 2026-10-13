//! Application-owned windows in the system's actual stacking order.
use super::{validate_window_id, WindowClient};
use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::impl_bridge_napi_type;

#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowStackRequest {
    pub display_id: i64,
    pub window_ids: Vec<i64>,
}
impl_bridge_napi_type!(WindowStackRequest, "ohos.window.StackRequest");
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowStackResponse {
    pub window_ids: Vec<i64>,
}
impl_bridge_napi_type!(WindowStackResponse, "ohos.window.StackResponse");

impl WindowClient {
    pub async fn window_stack(&self, display_id: i64, window_ids: Vec<i64>) -> Result<Vec<i64>> {
        validate_window_id(display_id)?;
        for id in &window_ids {
            validate_window_id(*id)?;
        }
        let response = self
            .call::<WindowStackRequest, WindowStackResponse>(
                "get-window-stack",
                WindowStackRequest {
                    display_id,
                    window_ids: window_ids.clone(),
                },
            )
            .await?;
        if response.window_ids.iter().enumerate().any(|(index, id)| {
            !window_ids.contains(id) || response.window_ids[..index].contains(id)
        }) {
            return Err(Error::from_reason(
                "window stack contains unknown or duplicate window IDs",
            ));
        }
        Ok(response.window_ids)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;
    #[test]
    fn stack_types_are_stable() {
        assert_eq!(WindowStackRequest::TYPE_NAME, "ohos.window.StackRequest");
        assert_eq!(WindowStackResponse::TYPE_NAME, "ohos.window.StackResponse");
    }
}
