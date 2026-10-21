//! Instance-owned observation identity and callback retirement, without platform objects.
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, RwLock,
    },
};
pub(crate) type Handler = Arc<dyn Fn(bool) + Send + Sync>;
#[derive(Default)]
pub(crate) struct MotionRoutes {
    next: AtomicU64,
    handlers: RwLock<BTreeMap<String, Handler>>,
}
impl MotionRoutes {
    pub(crate) fn insert(&self, handler: Handler) -> Result<String, &'static str> {
        let id = self
            .next
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
            .map_err(|_| "motion observation identities exhausted")?
            .to_string();
        self.handlers
            .write()
            .map_err(|_| "motion observer lock poisoned")?
            .insert(id.clone(), handler);
        Ok(id)
    }
    pub(crate) fn remove(&self, id: &str) {
        let removed = {
            self.handlers
                .write()
                .unwrap_or_else(|error| error.into_inner())
                .remove(id)
        };
        // Captured owners can reenter this registry from their destructors.
        drop(removed);
    }
    pub(crate) fn contains(&self, id: &str) -> bool {
        self.handlers
            .read()
            .unwrap_or_else(|error| error.into_inner())
            .contains_key(id)
    }
    pub(crate) fn ids(&self) -> Vec<String> {
        self.handlers
            .read()
            .unwrap_or_else(|error| error.into_inner())
            .keys()
            .cloned()
            .collect()
    }
    pub(crate) fn dispatch(&self, id: &str, enabled: bool) {
        let callback = self
            .handlers
            .read()
            .unwrap_or_else(|error| error.into_inner())
            .get(id)
            .cloned();
        if let Some(callback) = callback {
            callback(enabled);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn independent_owners_retire_without_reusing_identity_or_holding_callback_locks() {
        let a = Arc::new(MotionRoutes::default());
        let b = MotionRoutes::default();
        let count = Arc::new(AtomicU64::new(0));
        let counter = count.clone();
        let id = a
            .insert(Arc::new(move |_| {
                counter.fetch_add(1, Ordering::Relaxed);
            }))
            .unwrap();
        b.insert(Arc::new(|_| panic!("another owner"))).unwrap();
        a.dispatch(&id, false);
        a.remove(&id);
        a.dispatch(&id, true);
        assert_eq!(count.load(Ordering::Relaxed), 1);
        let weak = Arc::downgrade(&a);
        let replacement = a
            .insert(Arc::new(move |_| {
                let routes = weak.upgrade().unwrap();
                for id in routes.ids() {
                    routes.remove(&id);
                }
            }))
            .unwrap();
        assert_ne!(id, replacement);
        a.dispatch(&replacement, true);
        assert!(!a.contains(&replacement));
    }
    #[test]
    fn observations_have_no_application_budget() {
        let routes = MotionRoutes::default();
        for _ in 0..100 {
            routes.insert(Arc::new(|_| {})).unwrap();
        }
        assert_eq!(routes.ids().len(), 100);
    }
    #[test]
    fn captured_owner_destructor_reenters_after_the_registry_lock_is_released() {
        struct Captured(Arc<MotionRoutes>);
        impl Drop for Captured {
            fn drop(&mut self) {
                assert!(self.0.ids().is_empty());
            }
        }
        let routes = Arc::new(MotionRoutes::default());
        let captured = Captured(routes.clone());
        let id = routes
            .insert(Arc::new(move |_| {
                let _ = &captured;
            }))
            .unwrap();
        routes.remove(&id);
    }
}
