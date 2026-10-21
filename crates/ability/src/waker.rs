//! Input and user wakes share one owned FIFO and one main-thread scheduling callback.
//! Resolve the endpoint at wake time: application proxies can predate lifecycle setup.

use std::sync::{Arc, LazyLock, RwLock};

use napi_ohos::{
    threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode::NonBlocking},
    Status,
};

use crate::{input::queue::InputQueue, InputEvent};

pub(crate) struct InputWake {
    pub(crate) queue: Arc<InputQueue<InputEvent>>,
    pub(crate) callback: ThreadsafeFunction<(), (), (), Status, false>,
}

pub(crate) static WAKER: LazyLock<RwLock<Option<Arc<InputWake>>>> =
    LazyLock::new(|| RwLock::new(None));

fn endpoint() -> Option<Arc<InputWake>> {
    match WAKER.read() {
        Ok(endpoint) => endpoint.clone(),
        Err(error) => {
            crate::warn!("Cannot read native input waker: {error}");
            None
        }
    }
}

fn schedule(endpoint: &InputWake) {
    let status = endpoint.callback.call((), NonBlocking);
    if status != Status::Ok {
        crate::warn!("Cannot schedule native input queue: {status:?}");
    }
}

pub(crate) fn schedule_input(queue: &Arc<InputQueue<InputEvent>>) {
    if let Some(endpoint) = endpoint() {
        if Arc::ptr_eq(&endpoint.queue, queue) {
            schedule(&endpoint);
        }
    }
}

#[derive(Clone, Default)]
pub struct OpenHarmonyWaker;

impl OpenHarmonyWaker {
    pub fn new() -> Self {
        Self
    }

    pub fn wake(&self) {
        if let Some(endpoint) = endpoint() {
            match endpoint.queue.wake() {
                Ok(()) => schedule(&endpoint),
                Err(error) => crate::warn!("{error}"),
            }
        }
    }
}
