/*
 * Pure C demo native module (libdemo_native.so).
 *
 * It reuses the `demo_native` module name and the exact export surface of the Rust demo
 * (types/libdemo_native/Index.d.ts), so the demo app is unchanged: swap the .so and the same
 * Index page runs against a pure C backend. Every demo* export is a thin wrapper around the
 * oh_ability bridge (OHAbility_CallAsync / CallAsyncPromise / CallSync / CallSyncFromWorker).
 *
 * The module also demonstrates the SDL-style application model: AppInit/AppIterate/AppEvent/
 * AppQuit callbacks run on a dedicated application thread that starts when the XComponent
 * surface is created, and a C plugin ("ohos.resource") answers the ArkTS-pushed resource
 * manager event.
 */
#include <stdio.h>
#include <string.h>

#include <hilog/log.h>
#include <napi/native_api.h>

#include "demo_common.h"
#include "plugin_app_control.h"
#include "plugin_resource.h"
#include "plugin_webview.h"
#include "plugin_window.h"

#define DEMO_TAG "ohosCDemo"
#define DEMO_LOG(level, fmt, ...)                                                                  \
    OH_LOG_Print(LOG_APP, (level), 0xD002701, DEMO_TAG, fmt, ##__VA_ARGS__)

/* Defined below. */
int demo_register_app_callbacks(void);

/* Registers every C plugin; each is gated by its OH_ABILITY_PLUGIN_* macro inside its own
 * directory under src/plugins/. */
static int demo_register_plugins(void) {
    int rc = demo_register_resource_plugin();
    if (rc != OH_ABILITY_ERROR_OK) {
        return rc;
    }
    rc = demo_register_webview_plugin();
    if (rc != OH_ABILITY_ERROR_OK) {
        return rc;
    }
    rc = demo_register_window_plugin();
    if (rc != OH_ABILITY_ERROR_OK) {
        return rc;
    }
    return demo_register_app_control_plugin();
}

/* ------------------------------------------------------------------ */
/* Application callbacks (SDL-style entry model)                      */
/* ------------------------------------------------------------------ */

static int demo_app_init(void **appstate, int argc, char **argv) {
    (void)argc;
    (void)argv;
    *appstate = NULL;
    DEMO_LOG(LOG_INFO, "app init (application thread started)");
    return 0;
}

static void demo_app_iterate(void *appstate) {
    static int tick;
    (void)appstate;
    if ((++tick % 120) == 0) {
        DEMO_LOG(LOG_INFO, "app iterate tick %d", tick);
    }
}

static const char *demo_event_name(OHAbility_EventKind kind) {
    static const char *const names[] = {
        "WindowCreate",
        "WindowDestroy",
        "Start",
        "GainedFocus",
        "LostFocus",
        "Resume",
        "Pause",
        "Stop",
        "Create",
        "Destroy",
        "SaveState",
        "LowMemory",
        "ConfigChanged",
        "WindowResize",
        "ContentRectChange",
        "AvoidAreaChange",
        "SurfaceCreated",
        "SurfaceChanged",
        "SurfaceDestroyed",
        "WindowRedraw",
        "InputTouch",
        "InputKey",
        "InputMouse",
        "InputHover",
        "ImeTextInput",
        "ImeBackspace",
        "ImeStatus",
        "ImeEnter",
        "KeyboardHeightChange",
        "User",
    };
    if ((size_t)kind < sizeof(names) / sizeof(names[0])) {
        return names[kind];
    }
    return "Unknown";
}

static void demo_app_event(void *appstate, const OHAbility_Event *event) {
    (void)appstate;
    switch (event->kind) {
    case OH_ABILITY_EVENT_SURFACE_CREATED:
    case OH_ABILITY_EVENT_SURFACE_CHANGED:
        DEMO_LOG(LOG_INFO, "event %s: %ux%u at (%d,%d)", demo_event_name(event->kind),
                 event->data.surface.width, event->data.surface.height,
                 event->data.surface.offset_x, event->data.surface.offset_y);
        break;
    case OH_ABILITY_EVENT_INPUT_TOUCH: {
        const OHAbility_TouchEvent *touch = &event->data.input_touch.touch;
        for (uint32_t i = 0; i < touch->num_points && i < OH_ABILITY_MAX_TOUCH_POINTS; i++) {
            const OHAbility_TouchPoint *p = &touch->points[i];
            DEMO_LOG(LOG_INFO, "event InputTouch: id=%d type=%d at (%.1f,%.1f)", p->id,
                     (int)p->type, p->x, p->y);
        }
        break;
    }
    case OH_ABILITY_EVENT_IME_TEXT_INPUT:
        DEMO_LOG(LOG_INFO, "event ImeTextInput: '%s'", event->data.ime_text_input.text_input.text);
        break;
    case OH_ABILITY_EVENT_IME_STATUS:
        DEMO_LOG(LOG_INFO, "event ImeStatus: %d", (int)event->data.ime_status.status.status);
        break;
    case OH_ABILITY_EVENT_IME_BACKSPACE:
        DEMO_LOG(LOG_INFO, "event ImeBackspace: %d", event->data.ime_backspace.backspace.length);
        break;
    case OH_ABILITY_EVENT_IME_ENTER:
        DEMO_LOG(LOG_INFO, "event ImeEnter: %d", event->data.ime_enter.enter.key);
        break;
    case OH_ABILITY_EVENT_CONFIG_CHANGED:
        DEMO_LOG(LOG_INFO, "event ConfigChanged: lang=%s colorMode=%d direction=%d",
                 event->data.config_changed.configuration.language,
                 (int)event->data.config_changed.configuration.color_mode,
                 (int)event->data.config_changed.configuration.direction);
        break;
    case OH_ABILITY_EVENT_RESUME:
        DEMO_LOG(LOG_INFO, "event Resume: savedState='%s'",
                 event->data.resume.saved_state != NULL ? event->data.resume.saved_state : "");
        break;
    default:
        DEMO_LOG(LOG_INFO, "event %s", demo_event_name(event->kind));
        break;
    }
}

static void demo_app_quit(void *appstate, int result) {
    (void)appstate;
    DEMO_LOG(LOG_INFO, "app quit (result=%d)", result);
}

int demo_register_app_callbacks(void) {
    static const OHAbility_AppCallbacks callbacks = {
        .init = demo_app_init,
        .iterate = demo_app_iterate,
        .event = demo_app_event,
        .quit = demo_app_quit,
    };
    return OHAbility_StartApp(&callbacks);
}

/* ------------------------------------------------------------------ */
/* NAPI module glue                                                    */
/* ------------------------------------------------------------------ */

static napi_value DemoModuleInit(napi_env env, napi_value exports) {
    int rc = OHAbility_RegisterModule(env, exports);
    if (rc != OH_ABILITY_ERROR_OK) {
        DEMO_LOG(LOG_ERROR, "OHAbility_RegisterModule failed: %d", rc);
    }

    if (demo_register_plugins() != OH_ABILITY_ERROR_OK) {
        DEMO_LOG(LOG_ERROR, "failed to register demo C plugins");
    }

    if (demo_register_exported_functions(env, exports) != OH_ABILITY_ERROR_OK) {
        DEMO_LOG(LOG_ERROR, "failed to register demo exports");
    }

    /* The application thread starts when the first XComponent surface is created. */
    if (demo_register_app_callbacks() != OH_ABILITY_ERROR_OK) {
        DEMO_LOG(LOG_ERROR, "failed to register app callbacks");
    }

    DEMO_LOG(LOG_INFO, "demo module initialized (moduleName=%s)", OHAbility_GetModuleName());
    return exports;
}

static napi_module demo_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = DemoModuleInit,
    .nm_modname = "demo_native",
    .nm_priv = NULL,
    .reserved = {0},
};

__attribute__((constructor)) static void RegisterDemoModule(void) {
    napi_module_register(&demo_module);
}
