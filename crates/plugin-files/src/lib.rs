//! File dialog capability plugin facade.
//!
//! Ports the `showFileDialog` half of PR #65 into the pluginized bridge model. The request
//! travels as a structured named N-API object (`FileDialogOptions`); **no string-encoded
//! filter/accept grammar crosses the bridge**. The ArkTS side owns the picker-specific
//! string formats (`name|*.ext` choices, `;`-separated patterns) and converts internally.

use std::{future::Future, pin::Pin};

use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeCallOptions, BridgeContextRequirement, BridgePlugin,
    OpenHarmonyApp,
};

pub struct FilesBridgePlugin;

impl BridgePlugin for FilesBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.files";
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];
}

/// Dialog kind. Constants mirror the picker document modes.
pub mod dialog_type {
    pub const OPEN_FILE: &str = "open-file";
    pub const SAVE_FILE: &str = "save-file";
    pub const OPEN_FOLDER: &str = "open-folder";
}

/// One suffix filter group: a display name plus `;`-separated suffixes (e.g. `"md"`).
/// The pattern stays structured; the ArkTS plugin converts it to the picker grammar.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct FileDialogFilter {
    pub name: Option<String>,
    pub pattern: Option<String>,
}

impl_bridge_napi_type!(FileDialogFilter, "ohos.files.DialogFilter");

impl FileDialogFilter {
    pub fn new() -> Self {
        Self {
            name: None,
            pattern: None,
        }
    }

    pub fn name(mut self, name: impl Into<String>) -> Self {
        self.name = Some(name.into());
        self
    }

    pub fn pattern(mut self, pattern: impl Into<String>) -> Self {
        self.pattern = Some(pattern.into());
        self
    }
}

impl Default for FileDialogFilter {
    fn default() -> Self {
        Self::new()
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct FileDialogOptions {
    /// One of [`dialog_type`] constants.
    pub dialog_type: String,
    pub allow_many: bool,
    pub default_location: Option<String>,
    pub filters: Vec<FileDialogFilter>,
}

impl_bridge_napi_type!(FileDialogOptions, "ohos.files.DialogOptions");

impl FileDialogOptions {
    pub fn new(dialog_type: impl Into<String>) -> Self {
        Self {
            dialog_type: dialog_type.into(),
            allow_many: false,
            default_location: None,
            filters: Vec::new(),
        }
    }

    pub fn allow_many(mut self, allow_many: bool) -> Self {
        self.allow_many = allow_many;
        self
    }

    pub fn default_location(mut self, default_location: impl Into<String>) -> Self {
        self.default_location = Some(default_location.into());
        self
    }

    pub fn filters(mut self, filters: Vec<FileDialogFilter>) -> Self {
        self.filters = filters;
        self
    }

    fn validate(&self) -> Result<()> {
        match self.dialog_type.as_str() {
            dialog_type::OPEN_FILE | dialog_type::SAVE_FILE | dialog_type::OPEN_FOLDER => {}
            _ => {
                return Err(Error::from_reason(format!(
                    "unsupported file dialog type '{}'",
                    self.dialog_type
                )));
            }
        }
        if self.dialog_type == dialog_type::OPEN_FOLDER && self.allow_many {
            return Err(Error::from_reason(
                "open-folder dialog does not support allow_many",
            ));
        }
        for filter in &self.filters {
            if let Some(pattern) = filter.pattern.as_ref() {
                if pattern.trim().is_empty() {
                    return Err(Error::from_reason(
                        "file dialog filter pattern must not be empty",
                    ));
                }
            }
        }
        Ok(())
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct FileDialogResponse {
    /// Selected file URIs.
    pub files: Vec<String>,
    /// Selected filter index, or -1 when the platform does not report one.
    pub filter: i32,
}

impl_bridge_napi_type!(FileDialogResponse, "ohos.files.DialogResponse");

/// Extension trait supplied by the capability package, never by `openharmony-ability` core.
pub trait FilesExt {
    /// Shows the system file dialog (open / save / folder). Returns selected file URIs.
    fn show_file_dialog(
        &self,
        options: FileDialogOptions,
    ) -> Pin<Box<dyn Future<Output = Result<FileDialogResponse>> + Send>>;
}

impl FilesExt for OpenHarmonyApp {
    fn show_file_dialog(
        &self,
        options: FileDialogOptions,
    ) -> Pin<Box<dyn Future<Output = Result<FileDialogResponse>> + Send>> {
        if let Err(error) = options.validate() {
            return Box::pin(async move { Err(error) });
        }
        let bridge = self.bridge();
        Box::pin(async move {
            bridge?
                .call_async::<FilesBridgePlugin, FileDialogOptions, FileDialogResponse>(
                    "file-dialog",
                    options,
                    BridgeCallOptions::default().with_timeout_ms(60_000),
                )
                .await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{dialog_type, FileDialogFilter, FileDialogOptions, FileDialogResponse};
    use openharmony_ability::BridgeNapiType;

    #[test]
    fn files_uses_stable_named_napi_contracts() {
        assert_eq!(
            <FileDialogOptions as BridgeNapiType>::TYPE_NAME,
            "ohos.files.DialogOptions"
        );
        assert_eq!(
            <FileDialogResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.files.DialogResponse"
        );
        assert_eq!(
            <FileDialogFilter as BridgeNapiType>::TYPE_NAME,
            "ohos.files.DialogFilter"
        );
    }

    #[test]
    fn dialog_options_validate_kind_and_shape() {
        let open = FileDialogOptions::new(dialog_type::OPEN_FILE)
            .allow_many(true)
            .filters(vec![FileDialogFilter::new()
                .name("Documents")
                .pattern("md;txt")]);
        assert!(open.validate().is_ok());

        let bad_kind = FileDialogOptions::new("open-filesystem");
        assert!(bad_kind.validate().is_err());

        let folder_many = FileDialogOptions::new(dialog_type::OPEN_FOLDER).allow_many(true);
        assert!(folder_many.validate().is_err());
    }

    #[test]
    fn dialog_response_shape() {
        let response = FileDialogResponse {
            files: vec!["file://media/1.txt".to_owned()],
            filter: -1,
        };
        assert_eq!(response.files.len(), 1);
        assert_eq!(response.filter, -1);
    }
}
