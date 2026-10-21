//! Callback-scoped native-node interop. No ArkTS reference leaves decoding.
use crate::{impl_bridge_napi_type, BridgeNapiType};
use napi_derive_ohos::napi;
use napi_ohos::{
    bindgen_prelude::{FromNapiValue, Object, Unknown},
    Env, Error, JsValue, Result,
};
use ohos_arkui_binding::component::native_attachment::NativeAttachment;

/// Receipt of an inbound `ohos.node.NativeNodeReady { targetId, content }`.
/// Decoding synchronously consumes the borrowed FrameNode, attaches it to
/// the UI-thread binding target and keeps only this boolean acknowledgement.
pub struct NativeNodeReady {
    accepted: bool,
}

/// Callback-scoped receipt of an ArkTS wrapper and its NodeContent slot.
/// Only native handles remain after decoding; neither ArkTS object escapes.
pub struct NativeSubtreeReady {
    accepted: bool,
}
impl NativeSubtreeReady {
    /// Whether the current native generation accepted its wrapper.
    pub fn accepted(self) -> bool {
        self.accepted
    }
}
impl BridgeNapiType for NativeSubtreeReady {
    const TYPE_NAME: &'static str = "ohos.node.NativeSubtreeReady";
    fn into_bridge_value<'env>(self, _: &'env Env) -> Result<Unknown<'env>> {
        Err(Error::from_reason("NativeSubtreeReady is inbound-only"))
    }
    fn from_bridge_value(value: Unknown<'_>) -> Result<Self> {
        let raw = value.value();
        let env = Env::from_raw(raw.env);
        let object = Object::from_unknown(value)?;
        let id: u32 = object
            .get("targetId")?
            .ok_or_else(|| Error::from_reason("missing targetId"))?;
        let content: Object<'_> = object
            .get("content")?
            .ok_or_else(|| Error::from_reason("missing content"))?;
        let slot: Object<'_> = object
            .get("slot")?
            .ok_or_else(|| Error::from_reason("missing slot"))?;
        Ok(Self {
            // SAFETY: the paired wrapper owner retains its BuilderNode and NodeContent until retirement.
            accepted: unsafe { NativeAttachment::attach_subtree(&env, id, &content, &slot) }?,
        })
    }
}
impl NativeNodeReady {
    /// Whether the target was live and accepted the content.
    pub fn accepted(self) -> bool {
        self.accepted
    }
}
impl BridgeNapiType for NativeNodeReady {
    const TYPE_NAME: &'static str = "ohos.node.NativeNodeReady";
    fn into_bridge_value<'env>(self, _: &'env Env) -> Result<Unknown<'env>> {
        Err(Error::from_reason("NativeNodeReady is inbound-only"))
    }
    fn from_bridge_value(value: Unknown<'_>) -> Result<Self> {
        let raw = value.value();
        let env = Env::from_raw(raw.env);
        let object = Object::from_unknown(value)?;
        let id: u32 = object
            .get("targetId")?
            .ok_or_else(|| Error::from_reason("missing targetId"))?;
        let content: Object<'_> = object
            .get("content")?
            .ok_or_else(|| Error::from_reason("missing content"))?;
        Ok(Self {
            // SAFETY: native-embedding plugins retain the BuilderNode and
            // release it only after synchronous retirement succeeds.
            accepted: unsafe { NativeAttachment::attach(&env, id, &content) }?,
        })
    }
}
/// Synchronous notification before an external node owner disposes it.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct NativeNodeRetiring {
    /// Opaque target returned by the native UI-thread attachment registry.
    pub target_id: u32,
}
impl_bridge_napi_type!(NativeNodeRetiring, "ohos.node.NativeNodeRetiring");
impl NativeNodeRetiring {
    /// Detaches the native child before returning to its ArkTS owner.
    pub fn detach(self) -> Result<()> {
        NativeAttachment::retire(self.target_id)
    }
}
