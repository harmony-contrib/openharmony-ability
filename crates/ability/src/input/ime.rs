use std::{
    collections::{HashMap, VecDeque},
    sync::{Arc, Mutex},
};

use napi_ohos::{
    bindgen_prelude::Function,
    threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode::NonBlocking},
    Env, Result, Status,
};

#[cfg(feature = "keyboard")]
use crate::KeyboardInputDelivery;
use crate::{Event, OpenHarmonyApp};
use ohos_ime_binding::{AttachOptions, IME};

use super::{ImeEvent, InputEvent};

#[derive(Default)]
pub(crate) struct ImeInputQueue {
    state: Mutex<ImeInputState>,
}

#[derive(Default)]
struct ImeInputState {
    events: VecDeque<(String, ImeEvent)>,
    surfaces: HashMap<String, Arc<()>>,
}

impl ImeInputQueue {
    fn activate(&self, owner: &str) -> Option<Arc<()>> {
        match self.state.lock() {
            Ok(mut state) => {
                let surface = Arc::new(());
                state.events.retain(|(event_owner, _)| event_owner != owner);
                state.surfaces.insert(owner.to_owned(), surface.clone());
                Some(surface)
            }
            Err(error) => {
                crate::warn!("Cannot activate native IME input: {error}");
                None
            }
        }
    }

    fn push(&self, owner: &str, surface: &Arc<()>, event: ImeEvent) -> bool {
        match self.state.lock() {
            Ok(mut state) => {
                if !state
                    .surfaces
                    .get(owner)
                    .is_some_and(|active| Arc::ptr_eq(active, surface))
                {
                    return false;
                }
                state.events.push_back((owner.to_owned(), event));
                true
            }
            Err(error) => {
                crate::warn!("Cannot queue native IME input: {error}");
                false
            }
        }
    }

    fn pop(&self) -> Option<(String, ImeEvent)> {
        match self.state.lock() {
            Ok(mut state) => state.events.pop_front(),
            Err(error) => {
                crate::warn!("Cannot drain native IME input: {error}");
                None
            }
        }
    }

    pub(crate) fn discard(&self, owner: &str) {
        match self.state.lock() {
            Ok(mut state) => {
                state.surfaces.remove(owner);
                state.events.retain(|(event_owner, _)| event_owner != owner);
            }
            Err(error) => crate::warn!("Cannot discard native IME input: {error}"),
        }
    }
}

#[derive(Clone)]
pub(crate) struct ImeCallbackSource {
    queue: Arc<ImeInputQueue>,
    owner: String,
    native_window_id: i32,
    consume_key_events: bool,
    wake: Arc<ThreadsafeFunction<bool, (), bool, Status, false>>,
}

impl ImeCallbackSource {
    pub(crate) fn create_ime(&self) -> Result<IME> {
        let ime_callback = self.activate()?;

        // Reconnecting a hardware editor must not reopen a keyboard the user
        // dismissed. Explicit show requests still call try_show_keyboard().
        let ime = IME::new_for_window(AttachOptions::new(false), self.native_window_id);
        if self.consume_key_events {
            // These clients handle hardware characters and shortcuts themselves;
            // the IME still owns composition and candidate selection.
            ime.set_consume_key_events(true);
        }

        {
            let ime_callback = ime_callback.clone();
            ime.insert_text(move |text| {
                ime_callback.send(ImeEvent::TextInputEvent(crate::TextInputEventData { text }));
            });
        }
        {
            let ime_callback = ime_callback.clone();
            ime.on_status_change(move |status| {
                ime_callback.send(ImeEvent::ImeStatusEvent(status));
            });
        }
        {
            let ime_callback = ime_callback.clone();
            ime.on_backspace(move |length| {
                ime_callback.send(ImeEvent::BackspaceEvent(length));
            });
        }
        {
            let ime_callback = ime_callback.clone();
            ime.on_delete_forward(move |length| {
                ime_callback.send(ImeEvent::DeleteForwardEvent(length));
            });
        }
        {
            let ime_callback = ime_callback.clone();
            ime.on_move_cursor(move |direction| {
                ime_callback.send(ImeEvent::MoveCursorEvent(direction));
            });
        }
        {
            let ime_callback = ime_callback.clone();
            ime.on_set_selection(move |selection| {
                ime_callback.send(ImeEvent::SelectionEvent {
                    start: selection.start,
                    end: selection.end,
                });
            });
        }
        {
            let ime_callback = ime_callback.clone();
            ime.on_extend_action(move |action| {
                ime_callback.send(ImeEvent::ExtendActionEvent(action));
            });
        }
        {
            let ime_callback = ime_callback.clone();
            ime.on_enter(move |key| {
                ime_callback.send(ImeEvent::EnterEvent(u32::from(key) as i32));
            });
        }
        {
            let ime_callback = ime_callback.clone();
            ime.on_preview(move |text, start, end| {
                ime_callback.send(ImeEvent::PreviewTextEvent { text, start, end });
            });
        }
        {
            let ime_callback = ime_callback.clone();
            ime.on_finish_preview(move || {
                ime_callback.send(ImeEvent::FinishPreviewEvent);
            });
        }

        Ok(ime)
    }

