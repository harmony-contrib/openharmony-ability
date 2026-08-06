/*
 * WebView demos, aligned with the Rust demo: an ohos.webview C plugin answering the
 * ArkTS-originated sync events, the custom "demoweb" scheme (registered at module import,
 * handled natively on the IO thread), the window.test JavaScript proxy (installed on
 * controller-attached), and the webview export surface (create / composed / bottom /
 * sub-window / evaluate / style ops).
 *
 * Contract facts (verified against plugins/webview/src/main/ets/WebviewPlugin.ets):
 *   ohos.webview "create"
 * ohos.webview.CreateRequest{id,html|url,style,transparent,windowKey,parentHandle}
 *                          -> ohos.webview.CreateResponse{id}
 *   ohos.webview "evaluate-script" ohos.webview.ScriptRequest{id,script} ->
 * ohos.webview.ScriptResponse{result} ohos.webview "set-background-color"/"set-visible"
 * ohos.webview.ControllerRequest{id,...}
 *                          -> ohos.webview.Acknowledgement{accepted}
 *   ohos.node "create-container" ohos.node.CreateContainerRequest{} ->
 * ohos.node.HandleResponse{handle} ohos.node "mount-into-root"
 * ohos.node.MountIntoRootRequest{handle} -> ohos.node.Acknowledgement{accepted} sync events:
 * before-engine-init / engine-initialized / controller-attached / controller-removed /
 * navigation-request / download-start / download-end / title-change
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <hilog/log.h>
#include <web/arkweb_scheme_handler.h>
#include <web/native_interface_arkweb.h>

#include "demo_common.h"

#define DEMO_TAG "ohosCDemo"
#define DEMO_LOG(level, fmt, ...)                                                                  \
    OH_LOG_Print(LOG_APP, (level), 0xD002701, DEMO_TAG, fmt, ##__VA_ARGS__)

#define DEMO_WEB_TAG "demo_webview"
#define DEMO_COMPOSED_WEB_TAG "demo_composed_webview"
#define DEMO_BOTTOM_WEB_TAG "demo_bottom_webview"
#define DEMO_SUB_WINDOW_WEB_TAG "demo_sub_window_webview"
#define DEMO_WEB_SCHEME "demoweb"
#define DEMO_WEB_URL "demoweb://index"

/* Compile-time switch: OH_ABILITY_PLUGIN_WEBVIEW (default ON) compiles the full plugin,
 * scheme handler and JS proxy; OFF keeps the export surface as explicit-error stubs and drops
 * the libohweb dependency. */
#ifdef OH_ABILITY_PLUGIN_WEBVIEW

/* The demo page served by the custom scheme, mirroring the Rust demo's index.html (including
 * the window.test JavaScript proxy button). */
static const char DEMO_INDEX_HTML[] =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>run javascript demo</title></head>"
    "<body><h1>run JavaScript Ext demo (pure C)</h1><p id=\"webDemo\"></p><br/>"
    "<button type=\"button\" style=\"height:30px;width:200px\" "
    "onclick=\"testNdkProxyObjMethod1()\">test test !</button><br/><br/>"
    "<a href=\"demoweb://index\">reload through the custom protocol</a>"
    "<script type=\"text/javascript\">"
    "function testNdkProxyObjMethod1(){"
    "if(window.test==undefined){document.getElementById(\"webDemo\").innerHTML=\"test "
    "undefined\";return;} "
    "if(window.test.test==undefined){document.getElementById(\"webDemo\").innerHTML=\"test test "
    "undefined\";return;} "
    "let "
    "retStr=window.test.test(\"hello\",\"world\",[1.2,-3.4,123.456],1.23456,123789,true,false,0); "
    "document.getElementById(\"webDemo\").innerHTML=\"proxy ok: \"+retStr;"
    "}"
    "</script></body></html>";

/* ------------------------------------------------------------------ */
/* Custom scheme (demoweb://index)                                     */
/* ------------------------------------------------------------------ */

static ArkWeb_SchemeHandler *g_scheme_handler;

