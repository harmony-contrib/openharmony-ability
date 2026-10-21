//! UI-thread ownership of ArkTS content attached to native node trees.

use std::{
    cell::{Cell, RefCell},
    collections::BTreeMap,
    rc::Rc,
    sync::atomic::AtomicU32,
};

use napi_ohos::{
    bindgen_prelude::{FromNapiValue, Object, ObjectRef},
    Env, Error, JsValue, Result,
};
use ohos_arkui_binding::{
    api::node_content::NodeContent,
    common::{
        node::{ArkUINode, ArkUINodeRaw},
        node_retention::NodeRetention,
    },
    component::attribute::ArkUICommonAttribute,
    ArkUIHandle,
};

use super::attachment_state::{allocate_id, Active, AttachmentState};

static NEXT_TARGET_ID: AtomicU32 = AtomicU32::new(1);

thread_local! {
    static TARGETS: RefCell<BTreeMap<u32, Rc<Target>>> = RefCell::default();
}

struct RetainedContent {
    env: Env,
    frame: Option<ObjectRef>,
    slot: Option<ObjectRef>,
}

impl RetainedContent {
    fn new(env: &Env, frame: &Object<'_>, slot: Option<&Object<'_>>) -> Result<Self> {
        let mut retained = Self {
            env: *env,
            frame: Some(frame.create_ref()?),
            slot: None,
        };
        retained.slot = slot.map(Object::create_ref).transpose()?;
        Ok(retained)
    }
}

impl Drop for RetainedContent {
    fn drop(&mut self) {
        for reference in [self.slot.take(), self.frame.take()].into_iter().flatten() {
            if let Err(error) = reference.unref(&self.env) {
                crate::error!("Failed to release native attachment reference: {error}");
            }
        }
    }
}

struct Target {
    id: u32,
    state: AttachmentState,
    parent: Rc<RefCell<ArkUINode>>,
    parent_retention: RefCell<Option<NodeRetention>>,
    child: RefCell<Option<Rc<RefCell<ArkUINode>>>>,
    inner: Option<Rc<RefCell<ArkUINode>>>,
    inner_retention: RefCell<Option<NodeRetention>>,
    inner_receiver_active: Cell<bool>,
    slot: Cell<Option<ArkUIHandle>>,
    retained: RefCell<Option<RetainedContent>>,
}

impl Target {
    fn begin(&self) -> Result<Active<'_>> {
        self.state.begin().map_err(|error| {
            Error::from_reason(format!("Native attachment target {} {error}", self.id))
        })
    }

    fn detach_inner(&self) -> Result<()> {
        if let (Some(handle), Some(inner)) = (self.slot.get(), self.inner.as_ref()) {
            if self.inner_receiver_active.get() {
                inner
                    .borrow()
                    .remove_event_receiver()
                    .map_err(|error| Error::from_reason(error.to_string()))?;
                self.inner_receiver_active.set(false);
            }
            NodeContent::from_handle(handle)
                .remove_node(&inner.borrow())
                .map_err(|error| Error::from_reason(error.to_string()))?;
            self.slot.set(None);
            ohos_arkui_binding::common::node_registry::unregister(&inner.borrow());
        }
        if let Some(child) = self.child.borrow().clone() {
            let mut parent = self.parent.borrow_mut();
            let index = parent
                .children()
                .iter()
                .position(|node| Rc::ptr_eq(node, &child));
            let native_parent = child
                .borrow()
                .parent()
                .map_err(|error| Error::from_reason(error.to_string()))?;
            if let Some(native_parent) = native_parent {
                if native_parent != parent.raw_handle() {
                    return Err(Error::from_reason(
                        "Native attachment was reparented outside its target",
                    ));
                }
                if let Some(index) = index {
                    parent
                        .remove_child(index)
                        .map_err(|error| Error::from_reason(error.to_string()))?;
                } else {
                    child
                        .borrow()
                        .remove_from_parent()
                        .map_err(|error| Error::from_reason(error.to_string()))?;
                }
            } else if let Some(index) = index {
                parent.children_mut().remove(index);
            }
        }
        self.child.borrow_mut().take();
        self.retained.borrow_mut().take();
        Ok(())
    }

    fn retire(&self) -> Result<()> {
        // A failed detachment still closes admission, but preserves all native owners for retry.
        let _active = self.state.begin_retire().map_err(|error| {
            Error::from_reason(format!("Native attachment target {} {error}", self.id))
        })?;
        self.detach_inner()?;
        self.inner_retention.borrow_mut().take();
        self.parent_retention.borrow_mut().take();
        TARGETS.with(|targets| targets.borrow_mut().remove(&self.id));
        Ok(())
    }
}

