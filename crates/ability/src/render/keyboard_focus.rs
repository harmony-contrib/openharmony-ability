#![allow(
    clippy::missing_const_for_thread_local,
    reason = "OHOS OS-backed TLS reports this even for explicit const initializers"
)]

use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    rc::Rc,
    sync::Arc,
};

use napi_ohos::{Error, Result};

use crate::OpenHarmonyApp;

use ohos_window_manager_binding::{Input_KeyEvent, KeyEventFilter, KeyEventRef, Window};

fn current_filter(native_window_id: i32) -> Result<Option<KeyEventFilter>> {
    Window::from_id(native_window_id)
        .key_event_filter()
        .map_err(|error| {
            Error::from_reason(format!("Cannot inspect native keyboard filter: {error}"))
        })
}

fn restore_filter(native_window_id: i32) -> Result<()> {
    let window = Window::from_id(native_window_id);
    let current = match window.key_event_filter() {
        Ok(current) => current,
        Err(error) if error.code() == Some(1000) => {
            // The destroyed window has already released its filter.
            return Ok(());
        }
        Err(error) => return Err(Error::from_reason(error.to_string())),
    };
    if current.is_some_and(is_our_filter) {
        window.unregister_key_event_filter().map_err(|error| {
            Error::from_reason(format!("Cannot restore native keyboard filter: {error}"))
        })?;
    }
    Ok(())
}

struct Registration {
    app: OpenHarmonyApp,
    owner: String,
    window_id: i64,
    generation: u64,
    enabled: Cell<bool>,
}

#[derive(Default)]
struct FilterRegistry {
    generation: u64,
    windows: HashMap<i32, Rc<Registration>>,
}

// The NDK filter is a free C function without user data. Its event carries the
// native window ID; thread-local ownership keeps UI-affine app state off workers.
thread_local! {
    static FILTERS: RefCell<FilterRegistry> = RefCell::default();
    static IN_FILTER: Cell<bool> = const { Cell::new(false) };
}

struct FilterScope(bool);

impl FilterScope {
    fn enter() -> Self {
        Self(IN_FILTER.with(|active| active.replace(true)))
    }
}

impl Drop for FilterScope {
    fn drop(&mut self) {
        IN_FILTER.with(|active| active.set(self.0));
    }
}

fn is_our_filter(filter: KeyEventFilter) -> bool {
    std::ptr::fn_addr_eq(filter, recover_key_focus as KeyEventFilter)
}

unsafe extern "C" fn recover_key_focus(event: *mut Input_KeyEvent) -> bool {
    if event.is_null() {
        return false;
    }
    let _scope = FilterScope::enter();
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| recover_focus(event))) {
        Ok(consumed) => consumed,
        Err(_) => {
            crate::warn!("Native keyboard focus recovery panicked");
            false
        }
    }
}

fn recover_focus(event: *mut Input_KeyEvent) -> bool {
    // SAFETY: this borrowed event belongs to the current native filter invocation.
    let Some(event) = (unsafe { KeyEventRef::from_raw(event) }) else {
        return false;
    };
    let native_window_id = event.window_id();
    let registration = FILTERS.with(|filters| {
        filters
            .try_borrow()
            .map(|filters| filters.windows.get(&native_window_id).cloned())
    });
    let registration = match registration {
        Ok(Some(registration)) => registration,
        Ok(None) => return false,
        Err(error) => {
            crate::warn!("Cannot read native keyboard focus registration: {error}");
            return false;
        }
    };
    if registration.enabled.get()
        && registration
            .app
            .is_render_surface_active(&registration.owner)
        && !registration.app.window_has_focus(registration.window_id)
    {
        // Key delivery can precede WINDOW_ACTIVE. Set this before native focus
        // callbacks reenter us, and leave in-window native menus in charge after it.
        registration
            .app
            .record_window_focus(registration.window_id, true);
        if let Err(error) = registration
            .app
            .request_xcomponent_focus_for(registration.window_id)
        {
            registration
                .app
                .record_window_focus(registration.window_id, false);
            crate::warn!("Cannot recover native render focus before key delivery: {error}");
        }
    }
    false
}

