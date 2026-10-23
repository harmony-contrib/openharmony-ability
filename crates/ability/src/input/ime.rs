use std::sync::{Arc, RwLock};

use napi_ohos::{Error, Result};
use ohos_ime_binding::{AttachOptions, IME};

use crate::{waker::InputWake, Event, OpenHarmonyApp};

use super::{
    queue::{Delivery, InputOwner, InputQueue},
    ImeEvent, InputEvent,
};

#[derive(Clone)]
pub(crate) struct ImeCallbackSource {
    owner: String,
    platform_window_id: i32,
    input: InputCallback,
    ready: bool,
}

#[derive(Clone)]
pub(crate) struct InputCallback {
    queue: Arc<InputQueue<InputEvent>>,
    waker: Arc<RwLock<Option<Arc<InputWake>>>>,
    owner: InputOwner,
}

impl InputCallback {
    pub(crate) fn send(&self, event: InputEvent) {
        self.enqueue(self.queue.push(&self.owner, event));
    }

    fn ime(&self, event: ImeEvent) {
        #[cfg(feature = "keyboard")]
        if !matches!(event, ImeEvent::ImeStatusEvent(_)) {
            if let Err(error) = self.queue.ime_edit(&self.owner) {
                crate::warn!("{error}");
                return;
            }
        }
        self.send(InputEvent::Ime(event));
    }

    #[cfg(feature = "keyboard")]
    pub(crate) fn key(&self, event: crate::KeyboardEventData) {
        self.enqueue(self.queue.push_key(
            &self.owner,
            InputEvent::ArkUi(crate::ArkUiInputEvent::Key(event)),
        ));
    }

    #[cfg(feature = "keyboard")]
    pub(crate) fn after_ime(&self) {
        if let Err(error) = self.queue.after_ime(&self.owner) {
            crate::warn!("{error}");
        }
    }

    fn enqueue(&self, result: std::result::Result<bool, &'static str>) {
        match result {
            Ok(true) => crate::waker::schedule_input(&self.waker, &self.queue),
            Ok(false) => {}
            Err(error) => crate::warn!("{error}"),
        }
    }
}

impl ImeCallbackSource {
    fn create_ime(&self) -> IME {
        let ime = IME::new_for_window(AttachOptions::new(false), self.platform_window_id);
        macro_rules! callback {
            ($method:ident, |$($arg:ident),*| $event:expr) => {{
                let input = self.input.clone();
                ime.$method(move |$($arg),*| input.ime($event));
            }};
        }
        callback!(insert_text, |text| ImeEvent::TextInputEvent(
            crate::TextInputEventData { text }
        ));
        callback!(on_status_change, |status| ImeEvent::ImeStatusEvent(status));
        callback!(on_backspace, |length| ImeEvent::BackspaceEvent(length));
        callback!(on_delete_forward, |length| ImeEvent::DeleteForwardEvent(
            length
        ));
        callback!(on_move_cursor, |direction| ImeEvent::MoveCursorEvent(
            direction
        ));
        callback!(on_set_selection, |selection| ImeEvent::SelectionEvent {
            start: selection.start,
            end: selection.end,
        });
        callback!(on_extend_action, |action| ImeEvent::ExtendActionEvent(
            action
        ));
        callback!(on_enter, |key| ImeEvent::EnterEvent(u32::from(key) as i32));
        callback!(on_preview, |text, start, end| ImeEvent::PreviewTextEvent {
            text,
            start,
            end,
        });
        let input = self.input.clone();
        ime.on_finish_preview(move || input.ime(ImeEvent::FinishPreviewEvent));
        ime
    }
}

impl OpenHarmonyApp {
    /// Whether this render owner has a native editor, independently of EGL surface creation.
    /// Call only on the N-API/UI thread.
    pub fn is_text_input_ready_for(&self, window_id: i64) -> bool {
        if let Err(error) = self.ensure_input_main_thread() {
            crate::warn!("Cannot inspect native editor for window {window_id}: {error}");
            return false;
        }
        self.ime_sources
            .borrow()
            .get(&window_id)
            .is_some_and(|source| {
                source.ready
                    && self.render_window_id(&source.owner) == Some(window_id)
                    && if window_id == 0 {
                        self.ime.borrow().is_some()
                    } else {
                        self.sub_ime.borrow().contains_key(&window_id)
                    }
            })
    }

