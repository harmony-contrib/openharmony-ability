/*
 * Demo export table. The demo.* exports (login / raw / main-thread) live here because they are
 * demo-specific ArkTS plugins of the entry module; the official ohos.* plugin exports come from
 * the per-plugin directories under src/plugins/ (each gated by its own OH_ABILITY_PLUGIN_* macro,
 * with explicit-error stubs when disabled).
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <hilog/log.h>

#include "demo_common.h"
#include "plugin_app_control.h"
#include "plugin_files.h"
#include "plugin_permission.h"
#include "plugin_resource.h"
#include "plugin_url.h"
#include "plugin_webview.h"
#include "plugin_window.h"

#define DEMO_TAG "ohosCDemo"
#define DEMO_LOG(level, fmt, ...)                                                                  \
    OH_LOG_Print(LOG_APP, (level), 0xD002701, DEMO_TAG, fmt, ##__VA_ARGS__)

/* ------------------------------------------------------------------ */
/* Responder helper                                                    */
/* ------------------------------------------------------------------ */

/* Resolves the export promise with a plain string value. */
static void demo_responder_string(napi_env env, int status, napi_value value, const char *error,
                                  void *data) {
    DemoDeferred *ctx = (DemoDeferred *)data;
    if (status != OH_ABILITY_ERROR_OK || value == NULL) {
        demo_deferred_reject(ctx, env, error != NULL ? error : "bridge call failed");
        free(ctx);
        return;
    }
    demo_deferred_resolve(ctx, env, value);
    free(ctx);
}

/* ------------------------------------------------------------------ */
/* Request builders (run on the ArkTS main thread inside call-js)     */
/* ------------------------------------------------------------------ */

static int demo_build_string(napi_env env, napi_value *out, void *data) {
    return napi_create_string_utf8(env, (const char *)data, NAPI_AUTO_LENGTH, out) == napi_ok
               ? OH_ABILITY_ERROR_OK
               : OH_ABILITY_ERROR_BRIDGE;
}

