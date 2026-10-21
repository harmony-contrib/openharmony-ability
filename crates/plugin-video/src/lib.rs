//! API-12 AVPlayer ownership and native-tree presentation through ArkTS.
//! Workers carry owned playback settings and bytes; platform nodes stay in
//! the plugin and are borrowed only inside synchronous attachment callbacks.
use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{Object, ToNapiValue, Uint8Array, Unknown},
    Env, Error, Result,
};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement,
    BridgeMainThreadEvent, BridgeNapiType, BridgePlugin, BridgeRuntime, OpenHarmonyApp,
};
use std::sync::{Arc, Mutex};

/// Native video capability, paired with the `VideoPlugin` HAR factory.
#[derive(Default)]
pub struct VideoBridgePlugin {
    events: Arc<Mutex<playback_routes::PlaybackRoutes<VideoEvent>>>,
}
mod playback_routes;
impl VideoBridgePlugin {
    /// Creates an independent callback owner for one registered application.
    pub fn new() -> Self {
        Self::default()
    }
}
impl BridgePlugin for VideoBridgePlugin {
    type Mode = AsyncBridge;
    const ID: &'static str = "ohos.video";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::UiContext];
    fn required_contexts_for_main_thread_event(
        &self,
        name: &str,
    ) -> &'static [BridgeContextRequirement] {
        if name == "native-node-retiring" {
            &[]
        } else {
            Self::REQUIRED_CONTEXTS
        }
    }
    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        match event.name() {
            "native-node-ready" => {
                let ready = event.decode::<openharmony_ability::NativeNodeReady>()?;
                ready.attach(&event)?;
                event.respond(openharmony_ability::NodeAcknowledgement { accepted: true })
            }
            "native-node-retiring" => {
                event
                    .decode::<openharmony_ability::NativeNodeRetiring>()?
                    .detach()?;
                event.respond(openharmony_ability::NodeAcknowledgement { accepted: true })
            }
            "playback-event" => {
                let payload = event.decode::<VideoEvent>()?;
                let callback = self
                    .events
                    .lock()
                    .map_err(|_| Error::from_reason("video event lock poisoned"))?
                    .get(&payload.id, payload.target_id);
                openharmony_ability::NativeAttachment::dispatch(payload.target_id, || {
                    if let Some(callback) = callback {
                        callback(payload);
                    }
                })?;
                event.respond(VideoAcknowledgement { accepted: true })
            }
            _ => Err(Error::from_reason("Unsupported ohos.video native event")),
        }
    }
}
/// Playback presentation, independent of the current media source.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct VideoSettings {
    /// Unique controller ID within this native module.
    pub id: String,
    /// Pause playback; zero rate also pauses.
    pub paused: bool,
    /// Suppress audio while preserving the requested volume.
    pub muted: bool,
    /// Audio volume from zero to one.
    pub volume: f64,
    /// API-12 playback speed, or zero to pause.
    pub rate: f64,
    /// Loop at the end of the stream.
    pub repeat: bool,
    /// contain, cover, stretch or center.
    pub resize_mode: String,
    /// Display native playback controls.
    pub controls: bool,
    /// Minimum interval between progress events, in milliseconds.
    pub progress_interval_ms: f64,
}
impl_bridge_napi_type!(VideoSettings, "ohos.video.Settings");
impl VideoSettings {
    /// Validates the API-12 capabilities before crossing the bridge.
    pub fn validate(&self) -> Result<()> {
        validate_id(&self.id)?;
        if !self.volume.is_finite()
            || !(0.0..=1.0).contains(&self.volume)
            || ![0.0, 0.125, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0].contains(&self.rate)
            || !matches!(
                self.resize_mode.as_str(),
                "contain" | "cover" | "stretch" | "center"
            )
            || !self.progress_interval_ms.is_finite()
            || self.progress_interval_ms < 0.0
        {
            return Err(Error::from_reason("Unsupported API-12 video settings"));
        }
        Ok(())
    }
}
/// Creates an ArkTS-owned surface in a native attachment target.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct VideoCreateRequest {
    /// Non-reused UI-thread attachment target.
    pub target_id: u32,
    /// Initial playback presentation.
    pub settings: VideoSettings,
}
impl_bridge_napi_type!(VideoCreateRequest, "ohos.video.CreateRequest");
/// Acknowledgement of a completed video operation.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct VideoAcknowledgement {
    /// Whether the operation completed successfully.
    pub accepted: bool,
}
impl_bridge_napi_type!(VideoAcknowledgement, "ohos.video.Acknowledgement");
/// Controller operation; source is an absolute media URL, value is seconds.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct VideoCommandRequest {
    /// Controller ID.
    pub id: String,
    /// Optional media URL for set-source; absent clears playback.
    pub source: Option<String>,
    /// Seek time in seconds.
    pub value: Option<f64>,
}
impl_bridge_napi_type!(VideoCommandRequest, "ohos.video.CommandRequest");
/// Owned binary resource. Encoding creates a callback-scoped Uint8Array;
/// the worker never retains a N-API reference or typed-array view.
pub struct VideoBytesRequest {
    /// Controller ID.
    pub id: String,
    /// Owned encoded media bytes.
    pub bytes: Vec<u8>,
}
impl BridgeNapiType for VideoBytesRequest {
    const TYPE_NAME: &'static str = "ohos.video.BytesRequest";
    fn into_bridge_value<'env>(self, env: &'env Env) -> Result<Unknown<'env>> {
        let mut object = Object::new(env)?;
        object.set("id", self.id)?;
        object.set("bytes", Uint8Array::from(self.bytes))?;
        object.into_unknown(env)
    }
    fn from_bridge_value(_: Unknown<'_>) -> Result<Self> {
        Err(Error::from_reason("VideoBytesRequest is outbound-only"))
    }
}
/// Snapshot emitted by the live platform player.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct VideoEvent {
    /// Controller ID.
    pub id: String,
    /// Attachment generation, used to reject late callbacks.
    pub target_id: u32,
    /// load, progress, end, buffer, seek or error.
    pub phase: String,
    /// Playback time in seconds.
    pub current_time: f64,
    /// Duration in seconds, zero for unknown/live duration.
    pub duration: f64,
    /// Encoded width in physical pixels.
    pub width: f64,
    /// Encoded height in physical pixels.
    pub height: f64,
    /// Whether playback is waiting for data.
    pub buffering: bool,
    /// Platform failure description.
    pub message: Option<String>,
}
impl_bridge_napi_type!(VideoEvent, "ohos.video.Event");
type Callback = Arc<dyn Fn(VideoEvent) + Send + Sync>;
/// Removes its callback only from the registering plugin instance and generation.
pub struct VideoEvents {
    routes: Arc<Mutex<playback_routes::PlaybackRoutes<VideoEvent>>>,
    id: String,
    callback: Callback,
}
impl VideoEvents {
    /// Registers before creating the matching native attachment generation.
    pub fn new(
        app: &OpenHarmonyApp,
        id: String,
        target_id: u32,
        callback: impl Fn(VideoEvent) + Send + Sync + 'static,
    ) -> Result<Self> {
        validate_id(&id)?;
        if target_id == 0 {
            return Err(Error::from_reason(
                "Video callback requires a native target",
            ));
        }
        let plugin = app
            .registered_plugin::<VideoBridgePlugin>()?
            .ok_or_else(|| Error::from_reason("Video plugin is not registered"))?;
        let routes = plugin.events.clone();
        let callback: Callback = Arc::new(callback);
        let inserted = routes
            .lock()
            .map_err(|_| Error::from_reason("video event lock poisoned"))?
            .insert(id.clone(), target_id, callback.clone());
        if !inserted {
            return Err(Error::from_reason("Video ID is already registered"));
        }
        Ok(Self {
            routes,
            id,
            callback,
        })
    }
}
impl Drop for VideoEvents {
    fn drop(&mut self) {
        self.routes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.id, &self.callback);
    }
}
/// Worker-safe facade for the session's native video plugin.
#[derive(Clone)]
pub struct VideoClient {
    bridge: BridgeRuntime,
}
impl VideoClient {
    /// Uses the current Ability bridge session.
    pub fn new(app: &OpenHarmonyApp) -> Result<Self> {
        Ok(Self {
            bridge: app.bridge()?,
        })
    }
    /// Constructs and mounts a native player surface.
    pub async fn create(&self, request: VideoCreateRequest) -> Result<()> {
        request.settings.validate()?;
        if request.target_id == 0 {
            return Err(Error::from_reason("Video requires a native target"));
        }
        self.call("create", request).await
    }
    /// Updates playback presentation without replacing the source.
    pub async fn configure(&self, settings: VideoSettings) -> Result<()> {
        settings.validate()?;
        self.call("configure", settings).await
    }
    /// Sets a media source URL, seeks, or disposes the controller.
    pub async fn command(&self, action: &str, request: VideoCommandRequest) -> Result<()> {
        validate_id(&request.id)?;
        let valid = match action {
            "set-source" => {
                request.value.is_none()
                    && request
                        .source
                        .as_ref()
                        .is_none_or(|url| !url.trim().is_empty())
            }
            "seek" => {
                request.source.is_none()
                    && request
                        .value
                        .is_some_and(|n| n.is_finite() && n >= 0.0 && n * 1000.0 <= i32::MAX as f64)
            }
            "dispose" => request.source.is_none() && request.value.is_none(),
            _ => false,
        };
        if !valid {
            return Err(Error::from_reason("Invalid video command"));
        }
        self.call(action, request).await
    }
    /// Opens media bytes through a plugin-owned, temporary file descriptor.
    pub async fn set_bytes(&self, request: VideoBytesRequest) -> Result<()> {
        validate_id(&request.id)?;
        if request.bytes.is_empty() {
            return Err(Error::from_reason("Video resource must not be empty"));
        }
        self.call("set-bytes", request).await
    }
    async fn call<T: BridgeNapiType>(&self, action: &str, request: T) -> Result<()> {
        let ack = self
            .bridge
            .call_async::<VideoBridgePlugin, T, VideoAcknowledgement>(
                action,
                request,
                BridgeCallOptions::default(),
            )
            .await?;
        if ack.accepted {
            Ok(())
        } else {
            Err(Error::from_reason("Video operation was rejected"))
        }
    }
}
/// Application extension for the paired video capability.
pub trait VideoExt {
    /// Returns a facade for the current bridge session.
    fn video(&self) -> Result<VideoClient>;
}
impl VideoExt for OpenHarmonyApp {
    fn video(&self) -> Result<VideoClient> {
        VideoClient::new(self)
    }
}
fn validate_id(id: &str) -> Result<()> {
    if id.trim().is_empty() {
        Err(Error::from_reason("Video ID must not be empty"))
    } else {
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stable_contracts() {
        assert_eq!(VideoSettings::TYPE_NAME, "ohos.video.Settings");
        assert_eq!(VideoCreateRequest::TYPE_NAME, "ohos.video.CreateRequest");
        assert_eq!(VideoCommandRequest::TYPE_NAME, "ohos.video.CommandRequest");
        assert_eq!(VideoBytesRequest::TYPE_NAME, "ohos.video.BytesRequest");
        assert_eq!(VideoEvent::TYPE_NAME, "ohos.video.Event");
        assert_eq!(
            VideoAcknowledgement::TYPE_NAME,
            "ohos.video.Acknowledgement"
        );
        assert_eq!(VideoBridgePlugin::ID, "ohos.video");
        assert_eq!(
            VideoBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::UiContext]
        );
    }
    #[test]
    fn settings_reject_unsupported_rates_and_nonfinite_values() {
        let mut settings = VideoSettings {
            id: "test".into(),
            paused: false,
            muted: false,
            volume: 1.0,
            rate: 1.0,
            repeat: false,
            resize_mode: "contain".into(),
            controls: false,
            progress_interval_ms: 250.0,
        };
        assert!(settings.validate().is_ok());
        settings.rate = 1.1;
        assert!(settings.validate().is_err());
        settings.rate = 1.0;
        settings.volume = f64::NAN;
        assert!(settings.validate().is_err());
    }
}
