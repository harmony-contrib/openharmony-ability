#[cfg(any(feature = "keyboard", test))]
use std::sync::{
    atomic::{AtomicU8, Ordering},
    Weak,
};
use std::{
    collections::{HashMap, VecDeque},
    sync::{Arc, Mutex},
};

#[derive(Clone)]
pub(crate) struct InputOwner {
    name: String,
    lifetime: Arc<()>,
}

enum InputKind {
    Ordinary,
    #[cfg(any(feature = "keyboard", test))]
    Key(Arc<AtomicU8>),
}

pub(crate) enum Delivery<T> {
    Input {
        owner: String,
        value: T,
        ime_consumed: Option<bool>,
    },
    Wake,
}

enum Entry<T> {
    Input {
        owner: InputOwner,
        value: T,
        kind: InputKind,
    },
    Wake,
}

struct State<T> {
    owners: HashMap<String, Arc<()>>,
    events: VecDeque<Entry<T>>,
    #[cfg(any(feature = "keyboard", test))]
    current_keys: HashMap<String, Weak<AtomicU8>>,
}

pub(crate) struct InputQueue<T> {
    state: Mutex<State<T>>,
}

impl<T> Default for InputQueue<T> {
    fn default() -> Self {
        Self {
            state: Mutex::new(State {
                owners: HashMap::new(),
                events: VecDeque::new(),
                #[cfg(any(feature = "keyboard", test))]
                current_keys: HashMap::new(),
            }),
        }
    }
}