    pub(crate) fn initialize_render_input(
        &self,
        owner: &str,
        platform_window_id: i32,
    ) -> Result<()> {
        let window_id = self
            .render_window_id(owner)
            .ok_or_else(|| Error::from_reason("Native input requires a live render owner"))?;
        if self.is_text_input_ready_for(window_id) {
            return Ok(());
        }
        // A failed retirement retains the old session until detachment succeeds.
        self.try_detach_ime_for(window_id)?;
        let source = ImeCallbackSource {
            owner: owner.to_owned(),
            platform_window_id,
            input: InputCallback {
                queue: self.input_queue.clone(),
                waker: self.waker.clone(),
                owner: self
                    .input_queue
                    .activate(owner)
                    .map_err(Error::from_reason)?,
            },
            ready: true,
        };
        let ime = source.create_ime();
        if window_id == 0 {
            *self.ime.borrow_mut() = Some(ime);
        } else {
            self.sub_ime.borrow_mut().insert(window_id, ime);
        }
        self.ime_sources.borrow_mut().insert(window_id, source);
        self.notify_text_input_ready(window_id, true);
        Ok(())
    }

    pub(crate) fn input_callback(&self, owner: &str) -> Option<InputCallback> {
        let window_id = self.render_window_id(owner)?;
        self.ime_sources
            .borrow()
            .get(&window_id)
            .filter(|source| source.ready && source.owner == owner)
            .map(|source| source.input.clone())
    }

    pub(crate) fn retire_render_input(&self, owner: &str, window_id: i64) {
        if let Err(error) = self.input_queue.discard(owner) {
            crate::warn!("{error}");
        }
        let was_ready = self
            .ime_sources
            .borrow_mut()
            .get_mut(&window_id)
            .map(|source| std::mem::replace(&mut source.ready, false))
            .unwrap_or(false);
        if let Err(error) = self.try_detach_ime_for(window_id) {
            crate::warn!("Cannot detach retiring editor for window {window_id}: {error}");
            if was_ready {
                self.notify_text_input_ready(window_id, false);
            }
            return;
        }
        self.ime_sources.borrow_mut().remove(&window_id);
        if window_id == 0 {
            self.ime.borrow_mut().take();
        } else {
            self.sub_ime.borrow_mut().remove(&window_id);
        }
        if was_ready {
            self.notify_text_input_ready(window_id, false);
        }
    }

    /// Reassign an editor without accepting delayed edits from its previous lifetime.
    /// Call only on the N-API/UI thread.
    pub fn reset_ime_for(&self, window_id: i64) -> Result<()> {
        self.ensure_input_main_thread()?;
        let source = self
            .ime_sources
            .borrow()
            .get(&window_id)
            .cloned()
            .ok_or_else(|| {
                Error::from_reason(format!("Native IME is not ready for window {window_id}"))
            })?;
        self.retire_render_input(&source.owner, window_id);
        self.initialize_render_input(&source.owner, source.platform_window_id)
    }

    fn notify_text_input_ready(&self, window_id: i64, ready: bool) {
        if let Ok(mut handler) = self.event_loop.try_borrow_mut() {
            if let Some(handler) = handler.as_mut() {
                handler(Event::TextInputReadyChanged { window_id, ready });
            }
        } else {
            let app = self.clone();
            self.queue_after_input(move || app.notify_text_input_ready(window_id, ready));
        }
    }

    pub(crate) fn drain_input(&self) {
        // Native focus and drag callbacks can reenter while the application handler runs.
        // Leave the queue intact until the scheduled main-thread turn can own the handler.
        if self.event_loop.try_borrow_mut().is_err() {
            return;
        }
        loop {
            let delivery = match self.input_queue.pop() {
                Ok(Some(delivery)) => delivery,
                Ok(None) => break,
                Err(error) => {
                    crate::warn!("{error}");
                    break;
                }
            };
            match delivery {
                Delivery::Wake => {
                    self.drain_after_input();
                    if let Some(handler) = self.event_loop.borrow_mut().as_mut() {
                        handler(Event::UserEvent);
                    }
                }
                Delivery::Input {
                    owner,
                    mut value,
                    ime_consumed,
                } => {
                    #[cfg(feature = "keyboard")]
                    if let InputEvent::ArkUi(crate::ArkUiInputEvent::Key(ref mut key)) = value {
                        key.ime_consumed = ime_consumed.unwrap_or(false);
                    }
                    #[cfg(not(feature = "keyboard"))]
                    let _ = (&mut value, ime_consumed);
                    if let Some(handler) = self.event_loop.borrow_mut().as_mut() {
                        match self.render_window_id(&owner) {
                            Some(0) => handler(Event::Input(value)),
                            Some(window_id) => handler(Event::SubWindowInput {
                                window_id,
                                event: value,
                            }),
                            None => {}
                        }
                    }
                }
            }
            self.drain_after_input();
        }
    }
}
