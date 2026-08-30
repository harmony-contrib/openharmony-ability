/*
 * C plugin registry: module-agnostic declarations, context-gated lifecycle replay, and the
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
    const uint32_t valid_contexts = OH_ABILITY_PLUGIN_CONTEXT_ABILITY |
                                    OH_ABILITY_PLUGIN_CONTEXT_WINDOW_STAGE |
                                    OH_ABILITY_PLUGIN_CONTEXT_UI;
    if ((plugin->execution != OH_ABILITY_PLUGIN_ASYNC &&
         plugin->execution != OH_ABILITY_PLUGIN_SYNC_MAIN_THREAD) ||
        (plugin->required_contexts & ~valid_contexts) != 0) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }

    oh_state_lock();
    if (g_oh_state.plugins_frozen) {
        oh_state_unlock();
        return OH_ABILITY_ERROR_NOT_READY;
    }
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
    entry->activated = 0;
    oh_state_unlock();

    OHABILITY_LOG(LOG_INFO, "plugin registered: %s (%s)", plugin_id,
                  plugin->execution == OH_ABILITY_PLUGIN_ASYNC ? "async" : "sync-main-thread");
    return OH_ABILITY_ERROR_OK;
}

static int oh_plugin_contexts_ready(uint32_t requirements) {
    return ((requirements & OH_ABILITY_PLUGIN_CONTEXT_ABILITY) == 0 || g_oh_state.ability_ready) &&
           ((requirements & OH_ABILITY_PLUGIN_CONTEXT_WINDOW_STAGE) == 0 ||
            g_oh_state.window_stage_ready) &&
           ((requirements & OH_ABILITY_PLUGIN_CONTEXT_UI) == 0 || g_oh_state.ui_context_ready);
}

static void oh_observe_lifecycle(const char *kind) {
    if (strcmp(kind, "ability-create") == 0) {
        g_oh_state.ability_ready = 1;
    } else if (strcmp(kind, "ability-destroy") == 0) {
        g_oh_state.ability_ready = 0;
        g_oh_state.window_stage_ready = 0;
        g_oh_state.ui_context_ready = 0;
    } else if (strcmp(kind, "window-stage-create") == 0) {
        g_oh_state.window_stage_ready = 1;
    } else if (strcmp(kind, "window-stage-destroy") == 0) {
        g_oh_state.window_stage_ready = 0;
        g_oh_state.ui_context_ready = 0;
    } else if (strcmp(kind, "ui-context-ready") == 0) {
        g_oh_state.ui_context_ready = 1;
    } else if (strcmp(kind, "ui-context-destroy") == 0) {
        g_oh_state.ui_context_ready = 0;
    }
}

typedef struct OHAbility_LifecycleDelivery {
    void (*callback)(const OHAbility_LifecycleEvent *event, void *userdata);
    void *userdata;
    OHAbility_LifecycleEvent event;
} OHAbility_LifecycleDelivery;

void oh_plugins_dispatch_lifecycle(const char *kind, int32_t window_stage_event,
                                   int32_t memory_level) {
    if (kind == NULL) {
        return;
    }

    OHAbility_LifecycleDelivery deliveries[OHABILITY_MAX_PLUGINS * OHABILITY_MAX_LIFECYCLE_HISTORY];
    size_t delivery_count = 0;

    oh_state_lock();
    if (strcmp(kind, "ability-create") == 0) {
        g_oh_state.plugin_session_active = 1;
        g_oh_state.ability_ready = 0;
        g_oh_state.window_stage_ready = 0;
        g_oh_state.ui_context_ready = 0;
        g_oh_state.lifecycle_history_count = 0;
        for (size_t i = 0; i < g_oh_state.plugin_count; i++) {
            g_oh_state.plugins[i].activated = 0;
        }
    } else if (!g_oh_state.plugin_session_active) {
        oh_state_unlock();
        return;
    }

    oh_observe_lifecycle(kind);
    OHAbility_LifecycleEvent event = {
        .kind = kind,
        .restored_state = strcmp(kind, "ability-create") == 0
                              ? (g_oh_state.restored_state != NULL ? g_oh_state.restored_state : "")
                              : NULL,
        .window_stage_event = window_stage_event,
        .memory_level = memory_level,
    };

    if (g_oh_state.lifecycle_history_count >= OHABILITY_MAX_LIFECYCLE_HISTORY) {
        size_t drop = g_oh_state.lifecycle_history_count > 1 ? 1 : 0;
        for (size_t i = 0; i < g_oh_state.lifecycle_history_count; i++) {
            const char *recorded_kind = g_oh_state.lifecycle_history[i].kind;
            if (strcmp(recorded_kind, "configuration-updated") == 0 ||
                strcmp(recorded_kind, "memory-level") == 0 ||
                strcmp(recorded_kind, "window-stage-event") == 0) {
                drop = i;
                break;
            }
        }
        memmove(&g_oh_state.lifecycle_history[drop], &g_oh_state.lifecycle_history[drop + 1],
                (g_oh_state.lifecycle_history_count - drop - 1) * sizeof(OHAbility_LifecycleEvent));
        g_oh_state.lifecycle_history_count--;
    }
    g_oh_state.lifecycle_history[g_oh_state.lifecycle_history_count++] = event;

    for (size_t i = 0; i < g_oh_state.plugin_count; i++) {
        OHAbility_PluginEntry *entry = &g_oh_state.plugins[i];
        if (entry->plugin.on_lifecycle == NULL) {
            if (!entry->activated && oh_plugin_contexts_ready(entry->plugin.required_contexts)) {
                entry->activated = 1;
            }
            continue;
        }
        size_t begin = g_oh_state.lifecycle_history_count - 1;
        if (!entry->activated && oh_plugin_contexts_ready(entry->plugin.required_contexts)) {
            entry->activated = 1;
            begin = 0;
        } else if (!entry->activated) {
            continue;
        }
        for (size_t history = begin; history < g_oh_state.lifecycle_history_count; history++) {
            deliveries[delivery_count++] = (OHAbility_LifecycleDelivery){
                .callback = entry->plugin.on_lifecycle,
                .userdata = entry->userdata,
                .event = g_oh_state.lifecycle_history[history],
            };
        }
    }

    if (strcmp(kind, "ability-destroy") == 0) {
        g_oh_state.plugin_session_active = 0;
        g_oh_state.lifecycle_history_count = 0;
        for (size_t i = 0; i < g_oh_state.plugin_count; i++) {
            g_oh_state.plugins[i].activated = 0;
        }
    }
    oh_state_unlock();

    for (size_t i = 0; i < delivery_count; i++) {
        deliveries[i].callback(&deliveries[i].event, deliveries[i].userdata);
    }
}

napi_value oh_plugins_declarations(napi_env env) {
    OHAbility_PluginEntry entries[OHABILITY_MAX_PLUGINS];
    size_t count;
    oh_state_lock();
    g_oh_state.plugins_frozen = 1;
    count = g_oh_state.plugin_count;
    memcpy(entries, g_oh_state.plugins, count * sizeof(OHAbility_PluginEntry));
    oh_state_unlock();

    for (size_t i = 1; i < count; i++) {
        OHAbility_PluginEntry entry = entries[i];
        size_t j = i;
        while (j > 0 && strcmp(entries[j - 1].id, entry.id) > 0) {
            entries[j] = entries[j - 1];
            j--;
        }
        entries[j] = entry;
    }

    napi_value declarations;
    napi_create_array_with_length(env, count, &declarations);
    for (size_t i = 0; i < count; i++) {
        napi_value declaration;
        napi_value value;
        napi_create_object(env, &declaration);
        napi_create_string_utf8(env, entries[i].id, NAPI_AUTO_LENGTH, &value);
        napi_set_named_property(env, declaration, "id", value);
        const char *execution =
            entries[i].plugin.execution == OH_ABILITY_PLUGIN_ASYNC ? "async" : "sync-main-thread";
        napi_create_string_utf8(env, execution, NAPI_AUTO_LENGTH, &value);
        napi_set_named_property(env, declaration, "execution", value);

        napi_value requirements;
        napi_create_array(env, &requirements);
        uint32_t requirement_index = 0;
        static const struct {
            uint32_t bit;
            const char *name;
        } contexts[] = {
            {OH_ABILITY_PLUGIN_CONTEXT_ABILITY, "ability"},
            {OH_ABILITY_PLUGIN_CONTEXT_WINDOW_STAGE, "window-stage"},
            {OH_ABILITY_PLUGIN_CONTEXT_UI, "ui-context"},
        };
        for (size_t context = 0; context < sizeof(contexts) / sizeof(contexts[0]); context++) {
            if ((entries[i].plugin.required_contexts & contexts[context].bit) == 0) {
                continue;
            }
            napi_create_string_utf8(env, contexts[context].name, NAPI_AUTO_LENGTH, &value);
            napi_set_element(env, requirements, requirement_index++, value);
        }
        napi_set_named_property(env, declaration, "requires", requirements);
        napi_set_element(env, declarations, (uint32_t)i, declaration);
    }
    return declarations;
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
    uint32_t requirements = entry.plugin.required_contexts_for_event != NULL
                                ? entry.plugin.required_contexts_for_event(event, entry.userdata)
                                : entry.plugin.required_contexts;
    int ready = g_oh_state.plugin_session_active && oh_plugin_contexts_ready(requirements);
    oh_state_unlock();

    if (!ready) {
        napi_throw_error(env, "oh_ability/not_ready",
                         "C plugin received an event before its required context was ready");
        goto done;
    }
    if (entry.plugin.on_sync_event == NULL) {
        napi_throw_error(env, "oh_ability/not_found",
                         "C plugin does not support main-thread events");
        goto done;
    }

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
