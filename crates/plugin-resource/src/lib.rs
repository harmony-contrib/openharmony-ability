//! Resource manager capability plugin facade.
//!
//! The ArkTS wrapper (`plugins/resource`) owns the HarmonyOS `resourceManager` platform object
//! and hands it to Rust through the inbound `resource-manager-ready` main-thread event. Rust
//! converts the object to a native `NativeResourceManager` pointer **inside the same N-API
//! callback** ([`ResourceManagerRef::from_bridge_value`]) and stores it in the registered Rust
//! plugin instance; the ArkTS object is never retained. Every subsequent read
//! calls the OpenHarmony C API directly through `ohos-resource-manager-binding`.
//!
//! The wrapper pushes from its Ability-scoped `onInstall` hook. It does not depend on a
//! WindowStage or DefaultXComponent.

use std::{
    ops::Deref,
    sync::{Arc, RwLock},
};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Env, Error, JsValue, Result};
use ohos_resource_manager_binding::ResourceManager as NativeResourceManager;
use ohos_resource_manager_sys::OH_ResourceManager_InitNativeResourceManager;
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeContextRequirement, BridgeMainThreadEvent,
    BridgeNapiType, BridgePlugin, OpenHarmonyApp, PluginLifecycleEvent,
};

pub use ohos_resource_manager_binding::ScreenDensity as ResourceScreenDensity;
pub use ohos_resource_manager_binding::{IconType, RawDir, RawFile, RawFile64, RawFileError};

/// Inbound event name emitted when the Ability-scoped ArkTS wrapper is installed.
pub const RESOURCE_MANAGER_READY_EVENT: &str = "resource-manager-ready";

/// Cloneable handle to the HarmonyOS native resource manager installed by the `ohos.resource`
/// plugin. Read operations deref to `ohos_resource_manager_binding::ResourceManager`.
///
/// # Thread-safety contract
///
/// The underlying `NativeResourceManager` methods are **not thread-safe** (documented by
/// `ohos-resource-manager-binding`). The handle is cloneable across threads, but concurrent
/// reads from multiple threads must be serialized by the caller (for example through a
/// `Mutex<ResourceManager>`).
#[derive(Clone)]
pub struct ResourceManager(Arc<NativeResourceManager>);

impl ResourceManager {
    fn from_native(native: NativeResourceManager) -> Self {
        Self(Arc::new(native))
    }

    pub fn inner(&self) -> &NativeResourceManager {
        self.0.as_ref()
    }
}

impl Deref for ResourceManager {
    type Target = NativeResourceManager;

    fn deref(&self) -> &Self::Target {
        self.inner()
    }
}

/// Rust facade receiving and owning the native resource manager for one plugin registry.
#[derive(Default)]
pub struct ResourceBridgePlugin {
    resource_manager: RwLock<Option<ResourceManager>>,
}

impl ResourceBridgePlugin {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn resource_manager(&self) -> Option<ResourceManager> {
        self.resource_manager
            .read()
            .ok()
            .and_then(|guard| guard.as_ref().cloned())
    }

    fn replace_resource_manager(&self, resource_manager: Option<ResourceManager>) -> Result<()> {
        let mut state = self
            .resource_manager
            .write()
            .map_err(|_| Error::from_reason("Failed to update native resource manager"))?;
        *state = resource_manager;
        Ok(())
    }
}

impl BridgePlugin for ResourceBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.resource";
    // The wrapper pushes during its Ability-scoped onInstall hook, before any component is needed.
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        match event.name() {
            RESOURCE_MANAGER_READY_EVENT => {
                let ready = event.decode::<ResourceManagerRef>()?;
                self.replace_resource_manager(Some(ready.into_manager()))?;
                event.respond(ResourceManagerReadyResponse { accepted: true })
            }
            other => Err(Error::from_reason(format!(
                "Unsupported ohos.resource main-thread event '{other}'"
            ))),
        }
    }

    fn on_lifecycle(&self, event: &PluginLifecycleEvent) -> Result<()> {
        if matches!(
            event,
            PluginLifecycleEvent::AbilityCreated { .. } | PluginLifecycleEvent::AbilityDestroyed
        ) {
            self.replace_resource_manager(None)?;
        }
        Ok(())
    }
}

