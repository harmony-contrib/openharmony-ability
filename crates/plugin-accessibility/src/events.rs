//! API-12 screen-reader requests with worker-safe owned data.
use super::{AccessibilityClient, AccessibilityEventAcknowledgement};
use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::impl_bridge_napi_type;

/// An announcement or a focus request. Exactly one field must be present.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilitySendEventRequest {
    /// Text to announce, including an empty string to stop speech.
    pub announcement: Option<String>,
    /// Native accessibility element ID to focus.
    pub element_id: Option<i32>,
}
impl_bridge_napi_type!(
    AccessibilitySendEventRequest,
    "ohos.accessibility.SendEventRequest"
);
impl AccessibilitySendEventRequest {
    fn validate(&self) -> Result<()> {
        if self.announcement.is_some() == self.element_id.is_some()
            || self.element_id.is_some_and(|id| id < 0)
        {
            return Err(Error::from_reason(
                "provide exactly one announcement or nonnegative element ID",
            ));
        }
        Ok(())
    }
}
impl AccessibilityClient {
    /// Announces a changed live region with the system's interruption policy (API 18+).
    pub async fn announce_live(&self, text: String, assertive: bool) -> Result<()> {
        let response = self
            .call::<_, AccessibilityEventAcknowledgement>(
                "announce-live",
                AccessibilityLiveAnnouncement { text, assertive },
            )
            .await?;
        if !response.accepted {
            return Err(Error::from_reason("live announcement was rejected"));
        }
        Ok(())
    }
    /// Sends an announcement or moves accessibility focus on API 12 and later.
    pub async fn send_event(&self, request: AccessibilitySendEventRequest) -> Result<()> {
        request.validate()?;
        let response = self
            .call::<_, AccessibilityEventAcknowledgement>("send-event", request)
            .await?;
        if !response.accepted {
            return Err(Error::from_reason("accessibility event was rejected"));
        }
        Ok(())
    }
}
/// A live region update, separate from explicit announcement and focus commands.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityLiveAnnouncement {
    /// Changed text to announce.
    pub text: String,
    /// Interrupt current speech instead of waiting for it.
    pub assertive: bool,
}
impl_bridge_napi_type!(
    AccessibilityLiveAnnouncement,
    "ohos.accessibility.LiveAnnouncement"
);
#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;
    #[test]
    fn event_contract_and_modes() {
        assert_eq!(
            AccessibilityLiveAnnouncement::TYPE_NAME,
            "ohos.accessibility.LiveAnnouncement"
        );
        assert_eq!(
            AccessibilitySendEventRequest::TYPE_NAME,
            "ohos.accessibility.SendEventRequest"
        );
        for (announcement, element_id, valid) in [
            (Some(String::new()), None, true),
            (None, Some(0), true),
            (None, None, false),
            (Some("a".into()), Some(2), false),
            (None, Some(-1), false),
        ] {
            assert_eq!(
                AccessibilitySendEventRequest {
                    announcement,
                    element_id
                }
                .validate()
                .is_ok(),
                valid
            );
        }
    }
}
