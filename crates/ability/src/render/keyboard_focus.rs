#![allow(
    clippy::missing_const_for_thread_local,
    reason = "OHOS OS-backed TLS reports this even for explicit const initializers"
)]

use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    ffi::c_void,
    rc::Rc,
    sync::{Arc, OnceLock},
};

use napi_ohos::{Error, Result};

use crate::OpenHarmonyApp;

type KeyEventFilter = unsafe extern "C" fn(*mut c_void) -> bool;
type RegisterFilter = unsafe extern "C" fn(i32, Option<KeyEventFilter>) -> i32;
type UnregisterFilter = unsafe extern "C" fn(i32) -> i32;
type GetFilter = unsafe extern "C" fn(i32, *mut Option<KeyEventFilter>) -> i32;
type GetWindowId = unsafe extern "C" fn(*const c_void) -> i32;

struct NativeKeyFilterApi {
    _window_library: libloading::Library,
    _input_library: libloading::Library,
    register: RegisterFilter,
    unregister: UnregisterFilter,
    current: GetFilter,
    window_id: GetWindowId,
}

impl NativeKeyFilterApi {
    fn get() -> Result<Option<&'static Self>> {
        static API: OnceLock<std::result::Result<Option<NativeKeyFilterApi>, String>> =
            OnceLock::new();
        API.get_or_init(Self::load)
            .as_ref()
            .map(Option::as_ref)
            .map_err(|error| Error::from_reason(error.clone()))
    }

    fn load() -> std::result::Result<Option<Self>, String> {
        let window_library = unsafe { libloading::Library::new("libnative_window_manager.so") }
            .map_err(|error| format!("Cannot load native window key filters: {error}"))?;
        // Querying the installed filter lets us preserve another window consumer
        // and avoid removing a filter installed after ours. Older SDKs retain
        // window-focus callback recovery without taking over this filter slot.
        let current = match unsafe {
            window_library.get::<GetFilter>(b"OH_NativeWindowManager_GetKeyEventFilter\0")
        } {
            Ok(function) => *function,
            Err(error) => {
                crate::debug!("Native key filter inspection is unavailable: {error}");
                return Ok(None);
            }
        };
        let input_library = unsafe { libloading::Library::new("libohinput.so") }
            .map_err(|error| format!("Cannot load native key event window IDs: {error}"))?;
        // SAFETY: oh_window_event_filter.h and oh_input_manager.h declare these
        // C signatures. Both libraries outlive every registered callback.
        let register = unsafe {
            window_library.get::<RegisterFilter>(b"OH_NativeWindowManager_RegisterKeyEventFilter\0")
        }
        .map_err(|error| error.to_string())?;
        let unregister = unsafe {
            window_library
                .get::<UnregisterFilter>(b"OH_NativeWindowManager_UnregisterKeyEventFilter\0")
        }
        .map_err(|error| error.to_string())?;
        let window_id =
            unsafe { input_library.get::<GetWindowId>(b"OH_Input_GetKeyEventWindowId\0") }
                .map_err(|error| error.to_string())?;
        Ok(Some(Self {
            register: *register,
            unregister: *unregister,
            current,
            window_id: *window_id,
            _window_library: window_library,
            _input_library: input_library,
        }))
    }

    fn current_filter(&self, native_window_id: i32) -> Result<Option<KeyEventFilter>> {
        let mut filter = None;
        let status = unsafe { (self.current)(native_window_id, &mut filter) };
        check_status(status, "inspect")?;
        Ok(filter)
    }

    fn restore(&self, native_window_id: i32) -> Result<()> {
        let mut current = None;
        let status = unsafe { (self.current)(native_window_id, &mut current) };
        if status == 1000 {
            // INVALID_WINDOW_ID means the native window already released its filter.
            crate::debug!("Keyboard focus filter window {native_window_id} is already destroyed");
            return Ok(());
        }
        check_status(status, "inspect")?;
        if !current.is_some_and(is_our_filter) {
            return Ok(());
        }
        let status = unsafe { (self.unregister)(native_window_id) };
        check_status(status, "restore")
    }
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

fn check_status(status: i32, operation: &str) -> Result<()> {
    if status == 0 {
        Ok(())
    } else {
        Err(Error::from_reason(format!(
            "Cannot {operation} native keyboard focus filter: status {status}"
        )))
    }
}

unsafe extern "C" fn recover_key_focus(event: *mut c_void) -> bool {
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

fn recover_focus(event: *mut c_void) -> bool {
    let api = match NativeKeyFilterApi::get() {
        Ok(Some(api)) => api,
        Ok(None) => return false,
        Err(error) => {
            crate::warn!("Cannot access native keyboard focus filter: {error}");
            return false;
        }
    };
    // SAFETY: this borrowed event belongs to the current native filter invocation.
    let native_window_id = unsafe { (api.window_id)(event) };
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
    let Some(api) = NativeKeyFilterApi::get()? else {
        return Ok(());
    };
    let current = api.current_filter(native_window_id)?;
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
    let status = unsafe { (api.register)(native_window_id, Some(recover_key_focus)) };
    if let Err(error) = check_status(status, "register") {
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
        return Err(error);
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
            let result = NativeKeyFilterApi::get()
                .and_then(|api| api.map_or(Ok(()), |api| api.restore(native_window_id)));
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