fn target(id: u32) -> Result<Rc<Target>> {
    TARGETS
        .with(|targets| targets.borrow().get(&id).cloned())
        .ok_or_else(|| Error::from_reason(format!("Unknown native attachment target {id}")))
}

/// The single UI-thread owner of an externally constructed native subtree.
///
/// Target IDs are monotonically allocated and never reused, including across sessions.
/// This type is neither `Send` nor `Sync`; create, attach, dispatch and retire on the UI thread.
pub struct NativeAttachment(Rc<Target>);

impl NativeAttachment {
    pub fn new(parent: &Rc<RefCell<ArkUINode>>) -> Result<Self> {
        Self::create(parent, None)
    }

    pub fn for_subtree(
        parent: &Rc<RefCell<ArkUINode>>,
        inner: &Rc<RefCell<ArkUINode>>,
    ) -> Result<Self> {
        if Rc::ptr_eq(parent, inner) {
            return Err(Error::from_reason(
                "A subtree attachment needs distinct owned nodes",
            ));
        }
        Self::create(parent, Some(inner.clone()))
    }

    fn create(
        parent: &Rc<RefCell<ArkUINode>>,
        inner: Option<Rc<RefCell<ArkUINode>>>,
    ) -> Result<Self> {
        let parent_retention = parent
            .borrow()
            .retain_native()
            .map_err(|error| Error::from_reason(error.to_string()))?;
        let inner_retention = inner
            .as_ref()
            .map(|inner| {
                inner
                    .borrow()
                    .retain_native()
                    .map_err(|error| Error::from_reason(error.to_string()))
            })
            .transpose()?;
        let id = allocate_id(&NEXT_TARGET_ID)
            .ok_or_else(|| Error::from_reason("Native attachment IDs exhausted"))?;
        let target = Rc::new(Target {
            id,
            state: AttachmentState::default(),
            parent: parent.clone(),
            parent_retention: RefCell::new(Some(parent_retention)),
            child: RefCell::default(),
            inner,
            inner_retention: RefCell::new(inner_retention),
            inner_receiver_active: Cell::new(false),
            slot: Cell::new(None),
            retained: RefCell::default(),
        });
        TARGETS.with(|targets| targets.borrow_mut().insert(id, target.clone()));
        Ok(Self(target))
    }

    pub fn id(&self) -> u32 {
        self.0.id
    }

    /// Runs a platform callback under the same guard as attachment and retirement.
    /// A retired, unknown, or re-entrant target returns an explicit error without dispatch.
    pub fn dispatch<R>(id: u32, callback: impl FnOnce() -> R) -> Result<R> {
        let target = target(id)?;
        let _active = target.begin()?;
        if target.child.borrow().is_none() {
            return Err(Error::from_reason(format!(
                "Native attachment target {id} is not attached"
            )));
        }
        Ok(callback())
    }

    pub fn with_child<R>(&self, callback: impl FnOnce(&ArkUINode) -> R) -> Result<Option<R>> {
        let _active = self.0.begin()?;
        let child = self.0.child.borrow().clone();
        Ok(child.map(|child| callback(&child.borrow())))
    }

    /// Attaches and strongly retains the FrameNode until retirement succeeds.
    pub fn attach(env: &Env, id: u32, content: &Object<'_>) -> Result<()> {
        Self::attach_content(env, id, content, None)
    }

    /// Retains both the wrapper FrameNode and its NodeContent slot.
    pub fn attach_subtree(
        env: &Env,
        id: u32,
        content: &Object<'_>,
        slot: &Object<'_>,
    ) -> Result<()> {
        Self::attach_content(env, id, content, Some(slot))
    }

