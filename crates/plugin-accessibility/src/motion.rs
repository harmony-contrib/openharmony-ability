//! Instance-owned reduced-motion observations and one lazy cleanup worker.
use super::{
    motion_routes::{Handler, MotionRoutes},
    motion_stop::MotionStop,
};
use crate::{AccessibilityBridgePlugin, AccessibilityClient, AccessibilityEventAcknowledgement};
use napi_derive_ohos::napi;
use napi_ohos::{Error, Result};
use openharmony_ability::{impl_bridge_napi_type, OpenHarmonyApp};
use std::sync::{mpsc, Arc, Mutex, Weak};

/// Registration identity shared by subscribe and unsubscribe actions.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityMotionRequest {
    /// Monotonic identity scoped to the registered plugin owner.
    pub id: String,
}
impl_bridge_napi_type!(
    AccessibilityMotionRequest,
    "ohos.accessibility.MotionRequest"
);
/// Initial or changed reduced-motion value for one observation.
#[napi(object)]
#[derive(Clone, Debug)]
pub struct AccessibilityMotionState {
    /// Registration receiving this observation.
    pub id: String,
    /// Whether the system requests reduced motion.
    pub enabled: bool,
}
impl_bridge_napi_type!(AccessibilityMotionState, "ohos.accessibility.MotionState");

enum Job {
    Stop(MotionStop<OpenHarmonyApp>),
    Replay {
        app: OpenHarmonyApp,
        owner: Weak<Observers>,
    },
}
#[derive(Default)]
pub(crate) struct Observers {
    routes: MotionRoutes,
    worker: Mutex<Option<mpsc::Sender<Job>>>,
}
impl Observers {
    fn start_worker() -> Result<mpsc::Sender<Job>> {
        let (sender, receiver) = mpsc::channel();
        std::thread::Builder::new().name("accessibility-motion".into()).spawn(move || {
            // The receiver owns neither the sender nor a permanent app/owner.
            // Dropping the registered owner ends this worker after queued jobs.
            for job in receiver {
                match job {
                    Job::Stop(stop) => {
                        let result = stop.run(AccessibilityClient::new, |client, id| {
                            futures_executor::block_on(client.motion_call("stop-observing-reduce-motion", id))
                        });
                        if let Err(error) = result {
                            log::warn!("motion platform cleanup failed; host disposal remains required: {error}");
                        }
                    }
                    Job::Replay { app, owner } => {
                        let Some(owner) = owner.upgrade() else { continue; };
                        let client = match AccessibilityClient::new(&app) {
                            Ok(client) => client,
                            Err(error) => { log::warn!("motion replay bridge: {error}"); continue; }
                        };
                        for id in owner.routes.ids() {
                            if !owner.routes.contains(&id) { continue; }
                            let result = futures_executor::block_on(async {
                                client.motion_call("observe-reduce-motion", id.clone()).await?;
                                // Drop can race replay's in-flight subscription. Its earlier stop
                                // must not leave a late successful subscription installed.
                                if !owner.routes.contains(&id) {
                                    client.motion_call("stop-observing-reduce-motion", id).await?;
                                }
                                Ok::<(), Error>(())
                            });
                            if let Err(error) = result { log::warn!("motion observation replay: {error}"); }
                        }
                    }
                }
            }
        }).map_err(|error| Error::from_reason(format!("motion worker: {error}")))?;
        Ok(sender)
    }
    fn ensure_worker(&self) -> Result<()> {
        let mut worker = self
            .worker
            .lock()
            .map_err(|_| Error::from_reason("motion worker lock poisoned"))?;
        if worker.is_none() {
            *worker = Some(Self::start_worker()?);
        }
        Ok(())
    }
    fn enqueue(&self, job: Job) -> Result<()> {
        let mut worker = self
            .worker
            .lock()
            .map_err(|_| Error::from_reason("motion worker lock poisoned"))?;
        if worker.is_none() {
            *worker = Some(Self::start_worker()?);
        }
        if let Err(error) = worker.as_ref().expect("initialized worker").send(job) {
            // A disconnected worker never silently accepts cleanup. Recreate it
            // once with the original owned job; callers still see startup failure.
            *worker = Some(Self::start_worker()?);
            worker
                .as_ref()
                .expect("restarted worker")
                .send(error.0)
                .map_err(|_| Error::from_reason("motion worker disconnected"))?;
        }
        Ok(())
    }
    pub(crate) fn dispatch(&self, state: &AccessibilityMotionState) {
        self.routes.dispatch(&state.id, state.enabled);
    }
    pub(crate) fn replay(self: &Arc<Self>, app: &OpenHarmonyApp) {
        if self.routes.ids().is_empty() {
            return;
        }
        if let Err(error) = self.enqueue(Job::Replay {
            app: app.clone(),
            owner: Arc::downgrade(self),
        }) {
            log::warn!("motion replay could not be queued: {error}");
        }
    }
}
/// Owns Rust delivery and schedules platform unsubscribe on drop.
/// A callback already running can finish. Failed platform cleanup is reported;
/// the ArkTS host's disposal still removes its system listener.
pub struct AccessibilityMotionObservation {
    id: String,
    observers: Arc<Observers>,
    app: OpenHarmonyApp,
}
impl Drop for AccessibilityMotionObservation {
    fn drop(&mut self) {
        self.observers.routes.remove(&self.id);
        if let Err(error) = self.observers.enqueue(Job::Stop(MotionStop::new(
            self.app.clone(),
            self.id.clone(),
        ))) {
            log::warn!("motion platform cleanup could not be queued: {error}");
        }
    }
}
impl AccessibilityClient {
    /// Observes API-23 reduced motion, with initial state and changes on one ordered callback.
    /// The callback runs on the UI thread and must not block or reenter the bridge.
    pub async fn observe_reduce_motion<F>(
        &self,
        handler: F,
    ) -> Result<AccessibilityMotionObservation>
    where
        F: Fn(bool) + Send + Sync + 'static,
    {
        let plugin = self
            .app
            .registered_plugin::<AccessibilityBridgePlugin>()?
            .ok_or_else(|| Error::from_reason("accessibility plugin is not registered"))?;
        plugin.motion.ensure_worker()?;
        let callback: Handler = Arc::new(handler);
        let id = plugin
            .motion
            .routes
            .insert(callback)
            .map_err(Error::from_reason)?;
        let observation = AccessibilityMotionObservation {
            id: id.clone(),
            observers: plugin.motion.clone(),
            app: self.app.clone(),
        };
        self.motion_call("observe-reduce-motion", id).await?;
        Ok(observation)
    }
    async fn motion_call(&self, action: &str, id: String) -> Result<()> {
        let response: AccessibilityEventAcknowledgement =
            self.call(action, AccessibilityMotionRequest { id }).await?;
        if !response.accepted {
            return Err(Error::from_reason("motion observation rejected"));
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use openharmony_ability::BridgeNapiType;
    #[test]
    fn stable_contracts() {
        assert_eq!(
            AccessibilityMotionRequest::TYPE_NAME,
            "ohos.accessibility.MotionRequest"
        );
        assert_eq!(
            AccessibilityMotionState::TYPE_NAME,
            "ohos.accessibility.MotionState"
        );
    }
}
