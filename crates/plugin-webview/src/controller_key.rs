//! Declaration identity retains its owner token so addresses cannot be reused.
use std::{cmp::Ordering, sync::Arc};
#[derive(Clone, Debug, Default)]
pub(crate) struct ControllerKey {
    owner: Option<Arc<()>>,
    id: String,
}
impl ControllerKey {
    pub(crate) fn new(owner: Option<Arc<()>>, id: impl Into<String>) -> Self {
        Self {
            owner,
            id: id.into(),
        }
    }
    pub(crate) fn id(&self) -> &str {
        &self.id
    }
    pub(crate) fn belongs_to(&self, owner: Option<&Arc<()>>) -> bool {
        match (&self.owner, owner) {
            (None, None) => true,
            (Some(left), Some(right)) => Arc::ptr_eq(left, right),
            _ => false,
        }
    }
    fn identity(&self) -> Option<usize> {
        self.owner.as_ref().map(|owner| Arc::as_ptr(owner).addr())
    }
}
impl PartialEq for ControllerKey {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for ControllerKey {}
impl PartialOrd for ControllerKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for ControllerKey {
    fn cmp(&self, other: &Self) -> Ordering {
        self.identity()
            .cmp(&other.identity())
            .then_with(|| self.id.cmp(&other.id))
    }
}
impl From<&str> for ControllerKey {
    fn from(id: &str) -> Self {
        Self::new(None, id)
    }
}

/// Moves user-owned values out while the caller holds its registry lock.
pub(crate) fn take_owner<T>(
    values: &mut std::collections::BTreeMap<ControllerKey, T>,
    owner: &Arc<()>,
) -> Vec<T> {
    let keys: Vec<_> = values
        .keys()
        .filter(|key| key.belongs_to(Some(owner)))
        .cloned()
        .collect();
    keys.into_iter()
        .filter_map(|key| values.remove(&key))
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn owner_identity_is_pointer_based_and_retained_by_the_key() {
        let owner = Arc::new(());
        let key = ControllerKey::new(Some(owner.clone()), "same");
        assert_eq!(key, ControllerKey::new(Some(owner.clone()), "same"));
        assert_ne!(key, ControllerKey::new(Some(Arc::new(())), "same"));
        assert_ne!(key, ControllerKey::from("same"));
        assert_eq!(Arc::strong_count(&owner), 2);
    }
}
