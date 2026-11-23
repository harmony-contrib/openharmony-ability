//! Typed system notification bridge for OpenHarmony consumers.

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement, BridgePlugin,
    BridgeRuntime, OpenHarmonyApp,
};

const MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024;

pub struct NotificationBridgePlugin;

/// Supported notification slot classifications.
pub mod notification_slot {
    pub const DEFAULT: &str = "default";
    pub const SOCIAL: &str = "social";
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct SetBadgeRequest {
    pub count: u32,
}
impl_bridge_napi_type!(SetBadgeRequest, "ohos.notification.SetBadgeRequest");

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

/// Unified system notification request.
///
/// Optional presentation fields (`silent`, `group`, `sender_name`, `image`, `avatar`, `slot`)
/// are omitted when unused. `avatar` maps to the notification `smallIcon` (not a system contact
/// identity); `slot = "social"` routes to `SlotType.SOCIAL_COMMUNICATION`; `silent = true`
/// disables sound and vibration on API 23+.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ShowNotificationRequest {
    pub tag: String,
    pub title: String,
    pub body: String,
    pub actions: Vec<NotificationAction>,
    pub silent: Option<bool>,
    pub group: Option<String>,
    pub sender_name: Option<String>,
    pub image: Option<Vec<u8>>,
    pub avatar: Option<Vec<u8>>,
    pub slot: Option<String>,
}

impl_bridge_napi_type!(ShowNotificationRequest, "ohos.notification.ShowRequest");

impl ShowNotificationRequest {
    pub fn new(tag: impl Into<String>, title: impl Into<String>, body: impl Into<String>) -> Self {
        Self {
            tag: tag.into(),
            title: title.into(),
            body: body.into(),
            actions: Vec::new(),
            silent: None,
            group: None,
            sender_name: None,
            image: None,
            avatar: None,
            slot: None,
        }
    }

    pub fn actions(mut self, actions: Vec<NotificationAction>) -> Self {
        self.actions = actions;
        self
    }

    pub fn silent(mut self, silent: bool) -> Self {
        self.silent = Some(silent);
        self
    }

    pub fn group(mut self, group: impl Into<String>) -> Self {
        self.group = Some(group.into());
        self
    }

    pub fn sender_name(mut self, sender_name: impl Into<String>) -> Self {
        self.sender_name = Some(sender_name.into());
        self
    }

    pub fn image(mut self, image: Vec<u8>) -> Self {
        self.image = Some(image);
        self
    }

    pub fn avatar(mut self, avatar: Vec<u8>) -> Self {
        self.avatar = Some(avatar);
        self
    }

    pub fn social(mut self, social: bool) -> Self {
        self.slot = Some(if social {
            notification_slot::SOCIAL.to_owned()
        } else {
            notification_slot::DEFAULT.to_owned()
        });
        self
    }

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
        if self
            .image
            .as_ref()
            .is_some_and(|bytes| bytes.len() > MAX_IMAGE_BYTES)
            || self
                .avatar
                .as_ref()
                .is_some_and(|bytes| bytes.len() > MAX_IMAGE_BYTES)
        {
            return Err(Error::from_reason("Notification image exceeds 16 MiB"));
        }
        if let Some(slot) = self.slot.as_deref() {
            if slot != notification_slot::DEFAULT && slot != notification_slot::SOCIAL {
                return Err(Error::from_reason(format!(
                    "Unsupported notification slot '{slot}'"
                )));
            }
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

#[napi(object)]
#[derive(Clone, Debug)]
pub struct NotificationResponseRequest {
    pub uri: String,
}
impl_bridge_napi_type!(
    NotificationResponseRequest,
    "ohos.notification.ResponseRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct NotificationResponse {
    pub matched: bool,
    pub tag: String,
    pub action: String,
}
impl_bridge_napi_type!(NotificationResponse, "ohos.notification.Response");

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct NotificationEmptyRequest {}
impl_bridge_napi_type!(NotificationEmptyRequest, "ohos.notification.EmptyRequest");

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

    pub async fn set_badge(&self, count: u32) -> Result<bool> {
        if count > i32::MAX as u32 {
            return Err(Error::from_reason("Badge count out of range"));
        }
        let response = self
            .bridge
            .call_async::<NotificationBridgePlugin, SetBadgeRequest, NotificationAcknowledgement>(
                "set-badge",
                SetBadgeRequest { count },
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.accepted)
    }

    pub async fn show(&self, request: ShowNotificationRequest) -> Result<bool> {
        request.validate()?;
        let response = self
            .bridge
            .call_async::<NotificationBridgePlugin, ShowNotificationRequest, NotificationAcknowledgement>(
                "show",
                request,
                BridgeCallOptions::default().with_timeout_ms(120_000),
            )
            .await?;
        Ok(response.accepted)
    }

    pub async fn parse_response(&self, uri: String) -> Result<NotificationResponse> {
        self.bridge
            .call_async::<NotificationBridgePlugin, NotificationResponseRequest, NotificationResponse>(
                "parse-response",
                NotificationResponseRequest { uri },
                BridgeCallOptions::default(),
            )
            .await
    }

    pub async fn dismiss_all(&self) -> Result<bool> {
        let response = self
            .bridge
            .call_async::<NotificationBridgePlugin, NotificationEmptyRequest, NotificationAcknowledgement>(
                "dismiss-all",
                NotificationEmptyRequest {},
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.accepted)
    }

    pub async fn dismiss(&self, tag: String) -> Result<bool> {
        let response = self
            .bridge
            .call_async::<NotificationBridgePlugin, DismissNotificationRequest, NotificationAcknowledgement>(
                "dismiss",
                DismissNotificationRequest { tag },
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.accepted)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DismissNotificationRequest, NotificationAcknowledgement, NotificationAction,
        NotificationBridgePlugin, NotificationEmptyRequest, NotificationResponse,
        NotificationResponseRequest, SetBadgeRequest, ShowNotificationRequest,
    };
    use openharmony_ability::{BridgeContextRequirement, BridgeNapiType, BridgePlugin};

    #[test]
    fn notification_contracts_are_named() {
        assert_eq!(NotificationBridgePlugin::ID, "ohos.notification");
        assert_eq!(
            NotificationBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
        assert_eq!(
            SetBadgeRequest::TYPE_NAME,
            "ohos.notification.SetBadgeRequest"
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
        assert_eq!(
            NotificationResponseRequest::TYPE_NAME,
            "ohos.notification.ResponseRequest"
        );
        assert_eq!(
            NotificationResponse::TYPE_NAME,
            "ohos.notification.Response"
        );
        assert_eq!(
            NotificationEmptyRequest::TYPE_NAME,
            "ohos.notification.EmptyRequest"
        );
    }

    #[test]
    fn show_request_validates_fields_and_presentation_options() {
        let valid = ShowNotificationRequest::new("t1", "Title", "Body")
            .actions(vec![NotificationAction {
                id: "reply".to_owned(),
                label: "Reply".to_owned(),
            }])
            .silent(true)
            .group("chat")
            .sender_name("Alice")
            .image(vec![1, 2, 3])
            .avatar(vec![4, 5, 6])
            .social(true);
        assert!(valid.validate().is_ok());

        let mut bad_slot = valid.clone();
        bad_slot.slot = Some("invalid".to_owned());
        assert!(bad_slot.validate().is_err());

        let mut too_many_actions = ShowNotificationRequest::new("t1", "Title", "Body");
        too_many_actions.actions = (0..4)
            .map(|i| NotificationAction {
                id: format!("a{i}"),
                label: format!("Action {i}"),
            })
            .collect();
        assert!(too_many_actions.validate().is_err());
    }
}
