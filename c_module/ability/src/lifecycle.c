/*
 * `init` export: parses AbilityInitContext, resets the session state (ability recreation calls
 * init() again — NativeModuleLoader caches the Module instance process-wide), and assembles the
 * ApplicationLifecycle object consumed by NativeAbility. Also implements the 13 lifecycle
 * callbacks that translate ArkTS events into C plugin lifecycle notifications and app events.
 */
#include "oh_state.h"

#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Session reset (repeated init())                                    */
/* ------------------------------------------------------------------ */

static void oh_session_reset(void) {
    oh_state_lock();

    free(g_oh_state.base_path);
    free(g_oh_state.pref_path);
    free(g_oh_state.preferred_locales);
    free(g_oh_state.module_name);
    free(g_oh_state.saved_state);
    g_oh_state.base_path = NULL;
    g_oh_state.pref_path = NULL;
    g_oh_state.preferred_locales = NULL;
    g_oh_state.module_name = NULL;
    g_oh_state.saved_state = NULL;

    oh_configuration_free(&g_oh_state.configuration);
    memset(g_oh_state.avoid_area_present, 0, sizeof(g_oh_state.avoid_area_present));

    if (g_oh_state.resource_manager != NULL) {
        OH_ResourceManager_ReleaseNativeResourceManager(g_oh_state.resource_manager);
        g_oh_state.resource_manager = NULL;
    }

    g_oh_state.session_generation++;
    oh_state_unlock();

    /* The previous ability session's bridge bindings are dead: abort them now so the app
     * thread cannot call into a disposed BridgeHost between init and the next render. */
    oh_bindings_teardown();
}

/* ------------------------------------------------------------------ */
/* Common helpers                                                      */
/* ------------------------------------------------------------------ */

static napi_value oh_undefined(napi_env env) {
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}

static void oh_dispatch_plugin_lifecycle(const char *kind) {
    oh_plugins_dispatch_lifecycle(kind, 0, 0);
}

static napi_value oh_parse_rect(napi_env env, napi_value object, OHAbility_Rect *rect) {
    napi_value value;
    napi_get_named_property(env, object, "top", &value);
    napi_get_value_int32(env, value, &rect->top);
    napi_get_named_property(env, object, "left", &value);
    napi_get_value_int32(env, value, &rect->left);
    napi_get_named_property(env, object, "width", &value);
    napi_get_value_int32(env, value, &rect->width);
    napi_get_named_property(env, object, "height", &value);
    napi_get_value_int32(env, value, &rect->height);
    return oh_undefined(env);
}

/* ------------------------------------------------------------------ */
/* environmentCallback                                                 */
/* ------------------------------------------------------------------ */

static napi_value oh_napi_on_configuration_updated(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    OHAbility_Configuration config;
    oh_configuration_from_object(env, argc >= 1 ? args[0] : NULL, &config);

    /* Keep the framework snapshot (OHAbility_GetConfiguration) in sync. */
    oh_state_lock();
    oh_configuration_replace(&g_oh_state.configuration, &config);
    oh_state_unlock();

    oh_dispatch_plugin_lifecycle("configuration-updated");

    OHAbility_Event event;
    memset(&event, 0, sizeof(event));
    event.kind = OH_ABILITY_EVENT_CONFIG_CHANGED;
    event.data.config_changed.configuration = config;
    oh_event_post(&event);

    /* The queue deep-copied the string fields; release the parse-owned copies. */
    oh_configuration_free(&config);
    return oh_undefined(env);
}

static napi_value oh_napi_on_memory_level(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    int32_t level = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &level);
    }

    oh_state_lock();
    for (size_t i = 0; i < g_oh_state.plugin_count; i++) {
        OHAbility_PluginEntry *entry = &g_oh_state.plugins[i];
        if (entry->plugin.on_lifecycle != NULL) {
            OHAbility_LifecycleEvent event = {
                .kind = "memory-level",
                .memory_level = level,
            };
            entry->plugin.on_lifecycle(&event, entry->userdata);
        }
    }
    oh_state_unlock();

    OHAbility_Event event;
    memset(&event, 0, sizeof(event));
    event.kind = OH_ABILITY_EVENT_LOW_MEMORY;
    event.data.memory_level.level = level;
    oh_event_post(&event);
    return oh_undefined(env);
}

