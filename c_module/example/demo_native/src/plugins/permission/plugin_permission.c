/*
 * ohos.permission plugin (OH_ABILITY_PLUGIN_PERMISSION, default ON).
 *
 * Wire contract (verified against the ArkTS PermissionPlugin):
 *   ohos.permission "request" ohos.permission.PermissionRequestPayload{permissions} ->
 *                             ohos.permission.PermissionResponsePayload{codes}
 */
#include <stdlib.h>

#include "demo_common.h"

#ifdef OH_ABILITY_PLUGIN_PERMISSION

static int demo_build_permission_request(napi_env env, napi_value *out, void *data) {
    (void)data;
    static const char *const permissions[] = {"ohos.permission.MICROPHONE"};
    napi_value request;
    if (napi_create_object(env, &request) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    napi_value array;
    if (demo_build_string_array(env, &array, permissions, 1) != OH_ABILITY_ERROR_OK) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    napi_set_named_property(env, request, "permissions", array);
    *out = request;
    return OH_ABILITY_ERROR_OK;
}

static void demo_responder_codes(napi_env env, int status, napi_value value, const char *error,
                                 void *data) {
    DemoDeferred *ctx = (DemoDeferred *)data;
    if (status != OH_ABILITY_ERROR_OK || value == NULL) {
        demo_deferred_reject(ctx, env, error != NULL ? error : "permission request failed");
        free(ctx);
        return;
    }
    napi_value codes;
    if (napi_get_named_property(env, value, "codes", &codes) != napi_ok) {
        demo_deferred_reject(ctx, env, "permission response has no codes");
        free(ctx);
        return;
    }
    demo_deferred_resolve(ctx, env, codes);
    free(ctx);
}

/* demoRequestPermissionFromMainThread(): Promise<number[]> — ohos.permission via the bridge. */
napi_value demo_request_permission(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    int rc = OHAbility_CallAsync(
        "ohos.permission", 1, "request", "ohos.permission.PermissionRequestPayload",
        "ohos.permission.PermissionResponsePayload", demo_build_permission_request, NULL,
        demo_responder_codes, ctx, 60000);
    if (rc != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

#else /* !OH_ABILITY_PLUGIN_PERMISSION */

napi_value demo_request_permission(napi_env env, napi_callback_info info) {
    (void)info;
    return demo_disabled_promise(env, "ohos.permission");
}

#endif /* OH_ABILITY_PLUGIN_PERMISSION */
