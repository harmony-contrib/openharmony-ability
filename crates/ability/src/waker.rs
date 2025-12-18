use std::sync::{Arc, LazyLock, RwLock};

use napi_ohos::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};

type WakerType = LazyLock<RwLock<Option<Arc<ThreadsafeFunction<(), ()>>>>>;

pub(crate) static WAKER: WakerType = LazyLock::new(|| RwLock::new(None));

pub struct OpenHarmonyWaker {
    waker: Option<Arc<ThreadsafeFunction<(), ()>>>,
}

// Safety: ThreadsafeFunction can be called from any thread.
unsafe impl Send for OpenHarmonyWaker {}
unsafe impl Sync for OpenHarmonyWaker {}

impl OpenHarmonyWaker {
    pub fn new(waker: Option<Arc<ThreadsafeFunction<(), ()>>>) -> Self {
        Self { waker }
    }

    pub fn wake(&self) {
        if let Some(waker) = &self.waker {
            waker.call(Ok(()), ThreadsafeFunctionCallMode::NonBlocking);
        }
    }
}

impl Clone for OpenHarmonyWaker {
    fn clone(&self) -> Self {
        Self {
            waker: self.waker.clone(),
        }
    }
}
