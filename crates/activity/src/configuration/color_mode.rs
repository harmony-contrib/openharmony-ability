use napi_derive_ohos::napi;

#[napi]
pub enum ColorMode {
    NoSet = -1,
    Dark = 0,
    Light = 1,
}