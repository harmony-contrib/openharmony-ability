/*
 * Shared bridge demo helpers: N-API object construction, deferred promise plumbing, the
 * disabled-plugin stub, and the back-press interceptor state. Per-plugin code lives in
 * src/plugins/<plugin>/.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <hilog/log.h>

#include "demo_common.h"

#define DEMO_TAG "ohosCDemo"
#define DEMO_LOG(level, fmt, ...)                                                                  \
    OH_LOG_Print(LOG_APP, (level), 0xD002701, DEMO_TAG, fmt, ##__VA_ARGS__)

/* ------------------------------------------------------------------ */
/* Promise plumbing for exports                                        */
/* ------------------------------------------------------------------ */

DemoDeferred *demo_deferred_new(napi_env env, napi_value *out_promise) {
    DemoDeferred *ctx = (DemoDeferred *)malloc(sizeof(*ctx));
    if (ctx == NULL) {
        return NULL;
    }
    ctx->env = env;
    if (napi_create_promise(env, &ctx->deferred, out_promise) != napi_ok) {
        free(ctx);
        return NULL;
    }
    return ctx;
}

void demo_deferred_resolve(DemoDeferred *ctx, napi_env env, napi_value value) {
    /* The deferred belongs to the export env; the responder env must match (same module env). */
    if (ctx->env != env) {
        napi_value msg;
        napi_create_string_utf8(ctx->env, "bridge responder env mismatch", NAPI_AUTO_LENGTH, &msg);
        napi_reject_deferred(ctx->env, ctx->deferred, msg);
        return;
    }
    if (value == NULL) {
        napi_get_undefined(env, &value);
    }
    napi_resolve_deferred(ctx->env, ctx->deferred, value);
}

void demo_deferred_reject(DemoDeferred *ctx, napi_env env, const char *error) {
    if (ctx->env != env) {
        return;
    }
    napi_value msg;
    napi_create_string_utf8(env, error != NULL ? error : "bridge call failed", NAPI_AUTO_LENGTH,
                            &msg);
    napi_reject_deferred(env, ctx->deferred, msg);
}

/* Promise rejected with "<plugin> is disabled in this build"; used by the OH_ABILITY_PLUGIN_*
 * stubs that keep the export surface intact. */
napi_value demo_disabled_promise(napi_env env, const char *plugin) {
    napi_value promise;
    napi_deferred deferred;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        return NULL;
    }
    char message[128];
    snprintf(message, sizeof(message), "%s is disabled in this build", plugin);
    napi_value msg;
    napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &msg);
    napi_reject_deferred(env, deferred, msg);
    return promise;
}

/* ------------------------------------------------------------------ */
/* N-API object construction helpers                                   */
/* ------------------------------------------------------------------ */

int demo_object_string(napi_env env, napi_value object, const char *name, const char *value) {
    napi_value js_value;
    if (napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &js_value) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    return napi_set_named_property(env, object, name, js_value) == napi_ok
               ? OH_ABILITY_ERROR_OK
               : OH_ABILITY_ERROR_BRIDGE;
}

int demo_object_int32(napi_env env, napi_value object, const char *name, int32_t value) {
    napi_value js_value;
    if (napi_create_int32(env, value, &js_value) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    return napi_set_named_property(env, object, name, js_value) == napi_ok
               ? OH_ABILITY_ERROR_OK
               : OH_ABILITY_ERROR_BRIDGE;
}

int demo_object_bool(napi_env env, napi_value object, const char *name, bool value) {
    napi_value js_value;
    if (napi_get_boolean(env, value, &js_value) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    return napi_set_named_property(env, object, name, js_value) == napi_ok
               ? OH_ABILITY_ERROR_OK
               : OH_ABILITY_ERROR_BRIDGE;
}

/* Reads a named string property into a malloc'd buffer (NULL when absent). */
char *demo_object_get_string(napi_env env, napi_value object, const char *name) {
    napi_value value;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) {
        return NULL;
    }
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return NULL;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, NULL, 0, &length) != napi_ok) {
        return NULL;
    }
    char *result = (char *)malloc(length + 1);
    if (result == NULL) {
        return NULL;
    }
    napi_get_value_string_utf8(env, value, result, length + 1, &length);
    return result;
}

/* Builds a JS array of strings from a NULL-terminated C array. */
int demo_build_string_array(napi_env env, napi_value *out, const char *const *items, size_t count) {
    napi_value array;
    if (napi_create_array_with_length(env, count, &array) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    for (size_t i = 0; i < count; i++) {
        napi_value item;
        if (napi_create_string_utf8(env, items[i], NAPI_AUTO_LENGTH, &item) != napi_ok) {
            return OH_ABILITY_ERROR_BRIDGE;
        }
        napi_set_element(env, array, (uint32_t)i, item);
    }
    *out = array;
    return OH_ABILITY_ERROR_OK;
}

/* ------------------------------------------------------------------ */
/* Back-press interceptor                                              */
/* ------------------------------------------------------------------ */

static bool g_back_press_enabled = true;

static bool demo_back_press(void *userdata) {
    (void)userdata;
    DEMO_LOG(LOG_INFO, "back-press intercept => %s", g_back_press_enabled ? "true" : "false");
    return g_back_press_enabled;
}

int demo_toggle_back_press_intercept(void) {
    g_back_press_enabled = !g_back_press_enabled;
    OHAbility_SetBackPressInterceptor(demo_back_press, NULL);
    return g_back_press_enabled ? 1 : 0;
}
