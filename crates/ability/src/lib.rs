mod app;
mod area;
mod bridge;
mod configuration;
mod draw;
mod event;
mod input;
mod lifecycle;
mod log;
mod memory;
mod node;
mod render;
mod stage;
mod waker;

// Application-facing API.
pub use app::{AbilityInitContext, OpenHarmonyApp, SaveLoader, SaveSaver};
pub use area::{
    AvoidArea, AvoidAreaInfo, AvoidAreaType, ContentRect, Rect, RectChangeReason, Size,
};
pub use bridge::{
    AsyncBridge, BridgeCallOptions, BridgeClient, BridgeContextRequirement, BridgeExecution,
    BridgeMainThread, BridgeMainThreadEvent, BridgeNapiType, BridgePlugin, BridgePluginDeclaration,
    BridgePluginMode, BridgeRuntime, MainThreadScheduler, MainThreadSyncBridge,
    PluginLifecycleEvent,
};
pub use configuration::{ColorMode, Configuration, Direction, ScreenDensity};
pub use draw::IntervalInfo;
pub use event::Event;
pub use input::{ImeEvent, InputEvent, TextInputEventData};
pub use memory::MemoryLevel;
pub use node::{
    NodeAcknowledgement, NodeAppendChildRequest, NodeCreateContainerRequest, NodeDisposeRequest,
    NodeExt, NodeHandleResponse, NodeMountIntoRootRequest, NodeSurface, NodeSurfaceBridgePlugin,
    NODE_SURFACE_PLUGIN_ID,
};
pub use stage::StageEventType;
pub use waker::OpenHarmonyWaker;

// Framework wiring consumed by `#[ability]`-generated code; not part of the application API.
#[doc(hidden)]
pub use bridge::attach_bridge_session;
#[doc(hidden)]
pub use lifecycle::{
    create_lifecycle_handle, ApplicationLifecycle, EnvironmentCallback, KeyboardCallback,
    WindowStageEventCallback,
};
#[doc(hidden)]
pub use render::render;

/// Re-exported for [`impl_bridge_napi_type!`](crate::impl_bridge_napi_type) expansions in
/// application/plugin crates.
#[doc(hidden)]
pub use napi_ohos;

// re-export arkui and avoid the need to import it in the lib.rs
pub use ohos_arkui_binding as arkui;
pub use ohos_ime_binding as ime;
pub use ohos_xcomponent_binding as xcomponent;
