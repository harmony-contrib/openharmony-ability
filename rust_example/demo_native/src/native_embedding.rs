//! API-20 native editor mounted in an ordinary ArkTS ContentSlot.

use std::{cell::RefCell, rc::Rc};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Object, Env, Error, Result};
use openharmony_ability::arkui::component::{
    attribute::ArkUICommonAttribute, built_in_component::Column,
};
use openharmony_ability::{ContentRoot, NativeAttachment};
use openharmony_ability_plugin_arkui::{apply_editors, EditorBatch, EditorEvents, EditorSettings};

struct DemoEditor {
    _events: EditorEvents,
    _attachment: NativeAttachment,
    content: ContentRoot,
}
thread_local! { static EDITOR: RefCell<Option<DemoEditor>> = RefCell::default(); }
const ID: &str = "demo.native-editor";

fn platform_error(error: impl std::fmt::Display) -> Error {
    Error::from_reason(error.to_string())
}

/// Releases the prior editor and its native parent on the creating UI thread.
#[napi]
pub fn demo_dispose_native_editor(env: &Env) -> Result<()> {
    if EDITOR.with(|editor| editor.borrow().is_some()) {
        apply_editors(
            &super::current_app()?,
            env,
            EditorBatch {
                remove: vec![ID.into()],
                ..Default::default()
            },
        )?;
        EDITOR.with(|editor| {
            editor.borrow_mut().take();
        });
    }
    Ok(())
}

/// Returns a NodeContent whose Rust parent owns an attached ArkTS editor.
#[napi]
pub fn demo_native_editor(env: &Env) -> Result<Object<'_>> {
    demo_dispose_native_editor(env)?;
    let app = super::current_app()?;
    let parent = Column::new().map_err(platform_error)?;
    parent.width(320.0).map_err(platform_error)?;
    parent.height(48.0).map_err(platform_error)?;
    let parent = parent.into_node();
    let attachment = NativeAttachment::new(&parent)?;
    let events = EditorEvents::new(&app, ID.into(), attachment.id(), |event| {
        log::info!(
            "native editor {}: count={} text={}",
            event.kind,
            event.count,
            event.text
        );
    })?;
    let mut content = ContentRoot::new(Env::from_raw(env.raw()))?;
    content.mount(Rc::clone(&parent)).map_err(platform_error)?;
    apply_editors(
        &app,
        env,
        EditorBatch {
            updates: vec![EditorSettings {
                id: ID.into(),
                target_id: attachment.id(),
                width: 320.0,
                height: 48.0,
                text: "Edit native text".into(),
                placeholder: "Native editor".into(),
                ..Default::default()
            }],
            ..Default::default()
        },
    )?;
    EDITOR.with(|editor| {
        *editor.borrow_mut() = Some(DemoEditor {
            _events: events,
            _attachment: attachment,
            content,
        });
        editor
            .borrow()
            .as_ref()
            .expect("stored editor")
            .content
            .object(env)
    })
}
