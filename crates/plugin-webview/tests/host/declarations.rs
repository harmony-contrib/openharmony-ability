//! Production registries/installers with only ArkWeb and N-API effects substituted.
#![allow(dead_code)]
extern crate self as napi_ohos;
extern crate self as ohos_web_binding;
use std::{
    collections::BTreeMap,
    sync::{Arc, LazyLock, Mutex},
};
pub type Result<T> = std::result::Result<T, Error>;
#[derive(Debug)]
pub struct Error(String);
impl Error {
    pub fn from_reason(reason: impl Into<String>) -> Self {
        Self(reason.into())
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}
include!("types.rs");
use controller_key::ControllerKey;
#[path = "SOURCE_DIRECTORY/callbacks.rs"]
mod callbacks;
#[path = "SOURCE_DIRECTORY/controller.rs"]
mod controller;
#[path = "SOURCE_DIRECTORY/controller_key.rs"]
mod controller_key;
#[path = "SOURCE_DIRECTORY/js_proxy.rs"]
mod js_proxy;
#[path = "SOURCE_DIRECTORY/native_routes.rs"]
mod native_routes;
#[path = "SOURCE_DIRECTORY/protocol.rs"]
mod protocol;

type Proxy = Box<dyn FnMut(String, Vec<String>) + Send>;
type RequestCallback = Box<dyn FnMut(NativeRequest, ResourceHandle) -> bool + Send>;
static PROXIES: LazyLock<Mutex<BTreeMap<String, Proxy>>> = LazyLock::new(Default::default);
static PROTOCOLS: LazyLock<Mutex<BTreeMap<String, RequestCallback>>> =
    LazyLock::new(Default::default);
pub struct WebProxyBuilder {
    tag: String,
    methods: Vec<(String, Proxy)>,
}
pub struct ProxyRegistration;
impl WebProxyBuilder {
    pub fn new(tag: String, _: String) -> Self {
        Self {
            tag,
            methods: Vec::new(),
        }
    }
    pub fn add_method(
        mut self,
        name: String,
        callback: impl FnMut(String, Vec<String>) + Send + 'static,
    ) -> Self {
        self.methods.push((name, Box::new(callback)));
        self
    }
    pub fn build(self) -> Result<ProxyRegistration> {
        for (method, callback) in self.methods {
            PROXIES
                .lock()
                .unwrap()
                .insert(format!("{}:{method}", self.tag), callback);
        }
        Ok(ProxyRegistration)
    }
}
impl ProxyRegistration {
    pub fn refresh(&self) -> Result<()> {
        Ok(())
    }
}
pub struct CustomProtocol;
pub struct CustomProtocolOption(u32);
impl CustomProtocolOption {
    pub fn bits(&self) -> u32 {
        self.0
    }
}
impl CustomProtocol {
    pub fn add_protocol_with_option(_: &str, _: CustomProtocolOption) {}
    pub fn register() {}
}
pub struct CustomProtocolHandler {
    callback: Mutex<Option<RequestCallback>>,
}
impl CustomProtocolHandler {
    pub fn new() -> Self {
        Self {
            callback: Mutex::new(None),
        }
    }
    pub fn on_request_start(
        &self,
        callback: impl FnMut(NativeRequest, ResourceHandle) -> bool + Send + 'static,
    ) {
        *self.callback.lock().unwrap() = Some(Box::new(callback));
    }
}
pub struct Web(String);
impl Web {
    pub fn new(tag: String) -> Self {
        Self(tag)
    }
    pub fn custom_protocol(self, scheme: String, handler: CustomProtocolHandler) -> Result<bool> {
        if self.0.ends_with("-fail") {
            return Err(Error::from_reason("injected native installation failure"));
        }
        PROTOCOLS.lock().unwrap().insert(
            format!("{}:{scheme}", self.0),
            handler.callback.into_inner().unwrap().unwrap(),
        );
        Ok(true)
    }
}
pub struct NativeRequest {
    body: bool,
}
impl NativeRequest {
    pub fn url(&self) -> String {
        "asset://bundle/index.html".into()
    }
    pub fn method(&self) -> Method {
        Method
    }
    pub fn headers(&self) -> BTreeMap<String, String> {
        BTreeMap::new()
    }
    pub fn is_main_frame(&self) -> bool {
        true
    }
    pub fn http_body_stream(&self) -> Option<Body> {
        self.body.then_some(Body)
    }
}
pub struct Method;
impl Method {
    pub fn as_str(&self) -> &str {
        "GET"
    }
}
type BodyCallback = Box<dyn FnMut(Vec<u8>) + Send>;
static BODY_READS: LazyLock<Mutex<Vec<BodyCallback>>> = LazyLock::new(Default::default);
pub struct Body;
impl Body {
    pub fn size(&self) -> u64 {
        0
    }
    pub fn read(&self, _: usize, callback: impl FnMut(Vec<u8>) + Send + 'static) {
        BODY_READS.lock().unwrap().push(Box::new(callback));
    }
}
#[derive(Default)]
pub struct ArkWebResponse {
    status: std::cell::Cell<u16>,
}
impl ArkWebResponse {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn set_header(&self, _: &str, _: &str, _: bool) {}
    pub fn set_status(&self, status: u16) {
        self.status.set(status);
    }
}
#[derive(Clone, Default)]
pub struct ResourceHandle(Arc<Mutex<(u16, Vec<u8>, bool)>>);
impl ResourceHandle {
    pub fn receive_response(&self, response: ArkWebResponse) {
        self.0.lock().unwrap().0 = response.status.get();
    }
    pub fn receive_data(&self, bytes: &[u8]) {
        self.0.lock().unwrap().1.extend(bytes);
    }
    pub fn finish(&self) {
        self.0.lock().unwrap().2 = true;
    }
}

#[test]
fn native_declarations_install_on_real_tags_and_retire_only_their_owner() {
    use controller_key::ControllerKey;
    let a = Arc::new(());
    let b = Arc::new(());
    let ka = ControllerKey::new(Some(a.clone()), "same");
    let kb = ControllerKey::new(Some(b.clone()), "same");
    let messages = Arc::new(Mutex::new(Vec::new()));
    for (key, owner) in [(&ka, "a"), (&kb, "b")] {
        callbacks::WebviewCallbacksBuilder::with_key(key.clone())
            .on_navigation_request(|request| request.url.contains("blocked"))
            .build()
            .unwrap();
        let messages = messages.clone();
        js_proxy::WebviewJavascriptProxyBuilder::with_key(key.clone(), "NativeBridge")
            .add_method("postMessage", move |id, args| {
                messages.lock().unwrap().push((owner, id, args))
            })
            .build()
            .unwrap();
    }
    protocol::WebviewProtocol::register("asset", CustomProtocolOption(0)).unwrap();
    protocol::WebviewProtocol::seal_before_engine_init().unwrap();
    protocol::WebviewProtocol::mark_engine_initialized(&[("asset".into(), 0)]).unwrap();
    for key in [&ka, &kb] {
        protocol::bind_custom_protocol_for(key.clone(), "asset", |_, request, main| {
            assert!(main);
            assert_eq!(request.uri().scheme_str(), Some("asset"));
            Some(http::Response::new(std::borrow::Cow::Borrowed(
                &b"native asset"[..],
            )))
        })
        .unwrap();
    }
    for (key, tag) in [(&ka, "native-a"), (&kb, "native-b")] {
        assert!(callbacks::options_for(key).unwrap().navigation_intercept);
        controller::on_attached(key, tag).unwrap();
        protocol::on_controller_attached(key, tag).unwrap();
        js_proxy::on_controller_attached(key, tag).unwrap();
        assert!(
            callbacks::navigation_decision(
                key.clone(),
                WebviewNavigationRequest {
                    id: "same".into(),
                    native_tag: tag.into(),
                    url: "https://blocked.invalid".into()
                }
            )
            .unwrap()
            .intercept
        );
        let response = ResourceHandle::default();
        PROTOCOLS
            .lock()
            .unwrap()
            .get_mut(&format!("{tag}:asset"))
            .unwrap()(NativeRequest { body: false }, response.clone());
        assert_eq!(
            *response.0.lock().unwrap(),
            (200, b"native asset".to_vec(), true)
        );
        PROXIES
            .lock()
            .unwrap()
            .get_mut(&format!("{tag}:postMessage"))
            .unwrap()(tag.into(), vec!["hello".into()]);
    }
    controller::clear_attached(Some(&a)).unwrap();
    protocol::clear_attached(Some(&a)).unwrap();
    js_proxy::clear_attached(Some(&a)).unwrap();
    callbacks::remove_owner(&a).unwrap();
    protocol::remove_owner(&a).unwrap();
    js_proxy::remove_owner(&a).unwrap();
    PROXIES
        .lock()
        .unwrap()
        .get_mut("native-a:postMessage")
        .unwrap()("native-a".into(), vec!["late".into()]);
    let response = ResourceHandle::default();
    PROTOCOLS.lock().unwrap().get_mut("native-a:asset").unwrap()(
        NativeRequest { body: false },
        response.clone(),
    );
    assert_eq!(response.0.lock().unwrap().0, 410);
    PROXIES
        .lock()
        .unwrap()
        .get_mut("native-b:postMessage")
        .unwrap()("native-b".into(), vec!["alive".into()]);
    assert_eq!(
        *messages.lock().unwrap(),
        vec![
            ("a", "same".into(), vec!["hello".into()]),
            ("b", "same".into(), vec!["hello".into()]),
            ("b", "same".into(), vec!["alive".into()])
        ]
    );
}

#[test]
fn registry_removal_and_replacement_drop_user_closures_outside_the_lock() {
    use controller_key::ControllerKey;
    struct Reenter(ControllerKey);
    impl Drop for Reenter {
        fn drop(&mut self) {
            callbacks::remove(&self.0).unwrap();
        }
    }
    let owner = Arc::new(());
    let key = ControllerKey::new(Some(owner.clone()), "drop-owner");
    let guard = Reenter(key.clone());
    callbacks::WebviewCallbacksBuilder::with_key(key.clone())
        .on_navigation_request(move |_| {
            let _ = &guard;
            false
        })
        .build()
        .unwrap();
    callbacks::WebviewCallbacksBuilder::with_key(key.clone())
        .on_navigation_request(|_| false)
        .build()
        .unwrap();
    let guard = Reenter(key.clone());
    callbacks::WebviewCallbacksBuilder::with_key(key)
        .on_navigation_request(move |_| {
            let _ = &guard;
            false
        })
        .build()
        .unwrap();
    callbacks::remove_owner(&owner).unwrap();
}

#[test]
fn dropping_an_uninitialized_plugin_releases_its_final_owner_and_declarations() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct UserGuard(Arc<AtomicUsize>);
    impl Drop for UserGuard {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    let plugin = WebviewBridgePlugin::default();
    let owner = plugin.native_events.owner();
    let weak = Arc::downgrade(&owner);
    let key = ControllerKey::new(Some(owner.clone()), "never-created");
    let dropped = Arc::new(AtomicUsize::new(0));
    let guard = UserGuard(dropped.clone());
    callbacks::WebviewCallbacksBuilder::with_key(key.clone())
        .on_navigation_request(move |_| {
            let _ = &guard;
            false
        })
        .build()
        .unwrap();
    let guard = UserGuard(dropped.clone());
    js_proxy::WebviewJavascriptProxyBuilder::with_key(key.clone(), "NativeBridge")
        .add_method("postMessage", move |_, _| {
            let _ = &guard;
        })
        .build()
        .unwrap();
    protocol::WebviewProtocol::register("asset", CustomProtocolOption(0)).unwrap();
    let guard = UserGuard(dropped.clone());
    protocol::bind_custom_protocol_for(key.clone(), "asset", move |_, _, _| {
        let _ = &guard;
        None
    })
    .unwrap();
    drop(key);
    drop(owner);
    drop(plugin);
    assert_eq!(dropped.load(Ordering::SeqCst), 3);
    assert!(weak.upgrade().is_none());
}

#[test]
fn retired_controller_cannot_deliver_a_late_request_body_to_user_code() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let owner = Arc::new(());
    let key = ControllerKey::new(Some(owner), "late-body");
    let calls = Arc::new(AtomicUsize::new(0));
    protocol::WebviewProtocol::register("asset", CustomProtocolOption(0)).unwrap();
    protocol::WebviewProtocol::seal_before_engine_init().unwrap();
    protocol::WebviewProtocol::mark_engine_initialized(&[("asset".into(), 0)]).unwrap();
    protocol::bind_custom_protocol_for(key.clone(), "asset", {
        let calls = calls.clone();
        move |_, _, _| {
            calls.fetch_add(1, Ordering::SeqCst);
            None
        }
    })
    .unwrap();
    controller::on_attached(&key, "late-body-tag").unwrap();
    protocol::on_controller_attached(&key, "late-body-tag").unwrap();
    let response = ResourceHandle::default();
    PROTOCOLS
        .lock()
        .unwrap()
        .get_mut("late-body-tag:asset")
        .unwrap()(NativeRequest { body: true }, response.clone());
    assert!(!response.0.lock().unwrap().2);
    controller::on_removed(&key, "late-body-tag").unwrap();
    let mut callbacks = std::mem::take(&mut *BODY_READS.lock().unwrap());
    assert_eq!(callbacks.len(), 1);
    callbacks[0](b"late body".to_vec());
    assert_eq!(response.0.lock().unwrap().0, 410);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    protocol::remove_declarations(&key).unwrap();
}

