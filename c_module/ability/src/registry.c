/*
 * C plugin registry: identifiers, versioned registration, lifecycle fan-out, and the
 * `onBridgeSyncEvent` export that delivers ArkTS-originated main-thread events to plugins.
 * Dispatch is fail-closed: an unknown plugin id or a handler error throws into ArkTS, matching
 * the Rust `BridgePluginRegistry` semantics.
 */
#include "oh_state.h"

#include <stdlib.h>
#include <string.h>

#include <window_manager/oh_display_manager.h>

int OHAbility_RegisterPlugin(const char *plugin_id, const OHAbility_Plugin *plugin,
                             void *userdata) {
    if (plugin_id == NULL || plugin == NULL || !oh_validate_identifier("plugin id", plugin_id)) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    if (plugin->version == 0 || plugin->on_sync_event == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }

    oh_state_lock();
    for (size_t i = 0; i < g_oh_state.plugin_count; i++) {
        if (strcmp(g_oh_state.plugins[i].id, plugin_id) == 0) {
            oh_state_unlock();
            return OH_ABILITY_ERROR_DUPLICATE;
        }
    }
    if (g_oh_state.plugin_count >= OHABILITY_MAX_PLUGINS) {
        oh_state_unlock();
        return OH_ABILITY_ERROR_BRIDGE;
    }

    OHAbility_PluginEntry *entry = &g_oh_state.plugins[g_oh_state.plugin_count++];
    snprintf(entry->id, sizeof(entry->id), "%s", plugin_id);
    entry->plugin = *plugin;
    entry->userdata = userdata;
    oh_state_unlock();

    OHABILITY_LOG(LOG_INFO, "plugin registered: %s (version %u)", plugin_id, plugin->version);
    return OH_ABILITY_ERROR_OK;
}

void oh_plugins_dispatch_lifecycle(const char *kind, int32_t window_stage_event,
                                   int32_t memory_level) {
    /* Copy the entries under the lock, call user code outside it. */
    oh_state_lock();
    size_t count = g_oh_state.plugin_count;
    OHAbility_PluginEntry *entries = g_oh_state.plugins;
    OHAbility_LifecycleEvent event = {
        .kind = kind,
        .window_stage_event = window_stage_event,
        .memory_level = memory_level,
    };
    for (size_t i = 0; i < count; i++) {
        if (entries[i].plugin.on_lifecycle != NULL) {
            entries[i].plugin.on_lifecycle(&event, entries[i].userdata);
        }
    }
    oh_state_unlock();
}

