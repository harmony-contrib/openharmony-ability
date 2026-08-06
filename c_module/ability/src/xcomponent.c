/*
 * `render` export + XComponent mount: creates the native XComponent node through the ArkUI
 * native node API, registers surface/input callbacks before mounting (so the initial
 * OnSurfaceCreated cannot be missed), and converts callbacks into app events.
 *
 * Multi-window semantics (v1): every render() mounts its own XComponent into its NodeContent,
 * but only the latest mount generation delivers events; callbacks from older mounts are dropped
 * by component identity. The application thread starts once, on the first surface.
 */
#include "oh_state.h"

#include <stdlib.h>
#include <string.h>

/* The only translation unit that includes this header: this SDK's copy declares file-scope
 * const variables (OH_MAX_TOUCH_POINTS_NUMBER, OH_XCOMPONENT_ID_LEN_MAX) that duplicate across
 * TUs when included more than once. */
#include <ace/xcomponent/native_interface_xcomponent.h>

static ArkUI_NativeNodeAPI_1 *oh_node_api(void) {
    static ArkUI_NativeNodeAPI_1 *api;
    if (api == NULL) {
        OH_ArkUI_GetModuleInterface(ARKUI_NATIVE_NODE, ArkUI_NativeNodeAPI_1, api);
    }
    return api;
}

static int oh_is_current_mount(OH_NativeXComponent *component) {
    oh_state_lock();
    int current = g_oh_state.mounted_component == component;
    oh_state_unlock();
    return current;
}

/* ------------------------------------------------------------------ */
/* Surface callbacks                                                   */
/* ------------------------------------------------------------------ */

static void oh_on_surface_created(OH_NativeXComponent *component, void *window) {
    if (!oh_is_current_mount(component)) {
        return;
    }

    uint64_t width = 0;
    uint64_t height = 0;
    double offset_x = 0;
    double offset_y = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    OH_NativeXComponent_GetXComponentOffset(component, window, &offset_x, &offset_y);
    OHAbility_Rect rect = {
        .left = (int32_t)offset_x,
        .top = (int32_t)offset_y,
        .width = (int32_t)width,
        .height = (int32_t)height,
    };

    oh_state_lock();
    g_oh_state.native_window = (OHNativeWindow *)window;
    g_oh_state.content_rect = rect;
    oh_state_unlock();

    OHABILITY_LOG(LOG_INFO, "surface created: %dx%d at (%d,%d)", rect.width, rect.height, rect.left,
                  rect.top);

    oh_app_maybe_start();
#ifdef OH_ABILITY_ENABLE_IME
    oh_ime_attach();
#endif

    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_SURFACE_CREATED;
    event.data.surface.width = (uint32_t)rect.width;
    event.data.surface.height = (uint32_t)rect.height;
    event.data.surface.offset_x = rect.left;
    event.data.surface.offset_y = rect.top;
    oh_event_post(&event);
}

static void oh_on_surface_changed(OH_NativeXComponent *component, void *window) {
    if (!oh_is_current_mount(component)) {
        return;
    }

    uint64_t width = 0;
    uint64_t height = 0;
    double offset_x = 0;
    double offset_y = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    OH_NativeXComponent_GetXComponentOffset(component, window, &offset_x, &offset_y);
    OHAbility_Rect rect = {
        .left = (int32_t)offset_x,
        .top = (int32_t)offset_y,
        .width = (int32_t)width,
        .height = (int32_t)height,
    };

    oh_state_lock();
    g_oh_state.content_rect = rect;
    oh_state_unlock();

    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_SURFACE_CHANGED;
    event.data.surface.width = (uint32_t)rect.width;
    event.data.surface.height = (uint32_t)rect.height;
    event.data.surface.offset_x = rect.left;
    event.data.surface.offset_y = rect.top;
    oh_event_post(&event);
}

static void oh_on_surface_destroyed(OH_NativeXComponent *component, void *window) {
    (void)window;
    if (!oh_is_current_mount(component)) {
        return;
    }

#ifdef OH_ABILITY_ENABLE_IME
    oh_ime_detach();
#endif

    oh_state_lock();
    g_oh_state.native_window = NULL;
    oh_state_unlock();

    OHABILITY_LOG(LOG_INFO, "surface destroyed");
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_SURFACE_DESTROYED;
    oh_event_post(&event);
}

/* ------------------------------------------------------------------ */
/* Input callbacks                                                     */
/* ------------------------------------------------------------------ */

