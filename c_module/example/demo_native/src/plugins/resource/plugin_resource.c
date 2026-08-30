/*
 * ohos.resource plugin (OH_ABILITY_PLUGIN_RESOURCE, default ON).
 *
 * Wire contract (verified against the ArkTS ResourcePlugin):
 *   inbound event "resource-manager-ready" (ohos.resource.ResourceManagerRef, the
 *   resourceManager object) -> ohos.resource.ResourceManagerReadyResponse{accepted}
 *
 * The native resource manager is Ability/session-scoped. The conversion must happen inside the
 * same N-API callback and the C plugin releases its native handle at session boundaries.
 */
#include <stdlib.h>
#include <string.h>

#include <hilog/log.h>

#include "demo_common.h"

#define DEMO_TAG "ohosCDemo"
#define DEMO_LOG(level, fmt, ...)                                                                  \
    OH_LOG_Print(LOG_APP, (level), 0xD002701, DEMO_TAG, fmt, ##__VA_ARGS__)

#ifdef OH_ABILITY_PLUGIN_RESOURCE

static NativeResourceManager *g_pushed_resource_manager;

static int demo_resource_sync_event(napi_env env, const char *event, const char *request_type,
                                    napi_value value, const char *response_type,
                                    napi_value *out_response, void *userdata) {
    (void)userdata;

    if (strcmp(event, "resource-manager-ready") != 0) {
        return OH_ABILITY_ERROR_NOT_FOUND;
    }
    if (strcmp(request_type, "ohos.resource.ResourceManagerRef") != 0 ||
        strcmp(response_type, "ohos.resource.ResourceManagerReadyResponse") != 0) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }

    NativeResourceManager *manager = OH_ResourceManager_InitNativeResourceManager(env, value);
    if (manager == NULL) {
        DEMO_LOG(LOG_ERROR, "ohos.resource: failed to convert the resource manager");
        return OH_ABILITY_ERROR_BRIDGE;
    }
    if (g_pushed_resource_manager != NULL) {
        OH_ResourceManager_ReleaseNativeResourceManager(g_pushed_resource_manager);
    }
    g_pushed_resource_manager = manager;

    /* Response type ohos.resource.ResourceManagerReadyResponse: { accepted: true }. */
    napi_value response;
    napi_create_object(env, &response);
    demo_object_bool(env, response, "accepted", true);
    *out_response = response;
    DEMO_LOG(LOG_INFO, "ohos.resource: resource manager installed from ArkTS push");
    return OH_ABILITY_ERROR_OK;
}

static void demo_resource_lifecycle(const OHAbility_LifecycleEvent *event, void *userdata) {
    (void)userdata;
    if (strcmp(event->kind, "ability-create") != 0 && strcmp(event->kind, "ability-destroy") != 0) {
        return;
    }
    if (g_pushed_resource_manager != NULL) {
        OH_ResourceManager_ReleaseNativeResourceManager(g_pushed_resource_manager);
        g_pushed_resource_manager = NULL;
    }
}

static const OHAbility_Plugin RESOURCE_PLUGIN = {
    .execution = OH_ABILITY_PLUGIN_ASYNC,
    .required_contexts = OH_ABILITY_PLUGIN_CONTEXT_ABILITY,
    .on_sync_event = demo_resource_sync_event,
    .on_lifecycle = demo_resource_lifecycle,
};

int demo_register_resource_plugin(void) {
    return OHAbility_RegisterPlugin("ohos.resource", &RESOURCE_PLUGIN, NULL);
}

/* demoResourceManagerReady(): boolean — a native resource manager is available. */
napi_value demo_resource_manager_ready(napi_env env, napi_callback_info info) {
    (void)info;
    bool ready = g_pushed_resource_manager != NULL;
    napi_value result;
    napi_get_boolean(env, ready, &result);
    return result;
}

/* demoResourceRawDirCount(): number — raw file entries at the top level, or -1 when absent. */
napi_value demo_resource_raw_dir_count(napi_env env, napi_callback_info info) {
    (void)info;
    int32_t count = -1;
    NativeResourceManager *manager = g_pushed_resource_manager;
    if (manager != NULL) {
        RawDir *dir = OH_ResourceManager_OpenRawDir(manager, "");
        if (dir != NULL) {
            count = OH_ResourceManager_GetRawFileCount(dir);
            OH_ResourceManager_CloseRawDir(dir);
        }
    }
    napi_value result;
    napi_create_int32(env, count, &result);
    return result;
}

#else /* !OH_ABILITY_PLUGIN_RESOURCE */

int demo_register_resource_plugin(void) { return OH_ABILITY_ERROR_OK; }

napi_value demo_resource_manager_ready(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result;
    napi_get_boolean(env, false, &result);
    return result;
}

napi_value demo_resource_raw_dir_count(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

#endif /* OH_ABILITY_PLUGIN_RESOURCE */
