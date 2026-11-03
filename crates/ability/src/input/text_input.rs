//! IME text input payload.

#[derive(Debug, Clone)]
/// Text inserted or committed by the input method.
pub struct TextInputEventData {
    /// The committed text content.
    pub text: String,
}