static void demo_scheme_on_request_start(const ArkWeb_SchemeHandler *scheme_handler,
                                         ArkWeb_ResourceRequest *request,
                                         const ArkWeb_ResourceHandler *resource_handler,
                                         bool *intercept) {
    (void)scheme_handler;

    char *url = NULL;
    OH_ArkWebResourceRequest_GetUrl(request, &url);
    char *method = NULL;
    OH_ArkWebResourceRequest_GetMethod(request, &method);
    DEMO_LOG(LOG_INFO, "demoweb request: %s %s", method != NULL ? method : "(null)",
             url != NULL ? url : "(null)");
    OH_ArkWeb_ReleaseString(url);
    OH_ArkWeb_ReleaseString(method);

    ArkWeb_Response *response = NULL;
    OH_ArkWeb_CreateResponse(&response);
    OH_ArkWebResponse_SetStatus(response, 200);
    OH_ArkWebResponse_SetMimeType(response, "text/html");
    OH_ArkWebResponse_SetCharset(response, "utf-8");
    OH_ArkWebResourceHandler_DidReceiveResponse(resource_handler, response);
    OH_ArkWeb_DestroyResponse(response);
    OH_ArkWebResourceHandler_DidReceiveData(resource_handler, (const uint8_t *)DEMO_INDEX_HTML,
                                            (int64_t)(sizeof(DEMO_INDEX_HTML) - 1));
    OH_ArkWebResourceHandler_DidFinish(resource_handler);
    *intercept = true;
}

static void demo_scheme_on_request_stop(const ArkWeb_SchemeHandler *scheme_handler,
                                        const ArkWeb_ResourceRequest *request) {
    (void)scheme_handler;
    OH_ArkWebResourceRequest_Destroy((ArkWeb_ResourceRequest *)request);
}

/* Registers the scheme and creates the handler. Must run before the WebView engine is
 * initialized; the demo calls this from module import time (demo_register_plugins). */
static int demo_register_webview_scheme(void) {
    if (g_scheme_handler != NULL) {
        return OH_ABILITY_ERROR_OK;
    }
    int32_t option = ARKWEB_SCHEME_OPTION_STANDARD | ARKWEB_SCHEME_OPTION_CORS_ENABLED |
                     ARKWEB_SCHEME_OPTION_CSP_BYPASSING | ARKWEB_SCHEME_OPTION_FETCH_ENABLED |
                     ARKWEB_SCHEME_OPTION_CODE_CACHE_ENABLED;
    if (OH_ArkWeb_RegisterCustomSchemes(DEMO_WEB_SCHEME, option) != 0) {
        DEMO_LOG(LOG_ERROR, "failed to register custom scheme '%s'", DEMO_WEB_SCHEME);
        return OH_ABILITY_ERROR_BRIDGE;
    }
    OH_ArkWeb_CreateSchemeHandler(&g_scheme_handler);
    if (g_scheme_handler == NULL) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    OH_ArkWebSchemeHandler_SetOnRequestStart(g_scheme_handler, demo_scheme_on_request_start);
    OH_ArkWebSchemeHandler_SetOnRequestStop(g_scheme_handler, demo_scheme_on_request_stop);
    DEMO_LOG(LOG_INFO, "custom scheme '%s' registered", DEMO_WEB_SCHEME);
    return OH_ABILITY_ERROR_OK;
}

/* ------------------------------------------------------------------ */
/* window.test JavaScript proxy (native ArkWeb registration)           */
/* ------------------------------------------------------------------ */

static char *demo_js_proxy_callback(const char **argv, int32_t argc) {
    for (int32_t i = 0; i < argc; i++) {
        DEMO_LOG(LOG_INFO, "js proxy arg[%d] = %s", (int)i, argv[i] != NULL ? argv[i] : "(null)");
    }
    return NULL; /* undefined returned to the page */
}

/* The registration API writes the callback pointer into this slot. */
static NativeArkWeb_OnJavaScriptProxyCallback g_js_proxy_callback = demo_js_proxy_callback;

