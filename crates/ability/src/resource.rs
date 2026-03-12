use std::{ops::Deref, sync::Arc};

use napi_ohos::{bindgen_prelude::Object, Env, Result};
use ohos_resource_manager_binding::ResourceManager as NativeResourceManager;
pub use ohos_resource_manager_binding::ScreenDensity as ResourceScreenDensity;
pub use ohos_resource_manager_binding::{IconType, RawDir, RawFile, RawFile64, RawFileError};

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

impl Deref for ResourceManager {
    type Target = NativeResourceManager;

    fn deref(&self) -> &Self::Target {
        self.inner()
    }
}
