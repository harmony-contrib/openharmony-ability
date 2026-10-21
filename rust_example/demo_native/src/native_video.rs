//! Native attachment assembly. The UI thread retains the node owner; workers only use the client.
use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{Object, Uint8Array},
    Env, Error, Result,
};
use openharmony_ability::arkui::component::{
    attribute::ArkUICommonAttribute, built_in_component::Column,
};
use openharmony_ability::{ContentRoot, NativeAttachment};
use openharmony_ability_plugin_video::{
    VideoBytesRequest, VideoClient, VideoCommandRequest, VideoCreateRequest, VideoEvents,
    VideoSettings,
};
use std::{
    cell::RefCell,
    rc::Rc,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};
const ID: &str = "demo.native-video";
#[derive(Default)]
struct Playback {
    created: AtomicBool,
    busy: AtomicBool,
}
struct Owner {
    _events: VideoEvents,
    attachment: NativeAttachment,
    content: ContentRoot,
    playback: Arc<Playback>,
}
thread_local! { static OWNER: RefCell<Option<Owner>> = RefCell::default(); }
fn platform_error(error: impl std::fmt::Display) -> Error {
    Error::from_reason(error.to_string())
}
/// Allocates one video target and returns its parent for a normal ContentSlot.
#[napi]
pub fn demo_native_video(env: &Env) -> Result<Object<'_>> {
    let app = super::current_app()?;
    OWNER.with(|slot| {
        if slot.borrow().is_none() {
            let parent = Column::new().map_err(platform_error)?;
            parent.width(320.0).map_err(platform_error)?;
            parent.height(180.0).map_err(platform_error)?;
            let parent = parent.into_node();
            let attachment = NativeAttachment::new(&parent)?;
            let events = VideoEvents::new(&app, ID.into(), attachment.id(), |event| {
                log::info!(
                    "native video {}: {} / {}",
                    event.phase,
                    event.current_time,
                    event.duration
                );
            })?;
            let mut content = ContentRoot::new(Env::from_raw(env.raw()))?;
            content.mount(Rc::clone(&parent)).map_err(platform_error)?;
            *slot.borrow_mut() = Some(Owner {
                content,
                attachment,
                _events: events,
                playback: Arc::default(),
            });
        }
        slot.borrow()
            .as_ref()
            .expect("stored video")
            .content
            .object(env)
    })
}
async fn ensure_created(client: &VideoClient, target_id: u32) -> Result<()> {
    client
        .create(VideoCreateRequest {
            target_id,
            settings: VideoSettings {
                id: ID.into(),
                paused: false,
                muted: false,
                volume: 1.0,
                rate: 1.0,
                repeat: true,
                resize_mode: "contain".into(),
                controls: true,
                progress_interval_ms: 250.0,
            },
        })
        .await
}
/// Creates the player on first load and starts the supplied media URL.
#[napi]
pub fn demo_load_native_video(
    source: String,
) -> Result<napi_ohos::bindgen_prelude::AsyncTask<LoadVideo>> {
    load_task(Some(source), None)
}
/// Creates the player on first load and starts an owned raw resource.
#[napi]
pub fn demo_native_video_bytes(
    bytes: Uint8Array,
) -> Result<napi_ohos::bindgen_prelude::AsyncTask<LoadVideo>> {
    load_task(None, Some(bytes.to_vec()))
}
fn load_task(
    source: Option<String>,
    bytes: Option<Vec<u8>>,
) -> Result<napi_ohos::bindgen_prelude::AsyncTask<LoadVideo>> {
    let (target_id, playback) = OWNER
        .with(|slot| {
            slot.borrow()
                .as_ref()
                .map(|owner| (owner.attachment.id(), owner.playback.clone()))
        })
        .ok_or_else(|| Error::from_reason("Create the video ContentSlot first"))?;
    let client = VideoClient::new(&super::current_app()?)?;
    if playback.busy.swap(true, Ordering::AcqRel) {
        return Err(Error::from_reason("Video operation in progress"));
    }
    Ok(napi_ohos::bindgen_prelude::AsyncTask::new(LoadVideo {
        client,
        target_id,
        source,
        bytes,
        playback,
        dispose: false,
    }))
}
/// Worker operation containing only owned requests and the worker-safe bridge.
pub struct LoadVideo {
    client: VideoClient,
    target_id: u32,
    source: Option<String>,
    bytes: Option<Vec<u8>>,
    playback: Arc<Playback>,
    dispose: bool,
}
impl napi_ohos::Task for LoadVideo {
    type Output = ();
    type JsValue = ();
    fn compute(&mut self) -> Result<()> {
        let result = futures_executor::block_on(async {
            if self.dispose {
                if self.playback.created.load(Ordering::Acquire) {
                    self.client
                        .command(
                            "dispose",
                            VideoCommandRequest {
                                id: ID.into(),
                                source: None,
                                value: None,
                            },
                        )
                        .await?;
                    self.playback.created.store(false, Ordering::Release);
                }
                return Ok(());
            }
            if !self.playback.created.load(Ordering::Acquire) {
                ensure_created(&self.client, self.target_id).await?;
                self.playback.created.store(true, Ordering::Release);
            }
            if let Some(bytes) = self.bytes.take() {
                self.client
                    .set_bytes(VideoBytesRequest {
                        id: ID.into(),
                        bytes,
                    })
                    .await
            } else {
                self.client
                    .command(
                        "set-source",
                        VideoCommandRequest {
                            id: ID.into(),
                            source: self.source.take(),
                            value: None,
                        },
                    )
                    .await
            }
        });
        self.playback.busy.store(false, Ordering::Release);
        result
    }
    fn resolve(&mut self, _: Env, _: ()) -> Result<()> {
        Ok(())
    }
}
/// Detaches and releases the player; its target stays owned for another load.
#[napi]
pub fn demo_dispose_native_video() -> Result<napi_ohos::bindgen_prelude::AsyncTask<LoadVideo>> {
    let playback = OWNER
        .with(|slot| slot.borrow().as_ref().map(|owner| owner.playback.clone()))
        .ok_or_else(|| Error::from_reason("Create the video ContentSlot first"))?;
    let client = VideoClient::new(&super::current_app()?)?;
    if playback.busy.swap(true, Ordering::AcqRel) {
        return Err(Error::from_reason("Video operation in progress"));
    }
    Ok(napi_ohos::bindgen_prelude::AsyncTask::new(LoadVideo {
        client,
        target_id: 0,
        source: None,
        bytes: None,
        playback,
        dispose: true,
    }))
}
