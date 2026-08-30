/*
 * `render` export + XComponent mount: creates the native XComponent node through the ArkUI
 * native node API, registers surface/input callbacks before mounting (so the initial
 * OnSurfaceCreated cannot be missed), and converts callbacks into app events.
 *
 * One native module owns at most one active DefaultXComponent. A render owner token prevents
 * delayed cleanup from an old appearance from tearing down a replacement render. Multiple
 * components/windows use distinct native modules, matching the Rust framework contract.
 */
#include "oh_state.h"

#include <stdlib.h>
#include <string.h>

#include <arkui/ui_input_event.h>

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

static ArkUI_NativeGestureAPI_1 *oh_gesture_api(void) {
    static ArkUI_NativeGestureAPI_1 *api;
    if (api == NULL) {
        OH_ArkUI_GetModuleInterface(ARKUI_NATIVE_GESTURE, ArkUI_NativeGestureAPI_1, api);
    }
    return api;
}

static int oh_is_current_mount(OH_NativeXComponent *component) {
    oh_state_lock();
    int current = g_oh_state.mounted_component == component;
    oh_state_unlock();
    return current;
}

static int oh_is_current_node(ArkUI_NodeHandle node) {
    oh_state_lock();
    int current = g_oh_state.surface_active && g_oh_state.mounted_node == node;
    oh_state_unlock();
    return current;
}

static OHAbility_ArkUIPointerEvent oh_pointer_snapshot(const ArkUI_UIInputEvent *input) {
    OHAbility_ArkUIPointerEvent pointer = {0};
    if (input == NULL) {
        return pointer;
    }
    pointer.event_type = OH_ArkUI_UIInputEvent_GetType(input);
    pointer.action = OH_ArkUI_UIInputEvent_GetAction(input);
    pointer.source_type = OH_ArkUI_UIInputEvent_GetSourceType(input);
    pointer.tool_type = OH_ArkUI_UIInputEvent_GetToolType(input);
    pointer.x = OH_ArkUI_PointerEvent_GetX(input);
    pointer.y = OH_ArkUI_PointerEvent_GetY(input);
    pointer.window_x = OH_ArkUI_PointerEvent_GetWindowX(input);
    pointer.window_y = OH_ArkUI_PointerEvent_GetWindowY(input);
    pointer.display_x = OH_ArkUI_PointerEvent_GetDisplayX(input);
    pointer.display_y = OH_ArkUI_PointerEvent_GetDisplayY(input);
    pointer.time_stamp = OH_ArkUI_UIInputEvent_GetEventTime(input);
    pointer.pointer_count = OH_ArkUI_PointerEvent_GetPointerCount(input);
    if (pointer.pointer_count > 0) {
        pointer.pointer_id = OH_ArkUI_PointerEvent_GetPointerId(input, 0);
        pointer.has_pointer_id = true;
    }
    return pointer;
}

static int oh_gesture_phase(ArkUI_GestureEventActionType action, OHAbility_GesturePhase *phase) {
    if (action & GESTURE_EVENT_ACTION_ACCEPT) {
        *phase = OH_ABILITY_GESTURE_START;
    } else if (action & GESTURE_EVENT_ACTION_UPDATE) {
        *phase = OH_ABILITY_GESTURE_UPDATE;
    } else if (action & GESTURE_EVENT_ACTION_END) {
        *phase = OH_ABILITY_GESTURE_END;
    } else if (action & GESTURE_EVENT_ACTION_CANCEL) {
        *phase = OH_ABILITY_GESTURE_CANCEL;
    } else {
        return 0;
    }
    return 1;
}

static void oh_on_axis_node_event(ArkUI_NodeEvent *node_event) {
    if (node_event == NULL || OH_ArkUI_NodeEvent_GetEventType(node_event) != NODE_ON_AXIS) {
        return;
    }
    ArkUI_NodeHandle node = OH_ArkUI_NodeEvent_GetNodeHandle(node_event);
    if (!oh_is_current_node(node)) {
        return;
    }
    ArkUI_UIInputEvent *input = OH_ArkUI_NodeEvent_GetInputEvent(node_event);
    if (input == NULL) {
        return;
    }
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_INPUT_AXIS;
    event.data.input_axis.axis.pointer = oh_pointer_snapshot(input);
    event.data.input_axis.axis.delta_x = OH_ArkUI_AxisEvent_GetHorizontalAxisValue(input);
    event.data.input_axis.axis.delta_y = OH_ArkUI_AxisEvent_GetVerticalAxisValue(input);
    oh_event_post(&event);
}

