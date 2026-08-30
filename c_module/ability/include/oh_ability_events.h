/*
 * Pure C event surface for the openharmony-ability bridge.
 *
 * Events are delivered to the application thread via `OHAbility_AppEvent` (see oh_ability.h).
 * String fields are owned by the framework: they are deep-copied when the event is posted and
 * freed after the handler returns. Applications must not retain pointers into an event.
 *
 * Numeric values mirror the Rust `openharmony-ability` crate (`crates/ability`) so a business
 * code base can switch between the C and Rust frameworks without re-mapping event semantics.
 */
#ifndef OH_ABILITY_EVENTS_H
#define OH_ABILITY_EVENTS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/* window.AvoidAreaType — mirrors crates/ability/src/area/avoid.rs    */
/* ------------------------------------------------------------------ */
typedef enum OHAbility_AvoidAreaType {
    OH_ABILITY_AVOID_AREA_SYSTEM = 0,
    OH_ABILITY_AVOID_AREA_CUTOUT = 1,
    OH_ABILITY_AVOID_AREA_SYSTEM_GESTURE = 2,
    OH_ABILITY_AVOID_AREA_KEYBOARD = 3,
    OH_ABILITY_AVOID_AREA_NAVIGATION_INDICATOR = 4,
} OHAbility_AvoidAreaType;

/* window.RectChangeOptions.reason — mirrors area/rect_reason.rs */
typedef enum OHAbility_RectChangeReason {
    OH_ABILITY_RECT_REASON_UNDEFINED = 0,
    OH_ABILITY_RECT_REASON_MAXIMIZE = 1,
    OH_ABILITY_RECT_REASON_RECOVER = 2,
    OH_ABILITY_RECT_REASON_MOVE = 3,
    OH_ABILITY_RECT_REASON_DRAG = 4,
    OH_ABILITY_RECT_REASON_DRAG_START = 5,
    OH_ABILITY_RECT_REASON_DRAG_END = 6,
} OHAbility_RectChangeReason;

/* Configuration enums — mirror configuration/{color_mode,direction,screen_density}.rs */
typedef enum OHAbility_ColorMode {
    OH_ABILITY_COLOR_MODE_NO_SET = -1,
    OH_ABILITY_COLOR_MODE_DARK = 0,
    OH_ABILITY_COLOR_MODE_LIGHT = 1,
} OHAbility_ColorMode;

typedef enum OHAbility_Direction {
    OH_ABILITY_DIRECTION_NO_SET = -1,
    OH_ABILITY_DIRECTION_VERTICAL = 0,
    OH_ABILITY_DIRECTION_HORIZONTAL = 1,
} OHAbility_Direction;

typedef enum OHAbility_ScreenDensity {
    OH_ABILITY_SCREEN_DENSITY_NO_SET = 0,
    OH_ABILITY_SCREEN_DENSITY_SDPI = 120,
    OH_ABILITY_SCREEN_DENSITY_MDPI = 160,
    OH_ABILITY_SCREEN_DENSITY_LDPI = 240,
    OH_ABILITY_SCREEN_DENSITY_XLDPI = 320,
    OH_ABILITY_SCREEN_DENSITY_XXLDPI = 480,
    OH_ABILITY_SCREEN_DENSITY_XXXLDPI = 640,
} OHAbility_ScreenDensity;

/* ------------------------------------------------------------------ */
/* Value types                                                         */
/* ------------------------------------------------------------------ */

typedef struct OHAbility_Rect {
    int32_t top;
    int32_t left;
    int32_t width;
    int32_t height;
} OHAbility_Rect;

typedef struct OHAbility_Size {
    int32_t width;
    int32_t height;
} OHAbility_Size;

typedef struct OHAbility_AvoidArea {
    bool visible;
    OHAbility_Rect left_rect;
    OHAbility_Rect top_rect;
    OHAbility_Rect right_rect;
    OHAbility_Rect bottom_rect;
} OHAbility_AvoidArea;

