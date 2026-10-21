//! Instance-owned, worker-safe callbacks keyed by native attachment generation.
use std::{collections::BTreeMap, sync::Arc};
type Callback<E> = Arc<dyn Fn(E) + Send + Sync>;
pub(crate) struct PlaybackRoutes<E> {
    handlers: BTreeMap<String, (u32, Callback<E>)>,
}
impl<E> Default for PlaybackRoutes<E> {
    fn default() -> Self {
        Self {
            handlers: BTreeMap::new(),
        }
    }
}
impl<E> PlaybackRoutes<E> {
    pub(crate) fn insert(&mut self, id: String, target: u32, callback: Callback<E>) -> bool {
        if let std::collections::btree_map::Entry::Vacant(entry) = self.handlers.entry(id) {
            entry.insert((target, callback));
            true
        } else {
            false
        }
    }
    pub(crate) fn get(&self, id: &str, target: u32) -> Option<Callback<E>> {
        self.handlers
            .get(id)
            .filter(|(generation, _)| *generation == target)
            .map(|(_, cb)| cb.clone())
    }
    pub(crate) fn remove(&mut self, id: &str, expected: &Callback<E>) {
        if self
            .handlers
            .get(id)
            .is_some_and(|(_, cb)| Arc::ptr_eq(cb, expected))
        {
            self.handlers.remove(id);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn instances_generations_and_old_registration_drop_are_isolated() {
        let mut a = PlaybackRoutes::<u32>::default();
        let mut b = PlaybackRoutes::<u32>::default();
        let first: Callback<u32> = Arc::new(|_| {});
        assert!(a.insert("player".into(), 10, first.clone()));
        assert!(b.insert("player".into(), 20, Arc::new(|_| {})));
        assert!(a.get("player", 20).is_none());
        a.remove("player", &first);
        assert!(a.insert("player".into(), 11, Arc::new(|_| {})));
        a.remove("player", &first);
        assert!(a.get("player", 10).is_none());
        assert!(a.get("player", 11).is_some());
        assert!(b.get("player", 20).is_some());
    }
}
