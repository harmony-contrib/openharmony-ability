/*
 * Pure C framework for hosting business code inside the `@ohos-rs/ability` ArkTS package.
 *
 * The ArkTS host (`NativeAbility` + `DefaultXComponent`) loads one native module per session and
 * drives it through five N-API exports. This library implements that contract in C99 and exposes
 * an SDL-style application model on top:
 *
 *   1. The business NAPI module calls `OHAbility_RegisterModule()` from its module init.
 *   2. `init(context)` -> the framework returns the lifecycle callback object to ArkTS.
 *   3. `render(bindings, slot)` -> the framework keeps the bridge functions, mounts the
 *      XComponent, and starts the application thread once a surface exists.
 *   4. The application thread runs `AppInit` once, then `AppEvent`/`AppIterate` in a loop
 *      (SDL_AppInit / SDL_AppEvent / SDL_AppIterate / SDL_AppQuit model).
 *
 * Threading rules (non-negotiable):
 *   - N-API values never cross threads and never live in long-lived storage.
 * `OHAbility_ValueBuilder` and `OHAbility_ValueResponder` callbacks run on the ArkTS main thread
 * with a live `napi_env`.
 *   - `OHAbility_CallAsync` may be called from any thread; it returns immediately.
 *   - `OHAbility_CallSync` may only be called from inside an N-API callback on the main thread.
 *   - `OHAbility_CallSyncFromWorker` may only be called from a non-main thread; it blocks until the
 *     responder (main thread) has consumed the result.
 *   - Events delivered to `AppEvent` own their string fields only for the duration of the call.
 *
 * The library is written in C99 with no C++ ABI dependency.
 */
#ifndef OH_ABILITY_H
#define OH_ABILITY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <napi/native_api.h>
#include <native_window/external_window.h>

/* RawFile C API declarations.
 *
 * Declared manually instead of including <rawfile/raw_file_manager.h>: this SDK's raw_file.h
 * contains two unguarded C++-only prototypes (deprecated API 8 functions taking references) that
 * fail to parse under C99. The subset below is the stable C surface (API 8/12) and lives in
 * librawfile.z.so, which the demo module links. */
typedef struct NativeResourceManager NativeResourceManager;
typedef struct RawDir RawDir;
NativeResourceManager *OH_ResourceManager_InitNativeResourceManager(napi_env env,
                                                                    napi_value jsResMgr);
void OH_ResourceManager_ReleaseNativeResourceManager(NativeResourceManager *resMgr);
RawDir *OH_ResourceManager_OpenRawDir(const NativeResourceManager *resMgr, const char *dirName);
int OH_ResourceManager_GetRawFileCount(RawDir *rawDir);
void OH_ResourceManager_CloseRawDir(RawDir *rawDir);

#include "oh_ability_events.h"

