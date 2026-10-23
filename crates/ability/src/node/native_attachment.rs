//! Named, side-effect-free decoding of the native attachment handshake.

use crate::{impl_bridge_napi_type, BridgeMainThreadEvent};
use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{FromNapiValue, Object},
    Result,
};

use super::NativeAttachment;

/// Identifies a ready FrameNode. Decoding never attaches it.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct NativeNodeReady {
    pub target_id: u32,
}

impl_bridge_napi_type!(NativeNodeReady, "ohos.node.NativeNodeReady");

impl NativeNodeReady {
    /// Explicitly consumes the callback-scoped FrameNode and retains it in its target.
    pub fn attach(self, event: &BridgeMainThreadEvent<'_>) -> Result<()> {
        if event.decode::<Self>()?.target_id != self.target_id {
            return Err(napi_ohos::Error::from_reason(
                "NativeNodeReady target does not match its event",
            ));
        }
        let (env, value) = event.request_value();
        let object = Object::from_unknown(value)?;
        let content: Object<'_> = object.get("content")?.ok_or_else(|| {
            napi_ohos::Error::from_reason("NativeNodeReady is missing its FrameNode content")
        })?;
        NativeAttachment::attach(env, self.target_id, &content)
    }
}

/// Identifies a ready wrapper and NodeContent slot. Decoding never mounts either one.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct NativeSubtreeReady {
    pub target_id: u32,
}

impl_bridge_napi_type!(NativeSubtreeReady, "ohos.node.NativeSubtreeReady");

impl NativeSubtreeReady {
    pub fn attach(self, event: &BridgeMainThreadEvent<'_>) -> Result<()> {
        if event.decode::<Self>()?.target_id != self.target_id {
            return Err(napi_ohos::Error::from_reason(
                "NativeSubtreeReady target does not match its event",
            ));
        }
        let (env, value) = event.request_value();
        let object = Object::from_unknown(value)?;
        let content: Object<'_> = object.get("content")?.ok_or_else(|| {
            napi_ohos::Error::from_reason("NativeSubtreeReady is missing its FrameNode content")
        })?;
        let slot: Object<'_> = object.get("slot")?.ok_or_else(|| {
            napi_ohos::Error::from_reason("NativeSubtreeReady is missing its NodeContent slot")
        })?;
        NativeAttachment::attach_subtree(env, self.target_id, &content, &slot)
    }
}

/// Synchronous notification before an ArkTS owner disposes its content.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct NativeNodeRetiring {
    pub target_id: u32,
}

impl_bridge_napi_type!(NativeNodeRetiring, "ohos.node.NativeNodeRetiring");

impl NativeNodeRetiring {
    pub fn detach(self) -> Result<()> {
        NativeAttachment::retire(self.target_id)
    }
}
