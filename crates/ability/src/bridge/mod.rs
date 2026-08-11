//! Typed, lifecycle-aware transport between Rust plugins and ArkTS plugins.
//!
//! `BridgeRuntime` is the worker-safe half of the bridge: it owns only N-API
//! `ThreadsafeFunction`s and can therefore turn an ArkTS `Promise<T>` into a Rust future.
//! `BridgeMainThread` is deliberately a separate, non-cloneable capability. It is constructed
//! only from an N-API `Env` on the Ability main thread and is the sole route for synchronous plugins.
//! This split makes it impossible to accidentally invoke a synchronous ArkTS plugin from a Rust
//! worker through the public typed API.

use std::{
    any::Any,
    cell::Cell,
    collections::BTreeMap,
    marker::PhantomData,
    panic::{catch_unwind, AssertUnwindSafe},
    rc::Rc,
    sync::{Arc, RwLock},
};

use futures_channel::oneshot;
use napi_ohos::{
    bindgen_prelude::{
        CallbackContext, FnArgs, FromNapiValue, Function, FunctionRef, JsObjectValue, JsValue,
        PromiseRaw, ToNapiValue, Uint8Array, Unknown,
    },
    sys,
    threadsafe_function::{ThreadsafeCallContext, ThreadsafeFunction, ThreadsafeFunctionCallMode},
    Env, Error, Result, Status, ValueType,
};
const DEFAULT_TIMEOUT_MS: u32 = 15_000;
const MAX_TIMEOUT_MS: u32 = 60_000;

mod mode {
    pub trait Sealed {}
}

/// Execution mode selected by a bridge plugin at compile time.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BridgeExecution {
    /// The call is transported through a `ThreadsafeFunction` and resolves as a Rust future.
    Async,
    /// The call runs immediately in the active ArkTS N-API environment.
    MainThreadSync,
}

/// A named value that can cross the Rust ↔ ArkTS bridge through N-API.
///
/// The type name is a compatibility contract, independent from the N-API runtime shape. For
/// example, `String` is named `std.string` and `Vec<u8>` is `std.bytes`. Application types
/// normally use `#[napi(object)]` plus [`impl_bridge_napi_type!`], so ArkTS receives a real
/// object with a stable type name.
///
/// Values are encoded and decoded only while the ArkTS/N-API callback owns its `Env`. The async
/// transport keeps Rust-owned input/output values across threads; it never retains a JS object on
/// a worker.
pub trait BridgeNapiType: Send + Sized + 'static {
    const TYPE_NAME: &'static str;

    fn into_bridge_value<'env>(self, env: &'env Env) -> Result<Unknown<'env>>;
    fn from_bridge_value(value: Unknown<'_>) -> Result<Self>;
}

/// Implements [`BridgeNapiType`] for a `#[napi(object)]` or another owned N-API-convertible type.
///
/// ```ignore
/// #[napi(object)]
/// #[derive(Clone)]
/// struct LoginToken { user_id: String, expires_at_ms: i64 }
///
/// openharmony_ability::impl_bridge_napi_type!(LoginToken, "account.LoginToken");
/// ```
#[macro_export]
macro_rules! impl_bridge_napi_type {
    ($type:ty, $type_name:literal) => {
        impl $crate::BridgeNapiType for $type {
            const TYPE_NAME: &'static str = $type_name;

            fn into_bridge_value<'env>(
                self,
                env: &'env $crate::napi_ohos::Env,
            ) -> $crate::napi_ohos::Result<$crate::napi_ohos::bindgen_prelude::Unknown<'env>> {
                <$type as $crate::napi_ohos::bindgen_prelude::ToNapiValue>::into_unknown(self, env)
            }

            fn from_bridge_value(
                value: $crate::napi_ohos::bindgen_prelude::Unknown<'_>,
            ) -> $crate::napi_ohos::Result<Self> {
                <$type as $crate::napi_ohos::bindgen_prelude::FromNapiValue>::from_unknown(value)
            }
        }
    };
}

macro_rules! impl_builtin_napi_type {
    ($type:ty, $type_name:literal) => {
        impl BridgeNapiType for $type {
            const TYPE_NAME: &'static str = $type_name;

            fn into_bridge_value<'env>(self, env: &'env Env) -> Result<Unknown<'env>> {
                <$type as ToNapiValue>::into_unknown(self, env)
            }

            fn from_bridge_value(value: Unknown<'_>) -> Result<Self> {
                <$type as FromNapiValue>::from_unknown(value)
            }
        }
    };
}

impl_builtin_napi_type!(String, "std.string");
impl_builtin_napi_type!(bool, "std.bool");
impl_builtin_napi_type!(i32, "std.i32");
impl_builtin_napi_type!(f64, "std.f64");

impl BridgeNapiType for Vec<u8> {
    const TYPE_NAME: &'static str = "std.bytes";

    fn into_bridge_value<'env>(self, env: &'env Env) -> Result<Unknown<'env>> {
        Uint8Array::from(self).into_unknown(env)
    }

    fn from_bridge_value(value: Unknown<'_>) -> Result<Self> {
        let value = Uint8Array::from_unknown(value)?;
        Ok(value.as_ref().to_vec())
    }
}

/// Marker for plugins callable from any Rust thread through [`BridgeRuntime`].
pub enum AsyncBridge {}

/// Marker for plugins callable only through [`BridgeMainThread`].
pub enum MainThreadSyncBridge {}

/// Sealed mode trait: framework code owns the only two legal execution modes.
pub trait BridgePluginMode: mode::Sealed + Send + Sync + 'static {
    const EXECUTION: BridgeExecution;
}

impl mode::Sealed for AsyncBridge {}

impl BridgePluginMode for AsyncBridge {
    const EXECUTION: BridgeExecution = BridgeExecution::Async;
}

impl mode::Sealed for MainThreadSyncBridge {}

impl BridgePluginMode for MainThreadSyncBridge {
    const EXECUTION: BridgeExecution = BridgeExecution::MainThreadSync;
}

/// ArkTS context that an ArkTS implementation must wait for before it is activated.
///
/// The associated [`BridgePlugin::REQUIRED_CONTEXTS`] is checked by the Rust event registry. The
/// ArkTS factory declares the same requirement and `BridgeHost` enforces actual activation,
/// because the context objects themselves must never cross the N-API boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BridgeContextRequirement {
    Ability,
    WindowStage,
    UiContext,
}

/// A synchronous, ArkTS-originated event scoped to the active N-API environment.
///
/// ArkWeb callbacks such as navigation interception, download admission, title changes, and
/// controller lifecycle signals must finish before ArkTS returns from the active N-API callback.
/// This value is created only by the native N-API export and is deliberately non-Send and
/// non-Sync, so neither the request value nor its response can escape to a Rust worker. A handler
/// may hand decoded, Rust-owned data to a worker, but it must produce this call's response first.
pub struct BridgeMainThreadEvent<'env> {
    plugin_id: String,
    name: String,
    request_type_name: String,
    response_type_name: String,
    value: Unknown<'env>,
    env: &'env Env,
    _not_send_or_sync: PhantomData<Rc<()>>,
}