#[test]
fn production_controller_receipts_are_idempotent_across_replacement_and_failed_install() {
    protocol::WebviewProtocol::register("asset", CustomProtocolOption(0)).unwrap();
    protocol::WebviewProtocol::seal_before_engine_init().unwrap();
    protocol::WebviewProtocol::mark_engine_initialized(&[("asset".into(), 0)]).unwrap();
    let plugin = WebviewBridgePlugin::default();
    let receipt = |id: &str, generation, tag: &str| NativeWebviewControllerEvent {
        id: id.into(),
        target_id: 12,
        generation,
        native_tag: tag.into(),
    };
    let first = plugin.native_events.prepare("same", 12).unwrap();
    assert!(
        plugin
            .dispatch_native_controller(receipt("same", first.generation, "receipt-first"), true)
            .unwrap()
            .accepted
    );
    let replacement = plugin.native_events.prepare("same", 12).unwrap();
    retire_controller(
        &plugin.native_key("same"),
        replacement.previous_tag.as_deref().unwrap(),
    )
    .unwrap();
    assert!(
        plugin
            .dispatch_native_controller(receipt("same", first.generation, "receipt-first"), false)
            .unwrap()
            .accepted
    );
    assert!(
        plugin
            .dispatch_native_controller(
                receipt("same", replacement.generation, "receipt-second"),
                true
            )
            .unwrap()
            .accepted
    );
    assert!(
        plugin
            .dispatch_native_controller(receipt("same", first.generation, "receipt-first"), false)
            .unwrap()
            .accepted
    );
    assert!(controller::is_current(&plugin.native_key("same"), "receipt-second").unwrap());

    let key = plugin.native_key("installation");
    protocol::bind_custom_protocol_for(key.clone(), "asset", |_, _, _| None).unwrap();
    let failed = plugin.native_events.prepare("installation", 12).unwrap();
    assert!(plugin
        .dispatch_native_controller(
            receipt("installation", failed.generation, "receipt-fail"),
            true
        )
        .is_err());
    assert!(
        plugin
            .dispatch_native_controller(
                receipt("installation", failed.generation, "receipt-fail"),
                false
            )
            .unwrap()
            .accepted
    );
    let retry = plugin.native_events.prepare("installation", 12).unwrap();
    assert!(
        plugin
            .dispatch_native_controller(
                receipt("installation", retry.generation, "receipt-retry"),
                true
            )
            .unwrap()
            .accepted
    );
    assert!(
        plugin
            .dispatch_native_controller(
                receipt("installation", failed.generation, "receipt-fail"),
                false
            )
            .unwrap()
            .accepted
    );
    assert!(controller::is_current(&key, "receipt-retry").unwrap());
    let other = WebviewBridgePlugin::default();
    let generation = other.native_events.prepare("same", 12).unwrap().generation;
    assert!(
        other
            .dispatch_native_controller(receipt("same", generation, "receipt-other"), true)
            .unwrap()
            .accepted
    );
    drop(plugin);
    assert!(controller::is_current(&other.native_key("same"), "receipt-other").unwrap());
}