napi_value oh_napi_on_bridge_sync_event(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {NULL, NULL, NULL, NULL, NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    if (argc < 5) {
        napi_throw_error(env, "oh_ability/argc", "onBridgeSyncEvent requires 5 arguments");
        return NULL;
    }

    char *plugin_id = oh_napi_get_string(env, args[0]);
    char *event = oh_napi_get_string(env, args[1]);
    char *request_type = oh_napi_get_string(env, args[2]);
    char *response_type = oh_napi_get_string(env, args[3]);
    napi_value value = args[4];

    napi_value result = NULL;
    int delivered = 0;

    if (!oh_validate_identifier("plugin id", plugin_id) ||
        !oh_validate_identifier("event", event) ||
        !oh_validate_identifier("request type", request_type) ||
        !oh_validate_identifier("response type", response_type)) {
        napi_throw_error(env, "oh_ability/identifier",
                         "onBridgeSyncEvent identifiers must match ^[A-Za-z0-9._-]+$");
        goto done;
    }

    oh_state_lock();
    OHAbility_PluginEntry *match = NULL;
    for (size_t i = 0; i < g_oh_state.plugin_count; i++) {
        if (strcmp(g_oh_state.plugins[i].id, plugin_id) == 0) {
            match = &g_oh_state.plugins[i];
            break;
        }
    }
    if (match == NULL) {
        oh_state_unlock();
        napi_throw_error(env, "oh_ability/not_found",
                         "no C plugin is registered for this bridge event");
        goto done;
    }
    OHAbility_PluginEntry entry = *match;
    oh_state_unlock();

    /* The handler runs inside the active N-API callback and must respond synchronously. */
    int rc = entry.plugin.on_sync_event(env, event, request_type, value, response_type, &result,
                                        entry.userdata);
    if (rc != OH_ABILITY_ERROR_OK || result == NULL) {
        napi_throw_error(env, "oh_ability/handler", "bridge sync event handler failed");
        result = NULL;
    } else {
        delivered = 1;
    }

done:
    free(plugin_id);
    free(event);
    free(request_type);
    free(response_type);
    (void)delivered;
    return result;
}

int OHAbility_SetBackPressInterceptor(OHAbility_BackPressFn fn, void *userdata) {
    if (fn == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    oh_state_lock();
    g_oh_state.back_press_fn = fn;
    g_oh_state.back_press_data = userdata;
    oh_state_unlock();
    return OH_ABILITY_ERROR_OK;
}

/* ------------------------------------------------------------------ */
/* Init context + saved state                                          */
/* ------------------------------------------------------------------ */

const char *OHAbility_GetBasePath(void) {
    oh_state_lock();
    const char *result = g_oh_state.base_path != NULL ? g_oh_state.base_path : "";
    /* Keep the pointer valid after unlock: these strings are only replaced on re-init. */
    const char *copy = result;
    oh_state_unlock();
    return copy;
}

const char *OHAbility_GetPrefPath(void) {
    oh_state_lock();
    const char *result = g_oh_state.pref_path != NULL ? g_oh_state.pref_path : "";
    oh_state_unlock();
    return result;
}

const char *OHAbility_GetPreferredLocales(void) {
    oh_state_lock();
    const char *result = g_oh_state.preferred_locales != NULL ? g_oh_state.preferred_locales : "";
    oh_state_unlock();
    return result;
}

const char *OHAbility_GetModuleName(void) {
    oh_state_lock();
    const char *result = g_oh_state.module_name != NULL ? g_oh_state.module_name : "";
    oh_state_unlock();
    return result;
}

NativeResourceManager *OHAbility_GetResourceManager(void) {
    oh_state_lock();
    NativeResourceManager *result = g_oh_state.resource_manager;
    oh_state_unlock();
    return result;
}

int OHAbility_SetSavedState(const char *state) {
    char *copy = oh_strdup(state);
    if (copy == NULL) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    oh_state_lock();
    free(g_oh_state.saved_state);
    g_oh_state.saved_state = copy;
    oh_state_unlock();
    return OH_ABILITY_ERROR_OK;
}

const char *OHAbility_GetSavedState(void) {
    oh_state_lock();
    const char *result = g_oh_state.saved_state != NULL ? g_oh_state.saved_state : "";
    oh_state_unlock();
    return result;
}

/* ------------------------------------------------------------------ */
/* Misc accessors                                                      */
/* ------------------------------------------------------------------ */

OHNativeWindow *OHAbility_GetNativeWindow(void) {
    oh_state_lock();
    OHNativeWindow *window = g_oh_state.native_window;
    oh_state_unlock();
    return window;
}

int OHAbility_SetFrameRate(int32_t min, int32_t max, int32_t preferred) {
    if (min < 0 || max < min || preferred < min || preferred > max) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    oh_state_lock();
    g_oh_state.frame_rate_min = min;
    g_oh_state.frame_rate_max = max;
    g_oh_state.frame_rate_preferred = preferred;
    g_oh_state.frame_rate_set = 1;
    OH_NativeXComponent *component = g_oh_state.mounted_component;
    oh_state_unlock();

    if (component != NULL) {
        oh_xc_apply_frame_rate(component);
    }
    return OH_ABILITY_ERROR_OK;
}

bool OHAbility_IsBridgeIdentifier(const char *value) {
    return oh_validate_identifier("value", value) != 0;
}

/* ------------------------------------------------------------------ */
/* Keyboard + wake (Rust OpenHarmonyApp::show_keyboard / create_waker) */
/* ------------------------------------------------------------------ */

int OHAbility_ShowKeyboard(void) {
#ifdef OH_ABILITY_ENABLE_IME
    oh_ime_show_keyboard();
    return OH_ABILITY_ERROR_OK;
#else
    return OH_ABILITY_ERROR_NOT_READY;
#endif
}

int OHAbility_HideKeyboard(void) {
#ifdef OH_ABILITY_ENABLE_IME
    oh_ime_hide_keyboard();
    return OH_ABILITY_ERROR_OK;
#else
    return OH_ABILITY_ERROR_NOT_READY;
#endif
}

int OHAbility_Wake(void) {
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_USER;
    oh_event_post(&event);
    return OH_ABILITY_ERROR_OK;
}

/* ------------------------------------------------------------------ */
/* Snapshots (Rust OpenHarmonyApp::config / content_rect /            */
/* window_rect / avoid_area / scale)                                   */
/* ------------------------------------------------------------------ */

int OHAbility_GetConfiguration(OHAbility_Configuration *out) {
    if (out == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    oh_state_lock();
    /* The string fields point into the framework snapshot: valid until the next configuration
     * update (or environment teardown), and only read from the main thread or event loop. */
    *out = g_oh_state.configuration;
    oh_state_unlock();
    return OH_ABILITY_ERROR_OK;
}

int OHAbility_GetContentRect(OHAbility_Rect *out) {
    if (out == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    oh_state_lock();
    *out = g_oh_state.content_rect;
    oh_state_unlock();
    return OH_ABILITY_ERROR_OK;
}

int OHAbility_GetWindowRect(OHAbility_Rect *out) {
    if (out == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    oh_state_lock();
    *out = g_oh_state.window_rect;
    oh_state_unlock();
    return OH_ABILITY_ERROR_OK;
}

bool OHAbility_GetAvoidArea(OHAbility_AvoidAreaType type, OHAbility_AvoidArea *out) {
    if (out == NULL) {
        return false;
    }
    int32_t index = (int32_t)type;
    if (index < 0 || index >= 5) {
        return false;
    }
    oh_state_lock();
    int present = g_oh_state.avoid_area_present[index];
    if (present) {
        *out = g_oh_state.avoid_areas[index];
    }
    oh_state_unlock();
    return present != 0;
}

float OHAbility_GetScale(void) {
#ifdef OH_ABILITY_ENABLE_DISPLAY
    float density = 1.0f;
    if (OH_NativeDisplayManager_GetDefaultDisplayScaledDensity(&density) != 0) {
        density = 1.0f;
    }
    return density;
#else
    return 1.0f;
#endif
}