static int demo_build_bytes(napi_env env, napi_value *out, void *data) {
    (void)data;
    const uint8_t bytes[4] = {1, 2, 3, 4};
    napi_value buffer;
    void *data_ptr = NULL;
    if (napi_create_arraybuffer(env, sizeof(bytes), &data_ptr, &buffer) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    memcpy(data_ptr, bytes, sizeof(bytes));
    napi_value typed;
    if (napi_create_typedarray(env, napi_uint8_array, sizeof(bytes), buffer, 0, &typed) !=
        napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    *out = typed;
    return OH_ABILITY_ERROR_OK;
}

static int demo_build_profile(napi_env env, napi_value *out, void *data) {
    (void)data;
    napi_value profile;
    if (napi_create_object(env, &profile) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    demo_object_string(env, profile, "userId", "demo-user-1001");
    demo_object_int32(env, profile, "visitCount", 41);
    *out = profile;
    return OH_ABILITY_ERROR_OK;
}

static int demo_build_login_request(napi_env env, napi_value *out, void *data) {
    (void)data;
    static const char *const scopes[] = {"profile", "email"};
    napi_value request;
    if (napi_create_object(env, &request) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    demo_object_string(env, request, "provider", "demo");
    napi_value array;
    if (demo_build_string_array(env, &array, scopes, 2) != OH_ABILITY_ERROR_OK) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    napi_set_named_property(env, request, "scopes", array);
    *out = request;
    return OH_ABILITY_ERROR_OK;
}

/* C copy of the authorize response, used to build the publish request. It is a single
 * allocation: the framework owns builder_data and releases it with plain free(). */
typedef struct DemoLoginData {
    char user_id[128];
    char display_name[128];
    char access_token[128];
    int64_t expires_at_ms;
} DemoLoginData;

/* Rebuilds a demo.login.LoginResponse object from the authorize response; used as the publish
 * request. */
static int demo_build_publish_request(napi_env env, napi_value *out, void *data) {
    DemoLoginData *login = (DemoLoginData *)data;
    napi_value request;
    if (napi_create_object(env, &request) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    demo_object_string(env, request, "userId", login->user_id);
    demo_object_string(env, request, "displayName", login->display_name);
    demo_object_string(env, request, "accessToken", login->access_token);
    demo_object_int32(env, request, "expiresAtMs", (int32_t)login->expires_at_ms);
    *out = request;
    return OH_ABILITY_ERROR_OK;
}

static void demo_login_data_fill(DemoLoginData *login, napi_env env, napi_value response) {
    memset(login, 0, sizeof(*login));
    char *user_id = demo_object_get_string(env, response, "userId");
    char *display_name = demo_object_get_string(env, response, "displayName");
    char *access_token = demo_object_get_string(env, response, "accessToken");
    if (user_id != NULL) {
        snprintf(login->user_id, sizeof(login->user_id), "%s", user_id);
    }
    if (display_name != NULL) {
        snprintf(login->display_name, sizeof(login->display_name), "%s", display_name);
    }
    if (access_token != NULL) {
        snprintf(login->access_token, sizeof(login->access_token), "%s", access_token);
    }
    napi_value expires;
    if (napi_get_named_property(env, response, "expiresAtMs", &expires) == napi_ok) {
        napi_get_value_int64(env, expires, &login->expires_at_ms);
    }
    free(user_id);
    free(display_name);
    free(access_token);
}

static int demo_build_inspect_request(napi_env env, napi_value *out, void *data) {
    (void)data;
    napi_value request;
    if (napi_create_object(env, &request) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    demo_object_bool(env, request, "requested", true);
    *out = request;
    return OH_ABILITY_ERROR_OK;
}

/* ------------------------------------------------------------------ */
/* Response formatting (parity with the Rust demo)                    */
/* ------------------------------------------------------------------ */

static napi_value demo_format_inspect(napi_env env, napi_value response, const char *prefix) {
    char *session = demo_object_get_string(env, response, "sessionId");
    napi_value ready_value;
    napi_get_named_property(env, response, "uiContextReady", &ready_value);
    bool ready = false;
    napi_get_value_bool(env, ready_value, &ready);
    char *execution = demo_object_get_string(env, response, "execution");

    char buffer[256];
    snprintf(buffer, sizeof(buffer), "%ssession=%s, uiContextReady=%s, execution=%s", prefix,
             session != NULL ? session : "", ready ? "true" : "false",
             execution != NULL ? execution : "");
    free(session);
    free(execution);

    napi_value result;
    napi_create_string_utf8(env, buffer, NAPI_AUTO_LENGTH, &result);
    return result;
}

/* ------------------------------------------------------------------ */
/* demo.raw exports                                                    */
/* ------------------------------------------------------------------ */

/* demoPluginString(): Promise<string> — std.string echo through demo.raw. */
static napi_value demo_plugin_string(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    char *message = strdup("hello from C");
    if (message == NULL) {
        demo_deferred_reject(ctx, env, "demo.raw: out of memory");
        free(ctx);
        return promise;
    }
    int rc = OHAbility_CallAsync("demo.raw", "echo-string", "std.string", "std.string",
                                 demo_build_string, message, demo_responder_string, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        free(message);
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

/* demoPluginBytes(): Promise<number[]> — Uint8Array through demo.raw. */
static napi_value demo_plugin_bytes(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    int rc = OHAbility_CallAsync("demo.raw", "reverse-bytes", "std.bytes", "std.bytes",
                                 demo_build_bytes, NULL, demo_responder_string, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

/* demoPluginProfile(): Promise<DemoProfile> — typed object round-trip. */
static napi_value demo_plugin_profile(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    int rc = OHAbility_CallAsync("demo.raw", "bump-profile", "demo.Profile", "demo.Profile",
                                 demo_build_profile, NULL, demo_responder_string, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

/* ------------------------------------------------------------------ */
/* demo.login exports                                                  */
/* ------------------------------------------------------------------ */

/* Final publish responder: resolves with the access token captured from the authorize step. */
typedef struct DemoLoginPublishContext {
    DemoDeferred deferred;
    char *access_token;
} DemoLoginPublishContext;

static void demo_login_publish_responder(napi_env env, int status, napi_value value,
                                         const char *error, void *data) {
    DemoLoginPublishContext *ctx = (DemoLoginPublishContext *)data;
    (void)value;
    if (status != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(&ctx->deferred, env, error != NULL ? error : "login publish failed");
    } else {
        napi_value result;
        napi_create_string_utf8(env, ctx->access_token != NULL ? ctx->access_token : "",
                                NAPI_AUTO_LENGTH, &result);
        demo_deferred_resolve(&ctx->deferred, env, result);
    }
    free(ctx->access_token);
    free(ctx);
}

/* authorize responder: extracts the response into C data and chains the publish call. */
static void demo_login_authorize_responder(napi_env env, int status, napi_value value,
                                           const char *error, void *data) {
    DemoDeferred *ctx = (DemoDeferred *)data;
    if (status != OH_ABILITY_ERROR_OK || value == NULL) {
        demo_deferred_reject(ctx, env, error != NULL ? error : "login authorize failed");
        free(ctx);
        return;
    }

    DemoLoginData *login = (DemoLoginData *)calloc(1, sizeof(*login));
    DemoLoginPublishContext *publish_ctx =
        (DemoLoginPublishContext *)calloc(1, sizeof(*publish_ctx));
    if (login == NULL || publish_ctx == NULL) {
        free(login);
        free(publish_ctx);
        demo_deferred_reject(ctx, env, "login: out of memory");
        free(ctx);
        return;
    }
    demo_login_data_fill(login, env, value);
    publish_ctx->deferred = *ctx; /* copy the deferred; ctx is released below */
    publish_ctx->access_token = strdup(login->access_token);
    free(ctx);

    int rc = OHAbility_CallAsync("demo.login", "publish", "demo.login.LoginResponse",
                                 "demo.login.LoginPublishResponse", demo_build_publish_request,
                                 login, demo_login_publish_responder, publish_ctx, 10000);
    if (rc != OH_ABILITY_ERROR_OK) {
        free(login);
        demo_deferred_reject(&publish_ctx->deferred, env, "bridge not ready");
        free(publish_ctx->access_token);
        free(publish_ctx);
    }
}

/* demoPluginLogin(): Promise<string> — authorize -> publish chain, returns the access token. */
static napi_value demo_plugin_login(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    int rc = OHAbility_CallAsync("demo.login", "authorize", "demo.login.LoginRequest",
                                 "demo.login.LoginResponse", demo_build_login_request, NULL,
                                 demo_login_authorize_responder, ctx, 10000);
    if (rc != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

/* ------------------------------------------------------------------ */
/* demo.main-thread exports                                            */
/* ------------------------------------------------------------------ */

/* demoPluginSyncContext(): string — synchronous main-thread plugin call. */
static napi_value demo_plugin_sync_context(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value request;
    napi_create_object(env, &request);
    demo_object_bool(env, request, "requested", true);
    napi_value response =
        OHAbility_CallSync(env, "demo.main-thread", "inspect", "demo.main-thread.InspectRequest",
                           "demo.main-thread.InspectResponse", request);
    if (response == NULL) {
        return NULL; /* the thrown exception propagates to ArkTS */
    }
    return demo_format_inspect(env, response, "");
}

/* Worker thread for demoPluginSyncFromWorker. */
typedef struct DemoSyncWorkerContext {
    DemoDeferred deferred;
} DemoSyncWorkerContext;

static void demo_responder_inspect_resolve(napi_env env, int status, napi_value value,
                                           const char *error, void *data) {
    DemoSyncWorkerContext *ctx = (DemoSyncWorkerContext *)data;
    if (status != OH_ABILITY_ERROR_OK || value == NULL) {
        demo_deferred_reject(&ctx->deferred, env,
                             error != NULL ? error : "sync-from-worker failed");
        return;
    }
    napi_value formatted = demo_format_inspect(env, value, "worker => ");
    demo_deferred_resolve(&ctx->deferred, env, formatted);
}

static void *demo_sync_worker_main(void *arg) {
    DemoSyncWorkerContext *ctx = (DemoSyncWorkerContext *)arg;
    int rc = OHAbility_CallSyncFromWorker(
        "demo.main-thread", "inspect", "demo.main-thread.InspectRequest",
        "demo.main-thread.InspectResponse", demo_build_inspect_request, NULL,
        demo_responder_inspect_resolve, ctx);
    if (rc != OH_ABILITY_ERROR_OK) {
        DEMO_LOG(LOG_WARN, "sync-from-worker failed: %d", rc);
    }
    free(ctx);
    return NULL;
}

/* demoPluginSyncFromWorker(): Promise<string> — worker -> TSFN -> main-thread sync plugin. */
static napi_value demo_plugin_sync_from_worker(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoSyncWorkerContext *ctx = (DemoSyncWorkerContext *)malloc(sizeof(*ctx));
    if (ctx == NULL) {
        return NULL;
    }
    if (napi_create_promise(env, &ctx->deferred.deferred, &promise) != napi_ok) {
        free(ctx);
        return NULL;
    }
    ctx->deferred.env = env;

    pthread_t thread;
    if (pthread_create(&thread, NULL, demo_sync_worker_main, ctx) != 0) {
        free(ctx);
        return NULL;
    }
    pthread_detach(thread);
    return promise;
}

/* ------------------------------------------------------------------ */
/* Back press                                                          */
/* ------------------------------------------------------------------ */

/* toggleBackPressIntercept(): boolean */
static napi_value demo_toggle_back_press(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result;
    napi_get_boolean(env, demo_toggle_back_press_intercept() != 0, &result);
    return result;
}

/* ------------------------------------------------------------------ */
/* Export table                                                        */
/* ------------------------------------------------------------------ */

int demo_register_bridge_plugins(void) {
    static const OHAbility_Plugin RAW_PLUGIN = {
        .execution = OH_ABILITY_PLUGIN_ASYNC,
        .required_contexts = OH_ABILITY_PLUGIN_CONTEXT_ABILITY,
    };
    static const OHAbility_Plugin LOGIN_PLUGIN = {
        .execution = OH_ABILITY_PLUGIN_ASYNC,
        .required_contexts = OH_ABILITY_PLUGIN_CONTEXT_UI,
    };
    static const OHAbility_Plugin MAIN_THREAD_PLUGIN = {
        .execution = OH_ABILITY_PLUGIN_SYNC_MAIN_THREAD,
        .required_contexts = OH_ABILITY_PLUGIN_CONTEXT_UI,
    };
    int rc = OHAbility_RegisterPlugin("demo.raw", &RAW_PLUGIN, NULL);
    if (rc != OH_ABILITY_ERROR_OK) {
        return rc;
    }
    rc = OHAbility_RegisterPlugin("demo.login", &LOGIN_PLUGIN, NULL);
    if (rc != OH_ABILITY_ERROR_OK) {
        return rc;
    }
    return OHAbility_RegisterPlugin("demo.main-thread", &MAIN_THREAD_PLUGIN, NULL);
}

int demo_register_exported_functions(napi_env env, napi_value exports) {
    static const napi_property_descriptor EXPORTS[] = {
        /* demo.* (entry-module plugins) */
        {"demoPluginString", NULL, demo_plugin_string, NULL, NULL, NULL, napi_default, NULL},
        {"demoPluginBytes", NULL, demo_plugin_bytes, NULL, NULL, NULL, napi_default, NULL},
        {"demoPluginProfile", NULL, demo_plugin_profile, NULL, NULL, NULL, napi_default, NULL},
        {"demoPluginLogin", NULL, demo_plugin_login, NULL, NULL, NULL, napi_default, NULL},
        {"demoPluginSyncContext", NULL, demo_plugin_sync_context, NULL, NULL, NULL, napi_default,
         NULL},
        {"demoPluginSyncFromWorker", NULL, demo_plugin_sync_from_worker, NULL, NULL, NULL,
         napi_default, NULL},
        {"toggleBackPressIntercept", NULL, demo_toggle_back_press, NULL, NULL, NULL, napi_default,
         NULL},
        /* ohos.permission */
        {"demoRequestPermissionFromMainThread", NULL, demo_request_permission, NULL, NULL, NULL,
         napi_default, NULL},
        /* ohos.url */
        {"demoOpenUrl", NULL, demo_open_url, NULL, NULL, NULL, napi_default, NULL},
        /* ohos.files */
        {"demoFileDialogOpen", NULL, demo_file_dialog_open, NULL, NULL, NULL, napi_default, NULL},
        {"demoFileDialogSave", NULL, demo_file_dialog_save, NULL, NULL, NULL, napi_default, NULL},
        /* ohos.resource */
        {"demoResourceManagerReady", NULL, demo_resource_manager_ready, NULL, NULL, NULL,
         napi_default, NULL},
        {"demoResourceRawDirCount", NULL, demo_resource_raw_dir_count, NULL, NULL, NULL,
         napi_default, NULL},
        /* ohos.webview */
        {"setBackgroundColor", NULL, demo_set_background_color, NULL, NULL, NULL, napi_default,
         NULL},
        {"setVisible", NULL, demo_set_visible, NULL, NULL, NULL, napi_default, NULL},
        {"createDemoWebview", NULL, demo_create_webview, NULL, NULL, NULL, napi_default, NULL},
        {"createComposedDemoWebview", NULL, demo_create_composed_webview, NULL, NULL, NULL,
         napi_default, NULL},
        {"createBottomDemoWebview", NULL, demo_create_bottom_webview, NULL, NULL, NULL,
         napi_default, NULL},
        {"evaluateDemoWebviewScript", NULL, demo_evaluate_webview_script, NULL, NULL, NULL,
         napi_default, NULL},
    };

    if (napi_define_properties(env, exports, sizeof(EXPORTS) / sizeof(EXPORTS[0]), EXPORTS) !=
        napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    return OH_ABILITY_ERROR_OK;
}