impl<'env> BridgeMainThreadEvent<'env> {
    #[doc(hidden)]
    pub fn new(
        env: &'env Env,
        plugin_id: impl Into<String>,
        name: impl Into<String>,
        request_type_name: impl Into<String>,
        response_type_name: impl Into<String>,
        value: Unknown<'env>,
    ) -> Result<Self> {
        let plugin_id = plugin_id.into();
        let name = name.into();
        let request_type_name = request_type_name.into();
        let response_type_name = response_type_name.into();
        validate_identifier("plugin id", &plugin_id)?;
        validate_identifier("event", &name)?;
        validate_identifier("request type", &request_type_name)?;
        validate_identifier("response type", &response_type_name)?;
        if value.get_type()? == ValueType::Function {
            return Err(Error::from_reason(
                "Main-thread bridge events cannot carry Function values",
            ));
        }
        Ok(Self {
            plugin_id,
            name,
            request_type_name,
            response_type_name,
            value,
            env,
            _not_send_or_sync: PhantomData,
        })
    }

    pub fn plugin_id(&self) -> &str {
        &self.plugin_id
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn request_type_name(&self) -> &str {
        &self.request_type_name
    }

    pub fn response_type_name(&self) -> &str {
        &self.response_type_name
    }

    /// Decodes the request after verifying its stable named N-API contract.
    pub fn decode<T>(&self) -> Result<T>
    where
        T: BridgeNapiType,
    {
        if self.request_type_name != T::TYPE_NAME {
            return Err(Error::from_reason(format!(
                "Main-thread bridge event '{}.{}' received {}, expected {}",
                self.plugin_id,
                self.name,
                self.request_type_name,
                T::TYPE_NAME,
            )));
        }
        T::from_bridge_value(self.value)
    }

    /// Encodes the response while the originating N-API environment is still active.
    pub fn respond<T>(&self, response: T) -> Result<Unknown<'env>>
    where
        T: BridgeNapiType,
    {
        if self.response_type_name != T::TYPE_NAME {
            return Err(Error::from_reason(format!(
                "Main-thread bridge event '{}.{}' expects {}, attempted to return {}",
                self.plugin_id,
                self.name,
                self.response_type_name,
                T::TYPE_NAME,
            )));
        }
        response.into_bridge_value(self.env)
    }
}

/// Lifecycle notifications delivered to registered Rust plugins.
///
/// Native ability lifecycle events originate from `create_lifecycle_handle`. `UiContextReady`
/// originates in `DefaultXComponent`, because only ArkTS owns that object and its lifetime.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PluginLifecycleEvent {
    AbilityCreated { restored_state: String },
    AbilityDestroyed,
    WindowStageCreated,
    WindowStageDestroyed,
    ConfigurationUpdated,
    MemoryLevel { level: i32 },
    WindowStageEvent { event_type: i32 },
    UiContextReady,
    UiContextDestroyed,
}

impl PluginLifecycleEvent {
    /// Parses the small ArkTS-only lifecycle extension that cannot be observed by Rust directly.
    pub fn from_arkts(kind: &str) -> Result<Self> {
        validate_identifier("lifecycle event", kind)?;
        match kind {
            "ui-context-ready" => Ok(Self::UiContextReady),
            "ui-context-destroy" => Ok(Self::UiContextDestroyed),
            _ => Err(Error::from_reason(format!(
                "Unsupported ArkTS bridge lifecycle event '{kind}'"
            ))),
        }
    }
}

/// Stable Rust-side contract for a versioned ArkTS plugin.
///
/// `type Mode` is intentionally not a runtime flag. A facade for `AsyncBridge` cannot be passed
/// to [`BridgeMainThread::call_sync`], and a facade for `MainThreadSyncBridge` cannot be passed
/// to [`BridgeRuntime::call_async`].
pub trait BridgePlugin: Send + Sync + 'static {
    type Mode: BridgePluginMode;

    const ID: &'static str;
    const VERSION: u32 = 1;
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] = &[];

    /// Context gate for one ArkTS -> Rust main-thread event.
    ///
    /// Most events use the plugin-wide requirement. A plugin may narrow this only for an event
    /// that provably does not touch the later platform object (for example process-global engine
    /// registration performed after Ability creation but before any UI component exists).
    fn required_contexts_for_main_thread_event(
        &self,
        _event_name: &str,
    ) -> &'static [BridgeContextRequirement] {
        Self::REQUIRED_CONTEXTS
    }

    /// Handles a direct event emitted from ArkTS while its N-API environment is active.
    ///
    /// This hook is not an outbound plugin call: it is the only Rust callback path permitted to
    /// synchronously influence a platform callback or acknowledge a lifecycle notification. The
    /// borrowed event and response are non-Send and non-Sync, so implementations must finish
    /// immediately and must not retain N-API values. Plugins that do not own such a contract keep
    /// the default error.
    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        Err(Error::from_reason(format!(
            "Bridge plugin '{}' does not support main-thread event '{}'",
            event.plugin_id(),
            event.name(),
        )))
    }

    /// Receives ability and UI-context readiness transitions without exposing ArkTS objects to
    /// Rust worker threads.
    fn on_lifecycle(&self, _event: &PluginLifecycleEvent) -> Result<()> {
        Ok(())
    }
}

trait RegisteredBridgePlugin: Send + Sync {
    fn required_contexts_for_main_thread_event(
        &self,
        event_name: &str,
    ) -> &'static [BridgeContextRequirement];
    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>>;
    fn on_lifecycle(&self, event: &PluginLifecycleEvent) -> Result<()>;
}

impl<P> RegisteredBridgePlugin for P
where
    P: BridgePlugin,
{
    fn required_contexts_for_main_thread_event(
        &self,
        event_name: &str,
    ) -> &'static [BridgeContextRequirement] {
        BridgePlugin::required_contexts_for_main_thread_event(self, event_name)
    }

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        BridgePlugin::on_main_thread_event(self, event)
    }

    fn on_lifecycle(&self, event: &PluginLifecycleEvent) -> Result<()> {
        BridgePlugin::on_lifecycle(self, event)
    }
}

#[derive(Clone, Copy, Default)]
struct BridgeContextReadiness {
    ability: bool,
    window_stage: bool,
    ui_context: bool,
}

impl BridgeContextReadiness {
    fn supports(self, requirements: &[BridgeContextRequirement]) -> bool {
        requirements.iter().all(|requirement| match requirement {
            BridgeContextRequirement::Ability => self.ability,
            BridgeContextRequirement::WindowStage => self.window_stage,
            BridgeContextRequirement::UiContext => self.ui_context,
        })
    }

