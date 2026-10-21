//! Owned visual wrappers around native subtrees.
use super::event_routes::EventRoutes;
use super::ArkuiBridgePlugin;
use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Env, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, BridgeMainThreadEvent, NodeAcknowledgement, OpenHarmonyApp,
};
use std::{cell::RefCell, rc::Rc, sync::Arc};

/// One named accessibility action and its user-visible label.
#[napi(object)]
#[derive(Clone, Debug, PartialEq)]
pub struct ViewAction {
    /// Stable application action name.
    pub name: String,
    /// Spoken action label.
    pub label: String,
}
/// One context-menu action. `kind` explicitly chooses an ordinary item or a system paste grant.
#[napi(object)]
#[derive(Clone, Debug, PartialEq)]
pub struct ViewMenuItem {
    /// Application action ID, returned unchanged after activation.
    pub name: String,
    /// Display label for an ordinary action.
    pub label: String,
    /// `action` for an ordinary item, `paste` for a system PasteButton.
    pub kind: String,
}
/// Optional context menu for an owned native wrapper (API 20).
#[napi(object)]
#[derive(Clone, Debug, PartialEq)]
pub struct ViewMenu {
    /// Nonzero generation echoed by every menu callback.
    pub generation: u32,
    /// Whether the menu is currently shown.
    pub visible: bool,
    /// Horizontal offset in vp from the wrapper's top-left corner.
    pub x: f64,
    /// Vertical anchor in vp below the wrapper's top edge.
    pub y: f64,
    /// Menu entries in display order.
    pub items: Vec<ViewMenuItem>,
}
/// Visual and accessibility attributes on an ArkTS-owned native wrapper.
#[napi(object)]
#[derive(Clone, Debug, Default, PartialEq)]
pub struct NativeViewSettings {
    /// Unique wrapper generation.
    pub id: String,
    /// Target containing the Rust-owned subtree.
    pub target_id: u32,
    /// Host test identifier on the actual wrapper node.
    pub test_id: Option<String>,
    /// Width in vp.
    pub width: f64,
    /// Height in vp.
    pub height: f64,
    /// Hue rotation, in degrees.
    pub hue: f64,
    /// Wrapper owns this node's semantics while native descendants remain intact.
    pub semantic: bool,
    /// Advertise the standard accessibility click action.
    pub clickable: bool,
    /// Accessibility disabled state.
    pub disabled: bool,
    /// Explicit accessibility grouping, or the system default.
    pub accessible: Option<bool>,
    /// Hide this semantic subtree from accessibility services.
    pub hidden: bool,
    /// Accessible name.
    pub label: String,
    /// Accessible hint.
    pub hint: String,
    /// Spoken value and additional states.
    pub value: String,
    /// Semantic role name, or an empty string for the system default.
    pub role: String,
    /// Binary checked state, when provided.
    pub checked: Option<bool>,
    /// Selected state.
    pub selected: bool,
    /// Enable the API-23 state-description attribute.
    pub api23: bool,
    /// Enable API-26 custom actions for this wrapper.
    pub api26: bool,
    /// Actions in registration order.
    pub actions: Vec<ViewAction>,
    /// Optional context menu, independent of accessibility actions.
    pub menu: Option<ViewMenu>,
}
/// One UI turn's wrapper changes.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct NativeViewBatch {
    /// Coalesced desired wrapper states.
    pub updates: Vec<NativeViewSettings>,
    /// Generations to retire after detaching their native subtrees.
    pub remove: Vec<String>,
}
impl_bridge_napi_type!(NativeViewBatch, "ohos.arkui.NativeViewBatch");
/// Snapshot of a native accessibility or context-menu action.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct NativeViewAction {
    /// Native attachment generation.
    pub target_id: u32,
    /// Wrapper generation.
    pub id: String,
    /// Registered application action name.
    pub action: String,
    /// `menu` for a menu choice, `menu-dismiss` when hidden; absent for accessibility.
    pub kind: Option<String>,
    /// Context-menu generation, absent for accessibility actions.
    pub generation: Option<u32>,
}
impl_bridge_napi_type!(NativeViewAction, "ohos.arkui.NativeViewAction");
type Callback = Rc<dyn Fn(NativeViewAction) -> bool>;
thread_local! { static ACTIONS: RefCell<EventRoutes<NativeViewAction, bool>> = RefCell::default(); }
/// Main-thread action registration scoped to one wrapper generation.
pub struct NativeViewEvents {
    owner: Arc<()>,
    id: String,
    callback: Callback,
}
impl NativeViewEvents {
    /// Registers before enqueueing the matching wrapper.
    pub fn new(
        app: &OpenHarmonyApp,
        id: String,
        target_id: u32,
        callback: impl Fn(NativeViewAction) -> bool + 'static,
    ) -> Result<Self> {
        if id.is_empty() || target_id == 0 {
            return Err(Error::from_reason("Invalid wrapper callback identity"));
        }
        let plugin = app
            .registered_plugin::<ArkuiBridgePlugin>()?
            .ok_or_else(|| Error::from_reason("ArkUI plugin is not registered"))?;
        let owner = plugin.owner.clone();
        let callback: Callback = Rc::new(callback);
        ACTIONS.with(|actions| {
            if !actions.borrow_mut().insert(
                plugin.owner_key(),
                id.clone(),
                target_id,
                callback.clone(),
            ) {
                return Err(Error::from_reason("Wrapper ID already registered"));
            }
            Ok(Self {
                owner,
                id,
                callback,
            })
        })
    }
}
impl Drop for NativeViewEvents {
    fn drop(&mut self) {
        ACTIONS.with(|actions| {
            actions.borrow_mut().remove(
                Arc::as_ptr(&self.owner) as usize,
                &self.id,
                &self.callback,
            );
        });
    }
}
pub(crate) fn dispatch<'env>(
    owner: usize,
    event: BridgeMainThreadEvent<'env>,
) -> Result<Unknown<'env>> {
    let payload = event.decode::<NativeViewAction>()?;
    let callback =
        ACTIONS.with(|actions| actions.borrow().get(owner, &payload.id, payload.target_id));
    let accepted = callback.is_some_and(|callback| callback(payload));
    event.respond(NodeAcknowledgement { accepted })
}
impl NativeViewBatch {
    fn validate(&self) -> Result<()> {
        let mut ids = std::collections::BTreeSet::new();
        for update in &self.updates {
            if update.id.is_empty()
                || !ids.insert(&update.id)
                || update.target_id == 0
                || !update.hue.is_finite()
                || !matches!(
                    update.role.as_str(),
                    "" | "button"
                        | "checkbox"
                        | "switch"
                        | "radio"
                        | "slider"
                        | "image"
                        | "link"
                        | "list"
                        | "grid"
                        | "progress"
                        | "search"
                        | "menuitem"
                        | "text"
                )
                || update.menu.as_ref().is_some_and(|menu| {
                    menu.generation == 0
                        || !menu.x.is_finite()
                        || !menu.y.is_finite()
                        || menu.items.is_empty()
                        || menu.items.iter().any(|item| {
                            item.name.is_empty()
                                || item.label.is_empty()
                                || !matches!(item.kind.as_str(), "action" | "paste")
                        })
                        || menu
                            .items
                            .iter()
                            .map(|item| &item.name)
                            .collect::<std::collections::BTreeSet<_>>()
                            .len()
                            != menu.items.len()
                })
                || !update.width.is_finite()
                || !update.height.is_finite()
                || update.width < 0.0
                || update.height < 0.0
                || update
                    .actions
                    .iter()
                    .map(|action| &action.name)
                    .collect::<std::collections::BTreeSet<_>>()
                    .len()
                    != update.actions.len()
                || update
                    .actions
                    .iter()
                    .any(|action| action.name.is_empty() || action.label.is_empty())
            {
                return Err(Error::from_reason("Invalid native wrapper settings"));
            }
        }
        if self.remove.iter().any(String::is_empty) {
            return Err(Error::from_reason("Invalid retiring wrapper ID"));
        }
        Ok(())
    }
}

