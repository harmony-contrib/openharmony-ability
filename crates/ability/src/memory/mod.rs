//! Memory pressure level (mirrors `@ohos.app.ability.ApplicationStateChangeCallback`).

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Memory pressure level reported by the system via `onMemoryLevel`.
pub enum MemoryLevel {
    /// Low pressure: memory is sufficient, no trimming required.
    Low,
    /// Moderate pressure: trim caches that can be recomputed.
    Normal,
    /// High pressure: release non-critical resources promptly.
    High,
}