    fn observe(&mut self, event: &PluginLifecycleEvent) {
        match event {
            PluginLifecycleEvent::AbilityCreated { .. } => self.ability = true,
            PluginLifecycleEvent::AbilityDestroyed => *self = Self::default(),
            PluginLifecycleEvent::WindowStageCreated => self.window_stage = true,
            PluginLifecycleEvent::WindowStageDestroyed => {
                self.window_stage = false;
                self.ui_context = false;
            }
            PluginLifecycleEvent::UiContextReady => self.ui_context = true,
            PluginLifecycleEvent::UiContextDestroyed => self.ui_context = false,
            PluginLifecycleEvent::ConfigurationUpdated
            | PluginLifecycleEvent::MemoryLevel { .. }
            | PluginLifecycleEvent::WindowStageEvent { .. } => {}
        }
    }
}

struct RegisteredPluginEntry {
    plugin: Arc<dyn RegisteredBridgePlugin>,
    typed: Arc<dyn Any + Send + Sync>,
    required_contexts: &'static [BridgeContextRequirement],
    /// Once a plugin becomes ready in one Ability session it keeps receiving that session's
    /// teardown events even after its required context has already disappeared.
    activated: bool,
}

#[derive(Default)]
struct BridgePluginRegistryState {
    plugins: BTreeMap<String, RegisteredPluginEntry>,
    readiness: BridgeContextReadiness,
    lifecycle_history: Vec<PluginLifecycleEvent>,
    session_active: bool,
}

/// Registration point for Rust facades that consume ArkTS plugin events and lifecycle changes.
///
/// The registry owns a Rust-only readiness mirror. A facade that declares `UiContext` does not
/// receive an early lifecycle callback or ArkTS event; when it becomes ready it receives the
/// bounded lifecycle history in order. The lock is always dropped before invoking user code.
#[derive(Default)]
pub struct BridgePluginRegistry {
    state: RwLock<BridgePluginRegistryState>,
}

impl BridgePluginRegistry {
    pub fn register<P>(&self, plugin: P) -> Result<()>
    where
        P: BridgePlugin,
    {
        validate_plugin_contract::<P>()?;
        let plugin = Arc::new(plugin);
        let registered: Arc<dyn RegisteredBridgePlugin> = plugin.clone();
        let typed: Arc<dyn Any + Send + Sync> = plugin.clone();
        let replay = {
            let mut state = self
                .state
                .write()
                .map_err(|_| Error::from_reason("Failed to register bridge plugin"))?;
            if state.plugins.contains_key(P::ID) {
                return Err(Error::from_reason(format!(
                    "Bridge plugin '{}' is already registered",
                    P::ID
                )));
            }
            let activated = state.session_active && state.readiness.supports(P::REQUIRED_CONTEXTS);
            let replay = if activated {
                state.lifecycle_history.clone()
            } else {
                Vec::new()
            };
            state.plugins.insert(
                P::ID.to_owned(),
                RegisteredPluginEntry {
                    plugin: Arc::clone(&registered),
                    typed,
                    required_contexts: P::REQUIRED_CONTEXTS,
                    activated,
                },
            );
            replay
        };

        for event in replay {
            registered.on_lifecycle(&event)?;
        }
        Ok(())
    }

    /// Returns the concrete registered plugin while the registry retains module ownership.
    pub fn registered<P>(&self) -> Result<Option<Arc<P>>>
    where
        P: BridgePlugin,
    {
        validate_plugin_contract::<P>()?;
        let typed = {
            let state = self
                .state
                .read()
                .map_err(|_| Error::from_reason("Failed to read bridge plugin registry"))?;
            state
                .plugins
                .get(P::ID)
                .map(|entry| Arc::clone(&entry.typed))
        };
        let Some(typed) = typed else {
            return Ok(None);
        };
        Arc::downcast::<P>(typed).map(Some).map_err(|_| {
            Error::from_reason(format!(
                "Bridge plugin '{}' is registered with a different Rust implementation type",
                P::ID
            ))
        })
    }

    /// Delivers an ArkTS-originated direct event to its Rust plugin without allowing its N-API
    /// value to leave the current main-thread callback.
    pub fn dispatch_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        let plugin = {
            let state = self
                .state
                .read()
                .map_err(|_| Error::from_reason("Failed to read bridge plugin registry"))?;
            let entry = state.plugins.get(event.plugin_id()).ok_or_else(|| {
                Error::from_reason(format!(
                    "No Rust bridge plugin registered for '{}'",
                    event.plugin_id()
                ))
            })?;
            if !state.session_active {
                return Err(Error::from_reason(format!(
                    "Bridge plugin '{}' received a main-thread event outside an active Ability session",
                    event.plugin_id()
                )));
            }
            let event_requirements = entry
                .plugin
                .required_contexts_for_main_thread_event(event.name());
            if !state.readiness.supports(event_requirements) {
                return Err(Error::from_reason(format!(
                    "Bridge plugin '{}' received a main-thread event before its required context was ready",
                    event.plugin_id()
                )));
            }
            Arc::clone(&entry.plugin)
        };
        plugin.on_main_thread_event(event)
    }

    pub fn dispatch_lifecycle(&self, event: PluginLifecycleEvent) -> Result<()> {
        let deliveries = {
            let mut state = self
                .state
                .write()
                .map_err(|_| Error::from_reason("Failed to read bridge plugin registry"))?;

            // The OpenHarmony process may keep the native module loaded while recreating the
            // Ability. Lifecycle replay is session-scoped: never expose events from the previous
            // Ability instance to a plugin activated in the next one.
            if matches!(event, PluginLifecycleEvent::AbilityCreated { .. }) {
                state.readiness = BridgeContextReadiness::default();
                state.lifecycle_history.clear();
                state.session_active = true;
                for entry in state.plugins.values_mut() {
                    entry.activated = false;
                }
            } else if !state.session_active {
                // A closing ArkTS hook or stale TSFN may complete after AbilityDestroyed. Late
                // events belong to no session and must never reach process-wide Rust plugins.
                return Ok(());
            }

            state.readiness.observe(&event);
            if state.lifecycle_history.len() >= MAX_LIFECYCLE_HISTORY {
                if let Some(index) = state.lifecycle_history.iter().position(|recorded| {
                    matches!(
                        recorded,
                        PluginLifecycleEvent::ConfigurationUpdated
                            | PluginLifecycleEvent::MemoryLevel { .. }
                            | PluginLifecycleEvent::WindowStageEvent { .. }
                    )
                }) {
                    state.lifecycle_history.remove(index);
                } else {
                    // Preserve AbilityCreated at index 0 when possible, while keeping the replay
                    // buffer genuinely bounded even across repeated structural context cycles.
                    let index = usize::from(state.lifecycle_history.len() > 1);
                    state.lifecycle_history.remove(index);
                }
            }
            state.lifecycle_history.push(event.clone());

            let readiness = state.readiness;
            let history = state.lifecycle_history.clone();
            let session_active = state.session_active;
            let mut deliveries = Vec::new();
            for entry in state.plugins.values_mut() {
                let events = if entry.activated {
                    vec![event.clone()]
                } else if session_active && readiness.supports(entry.required_contexts) {
                    entry.activated = true;
                    history.clone()
                } else {
                    Vec::new()
                };
                if !events.is_empty() {
                    deliveries.push((Arc::clone(&entry.plugin), events));
                }
            }

            if matches!(event, PluginLifecycleEvent::AbilityDestroyed) {
                state.session_active = false;
                state.lifecycle_history.clear();
                for entry in state.plugins.values_mut() {
                    entry.activated = false;
                }
            }
            deliveries
        };

        let mut first_error = None;
        for (plugin, events) in deliveries {
            for event in events {
                if let Err(error) = plugin.on_lifecycle(&event) {
                    // A faulty lifecycle subscriber must not prevent the other plugins from
                    // observing teardown. Preserve the first error for diagnostics after every
                    // delivery has had a chance to run.
                    if first_error.is_none() {
                        first_error = Some(error);
                    }
                }
            }
        }
        first_error.map_or(Ok(()), Err)
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.state.read().map_or(0, |state| state.plugins.len())
    }
}