/// Inbound wire marker for the ArkTS `resourceManager` object.
///
/// The type never stores a JS reference: decoding converts the N-API value to a native pointer
/// while the originating callback is still active, then drops the `Unknown`.
pub struct ResourceManagerRef(ResourceManager);

impl ResourceManagerRef {
    pub fn into_manager(self) -> ResourceManager {
        self.0
    }
}

impl BridgeNapiType for ResourceManagerRef {
    const TYPE_NAME: &'static str = "ohos.resource.ResourceManagerRef";

    fn into_bridge_value<'env>(self, _env: &'env Env) -> Result<Unknown<'env>> {
        Err(Error::from_reason(
            "ohos.resource.ResourceManagerRef is inbound-only; the ArkTS wrapper owns the object",
        ))
    }

    fn from_bridge_value(value: Unknown<'_>) -> Result<Self> {
        let raw = value.value();
        let native = unsafe { OH_ResourceManager_InitNativeResourceManager(raw.env, raw.value) };
        if native.is_null() {
            return Err(Error::from_reason(
                "Failed to initialize the native resource manager from the ArkTS object",
            ));
        }
        Ok(Self(ResourceManager::from_native(
            NativeResourceManager::from_raw(native),
        )))
    }
}

#[napi(object)]
#[derive(Clone, Debug)]
pub struct ResourceManagerReadyResponse {
    pub accepted: bool,
}

impl_bridge_napi_type!(
    ResourceManagerReadyResponse,
    "ohos.resource.ResourceManagerReadyResponse"
);

/// Extension trait exposing the current bridge registry's resource manager.
///
/// ```no_run
/// use openharmony_ability::OpenHarmonyApp;
/// use openharmony_ability_plugin_resource::ResourceExt;
///
/// fn demo(app: &OpenHarmonyApp) {
///     if let Some(manager) = app.resource_manager() {
///         // manager.open_dir("") ...
///     }
/// }
/// ```
pub trait ResourceExt {
    fn resource_manager(&self) -> Option<ResourceManager>;
}

impl ResourceExt for OpenHarmonyApp {
    fn resource_manager(&self) -> Option<ResourceManager> {
        self.registered_plugin::<ResourceBridgePlugin>()
            .ok()
            .flatten()
            .and_then(|plugin| plugin.resource_manager())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ResourceBridgePlugin, ResourceExt, ResourceManagerReadyResponse, ResourceManagerRef,
        RESOURCE_MANAGER_READY_EVENT,
    };
    use openharmony_ability::{BridgeNapiType, OpenHarmonyApp};

    #[test]
    fn resource_uses_stable_named_napi_contracts() {
        assert_eq!(
            <ResourceManagerRef as BridgeNapiType>::TYPE_NAME,
            "ohos.resource.ResourceManagerRef"
        );
        assert_eq!(
            <ResourceManagerReadyResponse as BridgeNapiType>::TYPE_NAME,
            "ohos.resource.ResourceManagerReadyResponse"
        );
        assert_eq!(RESOURCE_MANAGER_READY_EVENT, "resource-manager-ready");
        assert!(ResourceManagerReadyResponse { accepted: true }.accepted);
    }

    #[test]
    fn resource_manager_is_unset_before_the_wrapper_pushes() {
        let app = OpenHarmonyApp::new();
        app.register_plugin(ResourceBridgePlugin::new()).unwrap();
        assert!(app.resource_manager().is_none());
        assert!(app
            .registered_plugin::<ResourceBridgePlugin>()
            .unwrap()
            .is_some());
    }
}
