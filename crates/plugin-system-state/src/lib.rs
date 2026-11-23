//! System thermal and screen sleep state for OpenHarmony consumers.

use std::sync::RwLock;

use crossbeam_channel::Sender;
use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

pub struct SystemStateBridgePlugin;
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct PreferredLanguagesRequest {}
impl_bridge_napi_type!(
    PreferredLanguagesRequest,
    "ohos.system-state.PreferredLanguagesRequest"
);
#[napi(object)]
#[derive(Clone, Debug)]
pub struct PreferredLanguagesResponse {
    pub languages: Vec<String>,
}
impl_bridge_napi_type!(
    PreferredLanguagesResponse,
    "ohos.system-state.PreferredLanguagesResponse"
);

/// Resolves the system-configured PAC policy. Empty/missing policies are errors.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ResolveProxyRequest {
    pub url: String,
}
impl_bridge_napi_type!(ResolveProxyRequest, "ohos.system-state.ResolveProxyRequest");
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ResolveProxyResponse {
    pub directives: String,
}
impl_bridge_napi_type!(
    ResolveProxyResponse,
    "ohos.system-state.ResolveProxyResponse"
);

/// Hold an idle-system sleep inhibitor without keeping the display on (API 23+).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct PreventSleepRequest {
    pub reason: String,
}
impl_bridge_napi_type!(PreventSleepRequest, "ohos.system-state.PreventSleepRequest");
#[napi(object)]
#[derive(Clone, Debug)]
pub struct PreventSleepResponse {
    pub id: String,
}
impl_bridge_napi_type!(
    PreventSleepResponse,
    "ohos.system-state.PreventSleepResponse"
);
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ReleaseSleepRequest {
    pub id: String,
}
impl_bridge_napi_type!(ReleaseSleepRequest, "ohos.system-state.ReleaseSleepRequest");
#[napi(object)]
#[derive(Clone, Debug)]
pub struct ReleaseSleepResponse {
    pub accepted: bool,
}
impl_bridge_napi_type!(
    ReleaseSleepResponse,
    "ohos.system-state.ReleaseSleepResponse"
);

/// Request a short-term background suspend delay (transient task).
#[napi(object)]
#[derive(Clone, Debug)]
pub struct SuspendDelayRequest {
    pub reason: String,
}
impl_bridge_napi_type!(SuspendDelayRequest, "ohos.system-state.SuspendDelayRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct SuspendDelayResponse {
    pub id: String,
}
impl_bridge_napi_type!(
    SuspendDelayResponse,
    "ohos.system-state.SuspendDelayResponse"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct CancelSuspendDelayRequest {
    pub id: String,
}
impl_bridge_napi_type!(
    CancelSuspendDelayRequest,
    "ohos.system-state.CancelSuspendDelayRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct CancelSuspendDelayResponse {
    pub accepted: bool,
}
impl_bridge_napi_type!(
    CancelSuspendDelayResponse,
    "ohos.system-state.CancelSuspendDelayResponse"
);

impl BridgePlugin for SystemStateBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.system-state";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        match event.name() {
            "state-changed" => {
                let change: SystemStateChangedEvent = event.decode()?;
                let sender = SYSTEM_STATE_EVENT_SENDER
                    .read()
                    .ok()
                    .and_then(|slot| slot.clone());
                if let Some(sender) = sender {
                    let _ = sender.send(change);
                }
                event.respond(true)
            }
            "media-command" => {
                let cmd: MediaCommandEvent = event.decode()?;
                let sender = MEDIA_COMMAND_EVENT_SENDER
                    .read()
                    .ok()
                    .and_then(|slot| slot.clone());
                if let Some(sender) = sender {
                    let _ = sender.send(cmd);
                }
                event.respond(true)
            }
            other => Err(Error::from_reason(format!(
                "Unsupported ohos.system-state event '{other}'"
            ))),
        }
    }
}