/* ------------------------------------------------------------------ */
/* windowStageEventCallback                                            */
/* ------------------------------------------------------------------ */

static napi_value oh_napi_on_window_stage_create(napi_env env, napi_callback_info info) {
    (void)info;
    oh_dispatch_plugin_lifecycle("window-stage-create");
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_WINDOW_CREATE;
    oh_event_post(&event);
    return oh_undefined(env);
}

static napi_value oh_napi_on_window_stage_destroy(napi_env env, napi_callback_info info) {
    (void)info;
    oh_dispatch_plugin_lifecycle("window-stage-destroy");
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_WINDOW_DESTROY;
    oh_event_post(&event);
    return oh_undefined(env);
}

static napi_value oh_napi_on_ability_create(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    oh_dispatch_plugin_lifecycle("ability-create");

    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_CREATE;
    oh_event_post(&event);
    (void)argc;
    (void)args;
    return oh_undefined(env);
}

static napi_value oh_napi_on_ability_destroy(napi_env env, napi_callback_info info) {
    (void)info;
    oh_dispatch_plugin_lifecycle("ability-destroy");
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_DESTROY;
    oh_event_post(&event);
    return oh_undefined(env);
}

/*
 * ArkTS calls onAbilitySaveState() synchronously while building the saved-state map, so this
 * must not block or wait for the application thread. It returns the saved-state slot that
 * business writes at any time via OHAbility_SetSavedState(); an empty string is returned when
 * nothing was saved yet. The SAVE_STATE app event is informational only.
 */
static napi_value oh_napi_on_ability_save_state(napi_env env, napi_callback_info info) {
    (void)info;
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_SAVE_STATE;
    oh_event_post(&event);

    oh_state_lock();
    const char *state = g_oh_state.saved_state != NULL ? g_oh_state.saved_state : "";
    napi_value result;
    napi_create_string_utf8(env, state, NAPI_AUTO_LENGTH, &result);
    oh_state_unlock();
    return result;
}

/* Parity with the Rust lifecycle object: the ArkTS host never calls this callback. */
static napi_value oh_napi_on_ability_restore_state(napi_env env, napi_callback_info info) {
    (void)info;
    oh_state_lock();
    const char *state = g_oh_state.saved_state != NULL ? g_oh_state.saved_state : "";
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_RESUME;
    event.data.resume.saved_state = state; /* deep-copied by the queue */
    oh_event_post(&event);
    oh_state_unlock();
    return oh_undefined(env);
}

/* Stage event mapping — mirrors crates/ability/src/stage/event.rs. */
static OHAbility_EventKind oh_stage_event_kind(int32_t event_type) {
    switch (event_type) {
    case 1: /* SHOWN */
        return OH_ABILITY_EVENT_START;
    case 2: /* ACTIVE */
        return OH_ABILITY_EVENT_GAINED_FOCUS;
    case 3: /* INACTIVE */
        return OH_ABILITY_EVENT_LOST_FOCUS;
    case 4: /* HIDDEN */
        return OH_ABILITY_EVENT_STOP;
    case 5: /* RESUMED */
        return OH_ABILITY_EVENT_RESUME;
    case 6: /* PAUSED */
        return OH_ABILITY_EVENT_PAUSE;
    default:
        return OH_ABILITY_EVENT_WINDOW_CREATE; /* unreachable; keeps the switch exhaustive */
    }
}

static napi_value oh_napi_on_window_stage_event(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    int32_t event_type = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &event_type);
    }

    oh_plugins_dispatch_lifecycle("window-stage-event", event_type, 0);

    OHAbility_Event event = {0};
    event.kind = oh_stage_event_kind(event_type);
    if (event.kind == OH_ABILITY_EVENT_RESUME) {
        oh_state_lock();
        event.data.resume.saved_state =
            g_oh_state.saved_state != NULL ? g_oh_state.saved_state : "";
        oh_state_unlock();
    }
    oh_event_post(&event);
    return oh_undefined(env);
}

static napi_value oh_napi_on_window_size_change(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_WINDOW_RESIZE;
    if (argc >= 1) {
        napi_value value;
        napi_get_named_property(env, args[0], "width", &value);
        napi_get_value_int32(env, value, &event.data.window_resize.size.width);
        napi_get_named_property(env, args[0], "height", &value);
        napi_get_value_int32(env, value, &event.data.window_resize.size.height);
    }
    oh_event_post(&event);
    return oh_undefined(env);
}