/* Installs the per-webview services when the controller attaches (engine exists, initial load
 * has not started yet). */
static void demo_install_webview_services(const char *web_tag) {
    if (g_scheme_handler != NULL) {
        OH_ArkWeb_SetSchemeHandler(DEMO_WEB_SCHEME, web_tag, g_scheme_handler);
    }
    static const char *const METHODS[] = {"test"};
    OH_NativeArkWeb_RegisterJavaScriptProxy(web_tag, "test", (const char **)METHODS,
                                            &g_js_proxy_callback, 1, false);
    DEMO_LOG(LOG_INFO, "webview services installed for tag '%s'", web_tag);
}

/* ------------------------------------------------------------------ */
/* ohos.webview C plugin: ArkTS-originated sync events                 */
/* ------------------------------------------------------------------ */

static int demo_webview_sync_event(napi_env env, const char *event, const char *request_type,
                                   napi_value value, const char *response_type,
                                   napi_value *out_response, void *userdata) {
    (void)request_type;
    (void)response_type;
    (void)userdata;

    napi_value response;
    if (napi_create_object(env, &response) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }

    if (strcmp(event, "navigation-request") == 0) {
        /* Navigation interception fails open: allow the navigation. */
        char *url = demo_object_get_string(env, value, "url");
        DEMO_LOG(LOG_INFO, "ohos.webview navigation-request => %s", url != NULL ? url : "(null)");
        free(url);
        demo_object_bool(env, response, "intercept", false);
        *out_response = response;
        return OH_ABILITY_ERROR_OK;
    }
    if (strcmp(event, "download-start") == 0) {
        /* Download admission fails closed; the demo allows downloads to the platform path. */
        char *url = demo_object_get_string(env, value, "url");
        char *temp_path = demo_object_get_string(env, value, "tempPath");
        DEMO_LOG(LOG_INFO, "ohos.webview download-start => url=%s tempPath=%s",
                 url != NULL ? url : "(null)", temp_path != NULL ? temp_path : "(null)");
        free(url);
        free(temp_path);
        demo_object_bool(env, response, "allow", true);
        napi_value null_value;
        napi_get_null(env, &null_value);
        napi_set_named_property(env, response, "tempPath", null_value);
        *out_response = response;
        return OH_ABILITY_ERROR_OK;
    }
    if (strcmp(event, "controller-attached") == 0) {
        char *id = demo_object_get_string(env, value, "id");
        if (id != NULL && id[0] != '\0') {
            demo_install_webview_services(id);
        }
        free(id);
        demo_object_bool(env, response, "accepted", true);
        *out_response = response;
        return OH_ABILITY_ERROR_OK;
    }
    if (strcmp(event, "controller-removed") == 0) {
        char *id = demo_object_get_string(env, value, "id");
        DEMO_LOG(LOG_INFO, "ohos.webview controller-removed => %s", id != NULL ? id : "(null)");
        free(id);
        demo_object_bool(env, response, "accepted", true);
        *out_response = response;
        return OH_ABILITY_ERROR_OK;
    }
    if (strcmp(event, "before-engine-init") == 0 || strcmp(event, "engine-initialized") == 0) {
        DEMO_LOG(LOG_INFO, "ohos.webview %s", event);
        demo_object_bool(env, response, "accepted", true);
        *out_response = response;
        return OH_ABILITY_ERROR_OK;
    }
    if (strcmp(event, "title-change") == 0) {
        char *id = demo_object_get_string(env, value, "id");
        char *title = demo_object_get_string(env, value, "title");
        DEMO_LOG(LOG_INFO, "ohos.webview title-change => id=%s title=%s",
                 id != NULL ? id : "(null)", title != NULL ? title : "(null)");
        free(id);
        free(title);
        demo_object_bool(env, response, "accepted", true);
        *out_response = response;
        return OH_ABILITY_ERROR_OK;
    }
    if (strcmp(event, "download-end") == 0) {
        char *url = demo_object_get_string(env, value, "url");
        DEMO_LOG(LOG_INFO, "ohos.webview download-end => url=%s", url != NULL ? url : "(null)");
        free(url);
        demo_object_bool(env, response, "accepted", true);
        *out_response = response;
        return OH_ABILITY_ERROR_OK;
    }

    return OH_ABILITY_ERROR_NOT_FOUND;
}