/// 0..7 correspond to `thermal.ThermalLevel`. `kind` is one of:
/// `thermal`, `sleep`, `wake`, `lock-screen`, `unlock-screen`, `locale`,
/// `power-source`, `network`, `available-area`, `displays`, or
/// `suspend-delay-expired`.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct SystemStateChangedEvent {
    pub kind: String,
    pub thermal_level: Option<i32>,
    pub available_area: Option<AvailableArea>,
    pub displays: Option<Vec<DisplaySnapshot>>,
}

impl_bridge_napi_type!(SystemStateChangedEvent, "ohos.system-state.ChangedEvent");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AvailableArea {
    pub left: i32,
    pub top: i32,
    pub width: i32,
    pub height: i32,
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct DisplaySnapshot {
    pub id: i64,
    pub width: i32,
    pub height: i32,
    pub density_pixels: f64,
    pub refresh_rate: Option<f64>,
    pub available_area: Option<AvailableArea>,
    pub is_default: bool,
}

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct GetThermalLevelRequest {}

impl_bridge_napi_type!(
    GetThermalLevelRequest,
    "ohos.system-state.GetThermalLevelRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct GetThermalLevelResponse {
    pub level: i32,
}

impl_bridge_napi_type!(
    GetThermalLevelResponse,
    "ohos.system-state.GetThermalLevelResponse"
);

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct GetBundleCodeDirRequest {}

impl_bridge_napi_type!(
    GetBundleCodeDirRequest,
    "ohos.system-state.GetBundleCodeDirRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct GetBundleCodeDirResponse {
    pub path: String,
}

impl_bridge_napi_type!(
    GetBundleCodeDirResponse,
    "ohos.system-state.GetBundleCodeDirResponse"
);

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct GetAvailableAreaRequest {}

impl_bridge_napi_type!(
    GetAvailableAreaRequest,
    "ohos.system-state.GetAvailableAreaRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct GetAvailableAreaResponse {
    pub area: AvailableArea,
}

impl_bridge_napi_type!(
    GetAvailableAreaResponse,
    "ohos.system-state.GetAvailableAreaResponse"
);

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct GetDisplaysRequest {}

impl_bridge_napi_type!(GetDisplaysRequest, "ohos.system-state.GetDisplaysRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct GetDisplaysResponse {
    pub displays: Vec<DisplaySnapshot>,
}

impl_bridge_napi_type!(GetDisplaysResponse, "ohos.system-state.GetDisplaysResponse");

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct GetLocaleRegionRequest {}
impl_bridge_napi_type!(
    GetLocaleRegionRequest,
    "ohos.system-state.GetLocaleRegionRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct GetLocaleRegionResponse {
    pub locale: String,
    /// `0` = Sunday .. `6` = Saturday, or `-1` when unavailable (API < 18).
    pub first_weekday: i32,
    pub hour_cycle: i32,
    pub app_preferred_language: String,
}
impl_bridge_napi_type!(
    GetLocaleRegionResponse,
    "ohos.system-state.GetLocaleRegionResponse"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct SetAppPreferredLanguageRequest {
    pub tag: String,
}
impl_bridge_napi_type!(
    SetAppPreferredLanguageRequest,
    "ohos.system-state.SetAppPreferredLanguageRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct SetAppPreferredLanguageResponse {
    pub kept: bool,
}
impl_bridge_napi_type!(
    SetAppPreferredLanguageResponse,
    "ohos.system-state.SetAppPreferredLanguageResponse"
);

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct GetPackageInfoRequest {}
impl_bridge_napi_type!(
    GetPackageInfoRequest,
    "ohos.system-state.GetPackageInfoRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct GetPackageInfoResponse {
    pub identifier: String,
    pub name: String,
    pub version: String,
}
impl_bridge_napi_type!(
    GetPackageInfoResponse,
    "ohos.system-state.GetPackageInfoResponse"
);

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct GetNetworkStatusRequest {}
impl_bridge_napi_type!(
    GetNetworkStatusRequest,
    "ohos.system-state.GetNetworkStatusRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct GetNetworkStatusResponse {
    pub online: bool,
    pub metered: bool,
}
impl_bridge_napi_type!(
    GetNetworkStatusResponse,
    "ohos.system-state.GetNetworkStatusResponse"
);

#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct GetPowerStatusRequest {}
impl_bridge_napi_type!(
    GetPowerStatusRequest,
    "ohos.system-state.GetPowerStatusRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct GetPowerStatusResponse {
    pub on_battery: bool,
    pub has_battery: bool,
}
impl_bridge_napi_type!(
    GetPowerStatusResponse,
    "ohos.system-state.GetPowerStatusResponse"
);

/// Bitmask flags for [`SetNowPlayingRequest::commands`].
pub mod media_command {
    pub const PLAY: u32 = 1 << 0;
    pub const PAUSE: u32 = 1 << 1;
    pub const STOP: u32 = 1 << 2;
    pub const NEXT: u32 = 1 << 3;
    pub const PREVIOUS: u32 = 1 << 4;
    pub const SEEK: u32 = 1 << 5;
    pub const ALL: u32 = PLAY | PAUSE | STOP | NEXT | PREVIOUS | SEEK;
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct SetNowPlayingRequest {
    pub active: bool,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub artwork: Option<Vec<u8>>,
    pub state: String,
    pub duration_ms: i64,
    pub position_ms: i64,
    pub rate: f64,
    /// Bitmask of [`media_command`] flags indicating which transport controls are enabled.
    pub commands: u32,
}
impl_bridge_napi_type!(
    SetNowPlayingRequest,
    "ohos.system-state.SetNowPlayingRequest"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct SetNowPlayingResponse {
    pub accepted: bool,
}
impl_bridge_napi_type!(
    SetNowPlayingResponse,
    "ohos.system-state.SetNowPlayingResponse"
);

#[napi(object)]
#[derive(Clone, Debug)]
pub struct MediaCommandEvent {
    pub command: String,
    pub position_ms: i64,
}
impl_bridge_napi_type!(MediaCommandEvent, "ohos.system-state.MediaCommandEvent");

static SYSTEM_STATE_EVENT_SENDER: RwLock<Option<Sender<SystemStateChangedEvent>>> =
    RwLock::new(None);
static MEDIA_COMMAND_EVENT_SENDER: RwLock<Option<Sender<MediaCommandEvent>>> = RwLock::new(None);

pub fn register_system_state_event_sender(sender: Sender<SystemStateChangedEvent>) {
    if let Ok(mut slot) = SYSTEM_STATE_EVENT_SENDER.write() {
        *slot = Some(sender);
    }
}

pub fn unregister_system_state_event_sender() {
    if let Ok(mut slot) = SYSTEM_STATE_EVENT_SENDER.write() {
        *slot = None;
    }
}

pub fn register_media_command_event_sender(sender: Sender<MediaCommandEvent>) {
    if let Ok(mut slot) = MEDIA_COMMAND_EVENT_SENDER.write() {
        *slot = Some(sender);
    }
}

pub fn unregister_media_command_event_sender() {
    if let Ok(mut slot) = MEDIA_COMMAND_EVENT_SENDER.write() {
        *slot = None;
    }
}

#[derive(Clone)]
pub struct SystemStateClient {
    bridge: BridgeRuntime,
}

impl SystemStateClient {
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }

    pub async fn preferred_languages(&self) -> Result<Vec<String>> {
        let response = self.bridge.call_async::<SystemStateBridgePlugin, PreferredLanguagesRequest, PreferredLanguagesResponse>(
            "preferred-languages", PreferredLanguagesRequest {}, BridgeCallOptions::default()).await?;
        Ok(response.languages)
    }
    pub async fn resolve_proxy(&self, url: String) -> Result<String> {
        if !(url.starts_with("http://") || url.starts_with("https://"))
            || url.chars().any(char::is_control)
        {
            return Err(Error::from_reason("Invalid proxy target URL"));
        }
        let response = self
            .bridge
            .call_async::<SystemStateBridgePlugin, ResolveProxyRequest, ResolveProxyResponse>(
                "resolve-proxy",
                ResolveProxyRequest { url },
                BridgeCallOptions::default(),
            )
            .await?;
        if response.directives.trim().is_empty() {
            return Err(Error::from_reason("System PAC policy unavailable"));
        }
        Ok(response.directives)
    }

    pub async fn thermal_level(&self) -> Result<i32> {
        let response = self
            .bridge
            .call_async::<SystemStateBridgePlugin, GetThermalLevelRequest, GetThermalLevelResponse>(
                "get-thermal-level",
                GetThermalLevelRequest {},
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.level)
    }

    pub async fn prevent_sleep(&self, reason: String) -> Result<String> {
        if reason.trim().is_empty()
            || reason.chars().count() > 256
            || reason.chars().any(char::is_control)
        {
            return Err(Error::from_reason("Invalid sleep prevention reason"));
        }
        let response = self
            .bridge
            .call_async::<SystemStateBridgePlugin, PreventSleepRequest, PreventSleepResponse>(
                "prevent-sleep",
                PreventSleepRequest { reason },
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.id)
    }

    pub async fn release_sleep(&self, id: String) -> Result<()> {
        let response = self
            .bridge
            .call_async::<SystemStateBridgePlugin, ReleaseSleepRequest, ReleaseSleepResponse>(
                "release-sleep",
                ReleaseSleepRequest { id },
                BridgeCallOptions::default(),
            )
            .await?;
        if !response.accepted {
            return Err(Error::from_reason("Sleep prevention release rejected"));
        }
        Ok(())
    }

    pub async fn bundle_code_dir(&self) -> Result<String> {
        let response = self
            .bridge
            .call_async::<SystemStateBridgePlugin, GetBundleCodeDirRequest, GetBundleCodeDirResponse>(
                "get-bundle-code-dir",
                GetBundleCodeDirRequest {},
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.path)
    }

    pub async fn available_area(&self) -> Result<AvailableArea> {
        let response = self
            .bridge
            .call_async::<SystemStateBridgePlugin, GetAvailableAreaRequest, GetAvailableAreaResponse>(
                "get-available-area",
                GetAvailableAreaRequest {},
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.area)
    }

    pub async fn displays(&self) -> Result<Vec<DisplaySnapshot>> {
        let response = self
            .bridge
            .call_async::<SystemStateBridgePlugin, GetDisplaysRequest, GetDisplaysResponse>(
                "get-displays",
                GetDisplaysRequest {},
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.displays)
    }

    pub async fn locale_region(&self) -> Result<GetLocaleRegionResponse> {
        self.bridge
            .call_async::<SystemStateBridgePlugin, GetLocaleRegionRequest, GetLocaleRegionResponse>(
                "get-locale-region",
                GetLocaleRegionRequest {},
                BridgeCallOptions::default(),
            )
            .await
    }

    pub async fn set_app_preferred_language(&self, tag: String) -> Result<bool> {
        let response = self
            .bridge
            .call_async::<SystemStateBridgePlugin, SetAppPreferredLanguageRequest, SetAppPreferredLanguageResponse>(
                "set-app-preferred-language",
                SetAppPreferredLanguageRequest { tag },
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.kept)
    }

    pub async fn package_info(&self) -> Result<GetPackageInfoResponse> {
        self.bridge
            .call_async::<SystemStateBridgePlugin, GetPackageInfoRequest, GetPackageInfoResponse>(
                "get-package-info",
                GetPackageInfoRequest {},
                BridgeCallOptions::default(),
            )
            .await
    }

    pub async fn network_status(&self) -> Result<GetNetworkStatusResponse> {
        self.bridge
            .call_async::<SystemStateBridgePlugin, GetNetworkStatusRequest, GetNetworkStatusResponse>(
                "get-network-status",
                GetNetworkStatusRequest {},
                BridgeCallOptions::default(),
            )
            .await
    }

    pub async fn power_status(&self) -> Result<GetPowerStatusResponse> {
        self.bridge
            .call_async::<SystemStateBridgePlugin, GetPowerStatusRequest, GetPowerStatusResponse>(
                "get-power-status",
                GetPowerStatusRequest {},
                BridgeCallOptions::default(),
            )
            .await
    }

    pub async fn request_suspend_delay(&self, reason: String) -> Result<String> {
        if reason.trim().is_empty()
            || reason.chars().count() > 256
            || reason.chars().any(char::is_control)
        {
            return Err(Error::from_reason("Invalid suspend delay reason"));
        }
        let response = self
            .bridge
            .call_async::<SystemStateBridgePlugin, SuspendDelayRequest, SuspendDelayResponse>(
                "request-suspend-delay",
                SuspendDelayRequest { reason },
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.id)
    }

    pub async fn cancel_suspend_delay(&self, id: String) -> Result<()> {
        if id.trim().is_empty() {
            return Err(Error::from_reason("Invalid suspend delay id"));
        }
        let response = self
            .bridge
            .call_async::<
                SystemStateBridgePlugin,
                CancelSuspendDelayRequest,
                CancelSuspendDelayResponse,
            >(
                "cancel-suspend-delay",
                CancelSuspendDelayRequest { id },
                BridgeCallOptions::default(),
            )
            .await?;
        if !response.accepted {
            return Err(Error::from_reason("Suspend delay cancellation rejected"));
        }
        Ok(())
    }

    pub async fn set_now_playing(&self, request: SetNowPlayingRequest) -> Result<bool> {
        let response = self
            .bridge
            .call_async::<SystemStateBridgePlugin, SetNowPlayingRequest, SetNowPlayingResponse>(
                "set-now-playing",
                request,
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.accepted)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::{BridgeContextRequirement, BridgeNapiType, BridgePlugin};

    #[test]
    fn bridge_types_are_named() {
        assert_eq!(
            PreferredLanguagesRequest::TYPE_NAME,
            "ohos.system-state.PreferredLanguagesRequest"
        );
        assert_eq!(
            PreferredLanguagesResponse::TYPE_NAME,
            "ohos.system-state.PreferredLanguagesResponse"
        );
        assert_eq!(
            ResolveProxyRequest::TYPE_NAME,
            "ohos.system-state.ResolveProxyRequest"
        );
        assert_eq!(
            ResolveProxyResponse::TYPE_NAME,
            "ohos.system-state.ResolveProxyResponse"
        );
        assert_eq!(
            PreventSleepRequest::TYPE_NAME,
            "ohos.system-state.PreventSleepRequest"
        );
        assert_eq!(
            PreventSleepResponse::TYPE_NAME,
            "ohos.system-state.PreventSleepResponse"
        );
        assert_eq!(
            ReleaseSleepRequest::TYPE_NAME,
            "ohos.system-state.ReleaseSleepRequest"
        );
        assert_eq!(
            ReleaseSleepResponse::TYPE_NAME,
            "ohos.system-state.ReleaseSleepResponse"
        );
        assert_eq!(
            SuspendDelayRequest::TYPE_NAME,
            "ohos.system-state.SuspendDelayRequest"
        );
        assert_eq!(
            SuspendDelayResponse::TYPE_NAME,
            "ohos.system-state.SuspendDelayResponse"
        );
        assert_eq!(
            CancelSuspendDelayRequest::TYPE_NAME,
            "ohos.system-state.CancelSuspendDelayRequest"
        );
        assert_eq!(
            CancelSuspendDelayResponse::TYPE_NAME,
            "ohos.system-state.CancelSuspendDelayResponse"
        );
        assert_eq!(SystemStateBridgePlugin::ID, "ohos.system-state");
        assert_eq!(
            SystemStateBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
        assert_eq!(
            SystemStateChangedEvent::TYPE_NAME,
            "ohos.system-state.ChangedEvent"
        );
        assert_eq!(
            GetThermalLevelRequest::TYPE_NAME,
            "ohos.system-state.GetThermalLevelRequest"
        );
        assert_eq!(
            GetThermalLevelResponse::TYPE_NAME,
            "ohos.system-state.GetThermalLevelResponse"
        );
        assert_eq!(
            GetBundleCodeDirRequest::TYPE_NAME,
            "ohos.system-state.GetBundleCodeDirRequest"
        );
        assert_eq!(
            GetBundleCodeDirResponse::TYPE_NAME,
            "ohos.system-state.GetBundleCodeDirResponse"
        );
        assert_eq!(
            GetAvailableAreaRequest::TYPE_NAME,
            "ohos.system-state.GetAvailableAreaRequest"
        );
        assert_eq!(
            GetAvailableAreaResponse::TYPE_NAME,
            "ohos.system-state.GetAvailableAreaResponse"
        );
        assert_eq!(
            GetDisplaysRequest::TYPE_NAME,
            "ohos.system-state.GetDisplaysRequest"
        );
        assert_eq!(
            GetDisplaysResponse::TYPE_NAME,
            "ohos.system-state.GetDisplaysResponse"
        );
        assert_eq!(
            GetLocaleRegionRequest::TYPE_NAME,
            "ohos.system-state.GetLocaleRegionRequest"
        );
        assert_eq!(
            GetLocaleRegionResponse::TYPE_NAME,
            "ohos.system-state.GetLocaleRegionResponse"
        );
        assert_eq!(
            SetAppPreferredLanguageRequest::TYPE_NAME,
            "ohos.system-state.SetAppPreferredLanguageRequest"
        );
        assert_eq!(
            SetAppPreferredLanguageResponse::TYPE_NAME,
            "ohos.system-state.SetAppPreferredLanguageResponse"
        );
        assert_eq!(
            GetPackageInfoRequest::TYPE_NAME,
            "ohos.system-state.GetPackageInfoRequest"
        );
        assert_eq!(
            GetPackageInfoResponse::TYPE_NAME,
            "ohos.system-state.GetPackageInfoResponse"
        );
        assert_eq!(
            GetNetworkStatusRequest::TYPE_NAME,
            "ohos.system-state.GetNetworkStatusRequest"
        );
        assert_eq!(
            GetNetworkStatusResponse::TYPE_NAME,
            "ohos.system-state.GetNetworkStatusResponse"
        );
        assert_eq!(
            GetPowerStatusRequest::TYPE_NAME,
            "ohos.system-state.GetPowerStatusRequest"
        );
        assert_eq!(
            GetPowerStatusResponse::TYPE_NAME,
            "ohos.system-state.GetPowerStatusResponse"
        );
        assert_eq!(
            SetNowPlayingRequest::TYPE_NAME,
            "ohos.system-state.SetNowPlayingRequest"
        );
        assert_eq!(
            SetNowPlayingResponse::TYPE_NAME,
            "ohos.system-state.SetNowPlayingResponse"
        );
        assert_eq!(
            MediaCommandEvent::TYPE_NAME,
            "ohos.system-state.MediaCommandEvent"
        );
        assert_eq!(media_command::ALL, 0b11_1111);
    }

    #[test]
    fn event_senders_can_be_replaced_and_cleared() {
        let (tx1, rx1) = crossbeam_channel::unbounded();
        let (tx2, rx2) = crossbeam_channel::unbounded();
        register_system_state_event_sender(tx1);
        register_system_state_event_sender(tx2);
        let sender = SYSTEM_STATE_EVENT_SENDER
            .read()
            .unwrap()
            .clone()
            .expect("sender registered");
        sender
            .send(SystemStateChangedEvent {
                kind: "network".to_string(),
                thermal_level: None,
                available_area: None,
                displays: None,
            })
            .unwrap();
        assert!(rx1.try_recv().is_err());
        assert_eq!(rx2.try_recv().unwrap().kind, "network");
        unregister_system_state_event_sender();
        assert!(SYSTEM_STATE_EVENT_SENDER.read().unwrap().is_none());

        let (mtx1, mrx1) = crossbeam_channel::unbounded();
        let (mtx2, mrx2) = crossbeam_channel::unbounded();
        register_media_command_event_sender(mtx1);
        register_media_command_event_sender(mtx2);
        let msender = MEDIA_COMMAND_EVENT_SENDER
            .read()
            .unwrap()
            .clone()
            .expect("media sender registered");
        msender
            .send(MediaCommandEvent {
                command: "play".to_string(),
                position_ms: 0,
            })
            .unwrap();
        assert!(mrx1.try_recv().is_err());
        assert_eq!(mrx2.try_recv().unwrap().command, "play");
        unregister_media_command_event_sender();
        assert!(MEDIA_COMMAND_EVENT_SENDER.read().unwrap().is_none());
    }
}
