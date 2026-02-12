use std::sync::{Arc, LazyLock, RwLock};

use napi_ohos::{
    bindgen_prelude::{Function, JsObjectValue, PromiseRaw, Unknown},
    threadsafe_function::ThreadsafeFunction,
    Either, Env, Error, Result, Status,
};

use crate::get_main_thread_env;

pub type PermissionRequestInput = Either<String, Vec<String>>;
pub type PermissionRequestOutput = Either<i32, Vec<i32>>;

type PermissionRequestCall<'a> = Function<'a, PermissionRequestInput, Unknown<'a>>;

type PermissionThreadsafeFunction = ThreadsafeFunction<
    PermissionRequestInput,
    Unknown<'static>,
    PermissionRequestInput,
    Status,
    false,
>;

type PermissionRequestTsfn = LazyLock<RwLock<Option<Arc<PermissionThreadsafeFunction>>>>;

pub(crate) static PERMISSION_REQUEST_TSFN: PermissionRequestTsfn =
    LazyLock::new(|| RwLock::new(None));

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PermissionRequest {
    Single(String),
    Multiple(Vec<String>),
}

impl PermissionRequest {
    pub fn permissions(&self) -> Vec<String> {
        match self {
            Self::Single(permission) => vec![permission.clone()],
            Self::Multiple(permissions) => permissions.clone(),
        }
    }

    pub fn into_input(self) -> PermissionRequestInput {
        match self {
            Self::Single(permission) => Either::A(permission),
            Self::Multiple(permissions) => Either::B(permissions),
        }
    }
}

impl From<String> for PermissionRequest {
    fn from(value: String) -> Self {
        Self::Single(value)
    }
}

impl From<&str> for PermissionRequest {
    fn from(value: &str) -> Self {
        Self::Single(value.to_string())
    }
}

impl From<Vec<String>> for PermissionRequest {
    fn from(value: Vec<String>) -> Self {
        Self::Multiple(value)
    }
}

impl From<Vec<&str>> for PermissionRequest {
    fn from(value: Vec<&str>) -> Self {
        Self::Multiple(value.into_iter().map(str::to_string).collect())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PermissionRequestCode {
    pub permission: String,
    pub code: i32,
}

/// Create permission request threadsafe function.
/// The callback proxies to ArkTS helper.requestPermission(permission) and returns its Promise object.
pub fn create_permission_request_tsfn(env: &Env) -> Result<Arc<PermissionThreadsafeFunction>> {
    let permission_request_callback: Function<'_, PermissionRequestInput, Unknown<'_>> = env
        .create_function_from_closure("permission_request_callback", move |ctx| {
            let permission = ctx.first_arg::<PermissionRequestInput>()?;

            if let Some(env_ref) = get_main_thread_env().borrow().as_ref() {
                let helper = unsafe { crate::get_helper() };
                let helper_borrow = helper.borrow();
                if let Some(helper_ref) = helper_borrow.as_ref() {
                    let helper_obj = helper_ref.get_value(env_ref)?;
                    let request_permission_fn = helper_obj
                        .get_named_property::<PermissionRequestCall<'_>>("requestPermission")?;
                    return request_permission_fn.call(permission);
                }
            }

            Err(Error::from_reason(
                "Failed to call helper.requestPermission from main thread",
            ))
        })?;

    let tsfn = permission_request_callback
        .build_threadsafe_function()
        .callee_handled::<false>()
        .build()?;

    let tsfn_arc = Arc::new(tsfn);

    {
        let mut guard = (*PERMISSION_REQUEST_TSFN)
            .write()
            .map_err(|_| Error::from_reason("Failed to write PERMISSION_REQUEST_TSFN"))?;
        guard.replace(tsfn_arc.clone());
    }

    Ok(tsfn_arc)
}

pub fn get_permission_request_tsfn() -> Option<Arc<PermissionThreadsafeFunction>> {
    (*PERMISSION_REQUEST_TSFN)
        .read()
        .ok()
        .and_then(|guard| guard.as_ref().map(Arc::clone))
}

pub fn unknown_to_permission_promise(
    value: Unknown<'static>,
) -> Result<PromiseRaw<'static, PermissionRequestOutput>> {
    // Safety: ArkTS helper.requestPermission always returns a Promise<number | number[]>.
    unsafe { value.cast::<PromiseRaw<'static, PermissionRequestOutput>>() }
}