static const OHAbility_Plugin WEBVIEW_PLUGIN = {
    .version = 1,
    .on_sync_event = demo_webview_sync_event,
    .on_lifecycle = NULL,
};

int demo_register_webview_plugin(void) {
    int rc = demo_register_webview_scheme();
    if (rc != OH_ABILITY_ERROR_OK) {
        return rc;
    }
    return OHAbility_RegisterPlugin("ohos.webview", &WEBVIEW_PLUGIN, NULL);
}

/* ------------------------------------------------------------------ */
/* Builders (single allocations; freed by the framework after use)    */
/* ------------------------------------------------------------------ */

typedef struct DemoWebviewCreateArgs {
    char id[64];
    char window_key[64];
    int32_t parent_handle; /* -1 = none */
    int32_t transparent;
    int32_t bottom_style;
} DemoWebviewCreateArgs;

static int demo_build_create_request(napi_env env, napi_value *out, void *data) {
    DemoWebviewCreateArgs *args = (DemoWebviewCreateArgs *)data;
    napi_value request;
    if (napi_create_object(env, &request) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    demo_object_string(env, request, "id", args->id);
    demo_object_string(env, request, "url", DEMO_WEB_URL);
    demo_object_bool(env, request, "transparent", args->transparent != 0);
    if (args->parent_handle >= 0) {
        demo_object_int32(env, request, "parentHandle", args->parent_handle);
    }
    if (args->window_key[0] != '\0') {
        demo_object_string(env, request, "windowKey", args->window_key);
    }
    if (args->bottom_style) {
        napi_value style;
        napi_create_object(env, &style);
        demo_object_string(env, style, "y", "70%");
        demo_object_string(env, style, "height", "30%");
        demo_object_string(env, style, "backgroundColor", "#00000000");
        napi_set_named_property(env, request, "style", style);
    }
    *out = request;
    return OH_ABILITY_ERROR_OK;
}

typedef struct DemoControllerStringArgs {
    char id[64];
    char value[64];
} DemoControllerStringArgs;

static int demo_build_controller_string(napi_env env, napi_value *out, void *data) {
    DemoControllerStringArgs *args = (DemoControllerStringArgs *)data;
    napi_value request;
    if (napi_create_object(env, &request) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    demo_object_string(env, request, "id", args->id);
    demo_object_string(env, request, "color", args->value);
    *out = request;
    return OH_ABILITY_ERROR_OK;
}

typedef struct DemoControllerBoolArgs {
    char id[64];
    int32_t value;
} DemoControllerBoolArgs;

static int demo_build_controller_bool(napi_env env, napi_value *out, void *data) {
    DemoControllerBoolArgs *args = (DemoControllerBoolArgs *)data;
    napi_value request;
    if (napi_create_object(env, &request) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    demo_object_string(env, request, "id", args->id);
    demo_object_bool(env, request, "visible", args->value != 0);
    *out = request;
    return OH_ABILITY_ERROR_OK;
}

typedef struct DemoScriptArgs {
    char id[64];
    char script[512];
} DemoScriptArgs;

static int demo_build_script_request(napi_env env, napi_value *out, void *data) {
    DemoScriptArgs *args = (DemoScriptArgs *)data;
    napi_value request;
    if (napi_create_object(env, &request) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    demo_object_string(env, request, "id", args->id);
    demo_object_string(env, request, "script", args->script);
    *out = request;
    return OH_ABILITY_ERROR_OK;
}

/* ------------------------------------------------------------------ */
/* Responders                                                          */
/* ------------------------------------------------------------------ */

static void demo_webview_ack_responder(napi_env env, int status, napi_value value,
                                       const char *error, void *data) {
    DemoDeferred *ctx = (DemoDeferred *)data;
    (void)value;
    if (status != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(ctx, env, error != NULL ? error : "webview call failed");
    } else {
        demo_deferred_resolve(ctx, env, NULL);
    }
    free(ctx);
}

static void demo_script_responder(napi_env env, int status, napi_value value, const char *error,
                                  void *data) {
    DemoDeferred *ctx = (DemoDeferred *)data;
    if (status != OH_ABILITY_ERROR_OK || value == NULL) {
        demo_deferred_reject(ctx, env, error != NULL ? error : "evaluate-script failed");
        free(ctx);
        return;
    }
    napi_value result;
    if (napi_get_named_property(env, value, "result", &result) != napi_ok) {
        demo_deferred_reject(ctx, env, "evaluate-script response has no result");
        free(ctx);
        return;
    }
    napi_valuetype type;
    napi_typeof(env, result, &type);
    if (type == napi_null || type == napi_undefined) {
        demo_deferred_reject(ctx, env, "evaluate-script returned no value");
        free(ctx);
        return;
    }
    demo_deferred_resolve(ctx, env, result);
    free(ctx);
}

/* ------------------------------------------------------------------ */
/* Exports                                                             */
/* ------------------------------------------------------------------ */

/* setBackgroundColor(color): Promise<void> */
napi_value demo_set_background_color(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    DemoControllerStringArgs *build_args =
        (DemoControllerStringArgs *)calloc(1, sizeof(*build_args));
    if (build_args == NULL) {
        free(ctx);
        return NULL;
    }
    snprintf(build_args->id, sizeof(build_args->id), "%s", DEMO_WEB_TAG);
    if (argc >= 1) {
        char *color = NULL;
        size_t length = 0;
        if (napi_get_value_string_utf8(env, args[0], NULL, 0, &length) == napi_ok) {
            color = (char *)malloc(length + 1);
            if (color != NULL) {
                napi_get_value_string_utf8(env, args[0], color, length + 1, &length);
            }
        }
        if (color != NULL) {
            snprintf(build_args->value, sizeof(build_args->value), "%s", color);
        }
        free(color);
    }

    int rc = OHAbility_CallAsync("ohos.webview", 1, "set-background-color",
                                 "ohos.webview.ControllerRequest", "ohos.webview.Acknowledgement",
                                 demo_build_controller_string, build_args,
                                 demo_webview_ack_responder, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        free(build_args);
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

/* setVisible(visible): Promise<void> */
napi_value demo_set_visible(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    DemoControllerBoolArgs *build_args = (DemoControllerBoolArgs *)calloc(1, sizeof(*build_args));
    if (build_args == NULL) {
        free(ctx);
        return NULL;
    }
    snprintf(build_args->id, sizeof(build_args->id), "%s", DEMO_WEB_TAG);
    if (argc >= 1) {
        napi_get_value_bool(env, args[0], (bool *)&build_args->value);
    }

    int rc = OHAbility_CallAsync("ohos.webview", 1, "set-visible", "ohos.webview.ControllerRequest",
                                 "ohos.webview.Acknowledgement", demo_build_controller_bool,
                                 build_args, demo_webview_ack_responder, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        free(build_args);
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

/* createDemoWebview(): Promise<void> — full-bleed, transparent, loads demoweb://index. */
napi_value demo_create_webview(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    DemoWebviewCreateArgs *build_args = (DemoWebviewCreateArgs *)calloc(1, sizeof(*build_args));
    if (build_args == NULL) {
        free(ctx);
        return NULL;
    }
    snprintf(build_args->id, sizeof(build_args->id), "%s", DEMO_WEB_TAG);
    build_args->parent_handle = -1;
    build_args->transparent = 1;

    int rc = OHAbility_CallAsync("ohos.webview", 1, "create", "ohos.webview.CreateRequest",
                                 "ohos.webview.CreateResponse", demo_build_create_request,
                                 build_args, demo_webview_ack_responder, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        free(build_args);
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

/* createBottomDemoWebview(): Promise<void> — bottom-pinned 30% strip via WebviewStyle. */
napi_value demo_create_bottom_webview(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    DemoWebviewCreateArgs *build_args = (DemoWebviewCreateArgs *)calloc(1, sizeof(*build_args));
    if (build_args == NULL) {
        free(ctx);
        return NULL;
    }
    snprintf(build_args->id, sizeof(build_args->id), "%s", DEMO_BOTTOM_WEB_TAG);
    build_args->parent_handle = -1;
    build_args->bottom_style = 1;

    int rc = OHAbility_CallAsync("ohos.webview", 1, "create", "ohos.webview.CreateRequest",
                                 "ohos.webview.CreateResponse", demo_build_create_request,
                                 build_args, demo_webview_ack_responder, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        free(build_args);
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

/* createSubWindowWebview(): Promise<void> — mounts into the "sub" window surface. */
napi_value demo_create_sub_window_webview(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    DemoWebviewCreateArgs *build_args = (DemoWebviewCreateArgs *)calloc(1, sizeof(*build_args));
    if (build_args == NULL) {
        free(ctx);
        return NULL;
    }
    snprintf(build_args->id, sizeof(build_args->id), "%s", DEMO_SUB_WINDOW_WEB_TAG);
    snprintf(build_args->window_key, sizeof(build_args->window_key), "%s", "sub");
    build_args->parent_handle = -1;
    build_args->transparent = 1;

    int rc = OHAbility_CallAsync("ohos.webview", 1, "create", "ohos.webview.CreateRequest",
                                 "ohos.webview.CreateResponse", demo_build_create_request,
                                 build_args, demo_webview_ack_responder, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        free(build_args);
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

/* ------------------------------------------------------------------ */
/* Composed webview: ohos.node container -> webview child -> mount     */
/* (requires the framework's OH_ABILITY_PLUGIN_NODE facade)            */
/* ------------------------------------------------------------------ */

#ifdef OH_ABILITY_PLUGIN_NODE

typedef struct DemoComposeContext {
    DemoDeferred deferred;
    int32_t handle;
    char id[64];
} DemoComposeContext;

static void demo_compose_final(napi_env env, int status, napi_value value, const char *error,
                               void *data) {
    DemoComposeContext *ctx = (DemoComposeContext *)data;
    (void)value;
    if (status != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(&ctx->deferred, env,
                             error != NULL ? error : "composed webview mount failed");
    } else {
        demo_deferred_resolve(&ctx->deferred, env, NULL);
    }
    free(ctx);
}

static void demo_compose_mount(napi_env env, int status, napi_value value, const char *error,
                               void *data) {
    DemoComposeContext *ctx = (DemoComposeContext *)data;
    (void)value;
    if (status != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(&ctx->deferred, env,
                             error != NULL ? error : "composed webview create failed");
        free(ctx);
        return;
    }
    int rc = OHAbility_NodeMountIntoRoot((uint32_t)ctx->handle, demo_compose_final, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(&ctx->deferred, env, "bridge not ready");
        free(ctx);
    }
}

static void demo_compose_created(napi_env env, int status, napi_value value, const char *error,
                                 void *data) {
    DemoComposeContext *ctx = (DemoComposeContext *)data;
    if (status != OH_ABILITY_ERROR_OK || value == NULL) {
        demo_deferred_reject(&ctx->deferred, env,
                             error != NULL ? error : "ohos.node create-container failed");
        free(ctx);
        return;
    }
    /* The framework facade extracted the opaque handle from the response. */
    if (napi_get_value_int32(env, value, &ctx->handle) != napi_ok) {
        demo_deferred_reject(&ctx->deferred, env, "ohos.node create-container returned no handle");
        free(ctx);
        return;
    }

    DemoWebviewCreateArgs *build_args = (DemoWebviewCreateArgs *)calloc(1, sizeof(*build_args));
    if (build_args == NULL) {
        demo_deferred_reject(&ctx->deferred, env, "out of memory");
        free(ctx);
        return;
    }
    snprintf(build_args->id, sizeof(build_args->id), "%s", ctx->id);
    build_args->parent_handle = ctx->handle;
    build_args->transparent = 1;

    int rc = OHAbility_CallAsync("ohos.webview", 1, "create", "ohos.webview.CreateRequest",
                                 "ohos.webview.CreateResponse", demo_build_create_request,
                                 build_args, demo_compose_mount, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        free(build_args);
        demo_deferred_reject(&ctx->deferred, env, "bridge not ready");
        free(ctx);
    }
}

/* createComposedDemoWebview(): Promise<void> — container tree + webview child + root mount. */
napi_value demo_create_composed_webview(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoComposeContext *ctx = (DemoComposeContext *)malloc(sizeof(*ctx));
    if (ctx == NULL) {
        return NULL;
    }
    if (napi_create_promise(env, &ctx->deferred.deferred, &promise) != napi_ok) {
        free(ctx);
        return NULL;
    }
    ctx->deferred.env = env;
    ctx->handle = -1;
    snprintf(ctx->id, sizeof(ctx->id), "%s", DEMO_COMPOSED_WEB_TAG);

    int rc = OHAbility_NodeCreateContainer(demo_compose_created, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(&ctx->deferred, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

#else /* !OH_ABILITY_PLUGIN_NODE */

napi_value demo_create_composed_webview(napi_env env, napi_callback_info info) {
    return demo_disabled_promise(env, "ohos.node");
}

#endif /* OH_ABILITY_PLUGIN_NODE */

/* evaluateDemoWebviewScript(): Promise<string> — document.title through the controller. */
napi_value demo_evaluate_webview_script(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    DemoScriptArgs *build_args = (DemoScriptArgs *)calloc(1, sizeof(*build_args));
    if (build_args == NULL) {
        free(ctx);
        return NULL;
    }
    snprintf(build_args->id, sizeof(build_args->id), "%s", DEMO_WEB_TAG);
    snprintf(build_args->script, sizeof(build_args->script), "%s", "document.title");

    int rc = OHAbility_CallAsync("ohos.webview", 1, "evaluate-script", "ohos.webview.ScriptRequest",
                                 "ohos.webview.ScriptResponse", demo_build_script_request,
                                 build_args, demo_script_responder, ctx, 0);
    if (rc != OH_ABILITY_ERROR_OK) {
        free(build_args);
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

#else /* !OH_ABILITY_PLUGIN_WEBVIEW */

/* The export surface stays intact (the demo Index page imports these names); every call fails
 * with an explicit error instead of a missing symbol. No libohweb dependency is linked. */
static napi_value demo_webview_disabled_stub(napi_env env, napi_callback_info info) {
    (void)info;
    napi_value promise;
    napi_deferred deferred;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        return NULL;
    }
    napi_value message;
    napi_create_string_utf8(env, "webview support is disabled in this build", NAPI_AUTO_LENGTH,
                            &message);
    napi_reject_deferred(env, deferred, message);
    return promise;
}

napi_value demo_set_background_color(napi_env env, napi_callback_info info) {
    return demo_webview_disabled_stub(env, info);
}
napi_value demo_set_visible(napi_env env, napi_callback_info info) {
    return demo_webview_disabled_stub(env, info);
}
napi_value demo_create_webview(napi_env env, napi_callback_info info) {
    return demo_webview_disabled_stub(env, info);
}
napi_value demo_create_composed_webview(napi_env env, napi_callback_info info) {
    return demo_webview_disabled_stub(env, info);
}
napi_value demo_create_bottom_webview(napi_env env, napi_callback_info info) {
    return demo_webview_disabled_stub(env, info);
}
napi_value demo_create_sub_window_webview(napi_env env, napi_callback_info info) {
    return demo_webview_disabled_stub(env, info);
}
napi_value demo_evaluate_webview_script(napi_env env, napi_callback_info info) {
    return demo_webview_disabled_stub(env, info);
}

int demo_register_webview_plugin(void) { return OH_ABILITY_ERROR_OK; }

#endif /* OH_ABILITY_PLUGIN_WEBVIEW */