/* onConfigurationUpdated payload — mirrors Configuration in configuration/config.rs */
typedef struct OHAbility_Configuration {
    const char *language;
    OHAbility_ColorMode color_mode;
    OHAbility_Direction direction;
    OHAbility_ScreenDensity screen_density;
    int32_t display_id;
    bool has_pointer_device;
    double font_size_scale;
    double font_weight_scale;
    const char *mcc;
    const char *mnc;
} OHAbility_Configuration;

/* XComponent frame callback — mirrors IntervalInfo in draw/mod.rs */
typedef struct OHAbility_IntervalInfo {
    int64_t time_stamp;
    int64_t target_time_stamp;
} OHAbility_IntervalInfo;

/* XComponent touch event — values mirror ace/xcomponent/native_interface_xcomponent.h */
typedef enum OHAbility_TouchType {
    OH_ABILITY_TOUCH_DOWN = 0,
    OH_ABILITY_TOUCH_UP = 1,
    OH_ABILITY_TOUCH_MOVE = 2,
    OH_ABILITY_TOUCH_CANCEL = 3,
    OH_ABILITY_TOUCH_UNKNOWN = 4,
} OHAbility_TouchType;

typedef struct OHAbility_TouchPoint {
    int32_t id;
    float screen_x;
    float screen_y;
    float x;
    float y;
    OHAbility_TouchType type;
    double size;
    float force;
    int64_t time_stamp;
    float tilt_x;
    float tilt_y;
} OHAbility_TouchPoint;

#define OH_ABILITY_MAX_TOUCH_POINTS 16

typedef struct OHAbility_TouchEvent {
    int32_t device_id;
    uint32_t num_points;
    OHAbility_TouchPoint points[OH_ABILITY_MAX_TOUCH_POINTS];
} OHAbility_TouchEvent;

/* XComponent key event — values mirror OH_NativeXComponent_KeyEvent */
typedef enum OHAbility_KeyAction {
    OH_ABILITY_KEY_ACTION_DOWN = 0,
    OH_ABILITY_KEY_ACTION_UP = 1,
} OHAbility_KeyAction;

typedef struct OHAbility_KeyEvent {
    OHAbility_KeyAction action;
    int32_t code;
    int32_t unicode_char;
    int32_t device_id;
    int64_t time_stamp;
} OHAbility_KeyEvent;

/* XComponent mouse event — values mirror OH_NativeXComponent_MouseEvent */
typedef enum OHAbility_MouseAction {
    OH_ABILITY_MOUSE_NONE = 0,
    OH_ABILITY_MOUSE_PRESS = 1,
    OH_ABILITY_MOUSE_RELEASE = 2,
    OH_ABILITY_MOUSE_MOVE = 3,
    OH_ABILITY_MOUSE_CANCEL = 4,
} OHAbility_MouseAction;

typedef enum OHAbility_MouseButton {
    OH_ABILITY_MOUSE_NONE_BUTTON = 0,
    OH_ABILITY_MOUSE_LEFT_BUTTON = 0x01,
    OH_ABILITY_MOUSE_RIGHT_BUTTON = 0x02,
    OH_ABILITY_MOUSE_MIDDLE_BUTTON = 0x04,
    OH_ABILITY_MOUSE_BACK_BUTTON = 0x08,
    OH_ABILITY_MOUSE_FORWARD_BUTTON = 0x10,
} OHAbility_MouseButton;

typedef struct OHAbility_MouseEvent {
    float x;
    float y;
    float screen_x;
    float screen_y;
    int64_t timestamp;
    OHAbility_MouseAction action;
    OHAbility_MouseButton button;
} OHAbility_MouseEvent;

/* Owned ArkUI pointer metadata used by axis and semantic gesture events. Raw integer values
 * mirror the corresponding ArkUI_UIInputEvent enums so newer platform values remain observable. */
typedef struct OHAbility_ArkUIPointerEvent {
    int32_t event_type;
    int32_t action;
    int32_t source_type;
    int32_t tool_type;
    float x;
    float y;
    float window_x;
    float window_y;
    float display_x;
    float display_y;
    int64_t time_stamp;
    uint32_t pointer_count;
    int32_t pointer_id;
    bool has_pointer_id;
} OHAbility_ArkUIPointerEvent;

