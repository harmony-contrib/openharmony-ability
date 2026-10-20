//! Reusable media players. File descriptors stay borrowed until the ArkTS side
//! acknowledges duplication; the player owns that duplicate until release.
use napi_derive_ohos::napi;
use std::os::fd::{AsRawFd, BorrowedFd, IntoRawFd};
mod descriptor;
use napi_ohos::{bindgen_prelude::Unknown, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};

pub struct AudioBridgePlugin;
impl BridgePlugin for AudioBridgePlugin {
    type Mode = AsyncBridge;
    const ID: &'static str = "ohos.audio";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        if event.name() == "playback" {
            let request: AudioPlaybackEvent = event.decode()?;
            log::debug!(
                "native audio player={} event={} state={} value={}",
                request.player,
                request.event,
                request.state,
                request.value
            );
            return event.respond(true);
        }
        if event.name() != "duplicate" {
            return Err(Error::from_reason("Unsupported audio event"));
        }
        let request: AudioDuplicateRequest = event.decode()?;
        if request.fd < 0 {
            return Err(Error::from_reason("Invalid audio source descriptor"));
        }
        let descriptor = descriptor::DescriptorDuplicator::duplicate(request.fd)
            .map_err(|error| Error::from_reason(error.to_string()))?;
        log::debug!(
            "native audio descriptor={} flags={}",
            descriptor.as_raw_fd(),
            {
                // SAFETY: the duplicate remains exclusively owned and live.
                unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_GETFD) }
            }
        );
        let response = event.respond(descriptor.as_raw_fd());
        if response.is_ok() {
            let _ = descriptor.into_raw_fd();
        }
        response
    }
}

#[napi(object)]
pub struct AudioDuplicateRequest {
    pub fd: i32,
}
#[napi(object)]
pub struct AudioPlaybackEvent {
    pub player: String,
    pub event: String,
    pub state: String,
    pub value: f64,
}
impl_bridge_napi_type!(AudioPlaybackEvent, "ohos.audio.PlaybackEvent");
impl_bridge_napi_type!(AudioDuplicateRequest, "ohos.audio.DuplicateRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct AudioUpdateRequest {
    pub player: String,
    pub source_fd: Option<i32>,
    pub replace: bool,
    pub release: bool,
    pub play: bool,
    pub volume: f64,
    pub report_errors: bool,
    pub label: String,
    pub diagnostics: bool,
}
impl_bridge_napi_type!(AudioUpdateRequest, "ohos.audio.UpdateRequest");
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
    /// The source is borrowed until native descriptor duplication is acknowledged.
    /// The wire descriptor is derived from this borrow, never from caller-supplied integers.
    pub async fn update(
        &self,
        mut request: AudioUpdateRequest,
        source: Option<BorrowedFd<'_>>,
    ) -> Result<()> {
        request.source_fd = source.map(|fd| fd.as_raw_fd());
        if request.player.is_empty()
            || !request.volume.is_finite()
            || !(0.0..=1.0).contains(&request.volume)
            || request.source_fd.is_some_and(|fd| fd < 0)
            || (request.source_fd.is_some() && !request.replace)
            || (request.release && (request.source_fd.is_some() || request.play))
        {
            return Err(Error::from_reason("Invalid media-player update"));
        }
        let response: AudioUpdateResponse = self
            .bridge
            .call_async::<AudioBridgePlugin, _, _>("update", request, BridgeCallOptions::default())
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
        assert_eq!(AudioUpdateRequest::TYPE_NAME, "ohos.audio.UpdateRequest");
        assert_eq!(AudioUpdateResponse::TYPE_NAME, "ohos.audio.UpdateResponse");
        assert_eq!(
            AudioDuplicateRequest::TYPE_NAME,
            "ohos.audio.DuplicateRequest"
        );
        assert_eq!(AudioPlaybackEvent::TYPE_NAME, "ohos.audio.PlaybackEvent");
        assert_eq!(AudioBridgePlugin::ID, "ohos.audio");
        assert_eq!(
            AudioBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::Ability]
        );
    }
}