const MAX_LIFECYCLE_HISTORY: usize = 16;

/// Per-call policy enforced by the ArkTS host.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BridgeCallOptions {
    timeout_ms: u32,
}

impl BridgeCallOptions {
    pub fn with_timeout_ms(mut self, timeout_ms: u32) -> Self {
        self.timeout_ms = timeout_ms.clamp(1, MAX_TIMEOUT_MS);
        self
    }

    pub fn timeout_ms(self) -> u32 {
        self.timeout_ms
    }
}

impl Default for BridgeCallOptions {
    fn default() -> Self {
        Self {
            timeout_ms: DEFAULT_TIMEOUT_MS,
        }
    }
}

struct BridgeRequest {
    plugin_id: String,
    plugin_version: u32,
    action: String,
    request_type_name: String,
    response_type_name: String,
    value: Box<dyn BridgeValueEncoder>,
    timeout_ms: u32,
}

/// A worker-originated request to invoke a synchronous ArkTS plugin on the main thread.
///
/// Unlike [`BridgeRequest`] there is no timeout: the ArkTS `invokeSync` side is synchronous
/// and must return promptly. The encoder is consumed on the ArkTS/N-API callback thread.
struct SyncFromWorkerRequest {
    plugin_id: String,
    plugin_version: u32,
    action: String,
    request_type_name: String,
    response_type_name: String,
    value: Box<dyn BridgeValueEncoder>,
}

trait BridgeValueEncoder: Send {
    fn encode(self: Box<Self>, env: &Env) -> Result<sys::napi_value>;
}

impl<T> BridgeValueEncoder for T
where
    T: BridgeNapiType,
{
    fn encode(self: Box<Self>, env: &Env) -> Result<sys::napi_value> {
        Ok((*self).into_bridge_value(env)?.raw())
    }
}

trait BridgeResponseDecoder: Send {
    fn decode(self: Box<Self>, value: Unknown<'_>) -> Result<Box<dyn Any + Send>>;
}

struct TypedBridgeResponse<T>(PhantomData<T>);

impl<T> BridgeResponseDecoder for TypedBridgeResponse<T>
where
    T: BridgeNapiType,
{
    fn decode(self: Box<Self>, value: Unknown<'_>) -> Result<Box<dyn Any + Send>> {
        T::from_bridge_value(value).map(|value| Box::new(value) as Box<dyn Any + Send>)
    }
}

type AsyncBridgeArgs = FnArgs<(String, u32, String, String, String, sys::napi_value, u32)>;
type SyncBridgeArgs = FnArgs<(String, u32, String, String, String, sys::napi_value)>;
type AsyncBridgeFunction<'env> = Function<'env, AsyncBridgeArgs, Unknown<'env>>;
type SyncBridgeFunction<'env> = Function<'env, SyncBridgeArgs, Unknown<'env>>;
type BridgeInvokeTsfn =
    ThreadsafeFunction<BridgeRequest, Unknown<'static>, AsyncBridgeArgs, Status, false>;
/// Worker → main-thread synchronous transport. The TSFN is built from the same `bridgeInvokeSync`
/// function the main-thread path uses, so the ArkTS host is agnostic to the caller's thread.
type SyncFromWorkerTsfn =
    ThreadsafeFunction<SyncFromWorkerRequest, Unknown<'static>, SyncBridgeArgs, Status, false>;

type BridgeWireResult = std::result::Result<Box<dyn Any + Send>, String>;
type BridgeSender = oneshot::Sender<BridgeWireResult>;

/// Cloneable client used by asynchronous plugins from the N-API main thread or a Rust worker.
///
/// Also carries the worker → main-thread synchronous transport
/// ([`BridgeClient::call_sync_from_worker`]); the guard thread id lets the same client reject an
/// accidental main-thread call that would otherwise deadlock against its own TSFN queue.
#[derive(Clone)]
pub struct BridgeClient {
    invoke: Arc<BridgeInvokeTsfn>,
    invoke_sync_from_worker: Arc<SyncFromWorkerTsfn>,
    main_thread_id: std::thread::ThreadId,
}

impl BridgeClient {
    /// Calls an action owned by an asynchronous plugin with named N-API request and response
    /// values. `Request` is materialized only on the ArkTS callback thread; `Response` is decoded
    /// there before it is sent back to the Rust worker.
    pub async fn call_async<P, Request, Response>(
        &self,
        action: impl AsRef<str>,
        request: Request,
        options: BridgeCallOptions,
    ) -> Result<Response>
    where
        P: BridgePlugin<Mode = AsyncBridge>,
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        validate_plugin_contract::<P>()?;
        self.call_raw::<Request, Response>(P::ID, P::VERSION, action.as_ref(), request, options)
            .await
    }

    async fn call_raw<Request, Response>(
        &self,
        plugin_id: &str,
        plugin_version: u32,
        action: &str,
        request: Request,
        options: BridgeCallOptions,
    ) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        validate_wire_call(
            plugin_id,
            plugin_version,
            action,
            Request::TYPE_NAME,
            Response::TYPE_NAME,
        )?;

        let request = BridgeRequest {
            plugin_id: plugin_id.to_owned(),
            plugin_version,
            action: action.to_owned(),
            request_type_name: Request::TYPE_NAME.to_owned(),
            response_type_name: Response::TYPE_NAME.to_owned(),
            value: Box::new(request),
            timeout_ms: options.timeout_ms(),
        };
        let response_decoder: Box<dyn BridgeResponseDecoder> =
            Box::new(TypedBridgeResponse::<Response>(PhantomData));
        let (sender, receiver) = oneshot::channel::<BridgeWireResult>();

