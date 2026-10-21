//! API-20 native editor mounted in an ordinary ArkTS ContentSlot.

use std::{cell::RefCell, rc::Rc};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Object, Env, Error, Result};
use openharmony_ability::arkui::component::{
    attribute::ArkUICommonAttribute,
    built_in_component::{Column, Text},
    content_root::ContentRoot,
    native_attachment::NativeAttachment,
};
use openharmony_ability_plugin_arkui::{
    apply_editors, apply_native_views, EditorBatch, EditorEvents, EditorSettings, NativeViewBatch,
    NativeViewEvents, NativeViewSettings,
};

struct DemoEditor {
    _events: EditorEvents,
    _attachment: NativeAttachment,
    content: ContentRoot,
}
thread_local! { static EDITOR: RefCell<Option<DemoEditor>> = RefCell::default(); }
const ID: &str = "demo.native-editor";
const WRAPPER_ID: &str = "demo.native-wrapper";
struct DemoWrapper {
    _events: NativeViewEvents,
    _attachment: NativeAttachment,
    content: ContentRoot,
}
thread_local! { static WRAPPER: RefCell<Option<DemoWrapper>> = RefCell::default(); }

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
    demo_dispose_native_wrapper(env)?;
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

/// Releases the semantic wrapper and its owned native subtree.
#[napi]
pub fn demo_dispose_native_wrapper(env: &Env) -> Result<()> {
    if WRAPPER.with(|wrapper| wrapper.borrow().is_some()) {
        apply_native_views(
            &super::current_app()?,
            env,
            NativeViewBatch {
                remove: vec![WRAPPER_ID.into()],
                ..Default::default()
            },
        )?;
        WRAPPER.with(|wrapper| {
            wrapper.borrow_mut().take();
        });
    }
    Ok(())
}

/// Embeds native C text inside an ArkTS-owned semantic wrapper.
#[napi]
pub fn demo_native_wrapper(env: &Env) -> Result<Object<'_>> {
    build_native_wrapper(env, None)
}

/// Exports the live native subtree into a caller-owned XComponent surface.
#[napi]
pub fn demo_native_texture(env: &Env, surface_id: String) -> Result<Object<'_>> {
    build_native_wrapper(env, Some(surface_id))
}

fn build_native_wrapper(env: &Env, surface_id: Option<String>) -> Result<Object<'_>> {
    demo_dispose_native_editor(env)?;
    demo_dispose_native_wrapper(env)?;
    let app = super::current_app()?;
    let parent = Column::new().map_err(platform_error)?;
    parent.width(320.0).map_err(platform_error)?;
    parent.height(48.0).map_err(platform_error)?;
    let parent = parent.into_node();
    let text = Text::new().map_err(platform_error)?;
    text.content("Native subtree with accessible semantics")
        .map_err(platform_error)?;
    let text = text.into_node();
    let attachment = NativeAttachment::for_subtree(&parent, &text)?;
    let events = NativeViewEvents::new(&app, WRAPPER_ID.into(), attachment.id(), |event| {
        log::info!("native wrapper action: {}", event.action);
        true
    })?;
    let mut content = ContentRoot::new(Env::from_raw(env.raw()))?;
    content.mount(parent).map_err(platform_error)?;
    apply_native_views(
        &app,
        env,
        NativeViewBatch {
            updates: vec![NativeViewSettings {
                texture_surface: surface_id,
                id: WRAPPER_ID.into(),
                target_id: attachment.id(),
                width: 320.0,
                height: 48.0,
                semantic: true,
                accessible: Some(true),
                role: "text".into(),
                label: "Native subtree demo".into(),
                ..Default::default()
            }],
            ..Default::default()
        },
    )?;
    WRAPPER.with(|wrapper| {
        *wrapper.borrow_mut() = Some(DemoWrapper {
            _events: events,
            _attachment: attachment,
            content,
        });
        wrapper
            .borrow()
            .as_ref()
            .expect("stored wrapper")
            .content
            .object(env)
    })
}
