//! Owned RGBA cursor data; native PixelMaps stay on the UI thread.
use super::*;

#[napi(object)]
#[derive(Clone, Debug)]
pub struct CustomCursorRequest {
    pub window_id: i64,
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub hotspot_x: u32,
    pub hotspot_y: u32,
}
impl_bridge_napi_type!(CustomCursorRequest, "ohos.window.CustomCursorRequest");

impl CustomCursorRequest {
    pub fn validate(&self) -> Result<()> {
        validate_window_id(self.window_id)?;
        if self.width == 0
            || self.height == 0
            || self.width > 256
            || self.height > 256
            || self.hotspot_x >= self.width
            || self.hotspot_y >= self.height
            || self.rgba.len() != (self.width * self.height * 4) as usize
        {
            return Err(Error::from_reason(
                "Cursor requires 1..256 RGBA pixels per axis and an in-bounds hotspot",
            ));
        }
        Ok(())
    }
}
impl WindowClient {
    pub async fn set_custom_cursor(&self, request: CustomCursorRequest) -> Result<()> {
        request.validate()?;
        self.call::<CustomCursorRequest, WindowAcknowledgement>("set-custom-cursor", request)
            .await?
            .ensure()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn window_icon_contract_and_bounds() {
        assert_eq!(
            WindowIconRequest::TYPE_NAME,
            "ohos.window.WindowIconRequest"
        );
        let mut icon = WindowIconRequest {
            window_id: 0,
            rgba: vec![],
            size: 0,
        };
        assert!(icon.validate().is_ok());
        icon.size = u32::MAX;
        assert!(icon.validate().is_err());
        icon.size = 0;
        icon.window_id = 1;
        assert!(icon.validate().is_err());
    }
    #[test]
    fn cursor_contract_and_bounds() {
        assert_eq!(
            CustomCursorRequest::TYPE_NAME,
            "ohos.window.CustomCursorRequest"
        );
        let mut request = CustomCursorRequest {
            window_id: 0,
            rgba: vec![255; 16],
            width: 2,
            height: 2,
            hotspot_x: 1,
            hotspot_y: 1,
        };
        assert!(request.validate().is_ok());
        request.rgba.pop();
        assert!(request.validate().is_err());
        request.rgba.push(255);
        request.hotspot_x = 2;
        assert!(request.validate().is_err());
        request.width = u32::MAX;
        assert!(request.validate().is_err());
    }
}

/// Main Ability window/task icon. An empty image restores the packaged Ability icon.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct WindowIconRequest {
    pub window_id: i64,
    pub rgba: Vec<u8>,
    pub size: u32,
}
impl_bridge_napi_type!(WindowIconRequest, "ohos.window.WindowIconRequest");
impl WindowIconRequest {
    pub fn validate(&self) -> Result<()> {
        if self.window_id != 0
            || self.size > 1024
            || self.rgba.len() != (self.size * self.size * 4) as usize
        {
            return Err(Error::from_reason(
                "Window icon requires the main Ability window and square RGBA pixels up to 1024",
            ));
        }
        Ok(())
    }
}
impl WindowClient {
    /// API 22+, PC/2in1 only. Child windows do not have an independent Ability icon.
    pub async fn set_window_icon(&self, request: WindowIconRequest) -> Result<()> {
        request.validate()?;
        self.call::<WindowIconRequest, WindowAcknowledgement>("set-window-icon", request)
            .await?
            .ensure()
    }
}