static napi_value oh_napi_on_window_rect_change(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_CONTENT_RECT_CHANGE;
    if (argc >= 1) {
        napi_value reason_value = NULL;
        napi_get_named_property(env, args[0], "reason", &reason_value);
        int32_t reason = 0;
        napi_get_value_int32(env, reason_value, &reason);
        event.data.content_rect.reason = (OHAbility_RectChangeReason)reason;

        napi_value rect = NULL;
        napi_get_named_property(env, args[0], "rect", &rect);
        oh_parse_rect(env, rect, &event.data.content_rect.rect);

        /* Keep the framework snapshot (OHAbility_GetWindowRect) in sync. */
        oh_state_lock();
        g_oh_state.window_rect = event.data.content_rect.rect;
        oh_state_unlock();
    }
    oh_event_post(&event);
    return oh_undefined(env);
}

static napi_value oh_parse_avoid_area(napi_env env, napi_value area, OHAbility_AvoidArea *out) {
    napi_value value;
    napi_get_named_property(env, area, "visible", &value);
    napi_get_value_bool(env, value, &out->visible);
    napi_get_named_property(env, area, "leftRect", &value);
    oh_parse_rect(env, value, &out->left_rect);
    napi_get_named_property(env, area, "topRect", &value);
    oh_parse_rect(env, value, &out->top_rect);
    napi_get_named_property(env, area, "rightRect", &value);
    oh_parse_rect(env, value, &out->right_rect);
    napi_get_named_property(env, area, "bottomRect", &value);
    oh_parse_rect(env, value, &out->bottom_rect);
    return oh_undefined(env);
}

static napi_value oh_napi_on_avoid_area_change(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_AVOID_AREA_CHANGE;
    if (argc >= 1) {
        napi_value type_value = NULL;
        napi_get_named_property(env, args[0], "type", &type_value);
        napi_get_value_int32(env, type_value, (int32_t *)&event.data.avoid_area.type);
        napi_value area = NULL;
        napi_get_named_property(env, args[0], "area", &area);
        oh_parse_avoid_area(env, area, &event.data.avoid_area.area);

        /* Keep the framework snapshot (OHAbility_GetAvoidArea) in sync. */
        int32_t type = (int32_t)event.data.avoid_area.type;
        if (type >= 0 && type < 5) {
            oh_state_lock();
            g_oh_state.avoid_areas[type] = event.data.avoid_area.area;
            g_oh_state.avoid_area_present[type] = 1;
            oh_state_unlock();
        }
    }
    oh_event_post(&event);
    return oh_undefined(env);
}

/* ------------------------------------------------------------------ */
/* keyboardEventCallback                                               */
/* ------------------------------------------------------------------ */

static napi_value oh_napi_on_keyboard_height_change(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    int32_t height = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &height);
    }

    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_KEYBOARD_HEIGHT_CHANGE;
    event.data.keyboard_height.height = height;
    oh_event_post(&event);
    return oh_undefined(env);
}

/* ------------------------------------------------------------------ */
/* init export                                                         */
/* ------------------------------------------------------------------ */

typedef struct OHAbility_CallbackEntry {
    const char *name;
    napi_callback callback;
} OHAbility_CallbackEntry;

static const OHAbility_CallbackEntry ENVIRONMENT_CALLBACKS[] = {
    {"onConfigurationUpdated", oh_napi_on_configuration_updated},
    {"onMemoryLevel", oh_napi_on_memory_level},
};

static const OHAbility_CallbackEntry WINDOW_STAGE_CALLBACKS[] = {
    {"onWindowStageCreate", oh_napi_on_window_stage_create},
    {"onWindowStageDestroy", oh_napi_on_window_stage_destroy},
    {"onAbilityCreate", oh_napi_on_ability_create},
    {"onAbilityDestroy", oh_napi_on_ability_destroy},
    {"onAbilitySaveState", oh_napi_on_ability_save_state},
    {"onAbilityRestoreState", oh_napi_on_ability_restore_state},
    {"onWindowStageEvent", oh_napi_on_window_stage_event},
    {"onWindowSizeChange", oh_napi_on_window_size_change},
    {"onWindowRectChange", oh_napi_on_window_rect_change},
    {"onAvoidAreaChange", oh_napi_on_avoid_area_change},
};

