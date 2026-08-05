//! Built-in `ohos.node` surface plugin.
//!
//! This is the normalized replacement for the former WebView-mode dichotomy and the old slot
//! registry: every session has exactly one root `FrameNode` tree, and plugins (WebView included)
//! are just FrameNode providers. Rust composes that tree through opaque handles — `FrameNode`
//! values themselves never cross the N-API boundary.
//!
//! The ArkTS half lives in `BridgeHost` (`native_ability`) and is installed automatically ahead
//! of business plugins, so no registration or factory is required on either side.

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};

use crate::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement, BridgePlugin,
    BridgeRuntime,
};

/// Plugin identity shared with the ArkTS built-in surface plugin.
pub const NODE_SURFACE_PLUGIN_ID: &str = "ohos.node";

/// Window surface key the default window registers under.
pub const MAIN_WINDOW_KEY: &str = "main";

/// Window-scoped request marker for `create-container`: the response carries the new handle.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct NodeCreateContainerRequest {
    /// Window surface key; defaults to `"main"`.
    pub window_key: Option<String>,
}

impl_bridge_napi_type!(
    NodeCreateContainerRequest,
    "ohos.node.CreateContainerRequest"
);

/// Appends the node of `child_handle` under the node of `parent_handle`.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct NodeAppendChildRequest {
    pub parent_handle: u32,
    pub child_handle: u32,
    /// Window surface key; defaults to `"main"`. Parent and child must share the same window.
    pub window_key: Option<String>,
}

impl_bridge_napi_type!(NodeAppendChildRequest, "ohos.node.AppendChildRequest");

/// Appends a handle-owned node to the window root.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct NodeMountIntoRootRequest {
    pub handle: u32,
    /// Window surface key; defaults to `"main"`.
    pub window_key: Option<String>,
}

impl_bridge_napi_type!(NodeMountIntoRootRequest, "ohos.node.MountIntoRootRequest");

/// Detaches a handle-owned node from its parent and disposes it.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct NodeDisposeRequest {
    pub handle: u32,
    /// Window surface key; defaults to `"main"`.
    pub window_key: Option<String>,
}

impl_bridge_napi_type!(NodeDisposeRequest, "ohos.node.DisposeRequest");

/// Opaque handle of a container `FrameNode` created in ArkTS.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct NodeHandleResponse {
    pub handle: u32,
}

impl_bridge_napi_type!(NodeHandleResponse, "ohos.node.HandleResponse");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct NodeAcknowledgement {
    pub accepted: bool,
}

impl_bridge_napi_type!(NodeAcknowledgement, "ohos.node.Acknowledgement");

impl NodeAcknowledgement {
    fn ensure(self) -> Result<()> {
        if self.accepted {
            Ok(())
        } else {
            Err(Error::from_reason(
                "ohos.node plugin rejected the requested node operation",
            ))
        }
    }
}

/// Rust facade marker for the built-in `ohos.node` plugin. It is installed automatically by the
/// ArkTS `BridgeHost`, so it is never registered through [`BridgePlugin`] registration on the
/// Rust side; outbound calls only use its identity.
pub struct NodeSurfaceBridgePlugin;

impl BridgePlugin for NodeSurfaceBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = NODE_SURFACE_PLUGIN_ID;
    const VERSION: u32 = 1;
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::UiContext];
}

/// Outbound facade for composing the session FrameNode tree from Rust.
#[derive(Clone)]
pub struct NodeSurface {
    bridge: BridgeRuntime,
}

impl NodeSurface {
    pub(crate) fn new(bridge: BridgeRuntime) -> Self {
        Self { bridge }
    }

    /// Creates an empty container `FrameNode` in the main window and returns its opaque handle.
    pub async fn create_container(&self) -> Result<u32> {
        self.create_container_in_window(None).await
    }

    /// Creates an empty container `FrameNode` in `window_key` and returns its opaque handle.
    pub async fn create_container_in_window(&self, window_key: Option<&str>) -> Result<u32> {
        let response = self
            .bridge
            .call_async::<NodeSurfaceBridgePlugin, NodeCreateContainerRequest, NodeHandleResponse>(
                "create-container",
                NodeCreateContainerRequest {
                    window_key: window_key.map(str::to_owned),
                },
                BridgeCallOptions::default(),
            )
            .await?;
        Ok(response.handle)
    }