static void oh_on_touch_event(OH_NativeXComponent *component, void *window) {
    if (!oh_is_current_mount(component)) {
        return;
    }

    OH_NativeXComponent_TouchEvent touch;
    memset(&touch, 0, sizeof(touch));
    if (OH_NativeXComponent_GetTouchEvent(component, window, &touch) != 0) {
        return;
    }

    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_INPUT_TOUCH;
    OHAbility_TouchEvent *out = &event.data.input_touch.touch;
    out->device_id = touch.deviceId;

    if (touch.numPoints > 0) {
        uint32_t count = touch.numPoints < OH_ABILITY_MAX_TOUCH_POINTS
                             ? touch.numPoints
                             : OH_ABILITY_MAX_TOUCH_POINTS;
        for (uint32_t i = 0; i < count; i++) {
            const OH_NativeXComponent_TouchPoint *point = &touch.touchPoints[i];
            out->points[i].id = point->id;
            out->points[i].screen_x = point->screenX;
            out->points[i].screen_y = point->screenY;
            out->points[i].x = point->x;
            out->points[i].y = point->y;
            out->points[i].type = (OHAbility_TouchType)point->type;
            out->points[i].size = point->size;
            out->points[i].force = point->force;
            out->points[i].time_stamp = point->timeStamp;
        }
        out->num_points = count;
    } else {
        /* Single-point fallback: the top-level fields of the event. */
        out->num_points = 1;
        out->points[0].id = touch.id;
        out->points[0].screen_x = touch.screenX;
        out->points[0].screen_y = touch.screenY;
        out->points[0].x = touch.x;
        out->points[0].y = touch.y;
        out->points[0].type = (OHAbility_TouchType)touch.type;
        out->points[0].size = touch.size;
        out->points[0].force = touch.force;
        out->points[0].time_stamp = touch.timeStamp;
    }
    oh_event_post(&event);
}

static void oh_on_key_event(OH_NativeXComponent *component, void *window) {
    (void)window;
    if (!oh_is_current_mount(component)) {
        return;
    }

    OH_NativeXComponent_KeyEvent *key = NULL;
    if (OH_NativeXComponent_GetKeyEvent(component, &key) != 0 || key == NULL) {
        return;
    }

    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_INPUT_KEY;
    OH_NativeXComponent_KeyAction action = OH_NATIVEXCOMPONENT_KEY_ACTION_DOWN;
    OH_NativeXComponent_KeyCode code = KEY_UNKNOWN;
    OH_NativeXComponent_GetKeyEventAction(key, &action);
    OH_NativeXComponent_GetKeyEventCode(key, &code);
    OH_NativeXComponent_GetKeyEventDeviceId(key, (int64_t *)&event.data.input_key.key.device_id);
    OH_NativeXComponent_GetKeyEventTimestamp(key, (int64_t *)&event.data.input_key.key.time_stamp);
    event.data.input_key.key.action = (OHAbility_KeyAction)action;
    event.data.input_key.key.code = (int32_t)code;
    oh_event_post(&event);
}

static void oh_on_mouse_event(OH_NativeXComponent *component, void *window) {
    if (!oh_is_current_mount(component)) {
        return;
    }

    OH_NativeXComponent_MouseEvent mouse;
    memset(&mouse, 0, sizeof(mouse));
    if (OH_NativeXComponent_GetMouseEvent(component, window, &mouse) != 0) {
        return;
    }

    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_INPUT_MOUSE;
    event.data.input_mouse.mouse.x = mouse.x;
    event.data.input_mouse.mouse.y = mouse.y;
    event.data.input_mouse.mouse.screen_x = mouse.screenX;
    event.data.input_mouse.mouse.screen_y = mouse.screenY;
    event.data.input_mouse.mouse.timestamp = mouse.timestamp;
    event.data.input_mouse.mouse.action = (OHAbility_MouseAction)mouse.action;
    event.data.input_mouse.mouse.button = (OHAbility_MouseButton)mouse.button;
    oh_event_post(&event);
}

static void oh_on_hover_event(OH_NativeXComponent *component, bool is_hover) {
    if (!oh_is_current_mount(component)) {
        return;
    }
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_INPUT_HOVER;
    event.data.input_hover.entered = is_hover;
    oh_event_post(&event);
}

static void oh_on_frame_callback(OH_NativeXComponent *component, uint64_t timestamp,
                                 uint64_t target_timestamp) {
    if (!oh_is_current_mount(component)) {
        return;
    }
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_WINDOW_REDRAW;
    event.data.window_redraw.interval.time_stamp = (int64_t)timestamp;
    event.data.window_redraw.interval.target_time_stamp = (int64_t)target_timestamp;
    oh_event_post(&event);
}

/* ------------------------------------------------------------------ */
/* Registration + frame rate                                           */
/* ------------------------------------------------------------------ */

