use napi_derive_ohos::napi;

#[napi]
pub enum ScreenDensity {
    NoSet = 0,
    SDPI = 120,
    MDPI = 160,
    LDPI = 240,
    XLDPI = 320,
    XXLDPI = 480,
    XXXLDPI = 640,
}