/// Applies wrapper changes once from an active N-API callback.
pub fn apply_native_views(app: &OpenHarmonyApp, env: &Env, batch: NativeViewBatch) -> Result<()> {
    batch.validate()?;
    app.with_main_thread_bridge(env, |bridge| {
        let response = bridge
            .call_sync::<ArkuiBridgePlugin, NativeViewBatch, NodeAcknowledgement>(
                "apply-native-views",
                batch,
            )?;
        if !response.accepted {
            return Err(Error::from_reason("Native wrapper batch rejected"));
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;
    #[test]
    fn validation_uses_platform_values_without_consumer_budgets() {
        let settings = NativeViewSettings {
            id: "wrapper".into(),
            target_id: 1,
            width: 100000.0,
            height: 2.0,
            ..Default::default()
        };
        let mut batch = NativeViewBatch {
            updates: vec![settings],
            ..Default::default()
        };
        assert!(batch.validate().is_ok());
        batch.updates[0].width = f64::NAN;
        assert!(batch.validate().is_err());
        batch.updates[0].width = 1.0;
        batch.updates[0].role = "unsupported".into();
        assert!(batch.validate().is_err());
    }
    #[test]
    fn wrapper_contracts_are_stable() {
        assert_eq!(NativeViewBatch::TYPE_NAME, "ohos.arkui.NativeViewBatch");
        assert_eq!(NativeViewAction::TYPE_NAME, "ohos.arkui.NativeViewAction");
    }
}