static void oh_xc_register_callbacks(OH_NativeXComponent *component) {
    static OH_NativeXComponent_Callback callbacks = {
        .OnSurfaceCreated = oh_on_surface_created,
        .OnSurfaceChanged = oh_on_surface_changed,
        .OnSurfaceDestroyed = oh_on_surface_destroyed,
        .DispatchTouchEvent = oh_on_touch_event,
    };
    static OH_NativeXComponent_MouseEvent_Callback mouse_callbacks = {
        .DispatchMouseEvent = oh_on_mouse_event,
        .DispatchHoverEvent = oh_on_hover_event,
    };
    OH_NativeXComponent_RegisterCallback(component, &callbacks);
    OH_NativeXComponent_RegisterKeyEventCallback(component, oh_on_key_event);
    OH_NativeXComponent_RegisterMouseEventCallback(component, &mouse_callbacks);
    OH_NativeXComponent_RegisterOnFrameCallback(component, oh_on_frame_callback);
}

void oh_xc_apply_frame_rate(OH_NativeXComponent *component) {
    oh_state_lock();
    int set = g_oh_state.frame_rate_set;
    OH_NativeXComponent_ExpectedRateRange range = {
        .min = g_oh_state.frame_rate_min,
        .max = g_oh_state.frame_rate_max,
        .expected = g_oh_state.frame_rate_preferred,
    };
    oh_state_unlock();
    if (set) {
        OH_NativeXComponent_SetExpectedFrameRateRange(component, &range);
    }
}

OH_NativeXComponent *oh_xc_current_component(void) {
    oh_state_lock();
    OH_NativeXComponent *component = g_oh_state.mounted_component;
    oh_state_unlock();
    return component;
}

/* ------------------------------------------------------------------ */
/* render export                                                       */
/* ------------------------------------------------------------------ */

napi_value oh_napi_render(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {NULL, NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    if (argc < 2) {
        napi_throw_error(env, "oh_ability/argc", "render requires (bindings, slot)");
        return NULL;
    }

    napi_value bindings = args[0];
    napi_value slot = args[1];

    /* Replace the bridge transports first; the app thread may call them as soon as the surface
     * exists. */
    oh_bindings_replace(env, bindings);

    ArkUI_NativeNodeAPI_1 *node_api = oh_node_api();
    if (node_api == NULL) {
        napi_throw_error(env, "oh_ability/node", "ArkUI native node API is unavailable");
        return NULL;
    }

    /* Detach the previous mount (re-render / sub-window remount). */
    oh_state_lock();
    ArkUI_NodeHandle old_node = g_oh_state.mounted_node;
    ArkUI_NodeContentHandle old_slot = g_oh_state.mounted_slot;
    g_oh_state.mounted_node = NULL;
    g_oh_state.mounted_slot = NULL;
    g_oh_state.mounted_component = NULL;
    g_oh_state.native_window = NULL;
    g_oh_state.mount_generation++;
    oh_state_unlock();
    if (old_node != NULL && old_slot != NULL) {
        OH_ArkUI_NodeContent_RemoveNode(old_slot, old_node);
        node_api->disposeNode(old_node);
    }

    ArkUI_NodeContentHandle slot_handle = NULL;
    if (OH_ArkUI_GetNodeContentFromNapiValue(env, slot, &slot_handle) != 0 || slot_handle == NULL) {
        napi_throw_error(env, "oh_ability/node", "failed to resolve the NodeContent slot");
        return NULL;
    }

    ArkUI_NodeHandle node = node_api->createNode(ARKUI_NODE_XCOMPONENT);
    if (node == NULL) {
        napi_throw_error(env, "oh_ability/node", "failed to create the XComponent node");
        return NULL;
    }

    OH_NativeXComponent *component = OH_NativeXComponent_GetNativeXComponent(node);
    if (component == NULL) {
        node_api->disposeNode(node);
        napi_throw_error(env, "oh_ability/node", "failed to resolve the native XComponent");
        return NULL;
    }

    /* Register callbacks BEFORE mounting so the initial surface event cannot be missed. */
    oh_xc_register_callbacks(component);
    oh_xc_apply_frame_rate(component);

    oh_state_lock();
    g_oh_state.mounted_component = component;
    g_oh_state.mounted_node = node;
    g_oh_state.mounted_slot = slot_handle;
    oh_state_unlock();

    if (OH_ArkUI_NodeContent_AddNode(slot_handle, node) != 0) {
        napi_throw_error(env, "oh_ability/node", "failed to mount the XComponent node");
        return NULL;
    }

    OHABILITY_LOG(LOG_INFO, "render: XComponent mounted into slot");
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}