    pub(crate) fn activate(&self) -> Result<ImeCallback> {
        let surface = self
            .queue
            .activate(&self.owner)
            .ok_or_else(|| napi_ohos::Error::from_reason("Cannot activate native IME input"))?;
        Ok(ImeCallback {
            source: self.clone(),
            surface,
        })
    }
}

#[derive(Clone)]
pub(crate) struct ImeCallback {
    source: ImeCallbackSource,
    surface: Arc<()>,
}

impl ImeCallback {
    pub(crate) fn send(&self, event: ImeEvent) {
        // An IPC callback can already hold its closure when native teardown
        // unregisters it. A recreated surface or reassigned editor must not receive that late edit.
        if !self
            .source
            .queue
            .push(&self.source.owner, &self.surface, event)
        {
            return;
        }
        let status = self.source.wake.call(true, NonBlocking);
        if status != Status::Ok {
            crate::warn!("Cannot schedule native IME input: {status:?}");
        }
    }
}

impl OpenHarmonyApp {
    /// Whether the current render owner has a native editor, including before SurfaceCreate.
    /// Call only on the N-API/UI thread.
    pub fn is_text_input_ready_for(&self, window_id: i64) -> bool {
        let source = self.ime_sources.borrow().get(&window_id).cloned();
        source.is_some_and(|source| {
            self.render_window_id(&source.owner) == Some(window_id)
                && if window_id == 0 {
                    self.ime.borrow().is_some()
                } else {
                    self.sub_ime.borrow().contains_key(&window_id)
                }
        })
    }

    pub(crate) fn is_render_input_ready(&self, owner: &str) -> bool {
        self.render_window_id(owner).is_some_and(|window_id| {
            self.ime_sources
                .borrow()
                .get(&window_id)
                .is_some_and(|source| source.owner == owner)
                && self.is_text_input_ready_for(window_id)
        })
    }

    pub(crate) fn initialize_render_input(&self, source: &ImeCallbackSource) -> Result<()> {
        let window_id = self.render_window_id(&source.owner).ok_or_else(|| {
            napi_ohos::Error::from_reason("Native input requires a live render owner")
        })?;
        if self.is_render_input_ready(&source.owner) {
            return Ok(());
        }
        let ime = source.create_ime()?;
        if window_id == 0 {
            *self.ime.borrow_mut() = Some(ime);
        } else {
            self.sub_ime.borrow_mut().insert(window_id, ime);
        }
        self.ime_sources
            .borrow_mut()
            .insert(window_id, source.clone());
        self.notify_text_input_ready(window_id);
        Ok(())
    }

    pub(crate) fn notify_text_input_ready(&self, window_id: i64) {
        if let Ok(mut handler) = self.event_loop.try_borrow_mut() {
            if let Some(handler) = handler.as_mut() {
                let ready = self.is_text_input_ready_for(window_id);
                handler(Event::TextInputReadyChanged { window_id, ready });
            }
        } else {
            let app = self.clone();
            self.queue_after_input(move || app.notify_text_input_ready(window_id));
            self.create_waker().wake();
        }
    }

    pub(crate) fn drain_ime_input(&self) {
        while let Some((owner, event)) = self.ime_input.pop() {
            if !self.is_render_input_ready(&owner) {
                continue;
            }
            if let Some(ref mut handler) = *self.event_loop.borrow_mut() {
                match self.render_window_id(&owner) {
                    Some(0) => handler(Event::Input(InputEvent::Ime(event))),
                    Some(window_id) => handler(Event::SubWindowInput {
                        window_id,
                        event: InputEvent::Ime(event),
                    }),
                    None => {}
                }
            }
            self.drain_after_input();
        }
    }
}