typedef struct OHAbility_AxisEvent {
    OHAbility_ArkUIPointerEvent pointer;
    double delta_x;
    double delta_y;
} OHAbility_AxisEvent;

typedef enum OHAbility_GesturePhase {
    OH_ABILITY_GESTURE_START = 0,
    OH_ABILITY_GESTURE_UPDATE = 1,
    OH_ABILITY_GESTURE_END = 2,
    OH_ABILITY_GESTURE_CANCEL = 3,
} OHAbility_GesturePhase;

typedef struct OHAbility_TapGestureEvent {
    OHAbility_ArkUIPointerEvent pointer;
} OHAbility_TapGestureEvent;

typedef struct OHAbility_PanGestureEvent {
    OHAbility_ArkUIPointerEvent pointer;
    OHAbility_GesturePhase phase;
    float delta_x;
    float delta_y;
    float offset_x;
    float offset_y;
    float velocity;
    float velocity_x;
    float velocity_y;
} OHAbility_PanGestureEvent;

typedef struct OHAbility_SwipeGestureEvent {
    OHAbility_ArkUIPointerEvent pointer;
    OHAbility_GesturePhase phase;
    float angle;
    float velocity;
} OHAbility_SwipeGestureEvent;

/* IME status — mirrors ohos-ime-binding KeyboardStatus */
typedef enum OHAbility_ImeStatus {
    OH_ABILITY_IME_STATUS_NONE = 0,
    OH_ABILITY_IME_STATUS_HIDE = 1,
    OH_ABILITY_IME_STATUS_SHOW = 2,
} OHAbility_ImeStatus;

/* IME insert-text / backspace / enter payloads */
typedef struct OHAbility_ImeTextInputEvent {
    const char *text; /* UTF-8; framework-owned, valid until the handler returns */
} OHAbility_ImeTextInputEvent;

typedef struct OHAbility_ImeBackspaceEvent {
    int32_t length;
} OHAbility_ImeBackspaceEvent;

typedef struct OHAbility_ImeStatusEvent {
    OHAbility_ImeStatus status;
} OHAbility_ImeStatusEvent;

/* Enter key of the IME action — raw InputMethod_EnterKey value (0=RETURN) */
typedef struct OHAbility_ImeEnterEvent {
    int32_t key;
} OHAbility_ImeEnterEvent;

/* ------------------------------------------------------------------ */
/* Event                                                               */
/* ------------------------------------------------------------------ */