impl<T> InputQueue<T> {
    pub(crate) fn activate(&self, name: &str) -> Result<InputOwner, &'static str> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "Native input queue poisoned")?;
        let lifetime = Arc::new(());
        state.owners.insert(name.to_owned(), lifetime.clone());
        #[cfg(any(feature = "keyboard", test))]
        state.current_keys.remove(name);
        state
            .events
            .retain(|entry| !matches!(entry, Entry::Input { owner, .. } if owner.name == name));
        Ok(InputOwner {
            name: name.to_owned(),
            lifetime,
        })
    }

    pub(crate) fn discard(&self, name: &str) -> Result<(), &'static str> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "Native input queue poisoned")?;
        state.owners.remove(name);
        #[cfg(any(feature = "keyboard", test))]
        state.current_keys.remove(name);
        state
            .events
            .retain(|entry| !matches!(entry, Entry::Input { owner, .. } if owner.name == name));
        Ok(())
    }

    pub(crate) fn push(&self, owner: &InputOwner, value: T) -> Result<bool, &'static str> {
        self.push_with_kind(owner, value, InputKind::Ordinary)
    }

    #[cfg(any(feature = "keyboard", test))]
    pub(crate) fn push_key(&self, owner: &InputOwner, value: T) -> Result<bool, &'static str> {
        self.push_with_kind(owner, value, InputKind::Key(Arc::new(AtomicU8::new(0))))
    }

    fn push_with_kind(
        &self,
        owner: &InputOwner,
        value: T,
        kind: InputKind,
    ) -> Result<bool, &'static str> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "Native input queue poisoned")?;
        if !state
            .owners
            .get(&owner.name)
            .is_some_and(|active| Arc::ptr_eq(active, &owner.lifetime))
        {
            return Ok(false);
        }
        #[cfg(any(feature = "keyboard", test))]
        if let InputKind::Key(disposition) = &kind {
            if let Some(previous) = state
                .current_keys
                .insert(owner.name.clone(), Arc::downgrade(disposition))
                .and_then(|previous| previous.upgrade())
            {
                let _ = previous.compare_exchange(0, 2, Ordering::AcqRel, Ordering::Acquire);
            }
        }
        state.events.push_back(Entry::Input {
            owner: owner.clone(),
            value,
            kind,
        });
        Ok(true)
    }

    #[cfg(any(feature = "keyboard", test))]
    pub(crate) fn after_ime(&self, owner: &InputOwner) -> Result<(), &'static str> {
        self.resolve_key(owner, 1)
    }

    #[cfg(any(feature = "keyboard", test))]
    pub(crate) fn ime_edit(&self, owner: &InputOwner) -> Result<(), &'static str> {
        self.resolve_key(owner, 2)
    }

    #[cfg(any(feature = "keyboard", test))]
    fn resolve_key(&self, owner: &InputOwner, resolved: u8) -> Result<(), &'static str> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "Native input queue poisoned")?;
        // Pre/post callbacks belong to the current platform dispatch, not a timestamp.
        // Repeated physical transitions with identical timestamps remain distinct entries.
        if state
            .owners
            .get(&owner.name)
            .is_some_and(|active| Arc::ptr_eq(active, &owner.lifetime))
        {
            if let Some(disposition) = state
                .current_keys
                .remove(&owner.name)
                .and_then(|current| current.upgrade())
            {
                let _ =
                    disposition.compare_exchange(0, resolved, Ordering::AcqRel, Ordering::Acquire);
            }
        }
        Ok(())
    }

    pub(crate) fn wake(&self) -> Result<(), &'static str> {
        self.state
            .lock()
            .map_err(|_| "Native input queue poisoned")?
            .events
            .push_back(Entry::Wake);
        Ok(())
    }

    pub(crate) fn has_pending(&self) -> bool {
        self.state
            .lock()
            .map(|state| !state.events.is_empty())
            .unwrap_or(false)
    }

    pub(crate) fn pop(&self) -> Result<Option<Delivery<T>>, &'static str> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "Native input queue poisoned")?;
        Ok(state.events.pop_front().map(|entry| match entry {
            Entry::Wake => Delivery::Wake,
            Entry::Input { owner, value, kind } => Delivery::Input {
                owner: owner.name,
                value,
                ime_consumed: match kind {
                    InputKind::Ordinary => None,
                    #[cfg(any(feature = "keyboard", test))]
                    InputKind::Key(disposition) => {
                        let _ =
                            disposition.compare_exchange(0, 2, Ordering::AcqRel, Ordering::Acquire);
                        Some(disposition.load(Ordering::Acquire) != 1)
                    }
                },
            },
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input<T>(delivery: Option<Delivery<T>>) -> (String, T, Option<bool>) {
        match delivery.expect("queued delivery") {
            Delivery::Input {
                owner,
                value,
                ime_consumed,
            } => (owner, value, ime_consumed),
            Delivery::Wake => panic!("expected input"),
        }
    }

    #[test]
    fn input_edits_and_wake_share_fifo_order() {
        let queue = InputQueue::default();
        let main = queue.activate("main").unwrap();
        let child = queue.activate("child").unwrap();
        queue.push(&main, "delete").unwrap();
        queue.wake().unwrap();
        queue.push(&child, "preview").unwrap();
        queue.push(&main, "insert").unwrap();
        assert_eq!(input(queue.pop().unwrap()), ("main".into(), "delete", None));
        assert!(matches!(queue.pop().unwrap(), Some(Delivery::Wake)));
        assert_eq!(
            input(queue.pop().unwrap()),
            ("child".into(), "preview", None)
        );
        assert_eq!(input(queue.pop().unwrap()), ("main".into(), "insert", None));
        assert!(queue.pop().unwrap().is_none());
    }

    #[test]
    fn each_physical_key_is_delivered_once_without_timestamp_deduplication() {
        let queue = InputQueue::default();
        let owner = queue.activate("main").unwrap();
        for _ in 0..3 {
            queue.push_key(&owner, (42, "a")).unwrap();
            queue.after_ime(&owner).unwrap();
        }
        queue.push_key(&owner, (42, "a")).unwrap();
        queue.ime_edit(&owner).unwrap();
        queue.push(&owner, (42, "composition")).unwrap();
        for _ in 0..3 {
            assert_eq!(input(queue.pop().unwrap()).2, Some(false));
        }
        assert_eq!(input(queue.pop().unwrap()).2, Some(true));
        assert_eq!(input(queue.pop().unwrap()).1, (42, "composition"));
        assert!(queue.pop().unwrap().is_none());
    }

    #[test]
    fn consumed_key_without_an_edit_is_still_delivered() {
        let queue = InputQueue::default();
        let owner = queue.activate("main").unwrap();
        assert!(!queue.has_pending());
        queue.push_key(&owner, "candidate navigation").unwrap();
        assert!(queue.has_pending());
        assert_eq!(input(queue.pop().unwrap()).2, Some(true));
        assert!(!queue.has_pending());
        assert!(queue.pop().unwrap().is_none());
    }

    #[test]
    fn key_resolution_never_crosses_owner_boundaries() {
        let queue = InputQueue::default();
        let main = queue.activate("main").unwrap();
        let child = queue.activate("child").unwrap();
        queue.push_key(&main, "main").unwrap();
        queue.push_key(&child, "child").unwrap();
        queue.after_ime(&main).unwrap();
        assert_eq!(input(queue.pop().unwrap()).2, Some(false));
        assert_eq!(input(queue.pop().unwrap()).2, Some(true));
    }

    #[test]
    fn duplicate_post_callback_cannot_reclassify_an_older_consumed_key() {
        let queue = InputQueue::default();
        let owner = queue.activate("main").unwrap();
        queue.push_key(&owner, "consumed").unwrap();
        queue.push_key(&owner, "unconsumed").unwrap();
        queue.after_ime(&owner).unwrap();
        queue.after_ime(&owner).unwrap();
        assert_eq!(input(queue.pop().unwrap()).2, Some(true));
        assert_eq!(input(queue.pop().unwrap()).2, Some(false));
        queue.after_ime(&owner).unwrap();
        assert!(queue.pop().unwrap().is_none());
    }

    #[test]
    fn retired_key_callbacks_cannot_change_replacement_disposition() {
        let queue = InputQueue::default();
        let old = queue.activate("main").unwrap();
        queue.push_key(&old, "old").unwrap();
        let replacement = queue.activate("main").unwrap();
        queue.push_key(&replacement, "replacement").unwrap();
        queue.after_ime(&old).unwrap();
        queue.ime_edit(&old).unwrap();
        queue.after_ime(&replacement).unwrap();
        assert_eq!(
            input(queue.pop().unwrap()),
            ("main".into(), "replacement", Some(false))
        );
        assert!(queue.pop().unwrap().is_none());
    }

    #[test]
    fn draining_releases_the_lock_before_the_handler_can_enqueue_or_retire() {
        let queue = InputQueue::default();
        let owner = queue.activate("main").unwrap();
        queue.push(&owner, 1).unwrap();
        assert_eq!(input(queue.pop().unwrap()).1, 1);
        queue.push(&owner, 2).unwrap();
        queue.discard("main").unwrap();
        queue.wake().unwrap();
        assert!(matches!(queue.pop().unwrap(), Some(Delivery::Wake)));
        assert!(queue.pop().unwrap().is_none());
    }

    #[test]
    fn retirement_and_replacement_reject_a_callback_already_running() {
        let queue = Arc::new(InputQueue::default());
        let old = queue.activate("main").unwrap();
        let child = queue.activate("child").unwrap();
        queue.push(&old, "stale pending edit").unwrap();
        queue.push(&child, "live child edit").unwrap();
        queue.wake().unwrap();
        let (resume, resumed) = std::sync::mpsc::channel();
        let callback = std::thread::spawn({
            let queue = queue.clone();
            move || {
                resumed.recv().unwrap();
                queue.push(&old, "late edit").unwrap()
            }
        });
        queue.discard("main").unwrap();
        let replacement = queue.activate("main").unwrap();
        resume.send(()).unwrap();
        assert!(!callback.join().unwrap());
        queue.push(&replacement, "replacement edit").unwrap();
        assert_eq!(input(queue.pop().unwrap()).1, "live child edit");
        assert!(matches!(queue.pop().unwrap(), Some(Delivery::Wake)));
        assert_eq!(input(queue.pop().unwrap()).1, "replacement edit");
        assert!(queue.pop().unwrap().is_none());
    }
}
