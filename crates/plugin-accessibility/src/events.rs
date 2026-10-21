//! Owned requests for explicit accessibility events and live-region announcements.

use super::{AccessibilityClient, AccessibilityEventAcknowledgement};
use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::impl_bridge_napi_type;

/// Exactly one of an announcement (including empty text) or a nonnegative element ID.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilitySendEventRequest {
    pub announcement: Option<String>,
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

/// A live-region update; the caller, not the transport, chooses interruption policy.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityLiveAnnouncement {
    pub text: String,
    pub assertive: bool,
}
impl_bridge_napi_type!(
    AccessibilityLiveAnnouncement,
    "ohos.accessibility.LiveAnnouncement"
);

impl AccessibilityClient {
    /// Sends an explicit announcement or moves accessibility focus (API 12+).
    pub async fn send_event(&self, request: AccessibilitySendEventRequest) -> Result<()> {
        request.validate()?;
        let response: AccessibilityEventAcknowledgement = self.call("send-event", request).await?;
        require_accepted(response, "accessibility event")
    }

    /// Announces a live-region update, interrupting only when `assertive` is true (API 18+).
    pub async fn announce_live(&self, text: String, assertive: bool) -> Result<()> {
        let response: AccessibilityEventAcknowledgement = self
            .call(
                "announce-live",
                AccessibilityLiveAnnouncement { text, assertive },
            )
            .await?;
        require_accepted(response, "live announcement")
    }
}

pub(crate) fn require_accepted(
    response: AccessibilityEventAcknowledgement,
    operation: &str,
) -> Result<()> {
    if !response.accepted {
        return Err(Error::from_reason(format!("{operation} was rejected")));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn stable_contracts_and_owned_data() {
        assert_eq!(
            AccessibilitySendEventRequest::TYPE_NAME,
            "ohos.accessibility.SendEventRequest"
        );
        assert_eq!(
            AccessibilityLiveAnnouncement::TYPE_NAME,
            "ohos.accessibility.LiveAnnouncement"
        );
        fn worker_safe<T: Send + Sync + 'static>() {}
        worker_safe::<AccessibilitySendEventRequest>();
        worker_safe::<AccessibilityLiveAnnouncement>();
    }

    #[test]
    fn validates_exactly_one_event_without_imposing_text_policy() {
        for (announcement, element_id, valid) in [
            (Some(String::new()), None, true),
            (Some("  ".into()), None, true),
            (None, Some(0), true),
            (None, Some(i32::MAX), true),
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

    #[test]
    fn rejection_is_not_success() {
        assert!(require_accepted(
            AccessibilityEventAcknowledgement { accepted: false },
            "event"
        )
        .is_err());
    }
}
