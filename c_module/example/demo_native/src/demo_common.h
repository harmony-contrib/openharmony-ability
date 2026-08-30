/*
 * Shared declarations for the pure C demo module (main.c / exports.c / bridge_demos.c /
 * webview_demos.c).
 */
#ifndef DEMO_COMMON_H
#define DEMO_COMMON_H

#include <napi/native_api.h>

#include "oh_ability.h"

/* Promise plumbing: the deferred belongs to the export env; responders run on the ArkTS main
 * thread with a matching env (same module environment). */
typedef struct DemoDeferred {
    napi_env env;
    napi_deferred deferred;
} DemoDeferred;

DemoDeferred *demo_deferred_new(napi_env env, napi_value *out_promise);
void demo_deferred_resolve(DemoDeferred *ctx, napi_env env, napi_value value);
void demo_deferred_reject(DemoDeferred *ctx, napi_env env, const char *error);

/* N-API object helpers. */
int demo_object_string(napi_env env, napi_value object, const char *name, const char *value);
int demo_object_int32(napi_env env, napi_value object, const char *name, int32_t value);
int demo_object_bool(napi_env env, napi_value object, const char *name, bool value);
int demo_build_string_array(napi_env env, napi_value *out, const char *const *items, size_t count);

/* Reads a named string property into a malloc'd buffer (NULL when absent). */
char *demo_object_get_string(napi_env env, napi_value object, const char *name);

/* Back-press demo state (bridge_demos.c). */
int demo_toggle_back_press_intercept(void);

/* Returns a Promise rejected with "<plugin> is disabled in this build" (bridge_demos.c). Used by
 * the OH_ABILITY_PLUGIN_* stubs that keep the export surface intact. */
napi_value demo_disabled_promise(napi_env env, const char *plugin);

/* Demo exports (exports.c). */
int demo_register_bridge_plugins(void);
int demo_register_exported_functions(napi_env env, napi_value exports);

#endif /* DEMO_COMMON_H */