pub(crate) fn install_keyboard_focus_recovery(
    app: &OpenHarmonyApp,
    owner: &str,
    window_id: i64,
    native_window_id: i32,
) -> Result<()> {
    if !app.window_keyboard_focus_recovery_enabled() || !app.is_render_surface_active(owner) {
        return Ok(());
    }
    if IN_FILTER.with(Cell::get) {
        let app = app.clone();
        let owner = owner.to_owned();
        return app.main_thread()?.dispatch(move || {
            if let Err(error) =
                install_keyboard_focus_recovery(&app, &owner, window_id, native_window_id)
            {
                crate::warn!("Cannot install deferred keyboard focus recovery: {error}");
            }
        });
    }
    let current = current_filter(native_window_id)?;
    if current.is_some_and(|filter| !is_our_filter(filter)) {
        return Err(Error::from_reason(
            "The native window already has another keyboard filter",
        ));
    }
    let (registration, replaced) = FILTERS.with(|filters| {
        let mut filters = filters
            .try_borrow_mut()
            .map_err(|error| Error::from_reason(error.to_string()))?;
        if current.is_some_and(is_our_filter) && !filters.windows.contains_key(&native_window_id) {
            return Err(Error::from_reason(
                "Native keyboard filter has no matching render owner",
            ));
        }
        filters.generation = filters
            .generation
            .checked_add(1)
            .ok_or_else(|| Error::from_reason("Native keyboard filter generation exhausted"))?;
        let registration = Rc::new(Registration {
            app: app.clone(),
            owner: owner.to_owned(),
            window_id,
            generation: filters.generation,
            enabled: Cell::new(true),
        });
        let replaced = filters
            .windows
            .insert(native_window_id, registration.clone());
        Ok::<_, Error>((registration, replaced))
    })?;
    if let Err(error) =
        Window::from_id(native_window_id).register_key_event_filter(recover_key_focus)
    {
        registration.enabled.set(false);
        FILTERS.with(|filters| {
            if let Ok(mut filters) = filters.try_borrow_mut() {
                filters.windows.remove(&native_window_id);
                if let Some(replaced) = replaced {
                    filters.windows.insert(native_window_id, replaced);
                }
            } else {
                crate::warn!("Cannot roll back native keyboard focus registration");
            }
        });
        return Err(Error::from_reason(format!(
            "Cannot register native keyboard filter: {error}"
        )));
    }
    if let Some(replaced) = replaced {
        replaced.enabled.set(false);
    }
    Ok(())
}

fn restore_registration(native_window_id: i32, generation: u64) {
    let registration = FILTERS.with(|filters| {
        let filters = filters
            .try_borrow()
            .map_err(|error| Error::from_reason(error.to_string()))?;
        if filters
            .windows
            .get(&native_window_id)
            .is_none_or(|entry| entry.generation != generation)
        {
            return Ok(None);
        }
        Ok::<_, Error>(filters.windows.get(&native_window_id).cloned())
    });
    match registration {
        Ok(Some(registration)) => {
            let result = restore_filter(native_window_id);
            if let Err(error) = result {
                crate::warn!("Cannot release native keyboard focus filter: {error}");
                return;
            }
            FILTERS.with(|filters| match filters.try_borrow_mut() {
                Ok(mut filters) => {
                    if filters
                        .windows
                        .get(&native_window_id)
                        .is_some_and(|entry| entry.generation == registration.generation)
                    {
                        filters.windows.remove(&native_window_id);
                    }
                }
                Err(error) => {
                    crate::warn!("Cannot clear native keyboard focus registration: {error}")
                }
            });
        }
        Ok(None) => {}
        Err(error) => crate::warn!("Cannot release native keyboard focus registration: {error}"),
    }
}

pub(crate) fn release_keyboard_focus_recovery(app: &OpenHarmonyApp, owner: &str) {
    let registrations = FILTERS.with(|filters| {
        filters.try_borrow().map(|filters| {
            filters
                .windows
                .iter()
                .filter_map(|(native_window_id, registration)| {
                    (Arc::ptr_eq(&registration.app.inner, &app.inner)
                        && registration.owner == owner)
                        .then_some((*native_window_id, registration.clone()))
                })
                .collect::<Vec<_>>()
        })
    });
    let registrations = match registrations {
        Ok(registrations) => registrations,
        Err(error) => {
            crate::warn!("Cannot find native keyboard focus registrations: {error}");
            return;
        }
    };
    for (native_window_id, registration) in registrations {
        registration.enabled.set(false);
        let generation = registration.generation;
        if IN_FILTER.with(Cell::get) {
            // WindowSessionImpl holds its key-filter mutex while invoking us.
            // A synchronous focus callback may destroy a surface; unregister on
            // the next UI turn rather than reacquiring that mutex here.
            let result = app.main_thread().and_then(|scheduler| {
                scheduler.dispatch(move || restore_registration(native_window_id, generation))
            });
            if let Err(error) = result {
                crate::warn!("Cannot defer native keyboard focus cleanup: {error}");
            }
        } else {
            restore_registration(native_window_id, generation);
        }
    }
}
