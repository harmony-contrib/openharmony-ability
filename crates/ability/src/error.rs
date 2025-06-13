#[derive(Debug)]
pub enum AbilityError {
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
