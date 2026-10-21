//! Instance-owned native controller generations and callback declarations.
use crate::NativeWebviewEvent;
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

type Callback = Arc<dyn Fn(NativeWebviewEvent) + Send + Sync>;
pub(crate) struct Registration {
    target_id: u32,
    callback: Callback,
}
#[derive(Default)]
pub(crate) struct NativeEvents {
    owner: Arc<()>,
    state: Mutex<State>,
}
#[derive(Default)]
struct State {
    entries: BTreeMap<String, Arc<Registration>>,
    controllers: BTreeMap<String, Controller>,
    next_generation: u32,
}
struct Controller {
    target_id: u32,
    generation: u32,
    native_tag: Option<String>,
}
pub(crate) struct Prepared {
    pub(crate) generation: u32,
    pub(crate) previous_tag: Option<String>,
}
#[derive(Debug, PartialEq)]
pub(crate) enum GenerationError {
    WrongTarget,
    Exhausted,
}
impl NativeEvents {
    pub(crate) fn owner(&self) -> Arc<()> {
        self.owner.clone()
    }
    pub(crate) fn register(
        &self,
        id: String,
        target_id: u32,
        callback: Callback,
    ) -> Arc<Registration> {
        let entry = Arc::new(Registration {
            target_id,
            callback,
        });
        let previous = self
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .entries
            .insert(id, entry.clone());
        drop(previous);
        entry
    }
    pub(crate) fn remove(&self, id: &str, expected: &Arc<Registration>) {
        let previous = {
            let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
            if state
                .entries
                .get(id)
                .is_some_and(|entry| Arc::ptr_eq(entry, expected))
            {
                state.entries.remove(id)
            } else {
                None
            }
        };
        drop(previous);
    }
    pub(crate) fn invalidate(&self) {
        self.state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .controllers
            .clear();
    }
    pub(crate) fn prepare(
        &self,
        id: &str,
        target_id: u32,
    ) -> std::result::Result<Prepared, GenerationError> {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if state
            .entries
            .get(id)
            .is_some_and(|entry| entry.target_id != target_id)
        {
            return Err(GenerationError::WrongTarget);
        }
        state.next_generation = state
            .next_generation
            .checked_add(1)
            .ok_or(GenerationError::Exhausted)?;
        let generation = state.next_generation;
        let previous_tag = state
            .controllers
            .insert(
                id.into(),
                Controller {
                    target_id,
                    generation,
                    native_tag: None,
                },
            )
            .and_then(|controller| controller.native_tag);
        Ok(Prepared {
            generation,
            previous_tag,
        })
    }
    pub(crate) fn attach(
        &self,
        id: &str,
        target_id: u32,
        generation: u32,
        native_tag: &str,
    ) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let Some(controller) = state.controllers.get_mut(id).filter(|controller| {
            controller.target_id == target_id
                && controller.generation == generation
                && generation != 0
        }) else {
            return false;
        };
        if native_tag.trim().is_empty()
            || controller
                .native_tag
                .as_deref()
                .is_some_and(|current| current != native_tag)
        {
            return false;
        }
        controller.native_tag = Some(native_tag.into());
        true
    }
    pub(crate) fn owns_generation(&self, id: &str, target_id: u32, generation: u32) -> bool {
        self.state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .controllers
            .get(id)
            .is_some_and(|controller| {
                controller.target_id == target_id
                    && controller.generation == generation
                    && controller.native_tag.is_some()
            })
    }
    pub(crate) fn is_current(&self, id: &str, native_tag: &str) -> bool {
        self.state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .controllers
            .get(id)
            .is_some_and(|controller| controller.native_tag.as_deref() == Some(native_tag))
    }
    pub(crate) fn retire(
        &self,
        id: &str,
        target_id: u32,
        generation: u32,
        native_tag: &str,
    ) -> bool {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if state.controllers.get(id).is_some_and(|controller| {
            controller.target_id == target_id
                && controller.generation == generation
                && controller
                    .native_tag
                    .as_deref()
                    .is_none_or(|tag| tag == native_tag)
        }) {
            state.controllers.remove(id);
            true
        } else {
            false
        }
    }
    pub(crate) fn cancel(&self, id: &str, target_id: u32, generation: u32) -> Option<String> {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if state.controllers.get(id).is_some_and(|controller| {
            controller.target_id == target_id && controller.generation == generation
        }) {
            state
                .controllers
                .remove(id)
                .and_then(|controller| controller.native_tag)
        } else {
            None
        }
    }
    pub(crate) fn dispatch(&self, event: NativeWebviewEvent) {
        let callback = {
            let state = self.state.lock().unwrap_or_else(|error| error.into_inner());
            state
                .controllers
                .get(&event.id)
                .filter(|controller| {
                    controller.target_id == event.target_id
                        && event.generation != 0
                        && controller.generation == event.generation
                })
                .and_then(|_| state.entries.get(&event.id))
                .filter(|entry| entry.target_id == event.target_id)
                .map(|entry| entry.callback.clone())
        };
        if let Some(callback) = callback {
            callback(event);
        }
    }
}
