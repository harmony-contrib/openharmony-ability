use std::{
    ops::Deref,
    sync::{Arc, LazyLock, RwLock},
};

use napi_ohos::{bindgen_prelude::Object, Env, Result};
use ohos_resource_manager_binding::ResourceManager as NativeResourceManager;
pub use ohos_resource_manager_binding::ScreenDensity as ResourceScreenDensity;
pub use ohos_resource_manager_binding::{IconType, RawDir, RawFile, RawFile64, RawFileError};

type ResourceManagerState = LazyLock<RwLock<Option<ResourceManager>>>;

pub(crate) static RESOURCE_MANAGER: ResourceManagerState = LazyLock::new(|| RwLock::new(None));

#[derive(Clone)]
pub struct ResourceManager(Arc<NativeResourceManager>);

impl ResourceManager {
    pub fn new(env: Env, resource_manager: Object) -> Self {
        Self(Arc::new(NativeResourceManager::new(env, resource_manager)))
    }

    pub fn from_init_context(env: Env, context: Option<&Object<'_>>) -> Result<Option<Self>> {
        let Some(context) = context else {
            return Ok(None);
        };

        Ok(context
            .get::<Object>("resourceManager")?
            .map(|resource_manager| Self::new(env, resource_manager)))
    }

    pub fn inner(&self) -> &NativeResourceManager {
        self.0.as_ref()
    }
}

/// Get global resource manager
pub fn resource_manager() -> Option<ResourceManager> {
    RESOURCE_MANAGER
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().cloned())
}

#[doc(hidden)]
/// Set global resource manager
pub(crate) fn set_resource_manager(resource_manager: Option<ResourceManager>) {
    if let Ok(mut guard) = RESOURCE_MANAGER.write() {
        *guard = resource_manager;
    }
}

impl Deref for ResourceManager {
    type Target = NativeResourceManager;

    fn deref(&self) -> &Self::Target {
        self.inner()
    }
}
