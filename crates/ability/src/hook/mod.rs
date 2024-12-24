use ohos_display_binding::default_display_scaled_density;

mod window_info;

pub(crate) struct Hooks;

impl Default for Hooks {
    fn default() -> Self {
        Hooks
    }
}

impl Hooks {
    pub fn new() -> Self {
        Hooks
    }

    pub fn scale(&self) -> f32 {
        default_display_scaled_density()
    }
}