static const OHAbility_CallbackEntry KEYBOARD_CALLBACKS[] = {
    {"onKeyboardHeightChange", oh_napi_on_keyboard_height_change},
};

static napi_value oh_attach_callback_group(napi_env env, const OHAbility_CallbackEntry *table,
                                           size_t count) {
    napi_value group;
    napi_create_object(env, &group);

    for (size_t i = 0; i < count; i++) {
        napi_value fn;
        napi_create_function(env, table[i].name, NAPI_AUTO_LENGTH, table[i].callback, NULL, &fn);
        napi_set_named_property(env, group, table[i].name, fn);
    }

    return group;
}

napi_value oh_napi_init(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);

    oh_session_reset();

    /* Parse AbilityInitContext (optional; all fields may be absent). */
    if (argc >= 1) {
        napi_value value;
        if (napi_get_named_property(env, args[0], "basePath", &value) == napi_ok) {
            napi_valuetype type;
            napi_typeof(env, value, &type);
            if (type == napi_string) {
                char *base_path = oh_napi_get_string(env, value);
                oh_state_lock();
                g_oh_state.base_path = base_path;
                oh_state_unlock();
            }
        }
        if (napi_get_named_property(env, args[0], "prefPath", &value) == napi_ok) {
            napi_valuetype type;
            napi_typeof(env, value, &type);
            if (type == napi_string) {
                char *pref_path = oh_napi_get_string(env, value);
                oh_state_lock();
                g_oh_state.pref_path = pref_path;
                oh_state_unlock();
            }
        }
        if (napi_get_named_property(env, args[0], "preferredLocales", &value) == napi_ok) {
            napi_valuetype type;
            napi_typeof(env, value, &type);
            if (type == napi_string) {
                char *locales = oh_napi_get_string(env, value);
                oh_state_lock();
                g_oh_state.preferred_locales = locales;
                oh_state_unlock();
            }
        }
        if (napi_get_named_property(env, args[0], "moduleName", &value) == napi_ok) {
            napi_valuetype type;
            napi_typeof(env, value, &type);
            if (type == napi_string) {
                char *module_name = oh_napi_get_string(env, value);
                oh_state_lock();
                g_oh_state.module_name = module_name;
                oh_state_unlock();
            }
        }
        /* Defensive: the ArkTS host also pushes the resource manager through the ohos.resource
         * plugin on ability-create; converting it here too is cheap and gives business code a
         * valid handle even without registering that plugin. */
        if (napi_get_named_property(env, args[0], "resourceManager", &value) == napi_ok) {
            napi_valuetype type;
            napi_typeof(env, value, &type);
            if (type == napi_object) {
                NativeResourceManager *manager =
                    OH_ResourceManager_InitNativeResourceManager(env, value);
                if (manager != NULL) {
                    oh_state_lock();
                    g_oh_state.resource_manager = manager;
                    oh_state_unlock();
                }
            }
        }
    }

    /* Assemble ApplicationLifecycle: three callback groups. */
    napi_value lifecycle;
    napi_create_object(env, &lifecycle);

    napi_value environment =
        oh_attach_callback_group(env, ENVIRONMENT_CALLBACKS,
                                 sizeof(ENVIRONMENT_CALLBACKS) / sizeof(ENVIRONMENT_CALLBACKS[0]));
    napi_value window_stage = oh_attach_callback_group(env, WINDOW_STAGE_CALLBACKS,
                                                       sizeof(WINDOW_STAGE_CALLBACKS) /
                                                           sizeof(WINDOW_STAGE_CALLBACKS[0]));
    napi_value keyboard = oh_attach_callback_group(
        env, KEYBOARD_CALLBACKS, sizeof(KEYBOARD_CALLBACKS) / sizeof(KEYBOARD_CALLBACKS[0]));

    napi_set_named_property(env, lifecycle, "environmentCallback", environment);
    napi_set_named_property(env, lifecycle, "windowStageEventCallback", window_stage);
    napi_set_named_property(env, lifecycle, "keyboardEventCallback", keyboard);

    OHABILITY_LOG(LOG_INFO, "init: lifecycle object returned to ArkTS");
    return lifecycle;
}