    /// Appends the node of `child_handle` under the node of `parent_handle` (main window).
    pub async fn append_child(&self, parent_handle: u32, child_handle: u32) -> Result<()> {
        self.append_child_in_window(None, parent_handle, child_handle)
            .await
    }

    /// Appends the node of `child_handle` under the node of `parent_handle` in `window_key`.
    pub async fn append_child_in_window(
        &self,
        window_key: Option<&str>,
        parent_handle: u32,
        child_handle: u32,
    ) -> Result<()> {
        self.bridge
            .call_async::<NodeSurfaceBridgePlugin, NodeAppendChildRequest, NodeAcknowledgement>(
                "append-child",
                NodeAppendChildRequest {
                    parent_handle,
                    child_handle,
                    window_key: window_key.map(str::to_owned),
                },
                BridgeCallOptions::default(),
            )
            .await?
            .ensure()
    }

    /// Appends a handle-owned node to the main window root.
    pub async fn mount_into_root(&self, handle: u32) -> Result<()> {
        self.mount_into_root_in_window(None, handle).await
    }

    /// Appends a handle-owned node to the `window_key` root.
    pub async fn mount_into_root_in_window(
        &self,
        window_key: Option<&str>,
        handle: u32,
    ) -> Result<()> {
        self.bridge
            .call_async::<NodeSurfaceBridgePlugin, NodeMountIntoRootRequest, NodeAcknowledgement>(
                "mount-into-root",
                NodeMountIntoRootRequest {
                    handle,
                    window_key: window_key.map(str::to_owned),
                },
                BridgeCallOptions::default(),
            )
            .await?
            .ensure()
    }

    /// Detaches a handle-owned node from its parent and disposes it (main window).
    pub async fn dispose(&self, handle: u32) -> Result<()> {
        self.dispose_in_window(None, handle).await
    }

    /// Detaches a handle-owned node in `window_key` from its parent and disposes it.
    pub async fn dispose_in_window(&self, window_key: Option<&str>, handle: u32) -> Result<()> {
        self.bridge
            .call_async::<NodeSurfaceBridgePlugin, NodeDisposeRequest, NodeAcknowledgement>(
                "dispose",
                NodeDisposeRequest {
                    handle,
                    window_key: window_key.map(str::to_owned),
                },
                BridgeCallOptions::default(),
            )
            .await?
            .ensure()
    }
}

/// Convenience accessor: `app.node()` returns the outbound surface facade.
pub trait NodeExt {
    fn node(&self) -> Result<NodeSurface>;
}

impl NodeExt for crate::OpenHarmonyApp {
    fn node(&self) -> Result<NodeSurface> {
        Ok(NodeSurface::new(self.bridge()?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::BridgeNapiType;

    #[test]
    fn node_actions_have_named_napi_contracts() {
        assert_eq!(
            <NodeCreateContainerRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.node.CreateContainerRequest"
        );
        assert_eq!(
            <NodeAppendChildRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.node.AppendChildRequest"
        );
        assert_eq!(
            <NodeMountIntoRootRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.node.MountIntoRootRequest"
        );
        assert_eq!(
            <NodeDisposeRequest as BridgeNapiType>::TYPE_NAME,
            "ohos.node.DisposeRequest"
        );
        assert_eq!(
            <NodeHandleResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.node.HandleResponse"
        );
        assert_eq!(
            <NodeAcknowledgement as BridgeNapiType>::TYPE_NAME,
            "ohos.node.Acknowledgement"
        );
    }

    #[test]
    fn plugin_identity_is_the_builtin_contract() {
        assert_eq!(NodeSurfaceBridgePlugin::ID, "ohos.node");
        assert_eq!(NodeSurfaceBridgePlugin::VERSION, 1);
        assert_eq!(
            NodeSurfaceBridgePlugin::REQUIRED_CONTEXTS,
            &[BridgeContextRequirement::UiContext]
        );
    }
}
