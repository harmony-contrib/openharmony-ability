/*
 * ohos.permission plugin — permission request demo (OH_ABILITY_PLUGIN_PERMISSION, default ON).
 * Outbound-only: the ArkTS PermissionPlugin owns the platform permission flow; this facade
 * requests permissions through the bridge and resolves the codes array.
 */
#ifndef PLUGIN_PERMISSION_H
#define PLUGIN_PERMISSION_H

#include <napi/native_api.h>

/* demoRequestPermissionFromMainThread(): Promise<number[]> */
napi_value demo_request_permission(napi_env env, napi_callback_info info);

#endif /* PLUGIN_PERMISSION_H */