        let status = self.invoke.call_with_return_value(
            request,
            ThreadsafeFunctionCallMode::NonBlocking,
            move |result, _env| {
                match result {
                    Ok(value) => {
                        attach_promise(value, response_decoder, sender);
                    }
                    Err(error) => send_once(sender, Err(error.to_string())),
                }
                // Deliver ArkTS errors through the Rust future rather than as uncaught N-API
                // exceptions on the UI thread.
                Ok(())
            },
        );

        if status != Status::Ok {
            return Err(Error::from_reason(format!(
                "Bridge TSFN dispatch failed with status: {status:?}"
            )));
        }

        let response = receiver
            .await
            .map_err(|_| Error::from_reason("Bridge response channel was cancelled"))?
            .map_err(Error::from_reason)?;
        response
            .downcast::<Response>()
            .map(|response| *response)
            .map_err(|_| {
                Error::from_reason(format!(
                    "Bridge response type dispatch failed for '{}'",
                    Response::TYPE_NAME
                ))
            })
    }

    /// Calls a synchronous, main-thread-only ArkTS plugin from a Rust worker.
    ///
    /// The request is encoded and the response decoded on the ArkTS/N-API main thread through a
    /// `ThreadsafeFunction`; the worker awaits the decoded Rust-owned result. Execution still
    /// happens on the main thread, exactly as with [`BridgeMainThread::call_sync`], so the same
    /// `MainThreadSyncBridge` contract applies. This must be called from a worker thread — the
    /// N-API main thread would deadlock awaiting its own TSFN queue, so such a call is rejected
    /// immediately.
    pub async fn call_sync_from_worker<P, Request, Response>(
        &self,
        action: impl AsRef<str>,
        request: Request,
    ) -> Result<Response>
    where
        P: BridgePlugin<Mode = MainThreadSyncBridge>,
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        if std::thread::current().id() == self.main_thread_id {
            return Err(Error::from_reason(
                "call_sync_from_worker must run on a Rust worker; the N-API main thread would \
                 deadlock awaiting its own ThreadsafeFunction queue",
            ));
        }
        validate_plugin_contract::<P>()?;
        self.call_sync_from_worker_raw::<Request, Response>(
            P::ID,
            P::VERSION,
            action.as_ref(),
            request,
        )
        .await
    }

    async fn call_sync_from_worker_raw<Request, Response>(
        &self,
        plugin_id: &str,
        plugin_version: u32,
        action: &str,
        request: Request,
    ) -> Result<Response>
    where
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        validate_wire_call(
            plugin_id,
            plugin_version,
            action,
            Request::TYPE_NAME,
            Response::TYPE_NAME,
        )?;

        let request = SyncFromWorkerRequest {
            plugin_id: plugin_id.to_owned(),
            plugin_version,
            action: action.to_owned(),
            request_type_name: Request::TYPE_NAME.to_owned(),
            response_type_name: Response::TYPE_NAME.to_owned(),
            value: Box::new(request),
        };
        let response_decoder: Box<dyn BridgeResponseDecoder> =
            Box::new(TypedBridgeResponse::<Response>(PhantomData));
        let (sender, receiver) = oneshot::channel::<BridgeWireResult>();

        let status = self.invoke_sync_from_worker.call_with_return_value(
            request,
            ThreadsafeFunctionCallMode::NonBlocking,
            move |result, _env| {
                match result {
                    Ok(value) => {
                        send_once(
                            sender,
                            response_decoder.decode(value).map_err(|e| e.to_string()),
                        );
                    }
                    Err(error) => send_once(sender, Err(error.to_string())),
                }
                // The ArkTS `bridgeInvokeSync` call is synchronous; the response is decoded on
                // this main-thread callback and returned over the oneshot, never as an uncaught
                // N-API exception.
                Ok(())
            },
        );

        if status != Status::Ok {
            return Err(Error::from_reason(format!(
                "Sync-from-worker TSFN dispatch failed with status: {status:?}"
            )));
        }

        let response = receiver
            .await
            .map_err(|_| Error::from_reason("Bridge sync-from-worker channel was cancelled"))?
            .map_err(Error::from_reason)?;
        response
            .downcast::<Response>()
            .map(|response| *response)
            .map_err(|_| {
                Error::from_reason(format!(
                    "Bridge sync-from-worker response type dispatch failed for '{}'",
                    Response::TYPE_NAME
                ))
            })
    }
}

fn attach_promise(
    value: Unknown<'static>,
    decoder: Box<dyn BridgeResponseDecoder>,
    sender: BridgeSender,
) {
    let sender = Rc::new(Cell::new(Some(sender)));

    let setup_result = (|| -> Result<()> {
        if value.get_type()? != ValueType::Object {
            send_once_cell(
                &sender,
                Err("Bridge handler did not return a Promise payload".to_owned()),
            );
            return Ok(());
        }

        let promise: PromiseRaw<'static, Unknown<'static>> = unsafe { value.cast()? };
        let resolve_sender = Rc::clone(&sender);
        let reject_sender = Rc::clone(&sender);

        promise
            .then(move |context| {
                let result = decoder
                    .decode(context.value)
                    .map_err(|error| error.to_string());
                send_once_cell(&resolve_sender, result);
                Ok(())
            })?
            .catch(move |context: CallbackContext<Unknown>| {
                let message = context
                    .value
                    .coerce_to_string()
                    .and_then(|value| value.into_utf8().and_then(|value| value.into_owned()))
                    .unwrap_or_else(|_| {
                        "Bridge handler rejected without a string message".to_owned()
                    });
                send_once_cell(&reject_sender, Err(message));
                Ok(())
            })?;

        Ok(())
    })();

    if let Err(error) = setup_result {
        send_once_cell(
            &sender,
            Err(format!("Failed to observe bridge Promise: {error}")),
        );
    }
}

fn send_once(sender: BridgeSender, result: BridgeWireResult) {
    let _ = sender.send(result);
}

fn send_once_cell(sender: &Rc<Cell<Option<BridgeSender>>>, result: BridgeWireResult) {
    if let Some(sender) = sender.replace(None) {
        let _ = sender.send(result);
    }
}

struct MainThreadTask {
    task: Box<dyn FnOnce() + Send + 'static>,
}

impl MainThreadTask {
    fn run(self) {
        // Never unwind through the N-API callback. `MainThreadScheduler::run` observes the
        // dropped oneshot sender as a cancelled task if the user closure panics.
        let _ = catch_unwind(AssertUnwindSafe(self.task));
    }
}

type MainThreadTsfn = ThreadsafeFunction<MainThreadTask, (), (), Status, false>;

