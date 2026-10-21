//! Reusable media players. File descriptors stay borrowed until the ArkTS side
//! acknowledges duplication; the player owns that duplicate until release.
use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement, BridgePlugin,
    BridgeRuntime, OpenHarmonyApp,
};
use std::os::fd::{AsRawFd, BorrowedFd};

pub struct AudioBridgePlugin;
impl BridgePlugin for AudioBridgePlugin {
    type Mode = AsyncBridge;
    const ID: &'static str = "ohos.audio";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

/// Playback options. Source descriptors are supplied only through [`AudioClient::update`].
#[derive(Clone, Debug)]
pub struct AudioUpdateRequest {
    pub player: String,
    pub replace: bool,
    pub release: bool,
    pub play: bool,
    pub volume: f64,
    pub report_errors: bool,
    pub label: String,
}

impl AudioUpdateRequest {
    fn validate(&self, has_source: bool) -> Result<()> {
        if self.player.is_empty()
            || !self.volume.is_finite()
            || !(0.0..=1.0).contains(&self.volume)
            || (has_source && !self.replace)
            || (self.release && (has_source || self.play))
        {
            return Err(Error::from_reason("Invalid media-player update"));
        }
        Ok(())
    }
}

// napi(object) requires public fields, so keep the descriptor in a private wire type.
#[napi(object)]
struct AudioUpdatePayload {
    pub player: String,
    pub source_fd: Option<i32>,
    pub replace: bool,
    pub release: bool,
    pub play: bool,
    pub volume: f64,
    pub report_errors: bool,
    pub label: String,
}
impl_bridge_napi_type!(AudioUpdatePayload, "ohos.audio.UpdateRequest");
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AudioUpdateResponse {
    pub accepted: bool,
}
impl_bridge_napi_type!(AudioUpdateResponse, "ohos.audio.UpdateResponse");

#[derive(Clone)]
pub struct AudioClient {
    bridge: BridgeRuntime,
}
impl AudioClient {
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }
    /// The source is borrowed until ArkTS acknowledges its synchronous `fs.dup`.
    /// The wire descriptor is derived from this borrow, never from caller-supplied integers.
    pub async fn update(
        &self,
        request: AudioUpdateRequest,
        source: Option<BorrowedFd<'_>>,
    ) -> Result<()> {
        request.validate(source.is_some())?;
        let payload = AudioUpdatePayload {
            player: request.player,
            source_fd: source.map(|fd| fd.as_raw_fd()),
            replace: request.replace,
            release: request.release,
            play: request.play,
            volume: request.volume,
            report_errors: request.report_errors,
            label: request.label,
        };
        let response: AudioUpdateResponse = self
            .bridge
            .call_async::<AudioBridgePlugin, _, _>("update", payload, BridgeCallOptions::default())
            .await?;
        if response.accepted {
            Ok(())
        } else {
            Err(Error::from_reason("Media-player update rejected"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;
    #[test]
    fn audio_contracts_and_context_are_stable() {
        assert_eq!(AudioUpdatePayload::TYPE_NAME, "ohos.audio.UpdateRequest");
        assert_eq!(AudioUpdateResponse::TYPE_NAME, "ohos.audio.UpdateResponse");
        assert_eq!(AudioBridgePlugin::ID, "ohos.audio");
        assert_eq!(
            AudioBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }

    #[test]
    fn validates_updates_before_platform_dispatch() {
        let mut request = AudioUpdateRequest {
            player: "bell".into(),
            replace: false,
            release: false,
            play: true,
            volume: 0.5,
            report_errors: true,
            label: "Bell".into(),
        };
        assert!(request.validate(false).is_ok());
        assert!(request.validate(true).is_err());
        request.replace = true;
        assert!(request.validate(true).is_ok());
        request.release = true;
        assert!(request.validate(true).is_err());
        assert!(request.validate(false).is_err());
        request.play = false;
        assert!(request.validate(false).is_ok());
        for volume in [f64::NAN, f64::INFINITY, -0.1, 1.1] {
            request.volume = volume;
            assert!(request.validate(false).is_err());
        }
        request.volume = 1.0;
        request.player.clear();
        assert!(request.validate(false).is_err());
    }
}
