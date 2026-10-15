//! System thermal and screen sleep state for OpenHarmony consumers.

use std::sync::OnceLock;

use crossbeam_channel::Sender;
use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

pub struct SystemStateBridgePlugin;

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
                if let Some(sender) = SYSTEM_STATE_EVENT_SENDER.get() {
                    let _ = sender.send(change);
                }
                event.respond(true)
            }
            other => Err(Error::from_reason(format!(
                "Unsupported ohos.system-state event '{other}'"
            ))),
        }
    }
}

/// 0..7 correspond to `thermal.ThermalLevel`. `kind` is thermal, sleep, wake,
/// available-area, or displays.
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

static SYSTEM_STATE_EVENT_SENDER: OnceLock<Sender<SystemStateChangedEvent>> = OnceLock::new();

pub fn register_system_state_event_sender(sender: Sender<SystemStateChangedEvent>) {
    let _ = SYSTEM_STATE_EVENT_SENDER.set(sender);
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
}

#[cfg(test)]
mod tests {
    use super::{
        GetAvailableAreaRequest, GetAvailableAreaResponse, GetBundleCodeDirRequest,
        GetBundleCodeDirResponse, GetDisplaysRequest, GetDisplaysResponse, GetThermalLevelRequest,
        GetThermalLevelResponse, SystemStateBridgePlugin, SystemStateChangedEvent,
    };
    use openharmony_ability::{BridgeContextRequirement, BridgeNapiType, BridgePlugin};

    #[test]
    fn bridge_types_are_named() {
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
    }
}