/// Schedules Rust-only state transitions onto the ArkTS/N-API main thread.
///
/// This is not a capability for synchronous plugins because a scheduled closure has no scoped
/// `Env`. Use [`crate::OpenHarmonyApp::with_main_thread_bridge`] from a N-API callback instead.
#[derive(Clone)]
pub struct MainThreadScheduler {
    dispatch: Arc<MainThreadTsfn>,
}

impl MainThreadScheduler {
    pub fn dispatch<F>(&self, task: F) -> Result<()>
    where
        F: FnOnce() + Send + 'static,
    {
        let status = self.dispatch.call(
            MainThreadTask {
                task: Box::new(task),
            },
            ThreadsafeFunctionCallMode::NonBlocking,
        );
        if status == Status::Ok {
            Ok(())
        } else {
            Err(Error::from_reason(format!(
                "Main-thread TSFN dispatch failed with status: {status:?}"
            )))
        }
    }

    pub async fn run<F, T>(&self, task: F) -> Result<T>
    where
        F: FnOnce() -> T + Send + 'static,
        T: Send + 'static,
    {
        let (sender, receiver) = oneshot::channel();
        self.dispatch(move || {
            let _ = sender.send(task());
        })?;
        receiver
            .await
            .map_err(|_| Error::from_reason("Main-thread task was cancelled or panicked"))
    }
}

type SyncBridgeFunctionRef = FunctionRef<SyncBridgeArgs, Unknown<'static>>;

/// A stored reference to the ArkTS synchronous dispatcher. It is intentionally crate-private;
/// callers can only obtain the scoped [`BridgeMainThread`] wrapper from `OpenHarmonyApp`.
pub(crate) struct MainThreadBridgeEndpoint {
    owner_env: usize,
    invoke_sync: SyncBridgeFunctionRef,
}

/// Main-thread and `Env`-scoped capability to invoke a synchronous ArkTS plugin.
///
/// The `Rc` marker makes this type `!Send` and `!Sync`; it cannot be captured by a worker or put
/// in a static. Its lifetime is tied to the N-API callback that supplied `Env`.
pub struct BridgeMainThread<'env> {
    env: &'env Env,
    endpoint: &'env MainThreadBridgeEndpoint,
    _not_send_or_sync: PhantomData<Rc<()>>,
}

impl<'env> BridgeMainThread<'env> {
    pub(crate) fn new(env: &'env Env, endpoint: &'env MainThreadBridgeEndpoint) -> Self {
        Self {
            env,
            endpoint,
            _not_send_or_sync: PhantomData,
        }
    }

    /// Calls a synchronous, main-thread-only ArkTS plugin with named N-API request and response
    /// values. The `Env` identity check permits N-API callbacks that share the active ArkTS
    /// environment even when the runtime uses a different OS thread for dispatch.
    pub fn call_sync<P, Request, Response>(
        &self,
        action: impl AsRef<str>,
        request: Request,
    ) -> Result<Response>
    where
        P: BridgePlugin<Mode = MainThreadSyncBridge>,
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        validate_plugin_contract::<P>()?;
        let action = action.as_ref();
        validate_wire_call(
            P::ID,
            P::VERSION,
            action,
            Request::TYPE_NAME,
            Response::TYPE_NAME,
        )?;
        if self.env.raw() as usize != self.endpoint.owner_env {
            return Err(Error::from_reason(
                "Synchronous bridge plugins may only run from the active ArkTS N-API environment",
            ));
        }

        let request = request.into_bridge_value(self.env)?.raw();
        let invoke = self.endpoint.invoke_sync.borrow_back(self.env)?;
        let response = invoke.call(FnArgs {
            data: (
                P::ID.to_owned(),
                P::VERSION,
                action.to_owned(),
                Request::TYPE_NAME.to_owned(),
                Response::TYPE_NAME.to_owned(),
                request,
            ),
        })?;
        Response::from_bridge_value(response)
    }
}

/// Per-module worker-safe runtime owned by one NativeAbility bridge session.
#[derive(Clone)]
pub struct BridgeRuntime {
    client: BridgeClient,
    main_thread: MainThreadScheduler,
}

pub(crate) struct BridgeBindings {
    pub(crate) runtime: BridgeRuntime,
    pub(crate) main_thread_endpoint: MainThreadBridgeEndpoint,
}

/// Builds and installs one module's Ability-session transport before any component render is
/// required. Kept public only for code generated by `#[ability]` in downstream crates.
#[doc(hidden)]
pub fn attach_bridge_session(
    env: &Env,
    bindings: napi_ohos::bindgen_prelude::ObjectRef,
    owner: &str,
    app: &crate::OpenHarmonyApp,
) -> Result<()> {
    let bindings = BridgeRuntime::from_bindings(env, &bindings)?;
    app.begin_bridge_session(owner, bindings.runtime, bindings.main_thread_endpoint)
}

impl BridgeRuntime {
    pub(crate) fn from_bindings(
        env: &Env,
        bindings: &napi_ohos::bindgen_prelude::ObjectRef,
    ) -> Result<BridgeBindings> {
        let bindings = bindings.get_value(env)?;
        let invoke: AsyncBridgeFunction<'_> = bindings.get_named_property("bridgeInvoke")?;
        let invoke_sync: SyncBridgeFunction<'_> =
            bindings.get_named_property("bridgeInvokeSync")?;
        let dispatch: Function<'_, (), ()> = bindings.get_named_property("bridgeDispatch")?;

        // Keep a main-thread borrow for the sync path before consuming the function to build the
        // worker transport.
        let invoke_sync_ref = invoke_sync.create_ref()?;

        let invoke = invoke
            .build_threadsafe_function::<BridgeRequest>()
            .callee_handled::<false>()
            .build_callback(|context: ThreadsafeCallContext<BridgeRequest>| {
                let request = context.value;
                let value = request.value.encode(&context.env)?;
                Ok(FnArgs {
                    data: (
                        request.plugin_id,
                        request.plugin_version,
                        request.action,
                        request.request_type_name,
                        request.response_type_name,
                        value,
                        request.timeout_ms,
                    ),
                })
            })?;

        // Worker → main-thread synchronous transport: the TSFN invokes the same `bridgeInvokeSync`
        // function the main-thread path uses, so ArkTS is agnostic to the caller's thread.
        let invoke_sync_from_worker = invoke_sync
            .build_threadsafe_function::<SyncFromWorkerRequest>()
            .callee_handled::<false>()
            .build_callback(|context: ThreadsafeCallContext<SyncFromWorkerRequest>| {
                let request = context.value;
                let value = request.value.encode(&context.env)?;
                Ok(FnArgs {
                    data: (
                        request.plugin_id,
                        request.plugin_version,
                        request.action,
                        request.request_type_name,
                        request.response_type_name,
                        value,
                    ),
                })
            })?;

        let dispatch = dispatch
            .build_threadsafe_function::<MainThreadTask>()
            .callee_handled::<false>()
            .build_callback(|context: ThreadsafeCallContext<MainThreadTask>| {
                context.value.run();
                Ok(())
            })?;

        Ok(BridgeBindings {
            runtime: Self {
                client: BridgeClient {
                    invoke: Arc::new(invoke),
                    invoke_sync_from_worker: Arc::new(invoke_sync_from_worker),
                    // The bindings are built on the ArkTS/N-API main thread.
                    main_thread_id: std::thread::current().id(),
                },
                main_thread: MainThreadScheduler {
                    dispatch: Arc::new(dispatch),
                },
            },
            main_thread_endpoint: MainThreadBridgeEndpoint {
                owner_env: env.raw() as usize,
                invoke_sync: invoke_sync_ref,
            },
        })
    }

