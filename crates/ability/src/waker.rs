//! Input and user wakes share one owned FIFO and one main-thread scheduling callback.
//! Resolve the endpoint at wake time: application proxies can predate lifecycle setup.

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, LazyLock, RwLock,
};

use napi_ohos::{
    threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode::NonBlocking},
    Status,
};

use crate::{input::queue::InputQueue, InputEvent};

pub(crate) struct InputWake {
    pub(crate) queue: Arc<InputQueue<InputEvent>>,
    pub(crate) callback: ThreadsafeFunction<(), (), (), Status, false>,
    pub(crate) scheduled: AtomicBool,
}

pub(crate) static WAKER: LazyLock<RwLock<Option<Arc<InputWake>>>> =
    LazyLock::new(|| RwLock::new(None));

fn endpoint_from(slot: &RwLock<Option<Arc<InputWake>>>) -> Option<Arc<InputWake>> {
    match slot.read() {
        Ok(endpoint) => endpoint.clone(),
        Err(error) => {
            crate::warn!("Cannot read native input waker: {error}");
            None
        }
    }
}

fn schedule(endpoint: &InputWake) {
    if endpoint.scheduled.swap(true, Ordering::AcqRel) {
        return;
    }
    let status = endpoint.callback.call((), NonBlocking);
    if status != Status::Ok {
        endpoint.scheduled.store(false, Ordering::Release);
        crate::warn!("Cannot schedule native input queue: {status:?}");
    }
}

pub(crate) fn clear_scheduled(
    slot: &RwLock<Option<Arc<InputWake>>>,
    queue: &Arc<InputQueue<InputEvent>>,
) {
    if let Some(endpoint) = endpoint_from(slot).or_else(|| endpoint_from(&WAKER)) {
        if Arc::ptr_eq(&endpoint.queue, queue) {
            endpoint.scheduled.store(false, Ordering::Release);
        }
    }
}

pub(crate) fn schedule_input(
    slot: &RwLock<Option<Arc<InputWake>>>,
    queue: &Arc<InputQueue<InputEvent>>,
) {
    if let Some(endpoint) = endpoint_from(slot).or_else(|| endpoint_from(&WAKER)) {
        if Arc::ptr_eq(&endpoint.queue, queue) {
            schedule(&endpoint);
        }
    }
}

#[derive(Clone, Default)]
pub struct OpenHarmonyWaker {
    slot: Option<Arc<RwLock<Option<Arc<InputWake>>>>>,
}

impl OpenHarmonyWaker {
    pub fn new() -> Self {
        Self { slot: None }
    }

    pub(crate) fn from_slot(slot: Arc<RwLock<Option<Arc<InputWake>>>>) -> Self {
        Self { slot: Some(slot) }
    }

    pub fn wake(&self) {
        let endpoint = self
            .slot
            .as_deref()
            .and_then(endpoint_from)
            .or_else(|| endpoint_from(&WAKER));
        if let Some(endpoint) = endpoint {
            match endpoint.queue.wake() {
                Ok(()) => schedule(&endpoint),
                Err(error) => crate::warn!("{error}"),
            }
        }
    }
}
