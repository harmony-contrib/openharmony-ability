//! A pending unsubscribe resolves the current session when the worker executes it.
pub(crate) struct MotionStop<A> {
    app: A,
    id: String,
}
impl<A> MotionStop<A> {
    pub(crate) fn new(app: A, id: String) -> Self {
        Self { app, id }
    }
    pub(crate) fn run<C, E>(
        self,
        resolve: impl FnOnce(&A) -> Result<C, E>,
        stop: impl FnOnce(C, String) -> Result<(), E>,
    ) -> Result<(), E> {
        stop(resolve(&self.app)?, self.id)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    };
    #[test]
    fn retirement_after_replay_uses_the_new_session_and_original_identity() {
        let app = Arc::new(AtomicU64::new(1));
        let stop = MotionStop::new(app.clone(), "observation-7".into());
        app.store(2, Ordering::Relaxed); // session rebuild and replay
        stop.run(
            |app| Ok::<_, ()>(app.load(Ordering::Relaxed)),
            |session, id| {
                assert_eq!(session, 2);
                assert_eq!(id, "observation-7");
                Ok(())
            },
        )
        .unwrap();
    }
    #[test]
    fn unavailable_session_or_failed_unsubscribe_is_not_success() {
        assert_eq!(
            MotionStop::new((), "0".into()).run(
                |_| Err::<(), _>("inactive"),
                |_, _| panic!("old session used")
            ),
            Err("inactive")
        );
        assert_eq!(
            MotionStop::new((), "0".into())
                .run(|_| Ok::<_, &str>(()), |_, _| Err("platform failure")),
            Err("platform failure")
        );
    }
}
