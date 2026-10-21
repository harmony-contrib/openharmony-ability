//! UI-thread ArkUI nodes with named batch configuration and native attachment.
//! ArkTS owns editors and BuilderNodes; Rust retains only attachment IDs and data.

mod views;
pub use views::{
    apply_native_views, NativeViewAction, NativeViewBatch, NativeViewEvents, NativeViewSettings,
    ViewAction, ViewMenu, ViewMenuItem,
};

mod event_routes;
use event_routes::EventRoutes;

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Env, Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, BridgeContextRequirement, BridgeMainThreadEvent, BridgePlugin,
    MainThreadSyncBridge, NativeAttachment, NativeNodeReady, NativeNodeRetiring,
    NodeAcknowledgement, OpenHarmonyApp,
};
use std::{cell::RefCell, rc::Rc, sync::Arc};

/// Paired with the standard `ArkuiPlugin` factory.
#[derive(Default)]
pub struct ArkuiBridgePlugin {
    owner: Arc<()>,
}
impl ArkuiBridgePlugin {
    /// Creates an independent callback owner for this registered plugin instance.
    pub fn new() -> Self {
        Self::default()
    }
    fn owner_key(&self) -> usize {
        Arc::as_ptr(&self.owner) as usize
    }
}
impl BridgePlugin for ArkuiBridgePlugin {
    type Mode = MainThreadSyncBridge;
    const ID: &'static str = "ohos.arkui";
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
            "native-subtree-ready" => {
                event
                    .decode::<openharmony_ability::NativeSubtreeReady>()?
                    .attach(&event)?;
                event.respond(NodeAcknowledgement { accepted: true })
            }
            "view-action" => views::dispatch(self.owner_key(), event),
            "native-node-ready" => {
                event.decode::<NativeNodeReady>()?.attach(&event)?;
                event.respond(NodeAcknowledgement { accepted: true })
            }
            "native-node-retiring" => {
                event.decode::<NativeNodeRetiring>()?.detach()?;
                event.respond(NodeAcknowledgement { accepted: true })
            }
            "editor-event" => {
                let payload = event.decode::<EditorEvent>()?;
                NativeAttachment::dispatch(payload.target_id, || {
                    dispatch_editor(self.owner_key(), payload)
                })?;
                event.respond(NodeAcknowledgement { accepted: true })
            }
            _ => Err(Error::from_reason("Unsupported ohos.arkui native event")),
        }
    }
}

/// Desired editor state. Text updates carry the last accepted native edit count.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct EditorSettings {
    /// Unique editor generation.
    pub id: String,
    /// Native attachment target; never an ArkTS node reference.
    pub target_id: u32,
    /// Multiline TextArea instead of TextInput.
    pub multiline: bool,
    /// Native password mode (single-line editors).
    pub secure: bool,
    /// Controlled text, accepted only at the matching native edit count.
    pub text: String,
    /// Native edit count associated with text.
    pub count: u32,
    /// Width in vp.
    pub width: f64,
    /// Height in vp.
    pub height: f64,
    /// Placeholder text.
    pub placeholder: String,
    /// Font size in font-scaled pixels (fp), matching ArkUI numeric fontSize.
    pub font_size: f64,
    /// Font weight from 100 through 900.
    pub font_weight: u32,
    /// Font family or the system default.
    pub font_family: Option<String>,
    /// Italic text.
    pub italic: bool,
    /// ARGB text color.
    pub color: u32,
    /// ARGB placeholder color.
    pub placeholder_color: u32,
    /// ARGB caret color.
    pub caret_color: u32,
    /// ARGB selection color.
    pub selection_color: u32,
    /// Whether edits are accepted.
    pub editable: bool,
    /// ArkUI HitTestMode, applied before the first native appearance.
    pub hit_test: u32,
    /// Text alignment: start, center or end.
    pub align: u32,
    /// Right-to-left text direction.
    pub rtl: bool,
    /// ArkUI capitalization mode (0 through 3).
    pub capitalize: u32,
    /// normal, number, decimal, phone, email, password or number-password.
    pub keyboard: String,
    /// go, next, search, send, newline or done.
    pub enter_key: String,
    /// Whether submission blurs the field.
    pub blur_on_submit: bool,
    /// Native maximum length, or the system default.
    pub max_length: Option<u32>,
    /// Whether native autofill is enabled.
    pub auto_fill: bool,
    /// ArkUI semantic autofill content type.
    pub content_type: Option<String>,
    /// Focus on first appearance.
    pub auto_focus: bool,
    /// Optional semantic overrides on the native editor, independent of its container.
    pub accessibility: Option<EditorAccessibility>,
}

