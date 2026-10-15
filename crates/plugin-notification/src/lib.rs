//! Typed system notification bridge for OpenHarmony consumers.

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement, BridgePlugin,
    BridgeRuntime, OpenHarmonyApp,
};

pub struct NotificationBridgePlugin;

impl BridgePlugin for NotificationBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.notification";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct NotificationAction {
    pub id: String,
    pub label: String,
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ShowNotificationRequest {
    pub tag: String,
    pub title: String,
    pub body: String,
    pub actions: Vec<NotificationAction>,
}

impl_bridge_napi_type!(ShowNotificationRequest, "ohos.notification.ShowRequest");

impl ShowNotificationRequest {
    fn validate(&self) -> Result<()> {
        if self.actions.len() > 3 {
            return Err(Error::from_reason(
                "Notification supports at most 3 actions",
            ));
        }
        if self.tag.trim().is_empty()
            || self.title.trim().is_empty()
            || self.body.trim().is_empty()
            || self
                .actions
                .iter()
                .any(|action| action.id.trim().is_empty() || action.label.trim().is_empty())
        {
            return Err(Error::from_reason(
                "Invalid notification tag, title, body or action",
            ));
        }
        Ok(())
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct DismissNotificationRequest {
    pub tag: String,
}

impl_bridge_napi_type!(
    DismissNotificationRequest,
    "ohos.notification.DismissRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct NotificationAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    NotificationAcknowledgement,
    "ohos.notification.Acknowledgement"
);

#[derive(Clone)]
pub struct NotificationClient {
    bridge: BridgeRuntime,
}

impl NotificationClient {
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }

    pub async fn show(&self, request: ShowNotificationRequest) -> Result<bool> {
        request.validate()?;
        let response = self
            .bridge
            .call_async::<NotificationBridgePlugin, ShowNotificationRequest, NotificationAcknowledgement>(
                "show", request, BridgeCallOptions::default().with_timeout_ms(120_000),
            )
            .await?;
        Ok(response.accepted)
    }

    pub async fn dismiss(&self, tag: String) -> Result<bool> {
        let response = self
            .bridge
            .call_async::<NotificationBridgePlugin, DismissNotificationRequest, NotificationAcknowledgement>(
                "dismiss", DismissNotificationRequest { tag }, BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.accepted)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DismissNotificationRequest, NotificationAcknowledgement, NotificationBridgePlugin,
        ShowNotificationRequest,
    };
    use openharmony_ability::{BridgeContextRequirement, BridgeNapiType, BridgePlugin};

    #[test]
    fn bridge_types_are_named() {
        assert_eq!(NotificationBridgePlugin::ID, "ohos.notification");
        assert_eq!(
            NotificationBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
        assert_eq!(
            ShowNotificationRequest::TYPE_NAME,
            "ohos.notification.ShowRequest"
        );
        assert_eq!(
            DismissNotificationRequest::TYPE_NAME,
            "ohos.notification.DismissRequest"
        );
        assert_eq!(
            NotificationAcknowledgement::TYPE_NAME,
            "ohos.notification.Acknowledgement"
        );
    }

    #[test]
    fn notification_rejects_excess_actions() {
        let mut request = ShowNotificationRequest {
            tag: "tag".into(),
            title: "title".into(),
            body: "body".into(),
            actions: vec![],
        };
        assert!(request.validate().is_ok());
        request.actions = (0..3)
            .map(|id| super::NotificationAction {
                id: id.to_string(),
                label: "Action".into(),
            })
            .collect();
        assert!(request.validate().is_ok());
        request.actions.push(super::NotificationAction {
            id: "four".into(),
            label: "Fourth".into(),
        });
        assert!(request.validate().is_err());
    }
}