    pub fn client(&self) -> BridgeClient {
        self.client.clone()
    }

    pub fn main_thread(&self) -> MainThreadScheduler {
        self.main_thread.clone()
    }

    pub async fn call_async<P, Request, Response>(
        &self,
        action: impl AsRef<str>,
        request: Request,
        options: BridgeCallOptions,
    ) -> Result<Response>
    where
        P: BridgePlugin<Mode = AsyncBridge>,
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.client
            .call_async::<P, Request, Response>(action, request, options)
            .await
    }

    /// Invokes a synchronous ArkTS plugin from a Rust worker through a `ThreadsafeFunction`.
    /// See [`BridgeClient::call_sync_from_worker`] for the thread-safety contract.
    pub async fn call_sync_from_worker<P, Request, Response>(
        &self,
        action: impl AsRef<str>,
        request: Request,
    ) -> Result<Response>
    where
        P: BridgePlugin<Mode = MainThreadSyncBridge>,
        Request: BridgeNapiType,
        Response: BridgeNapiType,
    {
        self.client
            .call_sync_from_worker::<P, Request, Response>(action, request)
            .await
    }
}

fn validate_plugin_contract<P>() -> Result<()>
where
    P: BridgePlugin,
{
    validate_identifier("plugin id", P::ID)?;
    if P::VERSION == 0 {
        return Err(Error::from_reason(
            "Bridge plugin version must be greater than zero",
        ));
    }
    for (index, requirement) in P::REQUIRED_CONTEXTS.iter().enumerate() {
        if P::REQUIRED_CONTEXTS[..index].contains(requirement) {
            return Err(Error::from_reason(format!(
                "Bridge plugin '{}' declares a context requirement more than once",
                P::ID
            )));
        }
    }
    Ok(())
}

fn validate_wire_call(
    plugin_id: &str,
    plugin_version: u32,
    action: &str,
    request_type_name: &str,
    response_type_name: &str,
) -> Result<()> {
    validate_identifier("plugin id", plugin_id)?;
    validate_identifier("action", action)?;
    validate_identifier("request type", request_type_name)?;
    validate_identifier("response type", response_type_name)?;
    if plugin_version == 0 {
        return Err(Error::from_reason(
            "Bridge plugin version must be greater than zero",
        ));
    }
    Ok(())
}