    fn attach_content(
        env: &Env,
        id: u32,
        content: &Object<'_>,
        slot: Option<&Object<'_>>,
    ) -> Result<()> {
        let target = target(id)?;
        let _active = target.begin()?;
        if target.child.borrow().is_some() {
            return Err(Error::from_reason("Native attachment is already occupied"));
        }
        if slot.is_some() != target.inner.is_some() {
            return Err(Error::from_reason(
                "Native attachment subtree does not match its registered target",
            ));
        }
        let retained = RetainedContent::new(env, content, slot)?;
        // SAFETY: conversion is scoped to this active N-API callback; `retained`
        // keeps the FrameNode alive until after the native edge is detached.
        let raw = unsafe { ArkUINodeRaw::from_napi_value(env.raw(), content.raw()) }?;
        // SAFETY: the target retains the FrameNode and never disposes its borrowed native node.
        let child = Rc::new(RefCell::new(
            unsafe { raw.borrowed_node() }
                .map_err(|error| Error::from_reason(error.to_string()))?,
        ));
        let handle = slot
            .map(|slot| {
                // SAFETY: the retained NodeContent belongs to this callback's N-API environment.
                unsafe { ArkUIHandle::from_napi_value(env.raw(), slot.raw()) }
            })
            .transpose()?;
        if let Some(inner) = target.inner.as_ref() {
            inner
                .borrow()
                .remove_event_receiver()
                .map_err(|error| Error::from_reason(error.to_string()))?;
            if let Err(error) = inner.borrow().remove_from_parent() {
                if let Err(restore_error) = inner.borrow().add_event_receiver() {
                    crate::error!(
                        "Failed to restore native subtree event receiver: {restore_error}"
                    );
                }
                return Err(Error::from_reason(error.to_string()));
            }
            target
                .parent
                .borrow_mut()
                .children_mut()
                .retain(|child| !Rc::ptr_eq(child, inner));
        }
        target
            .parent
            .borrow_mut()
            .add_existing_node(child.clone())
            .map_err(|error| Error::from_reason(error.to_string()))?;
        *target.child.borrow_mut() = Some(child);
        *target.retained.borrow_mut() = Some(retained);
        if let (Some(handle), Some(inner)) = (handle, target.inner.as_ref()) {
            if let Err(error) = NodeContent::from_handle(handle).add_node(&inner.borrow()) {
                target.detach_inner()?;
                return Err(Error::from_reason(error.to_string()));
            }
            target.slot.set(Some(handle));
            if let Err(error) =
                ohos_arkui_binding::common::node_registry::register(&inner.borrow(), inner.clone())
                    .and_then(|()| inner.borrow().add_event_receiver())
            {
                target.detach_inner()?;
                return Err(Error::from_reason(error.to_string()));
            }
            target.inner_receiver_active.set(true);
        }
        Ok(())
    }

    /// Permanently retires the target. Failure preserves its references for a UI-thread retry.
    pub fn retire(id: u32) -> Result<()> {
        target(id)?.retire()
    }

    /// Whether native detachment completed successfully.
    ///
    /// Closing callback admission after a failed retirement does not count as
    /// completion. The parent guard is released only after all native edges and
    /// retained platform content have been removed successfully.
    pub fn is_retired(&self) -> bool {
        self.0.state.is_retired() && self.0.parent_retention.borrow().is_none()
    }

    pub fn invalidate(&self) -> Result<()> {
        self.0.retire()
    }

    pub fn detach(&self) -> Result<()> {
        self.invalidate()
    }
}

impl Drop for NativeAttachment {
    fn drop(&mut self) {
        if let Err(error) = self.invalidate() {
            crate::error!("Failed to retire native attachment {}: {error}", self.id());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_targets_never_dispatch() {
        let mut dispatched = false;
        assert!(NativeAttachment::dispatch(0, || dispatched = true).is_err());
        assert!(!dispatched);
        assert!(NativeAttachment::retire(0).is_err());
    }

    #[test]
    fn retirement_is_guarded_and_permanently_closes_callback_admission() {
        let id = allocate_id(&NEXT_TARGET_ID).unwrap();
        let target = Rc::new(Target {
            id,
            state: AttachmentState::default(),
            parent: Rc::new(RefCell::new(ArkUINode::default())),
            parent_retention: RefCell::default(),
            child: RefCell::default(),
            inner: None,
            inner_retention: RefCell::default(),
            inner_receiver_active: Cell::new(false),
            slot: Cell::new(None),
            retained: RefCell::default(),
        });
        TARGETS.with(|targets| targets.borrow_mut().insert(id, target.clone()));
        let attachment = NativeAttachment(target.clone());
        assert!(!attachment.is_retired());
        {
            let _callback = target.begin().unwrap();
            assert!(NativeAttachment::retire(id).is_err());
            assert!(!attachment.is_retired());
        }
        NativeAttachment::retire(id).unwrap();
        assert!(attachment.is_retired());
        attachment.invalidate().unwrap();
        assert!(attachment.is_retired());
        let mut dispatched = false;
        assert!(NativeAttachment::dispatch(id, || dispatched = true).is_err());
        assert!(!dispatched);
        assert!(target.begin().is_err());
    }
}
