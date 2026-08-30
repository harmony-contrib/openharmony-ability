/*
 * Module glue: registers the eight exports consumed by the @ohos-rs/ability host and owns the
 * environment cleanup hook. The export implementations live in lifecycle.c (init), xcomponent.c
 * (render), registry.c (onBridgeSyncEvent) and here (onBackPressIntercept / onBridgeLifecycle).
 */
#include "oh_state.h"

#include <stdlib.h>
#include <string.h>

static const char *const OH_ABILITY_LIFECYCLE_KINDS[] = {
    "ui-context-ready",
    "ui-context-destroy",
};

static int oh_is_lifecycle_kind(const char *kind) {
    for (size_t i = 0;
         i < sizeof(OH_ABILITY_LIFECYCLE_KINDS) / sizeof(OH_ABILITY_LIFECYCLE_KINDS[0]); i++) {
        if (strcmp(kind, OH_ABILITY_LIFECYCLE_KINDS[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

static napi_value oh_napi_on_back_press_intercept(napi_env env, napi_callback_info info) {
    (void)env;
    (void)info;
    napi_value result;
    napi_get_boolean(env, false, &result);

    oh_state_lock();
    OHAbility_BackPressFn fn = g_oh_state.back_press_fn;
    void *userdata = g_oh_state.back_press_data;
    oh_state_unlock();

    bool intercept = false;
    if (fn != NULL) {
        intercept = fn(userdata);
    }
    napi_get_boolean(env, intercept, &result);
    return result;
}

static napi_value oh_napi_on_bridge_lifecycle(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    if (argc >= 1) {
        char *kind = oh_napi_get_string(env, args[0]);
        if (!oh_is_lifecycle_kind(kind)) {
            napi_throw_error(env, "oh_ability/lifecycle",
                             "unsupported ArkTS bridge lifecycle event");
        } else {
            /* ArkTS only emits ui-context-ready / ui-context-destroy through this port; the
             * remaining kinds are synthesized by the framework in lifecycle.c. */
            oh_plugins_dispatch_lifecycle(kind, 0, 0);
        }
        free(kind);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/* ------------------------------------------------------------------ */
/* Environment cleanup                                                 */
/* ------------------------------------------------------------------ */

static void oh_env_cleanup(void *arg) {
    (void)arg;
    OHABILITY_LOG(LOG_INFO, "environment cleanup: aborting bridge, wake waiters, stop app");

    /* Abort the bridge transports first: queued requests drain through call-js with env == NULL
     * and wake the worker-sync waiters instead of leaving them blocked. */
    oh_bindings_teardown();
    oh_render_cleanup(g_oh_state.env);

    oh_state_lock();

    free(g_oh_state.base_path);
    free(g_oh_state.pref_path);
    free(g_oh_state.preferred_locales);
    free(g_oh_state.module_name);
    free(g_oh_state.restored_state);
    free(g_oh_state.saved_state);
    free(g_oh_state.bridge_owner);
    free(g_oh_state.render_owner);
    g_oh_state.base_path = NULL;
    g_oh_state.pref_path = NULL;
    g_oh_state.preferred_locales = NULL;
    g_oh_state.module_name = NULL;
    g_oh_state.restored_state = NULL;
    g_oh_state.bridge_owner = NULL;
    g_oh_state.render_owner = NULL;

    oh_configuration_free(&g_oh_state.configuration);
    memset(g_oh_state.avoid_area_present, 0, sizeof(g_oh_state.avoid_area_present));
    g_oh_state.saved_state = NULL;

    if (g_oh_state.resource_manager != NULL) {
        OH_ResourceManager_ReleaseNativeResourceManager(g_oh_state.resource_manager);
        g_oh_state.resource_manager = NULL;
    }

    g_oh_state.mounted_component = NULL;
    g_oh_state.mounted_node = NULL;
    g_oh_state.mounted_slot = NULL;
    g_oh_state.native_window = NULL;
    g_oh_state.env = NULL;
    g_oh_state.plugin_count = 0;
    g_oh_state.plugins_frozen = 0;
    g_oh_state.plugin_session_active = 0;
    g_oh_state.lifecycle_history_count = 0;
    g_oh_state.cleanup_registered = 0;

    oh_state_unlock();

    /* Wake every worker-sync waiter: they return CANCELLED instead of blocking forever. */
    oh_waiter_abort_all(OH_ABILITY_ERROR_CANCELLED);

    oh_app_request_quit(0);
    oh_app_join();
}

int OHAbility_RegisterModule(napi_env env, napi_value exports) {
    if (env == NULL || exports == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }

    oh_state_lock();
    g_oh_state.env = env;
    int cleanup_registered = g_oh_state.cleanup_registered;
    oh_state_unlock();

    /* Register the cleanup hook exactly once per environment lifetime. */
    if (!cleanup_registered) {
        if (napi_add_env_cleanup_hook(env, oh_env_cleanup, NULL) != napi_ok) {
            OHABILITY_LOG(LOG_ERROR, "failed to register environment cleanup hook");
            return OH_ABILITY_ERROR_BRIDGE;
        }
        oh_state_lock();
        g_oh_state.cleanup_registered = 1;
        oh_state_unlock();
    }

    static const struct {
        const char *name;
        napi_callback callback;
    } exports_table[] = {
        {"init", oh_napi_init},
        {"disposeBridge", oh_napi_dispose_bridge},
        {"render", oh_napi_render},
        {"disposeRender", oh_napi_dispose_render},
        {"disposeAllRenders", oh_napi_dispose_all_renders},
        {"onBackPressIntercept", oh_napi_on_back_press_intercept},
        {"onBridgeSyncEvent", oh_napi_on_bridge_sync_event},
        {"onBridgeLifecycle", oh_napi_on_bridge_lifecycle},
    };

    napi_value global;
    if (napi_get_global(env, &global) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }

    for (size_t i = 0; i < sizeof(exports_table) / sizeof(exports_table[0]); i++) {
        napi_value fn;
        if (napi_create_function(env, exports_table[i].name, NAPI_AUTO_LENGTH,
                                 exports_table[i].callback, NULL, &fn) != napi_ok) {
            return OH_ABILITY_ERROR_BRIDGE;
        }
        if (napi_set_named_property(env, exports, exports_table[i].name, fn) != napi_ok) {
            return OH_ABILITY_ERROR_BRIDGE;
        }
    }

    OHABILITY_LOG(LOG_INFO,
                  "module registered (exports: init/disposeBridge/render/disposeRender/"
                  "disposeAllRenders/onBackPressIntercept/onBridgeSyncEvent/onBridgeLifecycle)");
    return OH_ABILITY_ERROR_OK;
}