fn validate_identifier(label: &str, value: &str) -> Result<()> {
    if value.is_empty()
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(Error::from_reason(format!(
            "Bridge {label} must contain only ASCII letters, digits, '.', '_' or '-'"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    };

    use super::{
        validate_identifier, validate_wire_call, AsyncBridge, BridgeCallOptions,
        BridgeContextRequirement, BridgeNapiType, BridgePlugin, BridgePluginRegistry,
        PluginLifecycleEvent, SyncFromWorkerRequest, MAX_TIMEOUT_MS,
    };

    struct TestPlugin;

    impl BridgePlugin for TestPlugin {
        type Mode = AsyncBridge;

        const ID: &'static str = "test.plugin";
    }

    struct StatefulPlugin {
        value: AtomicUsize,
    }

    impl BridgePlugin for StatefulPlugin {
        type Mode = AsyncBridge;

        const ID: &'static str = "test.stateful";
    }

    struct WrongStatefulPluginType;

    impl BridgePlugin for WrongStatefulPluginType {
        type Mode = AsyncBridge;

        const ID: &'static str = "test.stateful";
    }

    static UI_CONTEXT_LIFECYCLES: AtomicUsize = AtomicUsize::new(0);

    struct UiContextPlugin;

    impl BridgePlugin for UiContextPlugin {
        type Mode = AsyncBridge;

        const ID: &'static str = "test.ui-context";
        const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
            &[BridgeContextRequirement::UiContext];

        fn on_lifecycle(&self, _event: &PluginLifecycleEvent) -> Result<(), napi_ohos::Error> {
            UI_CONTEXT_LIFECYCLES.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    struct RecordingUiContextPlugin {
        events: Arc<Mutex<Vec<PluginLifecycleEvent>>>,
    }

    impl BridgePlugin for RecordingUiContextPlugin {
        type Mode = AsyncBridge;

        const ID: &'static str = "test.recording-ui-context";
        const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
            &[BridgeContextRequirement::UiContext];

        fn on_lifecycle(&self, event: &PluginLifecycleEvent) -> Result<(), napi_ohos::Error> {
            self.events.lock().unwrap().push(event.clone());
            Ok(())
        }
    }

    struct FailingLifecyclePlugin;

    impl BridgePlugin for FailingLifecyclePlugin {
        type Mode = AsyncBridge;

        const ID: &'static str = "test.a-failing-lifecycle";

        fn on_lifecycle(&self, _event: &PluginLifecycleEvent) -> Result<(), napi_ohos::Error> {
            Err(napi_ohos::Error::from_reason(
                "intentional lifecycle failure",
            ))
        }
    }

    struct HealthyLifecyclePlugin {
        deliveries: Arc<AtomicUsize>,
    }

    impl BridgePlugin for HealthyLifecyclePlugin {
        type Mode = AsyncBridge;

        const ID: &'static str = "test.z-healthy-lifecycle";

        fn on_lifecycle(&self, _event: &PluginLifecycleEvent) -> Result<(), napi_ohos::Error> {
            self.deliveries.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    #[test]
    fn accepts_versioned_plugin_identifiers() {
        assert!(validate_identifier("plugin id", "auth.login_v2").is_ok());
        assert!(validate_identifier("action", "publish-session").is_ok());
    }

    #[test]
    fn rejects_unroutable_identifiers() {
        assert!(validate_identifier("plugin id", "").is_err());
        assert!(validate_identifier("plugin id", "auth/login").is_err());
        assert!(validate_identifier("action", "login action").is_err());
    }

    #[test]
    fn named_napi_types_share_one_transport_contract() {
        assert_eq!(<String as BridgeNapiType>::TYPE_NAME, "std.string");
        assert_eq!(<Vec<u8> as BridgeNapiType>::TYPE_NAME, "std.bytes");
        assert!(validate_wire_call("test.plugin", 1, "echo", "std.string", "demo.Profile").is_ok());
    }

    #[test]
    fn sync_from_worker_payload_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<SyncFromWorkerRequest>();
    }

    #[test]
    fn clamps_bridge_timeout() {
        assert_eq!(
            BridgeCallOptions::default().with_timeout_ms(0).timeout_ms(),
            1
        );
        assert_eq!(
            BridgeCallOptions::default()
                .with_timeout_ms(MAX_TIMEOUT_MS + 1)
                .timeout_ms(),
            MAX_TIMEOUT_MS
        );
    }

    #[test]
    fn registry_rejects_duplicate_contracts() {
        let registry = BridgePluginRegistry::default();
        registry.register(TestPlugin).unwrap();
        assert_eq!(registry.len(), 1);
        assert!(registry.register(TestPlugin).is_err());
    }

    #[test]
    fn registry_returns_the_same_typed_plugin_instance() {
        let registry = BridgePluginRegistry::default();
        registry
            .register(StatefulPlugin {
                value: AtomicUsize::new(7),
            })
            .unwrap();

        let first = registry.registered::<StatefulPlugin>().unwrap().unwrap();
        let second = registry.registered::<StatefulPlugin>().unwrap().unwrap();
        assert!(Arc::ptr_eq(&first, &second));
        first.value.store(9, Ordering::SeqCst);
        assert_eq!(second.value.load(Ordering::SeqCst), 9);
        assert!(registry.registered::<WrongStatefulPluginType>().is_err());
    }

    #[test]
    fn registry_replays_lifecycle_only_after_required_context_is_ready() {
        UI_CONTEXT_LIFECYCLES.store(0, Ordering::SeqCst);
        let registry = BridgePluginRegistry::default();
        registry.register(UiContextPlugin).unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::AbilityCreated {
                restored_state: String::new(),
            })
            .unwrap();
        assert_eq!(UI_CONTEXT_LIFECYCLES.load(Ordering::SeqCst), 0);
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::UiContextReady)
            .unwrap();
        assert_eq!(UI_CONTEXT_LIFECYCLES.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn activated_plugin_receives_teardown_and_next_session_has_fresh_history() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let registry = BridgePluginRegistry::default();
        registry
            .register(RecordingUiContextPlugin {
                events: Arc::clone(&events),
            })
            .unwrap();

        registry
            .dispatch_lifecycle(PluginLifecycleEvent::AbilityCreated {
                restored_state: "first".to_owned(),
            })
            .unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::WindowStageCreated)
            .unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::UiContextReady)
            .unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::UiContextDestroyed)
            .unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::WindowStageDestroyed)
            .unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::AbilityDestroyed)
            .unwrap();

        assert_eq!(events.lock().unwrap().len(), 6);

        registry
            .dispatch_lifecycle(PluginLifecycleEvent::AbilityCreated {
                restored_state: "second".to_owned(),
            })
            .unwrap();
        assert_eq!(events.lock().unwrap().len(), 6);
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::UiContextReady)
            .unwrap();

        let events = events.lock().unwrap();
        assert_eq!(events.len(), 8);
        assert_eq!(
            events[6..],
            [
                PluginLifecycleEvent::AbilityCreated {
                    restored_state: "second".to_owned(),
                },
                PluginLifecycleEvent::UiContextReady,
            ]
        );
    }

    #[test]
    fn lifecycle_replay_keeps_session_anchors_during_transient_event_pressure() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let registry = BridgePluginRegistry::default();
        registry
            .register(RecordingUiContextPlugin {
                events: Arc::clone(&events),
            })
            .unwrap();

        registry
            .dispatch_lifecycle(PluginLifecycleEvent::AbilityCreated {
                restored_state: "anchor".to_owned(),
            })
            .unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::WindowStageCreated)
            .unwrap();
        for event_type in 0..32 {
            registry
                .dispatch_lifecycle(PluginLifecycleEvent::WindowStageEvent { event_type })
                .unwrap();
        }
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::UiContextReady)
            .unwrap();

        let events = events.lock().unwrap();
        assert!(matches!(
            events.first(),
            Some(PluginLifecycleEvent::AbilityCreated { restored_state }) if restored_state == "anchor"
        ));
        assert_eq!(
            events.get(1),
            Some(&PluginLifecycleEvent::WindowStageCreated)
        );
        assert_eq!(events.last(), Some(&PluginLifecycleEvent::UiContextReady));
    }

    #[test]
    fn lifecycle_replay_remains_bounded_during_context_recreation() {
        let registry = BridgePluginRegistry::default();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::AbilityCreated {
                restored_state: "bounded".to_owned(),
            })
            .unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::WindowStageCreated)
            .unwrap();
        for _ in 0..32 {
            registry
                .dispatch_lifecycle(PluginLifecycleEvent::UiContextReady)
                .unwrap();
            registry
                .dispatch_lifecycle(PluginLifecycleEvent::UiContextDestroyed)
                .unwrap();
        }
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::UiContextReady)
            .unwrap();

        let events = Arc::new(Mutex::new(Vec::new()));
        registry
            .register(RecordingUiContextPlugin {
                events: Arc::clone(&events),
            })
            .unwrap();

        let events = events.lock().unwrap();
        assert!(events.len() <= super::MAX_LIFECYCLE_HISTORY);
        assert!(matches!(
            events.first(),
            Some(PluginLifecycleEvent::AbilityCreated { restored_state }) if restored_state == "bounded"
        ));
        assert_eq!(events.last(), Some(&PluginLifecycleEvent::UiContextReady));
    }

    #[test]
    fn lifecycle_registry_ignores_events_after_ability_destroy() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let registry = BridgePluginRegistry::default();
        registry
            .register(RecordingUiContextPlugin {
                events: Arc::clone(&events),
            })
            .unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::AbilityCreated {
                restored_state: String::new(),
            })
            .unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::UiContextReady)
            .unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::AbilityDestroyed)
            .unwrap();
        let deliveries_after_destroy = events.lock().unwrap().len();

        registry
            .dispatch_lifecycle(PluginLifecycleEvent::WindowStageCreated)
            .unwrap();
        registry
            .dispatch_lifecycle(PluginLifecycleEvent::UiContextReady)
            .unwrap();
        assert_eq!(events.lock().unwrap().len(), deliveries_after_destroy);
    }

    #[test]
    fn lifecycle_failure_does_not_block_other_plugins() {
        let healthy_deliveries = Arc::new(AtomicUsize::new(0));
        let registry = BridgePluginRegistry::default();
        registry.register(FailingLifecyclePlugin).unwrap();
        registry
            .register(HealthyLifecyclePlugin {
                deliveries: Arc::clone(&healthy_deliveries),
            })
            .unwrap();

        assert!(registry
            .dispatch_lifecycle(PluginLifecycleEvent::AbilityCreated {
                restored_state: String::new(),
            })
            .is_err());
        assert_eq!(healthy_deliveries.load(Ordering::SeqCst), 1);
    }
}