typedef enum OHAbility_EventKind {
    /* window stage lifecycle — alias onWindowStageCreate/Destroy */
    OH_ABILITY_EVENT_WINDOW_CREATE,
    OH_ABILITY_EVENT_WINDOW_DESTROY,

    /* window.on("windowStageEvent") — SHOWN/ACTIVE/INACTIVE/HIDDEN/RESUMED/PAUSED */
    OH_ABILITY_EVENT_START,
    OH_ABILITY_EVENT_GAINED_FOCUS,
    OH_ABILITY_EVENT_LOST_FOCUS,
    OH_ABILITY_EVENT_RESUME,
    OH_ABILITY_EVENT_PAUSE,
    OH_ABILITY_EVENT_STOP,

    /* ability lifecycle — alias onAbilityCreate/onAbilityDestroy */
    OH_ABILITY_EVENT_CREATE,
    OH_ABILITY_EVENT_DESTROY,

    /* ability save state — alias onAbilitySaveState.
     * Informational only: the framework reads the saved-state slot synchronously and returns it
     * to ArkTS. Business writes the slot with OHAbility_SetSavedState(). */
    OH_ABILITY_EVENT_SAVE_STATE,

    /* environment callbacks — alias onMemoryLevel / onConfigurationUpdated */
    OH_ABILITY_EVENT_LOW_MEMORY,
    OH_ABILITY_EVENT_CONFIG_CHANGED,

    /* window.on("windowSizeChange") / ("windowRectChange") / ("avoidAreaChange") */
    OH_ABILITY_EVENT_WINDOW_RESIZE,
    OH_ABILITY_EVENT_CONTENT_RECT_CHANGE,
    OH_ABILITY_EVENT_AVOID_AREA_CHANGE,

    /* XComponent surface */
    OH_ABILITY_EVENT_SURFACE_CREATED,
    OH_ABILITY_EVENT_SURFACE_CHANGED,
    OH_ABILITY_EVENT_SURFACE_DESTROYED,

    /* XComponent frame callback */
    OH_ABILITY_EVENT_WINDOW_REDRAW,

    /* XComponent input */
    OH_ABILITY_EVENT_INPUT_TOUCH,
    OH_ABILITY_EVENT_INPUT_KEY,
    OH_ABILITY_EVENT_INPUT_MOUSE,
    OH_ABILITY_EVENT_INPUT_HOVER,

    /* ArkUI axis input and system-recognized touch gestures. */
    OH_ABILITY_EVENT_INPUT_AXIS,
    OH_ABILITY_EVENT_GESTURE_TAP,
    OH_ABILITY_EVENT_GESTURE_PAN,
    OH_ABILITY_EVENT_GESTURE_SWIPE,

    /* IME */
    OH_ABILITY_EVENT_IME_TEXT_INPUT,
    OH_ABILITY_EVENT_IME_BACKSPACE,
    OH_ABILITY_EVENT_IME_STATUS,
    OH_ABILITY_EVENT_IME_ENTER,

    /* window.on("keyboardHeightChange") */
    OH_ABILITY_EVENT_KEYBOARD_HEIGHT_CHANGE,

    /* Framework-internal wakeup (business may post it via OHAbility_PostEvent). */
    OH_ABILITY_EVENT_USER,
} OHAbility_EventKind;

typedef struct OHAbility_Event {
    OHAbility_EventKind kind;
    union {
        /* OH_ABILITY_EVENT_WINDOW_STAGE_* family carries no payload. */
        struct {
            int32_t level;
        } memory_level;
        struct {
            OHAbility_Configuration configuration;
        } config_changed;
        struct {
            OHAbility_Size size;
        } window_resize;
        struct {
            OHAbility_RectChangeReason reason;
            OHAbility_Rect rect;
        } content_rect;
        struct {
            OHAbility_AvoidAreaType type;
            OHAbility_AvoidArea area;
        } avoid_area;
        struct {
            uint32_t width;
            uint32_t height;
            int32_t offset_x;
            int32_t offset_y;
        } surface;
        struct {
            OHAbility_IntervalInfo interval;
        } window_redraw;
        struct {
            OHAbility_TouchEvent touch;
        } input_touch;
        struct {
            OHAbility_KeyEvent key;
        } input_key;
        struct {
            OHAbility_MouseEvent mouse;
        } input_mouse;
        /* The OHOS XComponent hover callback only reports enter/leave (no coordinates). */
        struct {
            bool entered;
        } input_hover;
        struct {
            OHAbility_AxisEvent axis;
        } input_axis;
        struct {
            OHAbility_TapGestureEvent tap;
        } gesture_tap;
        struct {
            OHAbility_PanGestureEvent pan;
        } gesture_pan;
        struct {
            OHAbility_SwipeGestureEvent swipe;
        } gesture_swipe;
        struct {
            OHAbility_ImeTextInputEvent text_input;
        } ime_text_input;
        struct {
            OHAbility_ImeBackspaceEvent backspace;
        } ime_backspace;
        struct {
            OHAbility_ImeStatusEvent status;
        } ime_status;
        struct {
            OHAbility_ImeEnterEvent enter;
        } ime_enter;
        struct {
            int32_t height;
        } keyboard_height;
        /* OH_ABILITY_EVENT_RESUME: saved-state snapshot at resume time. Framework-owned string. */
        struct {
            const char *saved_state;
        } resume;
    } data;
} OHAbility_Event;

#ifdef __cplusplus
}
#endif

#endif /* OH_ABILITY_EVENTS_H */