impl Default for EditorSettings {
    fn default() -> Self {
        Self {
            id: String::new(),
            target_id: 0,
            multiline: false,
            secure: false,
            text: String::new(),
            count: 0,
            width: 0.0,
            height: 0.0,
            placeholder: String::new(),
            font_size: 16.0,
            font_weight: 400,
            font_family: None,
            italic: false,
            color: 0xff000000,
            placeholder_color: 0xff808080,
            caret_color: 0xff007dff,
            selection_color: 0x33007dff,
            editable: true,
            hit_test: 0,
            align: 0,
            rtl: false,
            capitalize: 0,
            keyboard: "normal".into(),
            enter_key: "done".into(),
            blur_on_submit: true,
            max_length: None,
            auto_fill: true,
            content_type: None,
            auto_focus: false,
            accessibility: None,
        }
    }
}

/// Accessibility metadata owned by a native editor rather than its attachment host.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct EditorAccessibility {
    /// Accessible name; empty retains the editor's native text/placeholder behavior.
    pub label: String,
    /// Accessible hint.
    pub hint: String,
    /// Hide this editor and its internal accessibility descendants.
    pub hidden: bool,
    /// Explicit visibility in the accessibility tree.
    pub accessible: Option<bool>,
    /// Disabled interaction state.
    pub disabled: bool,
}

/// Focus and selection operations ordered after this batch's state updates.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct EditorCommand {
    /// Editor generation.
    pub id: String,
    /// focus, blur or selection.
    pub kind: String,
    /// UTF-16 selection start.
    pub start: u32,
    /// UTF-16 selection end.
    pub end: u32,
}

/// One UI turn's editor changes.
#[napi(object)]
#[derive(Clone, Debug, Default)]
pub struct EditorBatch {
    /// Coalesced desired states.
    pub updates: Vec<EditorSettings>,
    /// Commands in recording order.
    pub commands: Vec<EditorCommand>,
    /// Editor generations to retire after native detachment.
    pub remove: Vec<String>,
}
impl_bridge_napi_type!(EditorBatch, "ohos.arkui.EditorBatch");

impl EditorBatch {
    fn validate(&self) -> Result<()> {
        let mut ids = std::collections::BTreeSet::new();
        for editor in &self.updates {
            let keyboard = if editor.multiline {
                matches!(
                    editor.keyboard.as_str(),
                    "normal" | "number" | "decimal" | "phone" | "email"
                )
            } else {
                matches!(
                    editor.keyboard.as_str(),
                    "normal"
                        | "number"
                        | "decimal"
                        | "phone"
                        | "email"
                        | "password"
                        | "number-password"
                )
            };
            if editor.id.is_empty()
                || !ids.insert(&editor.id)
                || editor.target_id == 0
                || editor.capitalize > 3
                || editor.align > 2
                || editor.hit_test > 3
                || !editor.width.is_finite()
                || !editor.height.is_finite()
                || !editor.font_size.is_finite()
                || editor.font_size < 0.0
                || !(100..=900).contains(&editor.font_weight)
                || editor.font_weight % 100 != 0
                || editor.width < 0.0
                || editor.height < 0.0
                || editor
                    .max_length
                    .is_some_and(|length| length > i32::MAX as u32)
                || editor.multiline && editor.secure
                || !keyboard
                || !matches!(
                    editor.enter_key.as_str(),
                    "go" | "next" | "search" | "send" | "newline" | "done"
                )
                || editor.content_type.as_deref().is_some_and(|kind| {
                    !matches!(
                        kind,
                        "username"
                            | "password"
                            | "new-password"
                            | "email"
                            | "tel"
                            | "name"
                            | "given-name"
                            | "family-name"
                            | "nickname"
                            | "street-address"
                            | "address-line2"
                            | "city"
                            | "region"
                            | "country"
                            | "credit-card"
                    )
                })
            {
                return Err(Error::from_reason("Invalid native editor settings"));
            }
        }
        if self.remove.iter().any(String::is_empty)
            || self.commands.iter().any(|command| {
                command.id.is_empty()
                    || !matches!(command.kind.as_str(), "focus" | "blur" | "selection")
                    || command.start > command.end
                    || command.end > i32::MAX as u32
            })
        {
            return Err(Error::from_reason("Invalid native editor command"));
        }
        Ok(())
    }
}

/// Owned snapshot of a native editor callback.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct EditorEvent {
    /// Native attachment generation, checked before callback delivery.
    pub target_id: u32,
    /// Editor generation.
    pub id: String,
    /// change, focus, blur, submit, selection, size or key.
    pub kind: String,
    /// Current text or a key name.
    pub text: String,
    /// Native edit count.
    pub count: u32,
    /// UTF-16 selection start.
    pub start: u32,
    /// UTF-16 selection end.
    pub end: u32,
    /// Content width in vp.
    pub width: f64,
    /// Content height in vp.
    pub height: f64,
}
impl_bridge_napi_type!(EditorEvent, "ohos.arkui.EditorEvent");