#ifdef __cplusplus
extern "C" {
#endif

#define OH_ABILITY_VERSION "0.1.0"

/* Error codes returned by OHAbility_* functions. */
typedef enum OHAbility_Error {
    OH_ABILITY_ERROR_OK = 0,
    OH_ABILITY_ERROR_INVALID_ARG = -1,
    OH_ABILITY_ERROR_NOT_READY = -2,
    OH_ABILITY_ERROR_DUPLICATE = -3,
    OH_ABILITY_ERROR_NOT_FOUND = -4,
    OH_ABILITY_ERROR_BRIDGE = -5,
    OH_ABILITY_ERROR_TIMEOUT = -6,
    OH_ABILITY_ERROR_CANCELLED = -7,
    OH_ABILITY_ERROR_MAIN_THREAD = -8, /* worker-only API called from the ArkTS main thread */
} OHAbility_Error;

/* ------------------------------------------------------------------ */
/* Module glue                                                         */
/* ------------------------------------------------------------------ */

/**
 * Registers the five module exports consumed by `@ohos-rs/ability`:
 * `init`, `render`, `onBackPressIntercept`, `onBridgeSyncEvent`, `onBridgeLifecycle`.
 * Call this once from the business NAPI module init (`napi_register_module_v1` register func).
 * Returns OH_ABILITY_ERROR_OK on success, a negative OHAbility_Error otherwise.
 */
int OHAbility_RegisterModule(napi_env env, napi_value exports);

/* ------------------------------------------------------------------ */
/* Ability init context (valid after init())                           */
/* ------------------------------------------------------------------ */

const char *OHAbility_GetBasePath(void);
const char *OHAbility_GetPrefPath(void);
const char *OHAbility_GetPreferredLocales(void);
const char *OHAbility_GetModuleName(void);

/**
 * Native resource manager converted from the ArkTS `resourceManager` of the init context.
 * Owned by the framework; valid until the next init() or the environment is torn down.
 * Returns NULL when the host did not supply a resource manager.
 */
NativeResourceManager *OHAbility_GetResourceManager(void);

/* ------------------------------------------------------------------ */
/* Application thread (SDL-style entry model)                          */
/* ------------------------------------------------------------------ */

typedef struct OHAbility_AppCallbacks {
    /** Runs once on the application thread before the loop; appstate out-parameter. */
    int (*init)(void **appstate, int argc, char **argv);
    /** Called between events when the queue is idle (may be NULL). */
    void (*iterate)(void *appstate);
    /** Called for each event. Event string fields are freed after this returns. */
    void (*event)(void *appstate, const OHAbility_Event *event);
    /** Called once when the loop exits (may be NULL). */
    void (*quit)(void *appstate, int result);
} OHAbility_AppCallbacks;

/**
 * Registers the application callbacks. The thread itself starts automatically when the first
 * XComponent surface is created (surface must exist before rendering). Calling this again while
 * running replaces the callbacks for the next mount generation.
 */
int OHAbility_StartApp(const OHAbility_AppCallbacks *callbacks);

/** Posts an event to the application queue from any thread. String fields are deep-copied. */
int OHAbility_PostEvent(const OHAbility_Event *event);

/** Asks the application loop to quit; `AppQuit` runs with the given result. */
int OHAbility_RequestQuit(int result);

/** Saved-state slot read by onAbilitySaveState (synchronously) and carried by RESUME events. */
int OHAbility_SetSavedState(const char *state);
const char *OHAbility_GetSavedState(void);

/** Native window of the latest mounted XComponent surface, or NULL before surface creation. */
OHNativeWindow *OHAbility_GetNativeWindow(void);

/** Requests an XComponent frame rate range; applied to the current mount. */
int OHAbility_SetFrameRate(int32_t min, int32_t max, int32_t preferred);

/**
 * Snapshot accessors mirroring the Rust `OpenHarmonyApp` surface. Values are updated by the
 * framework on the ArkTS main thread; read them from the main thread or the application loop.
 * `OHAbility_GetConfiguration` fills the caller's struct with pointers into the framework
 * snapshot (string fields are valid until the next configuration update).
 */
int OHAbility_GetConfiguration(OHAbility_Configuration *out);
int OHAbility_GetContentRect(OHAbility_Rect *out);
int OHAbility_GetWindowRect(OHAbility_Rect *out);
bool OHAbility_GetAvoidArea(OHAbility_AvoidAreaType type, OHAbility_AvoidArea *out);

/**
 * Capability gates (compile-time, mirroring cargo features / SDL subsystems):
 *   OH_ABILITY_ENABLE_IME      IME support (attached on surface creation, show/hide keyboard)
 *   OH_ABILITY_ENABLE_DISPLAY  display density queries
 *   OH_ABILITY_PLUGIN_NODE     built-in ohos.node surface plugin
 * Disabled capabilities are declared away here and their accessors return
 * OH_ABILITY_ERROR_NOT_READY.
 */
#ifdef OH_ABILITY_ENABLE_DISPLAY
/** Display content scale (density); falls back to 1.0 when the display API is unavailable. */
float OHAbility_GetScale(void);
#endif

#ifdef OH_ABILITY_ENABLE_IME
/** Shows / hides the IME keyboard (attached on surface creation). */
int OHAbility_ShowKeyboard(void);
int OHAbility_HideKeyboard(void);
#endif

/** Wakes the application loop with a user event (Rust OpenHarmonyApp::create_waker). */
int OHAbility_Wake(void);

/* ------------------------------------------------------------------ */
/* Back press                                                          */
/* ------------------------------------------------------------------ */

typedef bool (*OHAbility_BackPressFn)(void *userdata);

/**
 * Registers the interceptor answering the module's `onBackPressIntercept` export. Return true to
 * intercept the system back action. May be called from any thread before the first back press.
 */
int OHAbility_SetBackPressInterceptor(OHAbility_BackPressFn fn, void *userdata);

/* ------------------------------------------------------------------ */
/* C plugins: ArkTS-originated main-thread events + lifecycle          */
/* ------------------------------------------------------------------ */

typedef struct OHAbility_LifecycleEvent {
    /** One of "ability-create", "ability-destroy", "window-stage-create",
     *  "window-stage-destroy", "window-stage-event", "ui-context-ready",
     *  "ui-context-destroy", "configuration-updated", "memory-level". */
    const char *kind;
    int32_t window_stage_event; /* valid when kind == "window-stage-event" */
    int32_t memory_level;       /* valid when kind == "memory-level" */
} OHAbility_LifecycleEvent;

typedef struct OHAbility_Plugin {
    uint32_t version; /* must be > 0 and match the ArkTS plugin declaration */
    /**
     * Handles a synchronous event emitted by an ArkTS plugin through
     * `context.invokeNativeSync(...)`. Runs on the ArkTS main thread inside the active N-API
     * callback; must construct the response value (of `response_type`) and return
     * OH_ABILITY_ERROR_OK, or return an error to throw into ArkTS (fail-closed).
     */
    int (*on_sync_event)(napi_env env, const char *event, const char *request_type,
                         napi_value value, const char *response_type, napi_value *out_response,
                         void *userdata);
    /** Receives lifecycle transitions (see OHAbility_LifecycleEvent). May be NULL. */
    void (*on_lifecycle)(const OHAbility_LifecycleEvent *event, void *userdata);
} OHAbility_Plugin;

/**
 * Registers a C plugin under a stable identifier (e.g. "ohos.webview"). The identifier must match
 * `^[A-Za-z0-9._-]+$`; duplicate registration fails. `plugin` and `userdata` are retained by
 * reference; the plugin must outlive the module.
 */
int OHAbility_RegisterPlugin(const char *plugin_id, const OHAbility_Plugin *plugin, void *userdata);

/* ------------------------------------------------------------------ */
/* Bridge calls                                                        */
/* ------------------------------------------------------------------ */

typedef int (*OHAbility_ValueBuilder)(napi_env env, napi_value *out_value, void *data);
typedef void (*OHAbility_ValueResponder)(napi_env env, int status, napi_value value,
                                         const char *error, void *data);

/**
 * Asynchronous bridge call (any thread; fire-and-forget).
 *
 * `builder` runs on the ArkTS main thread to produce the request value; `responder` runs on the
 * main thread with the resolved response value (or an error). `timeout_ms` is enforced by the
 * ArkTS host (BridgeHost); pass 0 for the host default. The builder/responder must not retain
 * napi values.
 */
int OHAbility_CallAsync(const char *plugin_id, uint32_t version, const char *action,
                        const char *request_type, const char *response_type,
                        OHAbility_ValueBuilder builder, void *builder_data,
                        OHAbility_ValueResponder responder, void *responder_data,
                        uint32_t timeout_ms);

/**
 * Async bridge call that resolves/rejects a JS Promise instead of a responder.
 * Must be called from an N-API callback (an env is required to create the promise); the promise
 * is resolved on the main thread with the raw response value, or rejected with the error message.
 * Returns the Promise value (never NULL when the call is accepted).
 */
napi_value OHAbility_CallAsyncPromise(napi_env env, const char *plugin_id, uint32_t version,
                                      const char *action, const char *request_type,
                                      const char *response_type, OHAbility_ValueBuilder builder,
                                      void *builder_data, uint32_t timeout_ms);

/**
 * Synchronous bridge call for main-thread-only plugins. Only valid inside an active N-API
 * callback on the main thread (the stored bridge env must match). Returns the raw response value.
 * Never returns NULL on success.
 */
napi_value OHAbility_CallSync(napi_env env, const char *plugin_id, uint32_t version,
                              const char *action, const char *request_type,
                              const char *response_type, napi_value request);

/**
 * Worker -> main-thread synchronous bridge call. The caller thread blocks until `responder` has
 * consumed the result on the ArkTS main thread (execution still happens there, exactly like
 * OHAbility_CallSync). Must NOT be called from the ArkTS main thread (deadlock guard); the
 * responder runs with a live env and may, for example, resolve a deferred.
 */
int OHAbility_CallSyncFromWorker(const char *plugin_id, uint32_t version, const char *action,
                                 const char *request_type, const char *response_type,
                                 OHAbility_ValueBuilder builder, void *builder_data,
                                 OHAbility_ValueResponder responder, void *responder_data);

/**
 * Schedules a closure onto the ArkTS/N-API main thread (wraps the host's `bridgeDispatch`).
 * The closure must not retain napi values (it receives no env).
 */
int OHAbility_WithMainThread(void (*fn)(void *data), void *data);

/* ------------------------------------------------------------------ */
/* Built-in ohos.node surface plugin (Rust NodeExt / NodeSurface)      */
/* ------------------------------------------------------------------ */

#ifdef OH_ABILITY_PLUGIN_NODE
/*
 * The `ohos.node` plugin is installed automatically by the ArkTS BridgeHost ahead of business
 * plugins; no C-side plugin registration is required. These facades are outbound-only and
 * compose the session FrameNode tree through opaque handles (FrameNode values never cross
 * N-API). Each call is an `ohos.node` action; responders run on the ArkTS main thread.
 *
 * For `OHAbility_NodeCreateContainer`/`...InWindow`, the responder receives the opaque handle
 * as a number value (`status == OH_ABILITY_ERROR_OK`). For the other actions the responder
 * receives NULL and `status == OH_ABILITY_ERROR_OK` only when ArkTS acknowledged the operation;
 * a rejected operation arrives as an error (mirrors the Rust `ensure()`).
 */
int OHAbility_NodeCreateContainer(OHAbility_ValueResponder responder, void *responder_data,
                                  uint32_t timeout_ms);
int OHAbility_NodeCreateContainerInWindow(const char *window_key,
                                          OHAbility_ValueResponder responder, void *responder_data,
                                          uint32_t timeout_ms);
int OHAbility_NodeAppendChild(uint32_t parent_handle, uint32_t child_handle,
                              OHAbility_ValueResponder responder, void *responder_data,
                              uint32_t timeout_ms);
int OHAbility_NodeAppendChildInWindow(const char *window_key, uint32_t parent_handle,
                                      uint32_t child_handle, OHAbility_ValueResponder responder,
                                      void *responder_data, uint32_t timeout_ms);
int OHAbility_NodeMountIntoRoot(uint32_t handle, OHAbility_ValueResponder responder,
                                void *responder_data, uint32_t timeout_ms);
int OHAbility_NodeMountIntoRootInWindow(const char *window_key, uint32_t handle,
                                        OHAbility_ValueResponder responder, void *responder_data,
                                        uint32_t timeout_ms);
int OHAbility_NodeDispose(uint32_t handle, OHAbility_ValueResponder responder, void *responder_data,
                          uint32_t timeout_ms);
int OHAbility_NodeDisposeInWindow(const char *window_key, uint32_t handle,
                                  OHAbility_ValueResponder responder, void *responder_data,
                                  uint32_t timeout_ms);
#endif /* OH_ABILITY_PLUGIN_NODE */

/* ------------------------------------------------------------------ */
/* Identifier validation (shared with host validation rules)           */
/* ------------------------------------------------------------------ */

/** True when `value` is non-empty and matches ^[A-Za-z0-9._-]+$ (bridge identifier rules). */
bool OHAbility_IsBridgeIdentifier(const char *value);

#ifdef __cplusplus
}
#endif

#endif /* OH_ABILITY_H */
