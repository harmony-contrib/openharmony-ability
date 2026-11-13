#[derive(Debug)]
/// Error type for ability runtime misuse.
pub enum AbilityError {
    /// An entry point that may only run on the main thread was called from
    /// another thread; carries the offending call site description.
    OnlyRunWithMainThread(String),
}

impl std::fmt::Display for AbilityError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AbilityError::OnlyRunWithMainThread(msg) => {
                write!(
                    f,
                    "OpenHarmonyAbilityError: {:?} only run with main thread",
                    msg
                )
            }
        }
    }
}

impl std::error::Error for AbilityError {}
