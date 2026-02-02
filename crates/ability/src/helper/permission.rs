use std::sync::{Arc, LazyLock, RwLock};

use napi_ohos::{
    bindgen_prelude::Function, threadsafe_function::ThreadsafeFunction, Env, Result, Status,
};

use crate::get_main_thread_env;

type PermissionRequestTsfn =
    LazyLock<RwLock<Option<Arc<ThreadsafeFunction<String, (), String, Status, false>>>>>;

pub(crate) static PERMISSION_REQUEST_TSFN: PermissionRequestTsfn =
    LazyLock::new(|| RwLock::new(None));

/// Create permission request threadsafe function
/// This function creates a threadsafe function that can be called from C layer
/// to request permissions from ArkTS layer
pub fn create_permission_request_tsfn(
    env: &Env,
) -> Result<Arc<ThreadsafeFunction<String, (), String, Status, false>>> {
    // Create a function that will be called from ArkTS when permission is requested
    let permission_request_callback: Function<'_, String, ()> =
        env.create_function_from_closure("permission_request_callback", move |ctx| {
            let permission = ctx.first_arg::<String>()?;

            // Get the helper object from thread-local storage
            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                if let Some(helper_ref) = helper.borrow().as_ref() {
                    if let Ok(helper_value) = helper_ref.get_value(env_ref) {
                        if let Ok(request_permission_fn) = helper_value
                            .get_named_property::<Function<'_, String, ()>>("requestPermission")
                        {
                            // Call the ArkTS requestPermission function
                            if let Err(e) = request_permission_fn.call(permission.clone()) {
                                eprintln!("Failed to call requestPermission: {:?}", e);
                            }
                        }
                    }
                }
            }

            Ok(())
        })?;

    let tsfn = permission_request_callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);

    {
        let mut guard = (*PERMISSION_REQUEST_TSFN).write().map_err(|_| {
            napi_ohos::Error::from_reason("Failed to write PERMISSION_REQUEST_TSFN")
        })?;
        guard.replace(tsfn_arc.clone());
    }

    Ok(tsfn_arc)
}

/// Get the permission request threadsafe function
/// This can be called from C layer to get the threadsafe function
pub fn get_permission_request_tsfn(
) -> Option<Arc<ThreadsafeFunction<String, (), String, Status, false>>> {
    (*PERMISSION_REQUEST_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}
