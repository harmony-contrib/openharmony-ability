/*
 * ohos.resource plugin (OH_ABILITY_PLUGIN_RESOURCE, default ON).
 *
 * Inbound: the ArkTS ResourcePlugin pushes the resourceManager object on ability-create via
 * invokeNativeSync("resource-manager-ready", ...); this C plugin converts it to a native
 * NativeResourceManager inside the same N-API callback and answers with {accepted: true}.
 * Outbound: the resource demo exports read through the native manager (rawfile C API).
 */
#ifndef PLUGIN_RESOURCE_H
#define PLUGIN_RESOURCE_H

#include <napi/native_api.h>

/* Registers the ohos.resource inbound plugin (returns OK when disabled). */
int demo_register_resource_plugin(void);

/* demoResourceManagerReady(): boolean */
napi_value demo_resource_manager_ready(napi_env env, napi_callback_info info);

/* demoResourceRawDirCount(): number */
napi_value demo_resource_raw_dir_count(napi_env env, napi_callback_info info);

#endif /* PLUGIN_RESOURCE_H */
