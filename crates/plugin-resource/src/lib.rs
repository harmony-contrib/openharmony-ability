//! Resource manager capability plugin facade.
//!
//! The ArkTS wrapper (`plugins/resource`) owns the HarmonyOS `resourceManager` platform object
//! and hands it to Rust through the inbound `resource-manager-ready` main-thread event. Rust
//! converts the object to a native `NativeResourceManager` pointer **inside the same N-API
//! callback** ([`ResourceManagerRef::from_bridge_value`]) and stores it globally; the ArkTS
//! object is never retained. Every subsequent read (raw files, media, drawables, strings) calls
//! the OpenHarmony C API directly through `ohos-resource-manager-binding` — no ArkTS round-trip
//! is involved.
//!
//! The wrapper pushes on the `ability-create` lifecycle event: the inbound event sink is
//! attached right after `module.init` in `NativeAbility.onCreate` (not at UI render time), so
//! plugins that only require `ability` can emit ArkTS → Rust events before rendering.

use std::{
    ops::Deref,
    sync::{Arc, LazyLock, RwLock},
};

use napi_derive_ohos::napi;
use napi_ohos::{bindgen_prelude::Unknown, Env, Error, JsValue, Result};
use ohos_resource_manager_binding::ResourceManager as NativeResourceManager;
use ohos_resource_manager_sys::OH_ResourceManager_InitNativeResourceManager;
use openharmony_ability::{
    impl_bridge_napi_type, AsyncBridge, BridgeContextRequirement, BridgeMainThreadEvent,
    BridgeNapiType, BridgePlugin, OpenHarmonyApp,
};

pub use ohos_resource_manager_binding::ScreenDensity as ResourceScreenDensity;
pub use ohos_resource_manager_binding::{IconType, RawDir, RawFile, RawFile64, RawFileError};

/// Inbound event name emitted by the ArkTS wrapper when the native module is rendered.
pub const RESOURCE_MANAGER_READY_EVENT: &str = "resource-manager-ready";

type ResourceManagerState = LazyLock<RwLock<Option<ResourceManager>>>;

static RESOURCE_MANAGER: ResourceManagerState = LazyLock::new(|| RwLock::new(None));

/// Cloneable handle to the HarmonyOS native resource manager installed by the `ohos.resource`
/// plugin. Read operations deref to `ohos_resource_manager_binding::ResourceManager`.
///
/// # Thread-safety contract
///
/// The underlying `NativeResourceManager` methods are **not thread-safe** (documented by
/// `ohos-resource-manager-binding`). The handle is cloneable across threads, but concurrent
/// reads from multiple threads must be serialized by the caller (for example through a
/// `Mutex<ResourceManager>`); this mirrors the pre-plugin global singleton semantics.
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

/// Returns the global resource manager installed by the `ohos.resource` plugin, if the ArkTS
/// wrapper has already pushed it on `ui-context-ready`.
pub fn resource_manager() -> Option<ResourceManager> {
    RESOURCE_MANAGER
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().cloned())
}

fn set_resource_manager(resource_manager: Option<ResourceManager>) {
    if let Ok(mut guard) = RESOURCE_MANAGER.write() {
        *guard = resource_manager;
    }
}

/// Rust facade receiving the ArkTS `resourceManager` object.
pub struct ResourceBridgePlugin;

impl BridgePlugin for ResourceBridgePlugin {
    type Mode = AsyncBridge;

    const ID: &'static str = "ohos.resource";
    const VERSION: u32 = 1;
    // The wrapper pushes the platform object on `ability-create`. The inbound event sink is
    // attached right after `module.init` in `NativeAbility.onCreate` and the Rust registry has
    // observed `AbilityCreated` before ArkTS emits `ability-create`, so the gate is satisfied.
    const REQUIRED_CONTEXTS: &'static [BridgeContextRequirement] =
        &[BridgeContextRequirement::Ability];

    fn on_main_thread_event<'env>(
        &self,
        event: BridgeMainThreadEvent<'env>,
    ) -> Result<Unknown<'env>> {
        match event.name() {
            RESOURCE_MANAGER_READY_EVENT => {
                let ready = event.decode::<ResourceManagerRef>()?;
                set_resource_manager(Some(ready.into_manager()));
                event.respond(ResourceManagerReadyResponse { accepted: true })
            }
            other => Err(Error::from_reason(format!(
                "Unsupported ohos.resource main-thread event '{other}'"
            ))),
        }
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

/// Extension trait exposing the global resource manager on `OpenHarmonyApp`.
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
        resource_manager()
    }
}

#[cfg(test)]
mod tests {
    use super::{ResourceManagerReadyResponse, ResourceManagerRef, RESOURCE_MANAGER_READY_EVENT};
    use openharmony_ability::BridgeNapiType;

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
        assert!(super::resource_manager().is_none());
    }
}