pub(crate) fn ime_ts_fn(
    env: &Env,
    app: OpenHarmonyApp,
    render_owner: String,
    native_window_id: i32,
) -> Result<ImeCallbackSource> {
    let queue = app.ime_input.clone();
    #[cfg(feature = "keyboard")]
    let consume_key_events =
        app.keyboard_input_delivery() == KeyboardInputDelivery::ArkUiWithTextInput;
    #[cfg(not(feature = "keyboard"))]
    let consume_key_events = false;
    // Separate TSFNs can reorder deletion, composition and insertion. Keep the
    // owned events in one FIFO that native input callbacks can also drain before
    // dispatching a later shortcut or changing the focused editor.
    let callback: Function<bool, ()> =
        env.create_function_from_closure("ime_input_callback", move |_ctx| {
            app.drain_ime_input();
            Ok(())
        })?;
    let wake = callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;
    Ok(ImeCallbackSource {
        queue,
        owner: render_owner,
        native_window_id,
        consume_key_events,
        wake: Arc::new(wake),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn destroyed_surface_rejects_late_input_after_recreation() {
        let queue = ImeInputQueue::default();
        let old_surface = queue.activate("main").expect("active surface");
        assert!(queue.push("main", &old_surface, ImeEvent::BackspaceEvent(1)));
        queue.discard("main");
        let replacement = queue.activate("main").expect("replacement surface");
        assert!(!queue.push("main", &old_surface, ImeEvent::BackspaceEvent(2)));
        assert!(queue.push("main", &replacement, ImeEvent::BackspaceEvent(3)));
        assert!(matches!(
            queue.pop(),
            Some((_, ImeEvent::BackspaceEvent(3)))
        ));
        assert!(queue.pop().is_none());
    }

    #[test]
    fn replacement_invalidates_pending_input_without_affecting_other_windows() {
        let queue = ImeInputQueue::default();
        let main = queue.activate("main").expect("main surface");
        let child = queue.activate("child").expect("child surface");
        assert!(queue.push("main", &main, ImeEvent::BackspaceEvent(1)));
        assert!(queue.push("child", &child, ImeEvent::BackspaceEvent(2)));
        let replacement = queue.activate("main").expect("replacement surface");
        assert!(!queue.push("main", &main, ImeEvent::BackspaceEvent(3)));
        assert!(queue.push("main", &replacement, ImeEvent::BackspaceEvent(4)));
        assert!(
            matches!(queue.pop(), Some((owner, ImeEvent::BackspaceEvent(2))) if owner == "child")
        );
        assert!(
            matches!(queue.pop(), Some((owner, ImeEvent::BackspaceEvent(4))) if owner == "main")
        );
        assert!(queue.pop().is_none());
    }

    #[test]
    fn live_input_keeps_cross_window_fifo_order_after_another_surface_is_discarded() {
        let queue = ImeInputQueue::default();
        let main = queue.activate("main").expect("main surface");
        let child = queue.activate("child").expect("child surface");
        assert!(queue.push("main", &main, ImeEvent::BackspaceEvent(1)));
        assert!(queue.push("child", &child, ImeEvent::BackspaceEvent(2)));
        assert!(queue.push("main", &main, ImeEvent::DeleteForwardEvent(3)));
        queue.discard("child");
        assert!(!queue.push("child", &child, ImeEvent::BackspaceEvent(4)));
        assert!(matches!(
            queue.pop(),
            Some((_, ImeEvent::BackspaceEvent(1)))
        ));
        assert!(matches!(
            queue.pop(),
            Some((_, ImeEvent::DeleteForwardEvent(3)))
        ));
        assert!(queue.pop().is_none());
    }

    #[test]
    fn callback_already_running_at_teardown_cannot_queue_into_new_surface() {
        let queue = Arc::new(ImeInputQueue::default());
        let surface = queue.activate("main").expect("main surface");
        let (resume, resume_callback) = std::sync::mpsc::channel();
        let callback = std::thread::spawn({
            let queue = queue.clone();
            move || {
                resume_callback.recv().expect("resume callback");
                queue.push("main", &surface, ImeEvent::BackspaceEvent(9))
            }
        });
        queue.discard("main");
        let replacement = queue.activate("main").expect("replacement surface");
        resume.send(()).expect("release native callback");
        assert!(!callback.join().expect("native callback"));
        assert!(queue.push("main", &replacement, ImeEvent::BackspaceEvent(1)));
        assert!(matches!(
            queue.pop(),
            Some((_, ImeEvent::BackspaceEvent(1)))
        ));
        assert!(queue.pop().is_none());
    }
}