static void oh_on_tap_gesture(ArkUI_GestureEvent *gesture_event, void *extra) {
    (void)extra;
    if (gesture_event == NULL) {
        return;
    }
    ArkUI_NodeHandle node = OH_ArkUI_GestureEvent_GetNode(gesture_event);
    if (!oh_is_current_node(node)) {
        return;
    }
    const ArkUI_UIInputEvent *input = OH_ArkUI_GestureEvent_GetRawInputEvent(gesture_event);
    if (input == NULL) {
        return;
    }
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_GESTURE_TAP;
    event.data.gesture_tap.tap.pointer = oh_pointer_snapshot(input);
    oh_event_post(&event);
}

static void oh_on_pan_gesture(ArkUI_GestureEvent *gesture_event, void *extra) {
    (void)extra;
    if (gesture_event == NULL) {
        return;
    }
    ArkUI_NodeHandle node = OH_ArkUI_GestureEvent_GetNode(gesture_event);
    OHAbility_GesturePhase phase;
    if (!oh_is_current_node(node) ||
        !oh_gesture_phase(OH_ArkUI_GestureEvent_GetActionType(gesture_event), &phase)) {
        return;
    }
    const ArkUI_UIInputEvent *input = OH_ArkUI_GestureEvent_GetRawInputEvent(gesture_event);
    if (input == NULL) {
        return;
    }
    float offset_x = OH_ArkUI_PanGesture_GetOffsetX(gesture_event);
    float offset_y = OH_ArkUI_PanGesture_GetOffsetY(gesture_event);
    float delta_x = 0.0f;
    float delta_y = 0.0f;
    oh_state_lock();
    if (phase != OH_ABILITY_GESTURE_CANCEL) {
        delta_x = offset_x - (g_oh_state.pan_has_previous ? g_oh_state.pan_previous_x : 0.0f);
        delta_y = offset_y - (g_oh_state.pan_has_previous ? g_oh_state.pan_previous_y : 0.0f);
        g_oh_state.pan_previous_x = offset_x;
        g_oh_state.pan_previous_y = offset_y;
        g_oh_state.pan_has_previous = phase != OH_ABILITY_GESTURE_END;
    } else {
        g_oh_state.pan_has_previous = 0;
    }
    oh_state_unlock();

    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_GESTURE_PAN;
    event.data.gesture_pan.pan.pointer = oh_pointer_snapshot(input);
    event.data.gesture_pan.pan.phase = phase;
    event.data.gesture_pan.pan.delta_x = delta_x;
    event.data.gesture_pan.pan.delta_y = delta_y;
    event.data.gesture_pan.pan.offset_x = offset_x;
    event.data.gesture_pan.pan.offset_y = offset_y;
    event.data.gesture_pan.pan.velocity = OH_ArkUI_PanGesture_GetVelocity(gesture_event);
    event.data.gesture_pan.pan.velocity_x = OH_ArkUI_PanGesture_GetVelocityX(gesture_event);
    event.data.gesture_pan.pan.velocity_y = OH_ArkUI_PanGesture_GetVelocityY(gesture_event);
    oh_event_post(&event);
}

static void oh_on_swipe_gesture(ArkUI_GestureEvent *gesture_event, void *extra) {
    (void)extra;
    if (gesture_event == NULL) {
        return;
    }
    ArkUI_NodeHandle node = OH_ArkUI_GestureEvent_GetNode(gesture_event);
    OHAbility_GesturePhase phase;
    if (!oh_is_current_node(node) ||
        !oh_gesture_phase(OH_ArkUI_GestureEvent_GetActionType(gesture_event), &phase)) {
        return;
    }
    const ArkUI_UIInputEvent *input = OH_ArkUI_GestureEvent_GetRawInputEvent(gesture_event);
    if (input == NULL) {
        return;
    }
    OHAbility_Event event = {0};
    event.kind = OH_ABILITY_EVENT_GESTURE_SWIPE;
    event.data.gesture_swipe.swipe.pointer = oh_pointer_snapshot(input);
    event.data.gesture_swipe.swipe.phase = phase;
    event.data.gesture_swipe.swipe.angle = OH_ArkUI_SwipeGesture_GetAngle(gesture_event);
    event.data.gesture_swipe.swipe.velocity = OH_ArkUI_SwipeGesture_GetVelocity(gesture_event);
    oh_event_post(&event);
}

