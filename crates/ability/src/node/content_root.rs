//! A UI-thread NodeContent owner for a native root hosted by an ArkTS ContentSlot.

use std::{cell::RefCell, rc::Rc};

#[cfg(target_env = "ohos")]
use napi_ohos::{
    bindgen_prelude::{FromNapiValue, Function},
    JsValue,
};
use napi_ohos::{
    bindgen_prelude::{Object, ObjectRef},
    Env, Result,
};
use ohos_arkui_binding::{
    api::node_content::NodeContent,
    common::{error::ArkUIResult, node::ArkUINode},
    RootNode,
};

/// Owns the platform object, native root and window listener on the creating UI thread.
///
/// Retire native attachments before unmounting or dropping `ContentRoot`. In owner structs,
/// declare event subscriptions and `NativeAttachment` before `ContentRoot` so Rust drops them first.
pub struct ContentRoot {
    owner: Option<ContentOwner>,
}

struct ContentOwner {
    root: RootNode,
    events: NodeContent,
    value: Option<ObjectRef>,
    env: Env,
}

impl ContentRoot {
    #[cfg(not(target_env = "ohos"))]
    pub fn new(_env: Env) -> Result<Self> {
        Err(napi_ohos::Error::from_reason(
            "ContentRoot requires an OpenHarmony N-API environment",
        ))
    }

    #[cfg(target_env = "ohos")]
    pub fn new(env: Env) -> Result<Self> {
        let module = env.load("@ohos.arkui.node")?;
        let constructor: Function<'_, (), Object<'_>> = module.get("NodeContent")?;
        let value = constructor.new_instance(())?;
        // SAFETY: the system constructor returned a live NodeContent in this callback.
        let object = unsafe { Object::from_napi_value(env.raw(), value.raw()) }?;
        // SAFETY: the live object belongs to this callback; it is retained below
        // before any native root or event callback can use the handle.
        let handle =
            unsafe { ohos_arkui_binding::ArkUIHandle::from_napi_value(env.raw(), object.raw()) }?;
        let value = object.create_ref()?;
        Ok(Self {
            owner: Some(ContentOwner {
                root: RootNode::new(handle),
                events: NodeContent::from_handle(handle),
                value: Some(value),
                env,
            }),
        })
    }

    pub fn object<'env>(&self, env: &'env Env) -> Result<Object<'env>> {
        let owner = self.owner.as_ref().expect("live ContentRoot");
        if owner.env.raw() != env.raw() {
            return Err(napi_ohos::Error::from_reason(
                "ContentRoot belongs to another N-API environment",
            ));
        }
        owner
            .value
            .as_ref()
            .expect("retained NodeContent")
            .get_value(env)
    }

    pub fn mount(&mut self, node: Rc<RefCell<ArkUINode>>) -> ArkUIResult<()> {
        self.owner
            .as_mut()
            .expect("live ContentRoot")
            .root
            .mount_node(node)
    }

    pub fn unmount(&mut self) -> ArkUIResult<()> {
        self.owner
            .as_mut()
            .expect("live ContentRoot")
            .root
            .unmount()
    }

    pub fn on_window_change(&mut self, callback: impl Fn(bool) + 'static) -> ArkUIResult<()> {
        self.owner
            .as_mut()
            .expect("live ContentRoot")
            .events
            .register_callback(move |event| {
                callback(
                    event.event_type()
                        == ohos_arkui_binding::types::advanced::NodeContentEventType::OnAttachToWindow,
                );
            })
    }

    pub fn clear_window_callback(&mut self) -> ArkUIResult<()> {
        self.owner
            .as_mut()
            .expect("live ContentRoot")
            .events
            .clear_callback()
    }
}

impl Drop for ContentRoot {
    fn drop(&mut self) {
        let Some(mut owner) = self.owner.take() else {
            return;
        };
        if let Err(error) = owner
            .events
            .clear_callback()
            .and_then(|()| owner.root.unmount())
        {
            crate::error!("Failed to retire ContentRoot; retaining its native owners: {error}");
            std::mem::forget(owner);
            return;
        }
        if let Some(value) = owner.value.take() {
            if let Err(error) = value.unref(&owner.env) {
                crate::error!("Failed to release ContentRoot reference: {error}");
            }
        }
    }
}
