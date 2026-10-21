//! Target-indexed subscriptions. Ability owns target validity and dispatch guards.
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

pub(crate) struct Registration<E> {
    callback: Arc<dyn Fn(E) + Send + Sync>,
}

pub(crate) struct NativeEvents<E> {
    entries: Mutex<BTreeMap<u32, Arc<Registration<E>>>>,
}

impl<E> Default for NativeEvents<E> {
    fn default() -> Self {
        Self {
            entries: Mutex::new(BTreeMap::new()),
        }
    }
}

impl<E> NativeEvents<E> {
    pub(crate) fn register(
        &self,
        target_id: u32,
        callback: impl Fn(E) + Send + Sync + 'static,
    ) -> Arc<Registration<E>> {
        let entry = Arc::new(Registration {
            callback: Arc::new(callback),
        });
        let previous = self
            .entries
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .insert(target_id, entry.clone());
        drop(previous);
        entry
    }

    pub(crate) fn remove(&self, target_id: u32, expected: &Arc<Registration<E>>) {
        let removed = {
            let mut entries = self
                .entries
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            if entries
                .get(&target_id)
                .is_some_and(|entry| Arc::ptr_eq(entry, expected))
            {
                entries.remove(&target_id)
            } else {
                None
            }
        };
        drop(removed);
    }

    pub(crate) fn dispatch(&self, target_id: u32, event: E) {
        let entry = self
            .entries
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .get(&target_id)
            .cloned();
        if let Some(entry) = entry {
            (entry.callback)(event);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_are_target_indexed_and_plugin_local() {
        let a = NativeEvents::default();
        let b = NativeEvents::default();
        let received = Arc::new(Mutex::new(Vec::new()));
        let _registration = a.register(7, {
            let received = received.clone();
            move |event: u32| received.lock().unwrap().push(event)
        });
        b.dispatch(7, 1);
        a.dispatch(8, 2);
        a.dispatch(7, 3);
        assert_eq!(*received.lock().unwrap(), [3]);
    }

    #[test]
    fn stale_guard_cannot_remove_replacement() {
        let routes = NativeEvents::default();
        let received = Arc::new(Mutex::new(Vec::new()));
        let old = routes.register(7, |_| panic!("replaced callback"));
        let new = routes.register(7, {
            let received = received.clone();
            move |event: u32| received.lock().unwrap().push(event)
        });
        routes.remove(7, &old);
        routes.dispatch(7, 1);
        routes.remove(7, &new);
        routes.dispatch(7, 2);
        assert_eq!(*received.lock().unwrap(), [1]);
    }

    #[test]
    fn callback_runs_without_holding_registry_lock() {
        let routes = Arc::new(NativeEvents::default());
        let _registration = routes.register(7, {
            let routes = Arc::downgrade(&routes);
            move |(): ()| {
                routes.upgrade().unwrap().register(8, |_| {});
            }
        });
        routes.dispatch(7, ());
    }
}