static int oh_register_arkui_input(ArkUI_NodeHandle node) {
    ArkUI_NativeNodeAPI_1 *node_api = oh_node_api();
    if (node_api == NULL || node_api->registerNodeEvent == NULL ||
        node_api->addNodeEventReceiver == NULL) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    if (node_api->registerNodeEvent(node, NODE_ON_AXIS, 0, NULL) != 0) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    if (node_api->addNodeEventReceiver(node, oh_on_axis_node_event) != 0) {
        if (node_api->unregisterNodeEvent != NULL) {
            node_api->unregisterNodeEvent(node, NODE_ON_AXIS);
        }
        return OH_ABILITY_ERROR_BRIDGE;
    }
    oh_state_lock();
    g_oh_state.axis_event_registered = 1;
    OHAbility_TouchInputDelivery delivery = g_oh_state.touch_input_delivery;
    oh_state_unlock();
    if (delivery == OH_ABILITY_TOUCH_INPUT_RAW_XCOMPONENT) {
        return OH_ABILITY_ERROR_OK;
    }

    ArkUI_NativeGestureAPI_1 *gesture_api = oh_gesture_api();
    if (gesture_api == NULL) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    ArkUI_GestureRecognizer *gestures[3] = {
        gesture_api->createTapGesture(1, 1),
        gesture_api->createPanGesture(1, GESTURE_DIRECTION_ALL, 8.0),
        gesture_api->createSwipeGesture(1, GESTURE_DIRECTION_ALL, 100.0),
    };
    const ArkUI_GestureEventActionTypeMask all_actions =
        GESTURE_EVENT_ACTION_ACCEPT | GESTURE_EVENT_ACTION_UPDATE | GESTURE_EVENT_ACTION_END |
        GESTURE_EVENT_ACTION_CANCEL;
    void (*receivers[3])(ArkUI_GestureEvent *, void *) = {
        oh_on_tap_gesture,
        oh_on_pan_gesture,
        oh_on_swipe_gesture,
    };
    ArkUI_GestureEventActionTypeMask masks[3] = {GESTURE_EVENT_ACTION_ACCEPT, all_actions,
                                                 all_actions};
    size_t registered = 0;
    for (size_t i = 0; i < 3; i++) {
        if (gestures[i] == NULL ||
            gesture_api->setGestureEventTarget(gestures[i], masks[i], NULL, receivers[i]) != 0 ||
            gesture_api->addGestureToNode(node, gestures[i], NORMAL, NORMAL_GESTURE_MASK) != 0) {
            for (size_t j = 0; j < 3; j++) {
                if (gestures[j] != NULL) {
                    if (j < registered) {
                        gesture_api->removeGestureFromNode(node, gestures[j]);
                    }
                    gesture_api->dispose(gestures[j]);
                }
            }
            return OH_ABILITY_ERROR_BRIDGE;
        }
        registered++;
    }
    oh_state_lock();
    memcpy(g_oh_state.gestures, gestures, sizeof(gestures));
    g_oh_state.gesture_count = 3;
    oh_state_unlock();
    return OH_ABILITY_ERROR_OK;
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
    if (g_oh_state.surface_active) {
        oh_state_unlock();
        return;
    }
    g_oh_state.native_window = (OHNativeWindow *)window;
    g_oh_state.content_rect = rect;
    g_oh_state.surface_active = 1;
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
    g_oh_state.content_rect = (OHAbility_Rect){0};
    g_oh_state.surface_active = 0;
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
    oh_state_lock();
    OHAbility_TouchInputDelivery delivery = g_oh_state.touch_input_delivery;
    oh_state_unlock();
    if (delivery == OH_ABILITY_TOUCH_INPUT_ARKUI_GESTURES) {
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

int OHAbility_SetTouchInputDelivery(OHAbility_TouchInputDelivery delivery) {
    if (delivery != OH_ABILITY_TOUCH_INPUT_RAW_XCOMPONENT &&
        delivery != OH_ABILITY_TOUCH_INPUT_ARKUI_GESTURES &&
        delivery != OH_ABILITY_TOUCH_INPUT_BOTH) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    oh_state_lock();
    if (g_oh_state.render_owner != NULL) {
        oh_state_unlock();
        return OH_ABILITY_ERROR_NOT_READY;
    }
    g_oh_state.touch_input_delivery = delivery;
    oh_state_unlock();
    return OH_ABILITY_ERROR_OK;
}

OHAbility_TouchInputDelivery OHAbility_GetTouchInputDelivery(void) {
    oh_state_lock();
    OHAbility_TouchInputDelivery delivery = g_oh_state.touch_input_delivery;
    oh_state_unlock();
    return delivery;
}

/* ------------------------------------------------------------------ */
/* render export                                                       */
/* ------------------------------------------------------------------ */

static void oh_release_render(napi_env env, const char *owner, int release_all) {
    ArkUI_NativeNodeAPI_1 *node_api = oh_node_api();
    oh_state_lock();
    int owns = g_oh_state.render_owner != NULL &&
               (release_all || (owner != NULL && strcmp(g_oh_state.render_owner, owner) == 0));
    if (!owns) {
        oh_state_unlock();
        return;
    }
    ArkUI_NodeHandle node = g_oh_state.mounted_node;
    ArkUI_NodeContentHandle slot = g_oh_state.mounted_slot;
    int surface_was_active = g_oh_state.surface_active;
    ArkUI_GestureRecognizer *gestures[3] = {NULL, NULL, NULL};
    size_t gesture_count = g_oh_state.gesture_count;
    memcpy(gestures, g_oh_state.gestures, sizeof(gestures));
    int axis_event_registered = g_oh_state.axis_event_registered;
    free(g_oh_state.render_owner);
    g_oh_state.render_owner = NULL;
    g_oh_state.mounted_node = NULL;
    g_oh_state.mounted_slot = NULL;
    g_oh_state.mounted_component = NULL;
    g_oh_state.native_window = NULL;
    g_oh_state.surface_active = 0;
    memset(g_oh_state.gestures, 0, sizeof(g_oh_state.gestures));
    g_oh_state.gesture_count = 0;
    g_oh_state.axis_event_registered = 0;
    g_oh_state.pan_has_previous = 0;
    g_oh_state.content_rect = (OHAbility_Rect){0};
    g_oh_state.window_rect = (OHAbility_Rect){0};
    memset(g_oh_state.avoid_area_present, 0, sizeof(g_oh_state.avoid_area_present));
    g_oh_state.mount_generation++;
    oh_state_unlock();

#ifdef OH_ABILITY_ENABLE_IME
    oh_ime_detach();
#endif
    if (node != NULL && node_api != NULL && axis_event_registered) {
        if (node_api->unregisterNodeEvent != NULL) {
            node_api->unregisterNodeEvent(node, NODE_ON_AXIS);
        }
        if (node_api->removeNodeEventReceiver != NULL) {
            node_api->removeNodeEventReceiver(node, oh_on_axis_node_event);
        }
    }
    ArkUI_NativeGestureAPI_1 *gesture_api = oh_gesture_api();
    if (node != NULL && gesture_api != NULL) {
        for (size_t i = 0; i < gesture_count; i++) {
            if (gestures[i] != NULL) {
                gesture_api->removeGestureFromNode(node, gestures[i]);
                gesture_api->dispose(gestures[i]);
            }
        }
    }
    if (node != NULL && slot != NULL) {
        OH_ArkUI_NodeContent_RemoveNode(slot, node);
    }
    if (node != NULL && node_api != NULL) {
        node_api->disposeNode(node);
    }
    if (surface_was_active) {
        OHAbility_Event event = {0};
        event.kind = OH_ABILITY_EVENT_SURFACE_DESTROYED;
        oh_event_post(&event);
    }
    (void)env;
}

napi_value oh_napi_render(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {NULL, NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    if (argc < 2) {
        napi_throw_error(env, "oh_ability/argc", "render requires (slot, renderOwner)");
        return NULL;
    }

    napi_value slot = args[0];
    char *render_owner = oh_napi_get_string(env, args[1]);
    if (render_owner == NULL || render_owner[0] == '\0') {
        free(render_owner);
        napi_throw_error(env, "oh_ability/owner", "renderOwner must not be empty");
        return NULL;
    }

    oh_state_lock();
    int bridge_active = g_oh_state.bridge_owner != NULL && g_oh_state.bindings_valid;
    int render_active = g_oh_state.render_owner != NULL;
    if (bridge_active && !render_active) {
        g_oh_state.render_owner = render_owner;
    }
    oh_state_unlock();
    if (!bridge_active) {
        free(render_owner);
        napi_throw_error(env, "oh_ability/not_ready",
                         "a DefaultXComponent cannot render outside an active Ability session");
        return NULL;
    }
    if (render_active) {
        free(render_owner);
        napi_throw_error(env, "oh_ability/owner",
                         "this native module is already rendered; use a distinct module");
        return NULL;
    }

    ArkUI_NativeNodeAPI_1 *node_api = oh_node_api();
    if (node_api == NULL) {
        oh_release_render(env, render_owner, 0);
        napi_throw_error(env, "oh_ability/node", "ArkUI native node API is unavailable");
        return NULL;
    }

    ArkUI_NodeContentHandle slot_handle = NULL;
    if (OH_ArkUI_GetNodeContentFromNapiValue(env, slot, &slot_handle) != 0 || slot_handle == NULL) {
        oh_release_render(env, render_owner, 0);
        napi_throw_error(env, "oh_ability/node", "failed to resolve the NodeContent slot");
        return NULL;
    }

    ArkUI_NodeHandle node = node_api->createNode(ARKUI_NODE_XCOMPONENT);
    if (node == NULL) {
        oh_release_render(env, render_owner, 0);
        napi_throw_error(env, "oh_ability/node", "failed to create the XComponent node");
        return NULL;
    }

    OH_NativeXComponent *component = OH_NativeXComponent_GetNativeXComponent(node);
    if (component == NULL) {
        node_api->disposeNode(node);
        oh_release_render(env, render_owner, 0);
        napi_throw_error(env, "oh_ability/node", "failed to resolve the native XComponent");
        return NULL;
    }

    /* Register callbacks BEFORE mounting so the initial surface event cannot be missed. */
    oh_xc_register_callbacks(component);
    oh_xc_apply_frame_rate(component);
    ArkUI_NumberValue background = {.u32 = 0x00000000};
    ArkUI_AttributeItem background_item = {
        .value = &background,
        .size = 1,
    };
    node_api->setAttribute(node, NODE_BACKGROUND_COLOR, &background_item);

    oh_state_lock();
    g_oh_state.mounted_component = component;
    g_oh_state.mounted_node = node;
    g_oh_state.mounted_slot = slot_handle;
    oh_state_unlock();

    if (oh_register_arkui_input(node) != OH_ABILITY_ERROR_OK) {
        oh_release_render(env, render_owner, 0);
        napi_throw_error(env, "oh_ability/input", "failed to attach ArkUI axis or gesture input");
        return NULL;
    }

    if (OH_ArkUI_NodeContent_AddNode(slot_handle, node) != 0) {
        oh_release_render(env, render_owner, 0);
        napi_throw_error(env, "oh_ability/node", "failed to mount the XComponent node");
        return NULL;
    }

    OHABILITY_LOG(LOG_INFO, "render: XComponent mounted into slot");
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value oh_napi_dispose_render(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    napi_get_cb_info(env, info, &argc, args, NULL, NULL);
    if (argc >= 1) {
        char *owner = oh_napi_get_string(env, args[0]);
        oh_release_render(env, owner, 0);
        free(owner);
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value oh_napi_dispose_all_renders(napi_env env, napi_callback_info info) {
    (void)info;
    oh_release_render(env, NULL, 1);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

void oh_render_cleanup(napi_env env) { oh_release_render(env, NULL, 1); }
