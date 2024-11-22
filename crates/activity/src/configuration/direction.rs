use napi_derive_ohos::napi;

#[napi]
pub enum Direction {
    NoSet = -1,
    Vertical,
    Horizontal,
}