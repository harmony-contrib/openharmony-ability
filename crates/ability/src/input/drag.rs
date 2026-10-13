//! Native drag/drop policy built on owned, typed platform bindings.
use crate::OpenHarmonyWaker;
use napi_ohos::{Error, Result};
use ohos_arkui_binding::{
    api::drag::{DragAction, DragCompletion, DragEvent},
    component::attribute::ArkUIAttributeBasic,
    image_native_binding::{
        PixelFormat, PixelMap, PixelMapAlphaType, PixelMapInitializationOptions,
    },
    types::advanced::DragStatus,
    XComponent,
};
use ohos_udmf_binding::{UdmfData, UdmfRecord, UdsFileUri};
use std::sync::{
    atomic::{AtomicU8, Ordering},
    Arc, Mutex,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DragPhase {
    Enter,
    Move,
    Leave,
    Drop,
}

#[derive(Clone, Debug, Default)]
pub struct DragResponse(Arc<AtomicU8>);
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DragOperation {
    Copy,
    Move,
}
impl DragOperation {
    pub(crate) fn native(self) -> ohos_arkui_binding::types::drag::DropOperation {
        match self {
            Self::Copy => ohos_arkui_binding::types::drag::DropOperation::Copy,
            Self::Move => ohos_arkui_binding::types::drag::DropOperation::Move,
        }
    }
}
/// Validated RGBA preview, in image pixels. The hotspot is relative to its top left.
#[derive(Clone, Debug)]
pub struct DragPreview {
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub hotspot_x: f32,
    pub hotspot_y: f32,
}
impl DragPreview {
    pub fn validate(&self) -> Result<()> {
        if self.width == 0
            || self.height == 0
            || self.width > 1024
            || self.height > 1024
            || self.rgba.len() != (self.width * self.height * 4) as usize
            || !self.hotspot_x.is_finite()
            || !self.hotspot_y.is_finite()
        {
            return Err(Error::from_reason(
                "Invalid drag preview dimensions, RGBA bytes or hotspot",
            ));
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NativeDragResult {
    Dropped(DragOperation),
    Cancelled,
    Failed,
}

impl DragResponse {
    pub fn accept(&self) {
        self.accept_operation(DragOperation::Copy);
    }
    pub fn accepted(&self) -> bool {
        self.operation().is_some()
    }
    pub fn accept_operation(&self, operation: DragOperation) {
        self.0.store(
            match operation {
                DragOperation::Copy => 1,
                DragOperation::Move => 2,
            },
            Ordering::Release,
        );
    }
    pub fn reject(&self) {
        self.0.store(0, Ordering::Release);
    }
    pub fn operation(&self) -> Option<DragOperation> {
        match self.0.load(Ordering::Acquire) {
            1 => Some(DragOperation::Copy),
            2 => Some(DragOperation::Move),
            _ => None,
        }
    }
}
impl PartialEq for DragResponse {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DragInputData {
    pub phase: DragPhase,
    /// Physical pixels relative to the window, including native content offsets.
    pub window_x: f32,
    pub window_y: f32,
    pub file_uris: Vec<String>,
    pub response: DragResponse,
}

impl DragInputData {
    /// Copies callback-scoped data. No native event or record escapes delivery.
    pub(crate) fn from_event(event: &DragEvent<'_>, phase: DragPhase) -> Self {
        let mut file_uris = Vec::new();
        if matches!(phase, DragPhase::Enter | DragPhase::Drop) {
            if let Ok(mut data) = UdmfData::try_new() {
                if event.get_udmf_data(&mut data).is_ok() && (0..=512).contains(&data.count()) {
                    if let Ok(records) = data.records() {
                        for record in records {
                            let Ok(uri) = record.file_uri().and_then(|uri| uri.file_uri()) else {
                                continue;
                            };
                            if uri.starts_with("file://") && !file_uris.contains(&uri) {
                                file_uris.push(uri);
                            }
                        }
                    }
                }
            }
        }
        Self {
            phase,
            window_x: event.touch_point_x_to_window(),
            window_y: event.touch_point_y_to_window(),
            file_uris,
            response: DragResponse::default(),
        }
    }
}

/// UI-thread owner of an outbound native file drag.
/// Keep the source surface alive until completion, and drop this before releasing that surface.
pub struct NativeFileDrag {
    // Native action disposal unregisters callbacks before releasing its data and preview.
    _action: DragAction,
    completion: Arc<Mutex<Option<NativeDragResult>>>,
    _source: XComponent,
    _pixels: Vec<u8>,
    _records: Vec<UdmfRecord>,
    _uris: Vec<UdsFileUri>,
}

impl NativeFileDrag {
    /// Capture a typed source view, then release the surface lock before `start`
    /// because ArkUI can synchronously reenter input dispatch.
    pub fn node_handle(component: &XComponent) -> XComponent {
        component.clone()
    }

    pub fn start(
        source: XComponent,
        pointer_id: i32,
        files: &[(String, bool)],
        waker: OpenHarmonyWaker,
    ) -> Result<Self> {
        Self::start_with_preview(source, pointer_id, files, None, waker)
    }

    pub fn start_with_preview(
        source: XComponent,
        pointer_id: i32,
        files: &[(String, bool)],
        preview: Option<DragPreview>,
        waker: OpenHarmonyWaker,
    ) -> Result<Self> {
        if let Some(preview) = &preview {
            preview.validate()?;
        }
        if files.is_empty() || files.len() > 512 {
            return Err(Error::from_reason("Native drag requires 1..512 files"));
        }
        let mut data = UdmfData::try_new().map_err(|e| Error::from_reason(e.to_string()))?;
        let mut records = Vec::with_capacity(files.len());
        let mut uris = Vec::with_capacity(files.len());
        for (value, directory) in files {
            if !value.starts_with("file://") {
                return Err(Error::from_reason("Native drag requires file:// URIs"));
            }
            let uri = UdsFileUri::new().map_err(|e| Error::from_reason(e.to_string()))?;
            uri.set_file_uri(value)
                .map_err(|e| Error::from_reason(e.to_string()))?;
            uri.set_file_type(if *directory {
                "general.folder"
            } else {
                "general.file"
            })
            .map_err(|e| Error::from_reason(e.to_string()))?;
            let record = UdmfRecord::try_new().map_err(|e| Error::from_reason(e.to_string()))?;
            record
                .add_file_uri(&uri)
                .map_err(|e| Error::from_reason(e.to_string()))?;
            data.add_record(&record)
                .map_err(|e| Error::from_reason(e.to_string()))?;
            records.push(record);
            uris.push(uri);
        }
        let mut options =
            PixelMapInitializationOptions::new().map_err(|e| Error::from_reason(e.to_string()))?;
        options
            .set_width(preview.as_ref().map_or(32, |p| p.width))
            .map_err(|e| Error::from_reason(e.to_string()))?;
        options
            .set_height(preview.as_ref().map_or(32, |p| p.height))
            .map_err(|e| Error::from_reason(e.to_string()))?;
        options
            .set_pixel_format(PixelFormat::Rgba8888)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        options
            .set_src_pixel_format(PixelFormat::Rgba8888)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        options
            .set_alpha_type(PixelMapAlphaType::Unpremultiplied)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        let hotspot = preview.as_ref().map(|p| (p.hotspot_x, p.hotspot_y));
        let mut pixels =
            preview.map_or_else(|| [0x3c, 0xc7, 0x55, 0xff].repeat(32 * 32), |p| p.rgba);
        let preview = PixelMap::create(&mut pixels, &mut options)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        let mut action = DragAction::new_with_node(source.raw())
            .map_err(|e| Error::from_reason(e.to_string()))?;
        action
            .set_pixel_maps(vec![preview])
            .map_err(|e| Error::from_reason(e.to_string()))?;
        action
            .set_pointer_id(pointer_id)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        action
            .set_data(data)
            .map_err(|e| Error::from_reason(e.to_string()))?;
        if let Some((x, y)) = hotspot {
            action
                .set_touch_point_x(x)
                .map_err(|e| Error::from_reason(e.to_string()))?;
            action
                .set_touch_point_y(y)
                .map_err(|e| Error::from_reason(e.to_string()))?;
        }
        let completion = Arc::new(Mutex::new(None));
        let completed = completion.clone();
        action
            .register_completion_listener(move |event| {
                if let Some(result) = native_drag_result(event) {
                    *completed.lock().unwrap_or_else(|e| e.into_inner()) = Some(result);
                    waker.wake();
                }
            })
            .map_err(|e| Error::from_reason(e.to_string()))?;
        action
            .start_drag()
            .map_err(|e| Error::from_reason(e.to_string()))?;
        Ok(Self {
            _action: action,
            completion,
            _source: source,
            _pixels: pixels,
            _records: records,
            _uris: uris,
        })
    }

    pub fn ended(&self) -> bool {
        self.result().is_some()
    }
}

impl NativeFileDrag {
    pub fn result(&self) -> Option<NativeDragResult> {
        *self.completion.lock().unwrap_or_else(|e| e.into_inner())
    }
}
fn native_drag_result(event: DragCompletion) -> Option<NativeDragResult> {
    use ohos_arkui_binding::types::drag::{DragResult, DropOperation};
    if event.status != DragStatus::Ended {
        return None;
    }
    Some(match (event.result, event.operation) {
        (Some(DragResult::Successful), Some(DropOperation::Copy)) => {
            NativeDragResult::Dropped(DragOperation::Copy)
        }
        (Some(DragResult::Successful), Some(DropOperation::Move)) => {
            NativeDragResult::Dropped(DragOperation::Move)
        }
        (Some(DragResult::Canceled), _) => NativeDragResult::Cancelled,
        _ => NativeDragResult::Failed,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn completion_does_not_report_cancellation_as_success() {
        use ohos_arkui_binding::types::drag::{DragResult, DropOperation};
        for (result, operation, expected) in [
            (
                Some(DragResult::Successful),
                Some(DropOperation::Move),
                NativeDragResult::Dropped(DragOperation::Move),
            ),
            (
                Some(DragResult::Canceled),
                Some(DropOperation::Copy),
                NativeDragResult::Cancelled,
            ),
            (None, None, NativeDragResult::Failed),
        ] {
            assert_eq!(
                native_drag_result(DragCompletion {
                    status: DragStatus::Ended,
                    result,
                    operation
                }),
                Some(expected)
            );
        }
        let response = DragResponse::default();
        response.accept_operation(DragOperation::Move);
        assert_eq!(response.operation(), Some(DragOperation::Move));
        response.reject();
        assert!(!response.accepted());
    }
}
