/*
 * Internal framework state shared by all oh_ability source files.
 * Not installed; consumers include only <oh_ability.h>.
 */
#ifndef OH_STATE_H
#define OH_STATE_H

#include "oh_ability.h"

#include <pthread.h>
#include <stdio.h>

/* Must precede arkui/native_node.h in this SDK (missing OH_PixelmapNative declaration). */
#include <multimedia/image_framework/image/pixelmap_native.h>

#include <arkui/native_interface.h>
#include <arkui/native_node.h>
#include <arkui/native_node_napi.h>
#include <hilog/log.h>
#include <native_window/external_window.h>

/* Opaque handle; the full ace/xcomponent/native_interface_xcomponent.h API is included only in
 * xcomponent.c. This SDK's header declares file-scope const variables (OH_MAX_TOUCH_POINTS_NUMBER
 * etc.), which duplicate across translation units when the header is included more than once. */
typedef struct OH_NativeXComponent OH_NativeXComponent;

#define OH_ABILITY_LOG_TAG "ohAbility"

/* LOG_APP domain from hilog/log.h; the module tag is our own. */
#define OHABILITY_LOG(level, fmt, ...)                                                             \
    OH_LOG_Print(LOG_APP, (level), 0xD002700, OH_ABILITY_LOG_TAG, fmt, ##__VA_ARGS__)

#define OHABILITY_QUEUE_CAPACITY 128
#define OHABILITY_MAX_PLUGINS 16
#define OHABILITY_MAX_STRING_LEN 128

/* Waiters for worker -> main-thread synchronous bridge calls.
 * refs starts at 2 (calling worker + completion side); the last release frees the waiter, so a
 * timed-out caller can never wake on freed memory and a late drain can never touch a freed one. */
typedef struct OHAbility_Waiter {
    uint64_t serial;
    int done;
    int status; /* OHAbility_Error completion status for the waiter */
    int refs;   /* guarded by mutex */
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    struct OHAbility_Waiter *next;
} OHAbility_Waiter;

/* One registered C plugin (ArkTS-originated events + lifecycle). */
typedef struct OHAbility_PluginEntry {
    char id[OHABILITY_MAX_STRING_LEN];
    OHAbility_Plugin plugin;
    void *userdata;
} OHAbility_PluginEntry;

typedef struct OHAbility_State {
    pthread_mutex_t lock; /* guards every field below; never held while calling user code */

    /* Module env: registered once, used for sync-call identity checks. */
    napi_env env;
    int cleanup_registered;

    /* Per-init (ability session) state. */
    uint64_t session_generation;
    char *base_path;
    char *pref_path;
    char *preferred_locales;
    char *module_name;
    NativeResourceManager *resource_manager;
    char *saved_state;

    /* Snapshot state, kept in sync with the Rust OpenHarmonyApp (app.config() / content_rect() /
     * window_rect() / avoid_area()). String fields of `configuration` are framework-owned and
     * replaced on every configuration update. Updated on the ArkTS main thread only. */
    OHAbility_Configuration configuration;
    OHAbility_Rect content_rect;
    OHAbility_Rect window_rect;
    OHAbility_AvoidArea avoid_areas[5];
    int avoid_area_present[5];

    /* Per-render (mount) state. */
    uint64_t mount_generation;
    OH_NativeXComponent *mounted_component; /* current mount; stale callbacks check identity */
    ArkUI_NodeHandle mounted_node;
    ArkUI_NodeContentHandle mounted_slot;
    OHNativeWindow *native_window;
    int32_t frame_rate_min;
    int32_t frame_rate_max;
    int32_t frame_rate_preferred;
    int frame_rate_set;

    /* Bridge bindings (replaced on every render). */
    napi_threadsafe_function invoke_tsfn;      /* bridgeInvoke (async + promise) */
    napi_threadsafe_function invoke_sync_tsfn; /* bridgeInvokeSync from worker threads */
    napi_threadsafe_function dispatch_tsfn;    /* bridgeDispatch main-thread scheduler */
    napi_ref invoke_sync_ref;                  /* main-thread borrow of bridgeInvokeSync */
    pthread_t bindings_thread;                 /* thread that created the bindings */
    int bindings_valid;

    /* Application loop. */
    OHAbility_AppCallbacks app_callbacks;
    int app_callbacks_valid;
    int app_thread_started;
    pthread_t app_thread;
    int quit_requested;
    int quit_result;

    /* Back press interceptor. */
    OHAbility_BackPressFn back_press_fn;
    void *back_press_data;

    /* Event ring queue (deep-copied entries; strings freed after AppEvent returns). */
    OHAbility_Event queue[OHABILITY_QUEUE_CAPACITY];
    size_t queue_head;
    size_t queue_tail;
    size_t queue_count;
    pthread_cond_t event_cond;

    /* Worker sync waiters. */
    OHAbility_Waiter *waiters;
    uint64_t next_serial;

    /* Registered C plugins. */
    OHAbility_PluginEntry plugins[OHABILITY_MAX_PLUGINS];
    size_t plugin_count;
} OHAbility_State;

extern OHAbility_State g_oh_state;

void oh_state_lock(void);
void oh_state_unlock(void);

/* Copies `src` into a malloc'd buffer ("" when NULL). Caller frees. */
char *oh_strdup(const char *src);

/* True when `value` is a valid bridge identifier (^[A-Za-z0-9._-]+$). */
int oh_validate_identifier(const char *label, const char *value);

/* N-API string -> malloc'd UTF-8 ("" on failure). Caller frees. */
char *oh_napi_get_string(napi_env env, napi_value value);

/* Event queue. */
void oh_event_post(const OHAbility_Event *event);
int oh_event_try_pop_batch(OHAbility_Event *out, size_t capacity);
void oh_event_free_strings(OHAbility_Event *event);

/* Application thread lifecycle. */
void oh_app_maybe_start(void);
void oh_app_request_quit(int result);
void oh_app_join(void);

/* Bridge internals. */
napi_threadsafe_function oh_bridge_invoke_tsfn(void);
napi_threadsafe_function oh_bridge_invoke_sync_tsfn(void);
napi_threadsafe_function oh_bridge_dispatch_tsfn(void);
napi_ref oh_bridge_invoke_sync_ref(void);
int oh_bridge_validate_env(napi_env env);

/* Serial waiters. */
OHAbility_Waiter *oh_waiter_create(void);
void oh_waiter_wait(OHAbility_Waiter *waiter, uint32_t timeout_ms);
void oh_waiter_signal(OHAbility_Waiter *waiter, int status);
void oh_waiter_release(OHAbility_Waiter *waiter);
void oh_waiter_abort_all(int status);

/* Lifecycle dispatch to registered C plugins (main thread). */
void oh_plugins_dispatch_lifecycle(const char *kind, int32_t window_stage_event,
                                   int32_t memory_level);

/* N-API module exports (declared here; implemented across the framework files). */
napi_value oh_napi_init(napi_env env, napi_callback_info info);                 /* lifecycle.c */
napi_value oh_napi_render(napi_env env, napi_callback_info info);               /* xcomponent.c */
napi_value oh_napi_on_bridge_sync_event(napi_env env, napi_callback_info info); /* registry.c */

/* Bridge bindings teardown/replacement (module.c / lifecycle.c / xcomponent.c). */
void oh_bindings_teardown(void);
void oh_bindings_replace(napi_env env, napi_value bindings);

/* Configuration object parsing (configuration.c). */
int oh_configuration_from_object(napi_env env, napi_value object, OHAbility_Configuration *out);
void oh_configuration_free(OHAbility_Configuration *config);
void oh_configuration_replace(OHAbility_Configuration *snapshot,
                              const OHAbility_Configuration *fresh);

/* IME attach/detach (surface lifecycle); only when OH_ABILITY_ENABLE_IME is defined. */
#ifdef OH_ABILITY_ENABLE_IME
void oh_ime_attach(void);
void oh_ime_detach(void);
void oh_ime_show_keyboard(void);
void oh_ime_hide_keyboard(void);
#endif

/* XComponent current mount state accessors. */
OH_NativeXComponent *oh_xc_current_component(void);
void oh_xc_apply_frame_rate(OH_NativeXComponent *component);

#endif /* OH_STATE_H */