type Callback = Rc<dyn Fn(EditorEvent)>;
thread_local! { static EDITORS: RefCell<EventRoutes<EditorEvent>> = RefCell::default(); }

fn dispatch_editor(owner: usize, payload: EditorEvent) {
    let callback =
        EDITORS.with(|editors| editors.borrow().get(owner, &payload.id, payload.target_id));
    if let Some(callback) = callback {
        callback(payload);
    }
}

/// UI-thread callback registration scoped to one editor generation.
pub struct EditorEvents {
    owner: Arc<()>,
    id: String,
    callback: Callback,
}
impl EditorEvents {
    /// Register before enqueuing creation of the editor.
    pub fn new(
        app: &OpenHarmonyApp,
        id: String,
        target_id: u32,
        callback: impl Fn(EditorEvent) + 'static,
    ) -> Result<Self> {
        if id.is_empty() || target_id == 0 {
            return Err(Error::from_reason("Invalid editor callback identity"));
        }
        let plugin = app
            .registered_plugin::<ArkuiBridgePlugin>()?
            .ok_or_else(|| Error::from_reason("ArkUI plugin is not registered"))?;
        Self::register(plugin.owner.clone(), id, target_id, Rc::new(callback))
    }
    fn register(owner: Arc<()>, id: String, target_id: u32, callback: Callback) -> Result<Self> {
        EDITORS.with(|editors| {
            let mut editors = editors.borrow_mut();
            if !editors.insert(
                Arc::as_ptr(&owner) as usize,
                id.clone(),
                target_id,
                callback.clone(),
            ) {
                return Err(Error::from_reason("Editor ID is already registered"));
            }
            Ok(Self {
                owner,
                id,
                callback,
            })
        })
    }
}
impl Drop for EditorEvents {
    fn drop(&mut self) {
        EDITORS.with(|editors| {
            let mut editors = editors.borrow_mut();
            editors.remove(Arc::as_ptr(&self.owner) as usize, &self.id, &self.callback);
        });
    }
}

/// Submit a batch from an active N-API/UI callback without waiting for app JS.
pub fn apply_editors(app: &OpenHarmonyApp, env: &Env, batch: EditorBatch) -> Result<()> {
    batch.validate()?;
    app.with_main_thread_bridge(env, |bridge| {
        let response = bridge.call_sync::<ArkuiBridgePlugin, EditorBatch, NodeAcknowledgement>(
            "apply-editors",
            batch,
        )?;
        if !response.accepted {
            return Err(Error::from_reason("ArkUI editor batch was rejected"));
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;
    #[test]
    fn callback_owners_and_native_generations_are_independent() {
        let first = ArkuiBridgePlugin::new();
        let second = ArkuiBridgePlugin::new();
        let count = Rc::new(std::cell::Cell::new(0));
        let counter = count.clone();
        let old = EditorEvents::register(
            first.owner.clone(),
            "same".into(),
            1,
            Rc::new(move |_| counter.set(counter.get() + 1)),
        )
        .unwrap();
        let counter = count.clone();
        let _other = EditorEvents::register(
            second.owner.clone(),
            "same".into(),
            2,
            Rc::new(move |_| counter.set(counter.get() + 10)),
        )
        .unwrap();
        let event = |target_id| EditorEvent {
            id: "same".into(),
            target_id,
            kind: "change".into(),
            text: "a".into(),
            count: 1,
            start: 0,
            end: 0,
            width: 0.0,
            height: 0.0,
        };
        dispatch_editor(first.owner_key(), event(2));
        assert_eq!(count.get(), 0);
        dispatch_editor(first.owner_key(), event(1));
        dispatch_editor(second.owner_key(), event(2));
        assert_eq!(count.get(), 11);
        drop(old);
        let counter = count.clone();
        let _replacement = EditorEvents::register(
            first.owner.clone(),
            "same".into(),
            3,
            Rc::new(move |_| counter.set(counter.get() + 100)),
        )
        .unwrap();
        dispatch_editor(first.owner_key(), event(1));
        assert_eq!(count.get(), 11);
        dispatch_editor(first.owner_key(), event(3));
        assert_eq!(count.get(), 111);
    }

    #[test]
    fn named_editor_contracts_are_stable() {
        assert_eq!(EditorBatch::TYPE_NAME, "ohos.arkui.EditorBatch");
        assert_eq!(EditorEvent::TYPE_NAME, "ohos.arkui.EditorEvent");
    }
}
