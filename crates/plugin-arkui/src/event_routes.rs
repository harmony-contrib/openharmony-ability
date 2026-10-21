//! UI-thread routes keyed by plugin ownership and native attachment generation.
use std::{collections::BTreeMap, rc::Rc};

type Handler<E> = Rc<dyn Fn(E)>;
pub(crate) struct EventRoutes<E> {
    handlers: BTreeMap<(usize, String), (u32, Handler<E>)>,
}
impl<E> Default for EventRoutes<E> {
    fn default() -> Self {
        Self {
            handlers: BTreeMap::new(),
        }
    }
}
impl<E> EventRoutes<E> {
    pub(crate) fn insert(
        &mut self,
        owner: usize,
        id: String,
        target: u32,
        handler: Handler<E>,
    ) -> bool {
        let entry = self.handlers.entry((owner, id));
        if let std::collections::btree_map::Entry::Vacant(entry) = entry {
            entry.insert((target, handler));
            true
        } else {
            false
        }
    }
    pub(crate) fn get(&self, owner: usize, id: &str, target: u32) -> Option<Handler<E>> {
        self.handlers
            .get(&(owner, id.to_owned()))
            .filter(|(generation, _)| *generation == target)
            .map(|(_, handler)| handler.clone())
    }
    pub(crate) fn remove(&mut self, owner: usize, id: &str, expected: &Handler<E>) {
        let key = (owner, id.to_owned());
        if self
            .handlers
            .get(&key)
            .is_some_and(|(_, handler)| Rc::ptr_eq(handler, expected))
        {
            self.handlers.remove(&key);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn owners_generations_and_replacement_cleanup_are_independent() {
        let mut routes = EventRoutes::<u32>::default();
        let count = Rc::new(std::cell::Cell::new(0));
        let counter = count.clone();
        let first: Handler<u32> = Rc::new(move |value| counter.set(counter.get() + value));
        let second: Handler<u32> = Rc::new(|_| panic!("wrong owner"));
        assert!(routes.insert(1, "editor".into(), 10, first.clone()));
        assert!(routes.insert(2, "editor".into(), 20, second));
        assert!(routes.get(1, "editor", 20).is_none());
        routes.get(1, "editor", 10).unwrap()(1);
        assert_eq!(count.get(), 1);
        routes.remove(1, "editor", &first);
        let replacement: Handler<u32> = Rc::new(|_| {});
        assert!(routes.insert(1, "editor".into(), 11, replacement));
        routes.remove(1, "editor", &first);
        assert!(routes.get(1, "editor", 10).is_none());
        assert!(routes.get(1, "editor", 11).is_some());
        assert!(routes.get(2, "editor", 20).is_some());
    }
}
