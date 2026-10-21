//! Instance-owned observation identities and callback retirement, without platform objects.

use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, RwLock,
    },
};

pub(crate) type Handler = Arc<dyn Fn(bool) + Send + Sync + 'static>;

#[derive(Default)]
pub(crate) struct MotionRoutes {
    next: AtomicU64,
    handlers: RwLock<BTreeMap<String, Handler>>,
}

pub(crate) struct MotionRegistration {
    pub(crate) id: String,
    owner: Arc<MotionRoutes>,
}

impl MotionRegistration {
    pub(crate) fn retire(&self) {
        let removed = {
            let mut handlers = self.owner.handlers.write().unwrap_or_else(|error| {
                log::error!("motion observer lock poisoned during retirement");
                error.into_inner()
            });
            handlers.remove(&self.id)
        };
        // Captured owners may reenter the routes from their destructors.
        drop(removed);
    }
}

impl Drop for MotionRegistration {
    fn drop(&mut self) {
        self.retire();
    }
}

impl MotionRoutes {
    pub(crate) fn register(
        self: &Arc<Self>,
        handler: Handler,
    ) -> Result<MotionRegistration, &'static str> {
        let id = self
            .next
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
            .map_err(|_| "motion observation identities exhausted")?
            .to_string();
        self.handlers
            .write()
            .map_err(|_| "motion observer lock poisoned")?
            .insert(id.clone(), handler);
        Ok(MotionRegistration {
            id,
            owner: self.clone(),
        })
    }

    pub(crate) fn ids(&self) -> Result<Vec<String>, &'static str> {
        Ok(self
            .handlers
            .read()
            .map_err(|_| "motion observer lock poisoned")?
            .keys()
            .cloned()
            .collect())
    }

    pub(crate) fn dispatch(&self, id: &str, enabled: bool) -> Result<bool, &'static str> {
        let handler = self
            .handlers
            .read()
            .map_err(|_| "motion observer lock poisoned")?
            .get(id)
            .cloned();
        if let Some(handler) = handler {
            handler(enabled);
            Ok(true)
        } else {
            // ArkTS prunes retired routes and removes its listener when none remain.
            Ok(false)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn drop_retires_delivery_and_ready_snapshot_without_reusing_identity() {
        let routes = Arc::new(MotionRoutes::default());
        let count = Arc::new(AtomicU64::new(0));
        let counter = count.clone();
        let registration = routes
            .register(Arc::new(move |_| {
                counter.fetch_add(1, Ordering::Relaxed);
            }))
            .unwrap();
        let id = registration.id.clone();
        assert!(routes.dispatch(&id, false).unwrap());
        assert_eq!(routes.ids().unwrap(), std::slice::from_ref(&id));
        drop(registration);
        assert!(!routes.dispatch(&id, true).unwrap());
        assert!(routes.ids().unwrap().is_empty());
        assert_eq!(count.load(Ordering::Relaxed), 1);
        assert_ne!(id, routes.register(Arc::new(|_| {})).unwrap().id);
    }

    #[test]
    fn callback_can_drop_itself_without_holding_route_locks() {
        let routes = Arc::new(MotionRoutes::default());
        let slot = Arc::new(Mutex::new(None::<MotionRegistration>));
        let callback_slot = slot.clone();
        let registration = routes
            .register(Arc::new(move |_| {
                callback_slot.lock().unwrap().take();
            }))
            .unwrap();
        let id = registration.id.clone();
        *slot.lock().unwrap() = Some(registration);
        assert!(routes.dispatch(&id, true).unwrap());
        assert!(!routes.dispatch(&id, false).unwrap());
    }

    #[test]
    fn captured_destructor_runs_outside_route_locks() {
        struct Captured(Arc<MotionRoutes>);
        impl Drop for Captured {
            fn drop(&mut self) {
                assert!(self.0.ids().unwrap().is_empty());
            }
        }
        let routes = Arc::new(MotionRoutes::default());
        let captured = Captured(routes.clone());
        let registration = routes
            .register(Arc::new(move |_| {
                let _ = &captured;
            }))
            .unwrap();
        drop(registration);
    }

    #[test]
    fn owners_are_independent_and_observations_have_no_consumer_budget() {
        let a = Arc::new(MotionRoutes::default());
        let b = Arc::new(MotionRoutes::default());
        let registration = a.register(Arc::new(|_| {})).unwrap();
        assert!(!b.dispatch(&registration.id, true).unwrap());
        let registrations: Vec<_> = (0..100)
            .map(|_| b.register(Arc::new(|_| {})).unwrap())
            .collect();
        drop(registration);
        assert!(a.ids().unwrap().is_empty());
        assert_eq!(b.ids().unwrap().len(), 100);
        drop(registrations);
        assert!(b.ids().unwrap().is_empty());
    }

    #[test]
    fn exhausted_identity_is_an_error_not_a_reused_route() {
        let routes = Arc::new(MotionRoutes::default());
        routes.next.store(u64::MAX, Ordering::Relaxed);
        assert!(matches!(
            routes.register(Arc::new(|_| {})),
            Err("motion observation identities exhausted")
        ));
        assert!(routes.ids().unwrap().is_empty());
    }
}
