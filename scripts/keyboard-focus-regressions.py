#!/usr/bin/env python3
"""Run the actual native keyboard-focus adapter against a host SDK substitute."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

HOST_TEMPLATE = r'''#![allow(dead_code)]

extern crate self as napi_ohos;
#[cfg(feature = "keyboard-focus-recovery")]
extern crate self as ohos_window_manager_binding;
__BINDING_SUBSTITUTE__
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, RwLock},
};
#[derive(Debug)]
pub struct Error(String);
impl Error {
    pub fn from_reason(reason: impl Into<String>) -> Self {
        Self(reason.into())
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}
pub type Result<T> = std::result::Result<T, Error>;
#[macro_export]
macro_rules! warn { ($($value:tt)*) => { eprintln!($($value)*) }; }
#[macro_export]
macro_rules! debug { ($($value:tt)*) => { eprintln!($($value)*) }; }
#[derive(Default)]
struct Inner {
    render_owner: Option<String>,
    sub_surfaces: HashMap<i64, String>,
    window_keyboard_focus_recovery: bool,
    window_focus: HashMap<i64, bool>,
}
#[derive(Default)]
struct Effects {
    owners: HashMap<String, i64>,
    requested: Vec<i64>,
    fail: bool,
    hook: Option<fn(&OpenHarmonyApp)>,
}
type Scheduled = Box<dyn FnOnce() + Send>;
#[derive(Clone)]
pub struct OpenHarmonyApp {
    inner: Arc<RwLock<Inner>>,
    effects: Arc<Mutex<Effects>>,
    queue: Arc<Mutex<Vec<Scheduled>>>,
}
impl OpenHarmonyApp {
    fn new(owner: &str, window: i64) -> Self {
        let app = Self {
            inner: Arc::default(),
            effects: Arc::default(),
            queue: Arc::default(),
        };
        #[cfg(feature = "keyboard-focus-recovery")]
        app.set_window_keyboard_focus_recovery(true)
            .expect("enable");
        app.effects
            .lock()
            .expect("effects")
            .owners
            .insert(owner.into(), window);
        app
    }
    fn is_render_surface_active(&self, owner: &str) -> bool {
        self.effects
            .lock()
            .expect("effects")
            .owners
            .contains_key(owner)
    }
    fn request_xcomponent_focus_for(&self, window: i64) -> Result<()> {
        let hook = {
            let mut effects = self.effects.lock().expect("effects");
            effects.requested.push(window);
            if effects.fail {
                return Err(Error::from_reason("native focus failure"));
            }
            effects.hook
        };
        if let Some(hook) = hook {
            hook(self);
        }
        Ok(())
    }
    fn main_thread(&self) -> Result<Scheduler> {
        Ok(Scheduler(self.queue.clone()))
    }
    fn requested(&self) -> Vec<i64> {
        self.effects.lock().expect("effects").requested.clone()
    }
    fn drain(&self) {
        let tasks = std::mem::take(&mut *self.queue.lock().expect("queue"));
        for task in tasks {
            task();
        }
    }
__APPLICATION_METHODS__



}
struct Scheduler(Arc<Mutex<Vec<Scheduled>>>);
impl Scheduler {
    fn dispatch(&self, task: impl FnOnce() + Send + 'static) -> Result<()> {
        self.0.lock().expect("queue").push(Box::new(task));
        Ok(())
    }
}

#[cfg(all(test, not(feature = "keyboard-focus-recovery")))]
#[test]
fn disabled_feature_rejects_enable_without_native_sdk() {
    let app = OpenHarmonyApp::new("main", 0);
    assert!(app.set_window_keyboard_focus_recovery(true).is_err());
    app.set_window_keyboard_focus_recovery(false).expect("disable");
    assert!(!app.window_keyboard_focus_recovery_enabled());
}

#[cfg(feature = "keyboard-focus-recovery")]
mod focus {
__KEYBOARD_FOCUS_SOURCE__

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::sync::atomic::{AtomicUsize, Ordering};
        static FOREIGN_CALLS: AtomicUsize = AtomicUsize::new(0);
        unsafe extern "C" fn foreign(_: *mut Input_KeyEvent) -> bool {
            FOREIGN_CALLS.fetch_add(1, Ordering::SeqCst);
            true
        }
        struct Sdk;
        impl Sdk {
            fn new() -> Self {
                unsafe { crate::native::mock_reset() };
                Self
            }
            fn set(&self, name: &[u8], value: i32) {
                unsafe {
                    match name {
                        b"mock_fail_register\0" => crate::native::mock_fail_register(value),
                        b"mock_fail_get\0" => crate::native::mock_fail_get(value),
                        b"mock_fail_unregister\0" => crate::native::mock_fail_unregister(value),
                        b"mock_destroyed\0" => crate::native::mock_destroyed(value),
                        _ => panic!("unknown SDK setter"),
                    }
                }
            }
            fn foreign(&self, window: i32) {
                unsafe { crate::native::mock_set_filter(window, Some(foreign)) };
            }
            fn invoke(&self, window: i32, target: i32) -> bool {
                unsafe { crate::native::mock_invoke(window, target) }
            }
            fn has(&self, window: i32) -> bool {
                unsafe { crate::native::mock_has_filter(window) }
            }
            fn inline_unregister(&self) -> i32 {
                unsafe { crate::native::mock_inline_unregister() }
            }
        }
        fn mount(app: &OpenHarmonyApp, owner: &str, logical: i64, native: i32) {
            install_keyboard_focus_recovery(app, owner, logical, native).expect("mount");
        }
        #[test]
        fn first_key_restores_focus_before_window_active_and_keeps_normal_dispatch() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            assert!(!sdk.invoke(75, 75));
            assert_eq!(app.requested(), [0]);
            assert!(app.window_has_focus(0));
            assert!(!sdk.invoke(75, 75));
            assert_eq!(app.requested(), [0]);
            release_keyboard_focus_recovery(&app, "main");
            assert!(!sdk.has(75));
        }
        #[test]
        fn native_menu_keeps_node_focus_while_window_stays_active() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            app.record_window_focus(0, true);
            assert!(!sdk.invoke(75, 75));
            assert!(app.requested().is_empty());
            app.record_window_focus(0, false);
            sdk.invoke(75, 75);
            assert_eq!(app.requested(), [0]);
            release_keyboard_focus_recovery(&app, "main");
        }
        #[test]
        fn routes_main_and_child_by_native_event_window() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            app.effects
                .lock()
                .expect("effects")
                .owners
                .insert("child".into(), 9);
            mount(&app, "main", 0, 75);
            mount(&app, "child", 9, 85);
            sdk.invoke(85, 85);
            assert_eq!(app.requested(), [9]);
            sdk.invoke(75, 75);
            assert_eq!(app.requested(), [9, 0]);
            release_keyboard_focus_recovery(&app, "main");
            release_keyboard_focus_recovery(&app, "child");
        }
        #[test]
        fn unknown_window_and_null_event_are_not_routed() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            assert!(!sdk.invoke(75, 76));
            assert!(!unsafe { recover_key_focus(std::ptr::null_mut()) });
            assert!(app.requested().is_empty());
            release_keyboard_focus_recovery(&app, "main");
        }
        #[test]
        fn inactive_owner_cannot_receive_keyboard_focus() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            app.effects.lock().expect("effects").owners.clear();
            sdk.invoke(75, 75);
            assert!(app.requested().is_empty());
            release_keyboard_focus_recovery(&app, "main");
        }
        #[test]
        fn callback_on_another_thread_does_not_access_ui_state() {
            let _sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            std::thread::spawn(|| {
                let sdk = Sdk;
                assert!(!sdk.invoke(75, 75));
            })
            .join()
            .expect("worker");
            assert!(app.requested().is_empty());
            release_keyboard_focus_recovery(&app, "main");
        }
        #[test]
        fn native_focus_failure_retains_retry_and_normal_key_delivery() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            app.effects.lock().expect("effects").fail = true;
            assert!(!sdk.invoke(75, 75));
            assert!(!app.window_has_focus(0));
            app.effects.lock().expect("effects").fail = false;
            assert!(!sdk.invoke(75, 75));
            assert_eq!(app.requested(), [0, 0]);
            release_keyboard_focus_recovery(&app, "main");
        }
        #[test]
        fn preserves_an_existing_native_filter() {
            let sdk = Sdk::new();
            FOREIGN_CALLS.store(0, Ordering::SeqCst);
            sdk.foreign(75);
            let app = OpenHarmonyApp::new("main", 0);
            assert!(install_keyboard_focus_recovery(&app, "main", 0, 75).is_err());
            assert!(sdk.invoke(75, 75));
            assert_eq!(FOREIGN_CALLS.load(Ordering::SeqCst), 1);
            release_keyboard_focus_recovery(&app, "main");
            assert!(sdk.has(75));
        }
        #[test]
        fn cleanup_does_not_remove_a_later_foreign_filter() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            sdk.foreign(75);
            release_keyboard_focus_recovery(&app, "main");
            assert!(sdk.invoke(75, 75));
            assert!(FILTERS.with(|filters| filters.borrow().windows.is_empty()));
        }
        #[test]
        fn failed_native_registration_rolls_back_ownership() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            sdk.set(b"mock_fail_register\0", 2000);
            assert!(install_keyboard_focus_recovery(&app, "main", 0, 75).is_err());
            assert!(FILTERS.with(|filters| filters.borrow().windows.is_empty()));
            assert!(!sdk.has(75));
        }
        #[test]
        fn cleanup_inside_focus_callback_waits_for_next_ui_turn() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            app.effects.lock().expect("effects").hook =
                Some(|app| release_keyboard_focus_recovery(app, "main"));
            sdk.invoke(75, 75);
            assert_eq!(sdk.inline_unregister(), 0);
            assert!(sdk.has(75));
            app.drain();
            assert!(!sdk.has(75));
        }
        #[test]
        fn replacement_survives_stale_owner_and_queued_cleanup() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("old", 0);
            mount(&app, "old", 0, 75);
            app.effects.lock().expect("effects").hook =
                Some(|app| release_keyboard_focus_recovery(app, "old"));
            sdk.invoke(75, 75);
            {
                let mut effects = app.effects.lock().expect("effects");
                effects.hook = None;
                effects.owners.clear();
                effects.owners.insert("new".into(), 2);
            }
            mount(&app, "new", 2, 75);
            release_keyboard_focus_recovery(&app, "old");
            app.drain();
            assert!(sdk.has(75));
            app.record_window_focus(2, false);
            sdk.invoke(75, 75);
            assert_eq!(app.requested(), [0, 2]);
            release_keyboard_focus_recovery(&app, "new");
        }
        #[test]
        fn cleanup_error_keeps_disabled_registration_for_retry() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            sdk.set(b"mock_fail_get\0", 2000);
            release_keyboard_focus_recovery(&app, "main");
            assert!(sdk.has(75));
            assert!(!sdk.invoke(75, 75));
            assert!(app.requested().is_empty());
            sdk.set(b"mock_fail_get\0", 0);
            release_keyboard_focus_recovery(&app, "main");
            assert!(!sdk.has(75));
        }
        #[test]
        fn already_destroyed_window_releases_registration() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            sdk.set(b"mock_destroyed\0", 1);
            release_keyboard_focus_recovery(&app, "main");
            assert!(FILTERS.with(|filters| filters.borrow().windows.is_empty()));
        }
        #[test]
        fn configuration_is_explicit_and_cannot_change_after_rendering() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            app.set_window_keyboard_focus_recovery(false)
                .expect("disable");
            mount(&app, "main", 0, 75);
            assert!(!sdk.has(75));
            app.inner.write().expect("inner").render_owner = Some("main".into());
            assert!(app.set_window_keyboard_focus_recovery(true).is_err());
        }

        #[test]
        fn deferred_install_ignores_a_surface_destroyed_before_the_next_ui_turn() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            app.effects.lock().expect("effects").hook = Some(|app| {
                app.effects
                    .lock()
                    .expect("effects")
                    .owners
                    .insert("temporary".into(), 2);
                install_keyboard_focus_recovery(app, "temporary", 2, 85).expect("deferred install");
                app.effects
                    .lock()
                    .expect("effects")
                    .owners
                    .remove("temporary");
            });
            sdk.invoke(75, 75);
            app.drain();
            assert!(!sdk.has(85));
            release_keyboard_focus_recovery(&app, "main");
        }
        #[test]
        fn failed_unregister_keeps_disabled_filter_until_retry() {
            let sdk = Sdk::new();
            let app = OpenHarmonyApp::new("main", 0);
            mount(&app, "main", 0, 75);
            sdk.set(b"mock_fail_unregister\0", 2000);
            release_keyboard_focus_recovery(&app, "main");
            assert!(sdk.has(75));
            sdk.invoke(75, 75);
            assert!(app.requested().is_empty());
            sdk.set(b"mock_fail_unregister\0", 0);
            release_keyboard_focus_recovery(&app, "main");
            assert!(!sdk.has(75));
        }
    }
}
'''


BINDING_SUBSTITUTE = r'''#[cfg(feature = "keyboard-focus-recovery")]
mod binding {
    use std::{ffi::c_void, marker::PhantomData, ptr::NonNull};
    pub type Input_KeyEvent = c_void;
    pub type KeyEventFilter = unsafe extern "C" fn(*mut Input_KeyEvent) -> bool;
    #[derive(Debug)]
    pub struct NativeError(i32);
    impl NativeError {
        pub fn code(&self) -> Option<i32> { Some(self.0) }
    }
    impl std::fmt::Display for NativeError {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { self.0.fmt(f) }
    }
    fn check(status: i32) -> std::result::Result<(), NativeError> {
        if status == 0 { Ok(()) } else { Err(NativeError(status)) }
    }
    pub struct Window(i32);
    impl Window {
        pub fn from_id(id: i32) -> Self { Self(id) }
        pub fn key_event_filter(&self) -> std::result::Result<Option<KeyEventFilter>, NativeError> {
            let mut filter = None;
            check(unsafe { crate::native::OH_NativeWindowManager_GetKeyEventFilter(self.0, &mut filter) })?;
            Ok(filter)
        }
        pub fn register_key_event_filter(&self, filter: KeyEventFilter) -> std::result::Result<(), NativeError> {
            check(unsafe { crate::native::OH_NativeWindowManager_RegisterKeyEventFilter(self.0, Some(filter)) })
        }
        pub fn unregister_key_event_filter(&self) -> std::result::Result<(), NativeError> {
            check(unsafe { crate::native::OH_NativeWindowManager_UnregisterKeyEventFilter(self.0) })
        }
    }
    pub struct KeyEventRef<'a>(NonNull<Input_KeyEvent>, PhantomData<&'a Input_KeyEvent>);
    impl<'a> KeyEventRef<'a> {
        pub unsafe fn from_raw(raw: *mut Input_KeyEvent) -> Option<Self> {
            NonNull::new(raw).map(|raw| Self(raw, PhantomData))
        }
        pub fn window_id(&self) -> i32 {
            unsafe { crate::native::OH_Input_GetKeyEventWindowId(self.0.as_ptr()) }
        }
    }
}
#[cfg(feature = "keyboard-focus-recovery")]
pub use binding::{Input_KeyEvent, KeyEventFilter, KeyEventRef, Window};
#[cfg(feature = "keyboard-focus-recovery")]
mod native {
    use super::{Input_KeyEvent, KeyEventFilter};
    #[link(name = "focus_mock", kind = "static")]
    unsafe extern "C" {
        pub fn OH_NativeWindowManager_RegisterKeyEventFilter(window: i32, filter: Option<KeyEventFilter>) -> i32;
        pub fn OH_NativeWindowManager_UnregisterKeyEventFilter(window: i32) -> i32;
        pub fn OH_NativeWindowManager_GetKeyEventFilter(window: i32, filter: *mut Option<KeyEventFilter>) -> i32;
        pub fn OH_Input_GetKeyEventWindowId(event: *const Input_KeyEvent) -> i32;
        pub fn mock_reset();
        pub fn mock_fail_register(value: i32);
        pub fn mock_fail_get(value: i32);
        pub fn mock_fail_unregister(value: i32);
        pub fn mock_destroyed(value: i32);
        pub fn mock_set_filter(window: i32, filter: Option<KeyEventFilter>);
        pub fn mock_has_filter(window: i32) -> bool;
        pub fn mock_invoke(window: i32, target: i32) -> bool;
        pub fn mock_inline_unregister() -> i32;
    }
}
'''

WINDOW_SDK = r'''
#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>
typedef bool (*Filter)(void *);
static Filter filters[256];
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static int failed_register, failed_get, failed_unregister, destroyed, inside, inline_unregister;
void mock_reset(void) { for(int index=0; index<256; ++index) filters[index]=0; failed_register=failed_get=failed_unregister=destroyed=inside=inline_unregister=0; }
void mock_fail_register(int value) { failed_register=value; }
void mock_fail_get(int value) { failed_get=value; }
void mock_fail_unregister(int value) { failed_unregister=value; }
void mock_destroyed(int value) { destroyed=value; }
int mock_inline_unregister(void) { return inline_unregister; }
int OH_NativeWindowManager_RegisterKeyEventFilter(int32_t window, Filter filter) { if(failed_register) return failed_register; filters[window]=filter; return 0; }
int OH_NativeWindowManager_UnregisterKeyEventFilter(int32_t window) { if(inside) {inline_unregister++;return 2999;} if(failed_unregister) return failed_unregister;filters[window]=0;return 0; }
int OH_NativeWindowManager_GetKeyEventFilter(int32_t window, Filter *filter) { if(destroyed) return 1000; if(failed_get) return failed_get; *filter=filters[window]; return 0; }
void mock_set_filter(int window, Filter filter) { filters[window]=filter; }
bool mock_has_filter(int window) { return filters[window]!=0; }
bool mock_invoke(int window, int target) { pthread_mutex_lock(&mutex); inside=1; bool result=filters[window] ? filters[window](&target) : false;inside=0;pthread_mutex_unlock(&mutex);return result; }
'''

INPUT_SDK = r'''int OH_Input_GetKeyEventWindowId(const int *event) { return *event; }
'''


def extract_method(source, name):
    start = source.index("fn " + name + "(")
    start = source.rfind("\n", 0, start) + 1
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


def run():
    repository = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=repository / "target/keyboard-focus-regressions")
    arguments = parser.parse_args()
    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / "README.md").write_text("Generated host regression harness with a static SDK substitute.\n")
    keyboard_source = repository / "crates/ability/src/render/keyboard_focus.rs"
    app_source = repository / "crates/ability/src/app.rs"
    methods = "\n".join(extract_method(app_source.read_text(), name) for name in [
        "set_window_keyboard_focus_recovery", "window_keyboard_focus_recovery_enabled",
        "record_window_focus", "window_has_focus",
    ])
    source = HOST_TEMPLATE.replace("__APPLICATION_METHODS__", methods).replace(
        "__KEYBOARD_FOCUS_SOURCE__", keyboard_source.read_text()).replace(
        "__BINDING_SUBSTITUTE__", BINDING_SUBSTITUTE)
    (output / "keyboard_focus.rs").write_text(source)
    (output / "Cargo.toml").write_text(
        '[package]\nname="keyboard-focus-regressions"\nversion="0.1.0"\nedition="2021"\n'
        '[lib]\npath="keyboard_focus.rs"\n[workspace]\n[features]\n'
        'default=["keyboard-focus-recovery"]\nkeyboard=[]\nkeyboard-focus-recovery=["keyboard"]\n')
    compiler = shlex.split(os.environ.get("CC", "cc"))
    sdk = output / "sdk"
    sdk.mkdir(exist_ok=True)
    (sdk / "filter.c").write_text(WINDOW_SDK)
    (sdk / "input.c").write_text(INPUT_SDK)
    objects = []
    for name in ["filter", "input"]:
        obj = sdk / (name + ".o")
        subprocess.run(compiler + ["-c", "-o", str(obj), str(sdk / (name + ".c"))], check=True)
        objects.append(str(obj))
    subprocess.run(["ar", "rcs", str(sdk / "libfocus_mock.a"), *objects], check=True)
    command = ["cargo", "test", "--manifest-path", str(output / "Cargo.toml"), "--lib"]
    records = []
    for feature, log_name, arguments in [
        ("enabled", "host-tests.log", []),
        ("disabled", "disabled-feature-tests.log", ["--no-default-features", "--features", "keyboard"]),
    ]:
        environment = dict(os.environ)
        # The feature-disabled executable must link without any native substitute.
        environment["RUSTFLAGS"] = "-Lnative=" + str(sdk) if feature == "enabled" else ""
        with (output / log_name).open("w") as log:
            result = subprocess.run(command + arguments + ["--", "--test-threads=1", "--nocapture"],
                                    env=environment, stdout=log, stderr=subprocess.STDOUT)
        records.append({"feature": feature, "returncode": result.returncode, "log": str(output / log_name)})
        print((output / log_name).read_text()[-2600:])
        if result.returncode:
            raise SystemExit(result.returncode)
    records.append({"sources": {str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in [keyboard_source, app_source]}})
    (output / "result.json").write_text(json.dumps(records, indent=2) + "\n")
    print("Keyboard focus regressions passed; evidence:", output)


if __name__ == "__main__":
    run()
