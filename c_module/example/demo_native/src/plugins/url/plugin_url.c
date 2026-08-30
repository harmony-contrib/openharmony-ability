/*
 * ohos.url plugin (OH_ABILITY_PLUGIN_URL, default ON).
 *
 * Wire contract (verified against the ArkTS UrlPlugin):
 *   ohos.url "open-url" ohos.url.OpenRequest{url} -> ohos.url.OpenResponse
 */
#include <stdlib.h>

#include "demo_common.h"

#ifdef OH_ABILITY_PLUGIN_URL

static const OHAbility_Plugin URL_PLUGIN = {
    .execution = OH_ABILITY_PLUGIN_ASYNC,
    .required_contexts = OH_ABILITY_PLUGIN_CONTEXT_ABILITY,
};

int demo_register_url_plugin(void) {
    return OHAbility_RegisterPlugin("ohos.url", &URL_PLUGIN, NULL);
}

static int demo_build_url_request(napi_env env, napi_value *out, void *data) {
    (void)data;
    napi_value request;
    if (napi_create_object(env, &request) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    demo_object_string(env, request, "url", "https://www.openharmony.cn");
    *out = request;
    return OH_ABILITY_ERROR_OK;
}

static void demo_responder_void(napi_env env, int status, napi_value value, const char *error,
                                void *data) {
    DemoDeferred *ctx = (DemoDeferred *)data;
    (void)value;
    if (status != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(ctx, env, error != NULL ? error : "bridge call failed");
    } else {
        demo_deferred_resolve(ctx, env, NULL);
    }
    free(ctx);
}

/* demoOpenUrl(): Promise<void> — ohos.url openLink. */
napi_value demo_open_url(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    int rc =
        OHAbility_CallAsync("ohos.url", "open-url", "ohos.url.OpenRequest", "ohos.url.OpenResponse",
                            demo_build_url_request, NULL, demo_responder_void, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

#else /* !OH_ABILITY_PLUGIN_URL */

int demo_register_url_plugin(void) { return OH_ABILITY_ERROR_OK; }

napi_value demo_open_url(napi_env env, napi_callback_info info) {
    (void)info;
    return demo_disabled_promise(env, "ohos.url");
}

#endif /* OH_ABILITY_PLUGIN_URL */
