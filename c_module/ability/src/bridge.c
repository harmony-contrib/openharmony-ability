/*
 * Bridge transport: async calls (any thread -> TSFN -> bridgeInvoke Promise), main-thread sync
 * calls (borrowed bridgeInvokeSync reference), worker -> main-thread sync calls (TSFN + serial
 * waiters), and the main-thread scheduler (bridgeDispatch).
 *
 * napi_value discipline: request values are built by `OHAbility_ValueBuilder` callbacks and
 * consumed by `OHAbility_ValueResponder` callbacks, both on the ArkTS main thread inside the
 * TSFN call-js / Promise handlers. No napi value is ever queued across threads; every queued
 * request struct is freed by its call-js callback (including the env==NULL abort drain).
 */
#include "oh_state.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

#define OH_ABILITY_DEFAULT_TIMEOUT_MS 15000u
#define OH_ABILITY_MAX_TIMEOUT_MS 60000u

/* TSFN call-js callbacks (defined below; used by oh_bindings_replace). */
static void oh_async_call_js(napi_env env, napi_value js_callback, void *context, void *data);
static void oh_worker_sync_call_js(napi_env env, napi_value js_callback, void *context, void *data);
static void oh_dispatch_call_js(napi_env env, napi_value js_callback, void *context, void *data);

/* ------------------------------------------------------------------ */
/* Request struct shared by async + worker-sync transports            */
/* ------------------------------------------------------------------ */

typedef struct OHAbility_AsyncRequest {
    char plugin_id[OHABILITY_MAX_STRING_LEN];
    uint32_t version;
    char action[OHABILITY_MAX_STRING_LEN];
    char request_type[OHABILITY_MAX_STRING_LEN];
    char response_type[OHABILITY_MAX_STRING_LEN];
    uint32_t timeout_ms;
    OHAbility_ValueBuilder builder;
    void *builder_data;
    OHAbility_ValueResponder responder;
    void *responder_data;
    int promise_mode; /* resolve/reject a deferred instead of calling the responder */
    napi_env deferred_env;
    napi_deferred deferred;
    int settled;              /* untrack-once guard against double settlement */
    OHAbility_Waiter *waiter; /* worker-sync mode: caller blocks on this */
} OHAbility_AsyncRequest;

static OHAbility_AsyncRequest *oh_request_alloc(const char *plugin_id, uint32_t version,
                                                const char *action, const char *request_type,
                                                const char *response_type,
                                                OHAbility_ValueBuilder builder, void *builder_data,
                                                OHAbility_ValueResponder responder,
                                                void *responder_data, uint32_t timeout_ms) {
    if (!oh_validate_identifier("plugin id", plugin_id) ||
        !oh_validate_identifier("action", action) ||
        !oh_validate_identifier("request type", request_type) ||
        !oh_validate_identifier("response type", response_type) || version == 0) {
        return NULL;
    }

    OHAbility_AsyncRequest *req = (OHAbility_AsyncRequest *)calloc(1, sizeof(*req));
    if (req == NULL) {
        return NULL;
    }
    snprintf(req->plugin_id, sizeof(req->plugin_id), "%s", plugin_id);
    snprintf(req->action, sizeof(req->action), "%s", action);
    snprintf(req->request_type, sizeof(req->request_type), "%s", request_type);
    snprintf(req->response_type, sizeof(req->response_type), "%s", response_type);
    req->version = version;
    req->builder = builder;
    req->builder_data = builder_data;
    req->responder = responder;
    req->responder_data = responder_data;
    /* 0 means "host default"; mirror the Rust BridgeCallOptions default. */
    req->timeout_ms =
        timeout_ms == 0
            ? OH_ABILITY_DEFAULT_TIMEOUT_MS
            : (timeout_ms > OH_ABILITY_MAX_TIMEOUT_MS ? OH_ABILITY_MAX_TIMEOUT_MS : timeout_ms);
    return req;
}

/* Delivers a failure to whichever sink the request owns. The caller frees the request. */
static void oh_request_fail(OHAbility_AsyncRequest *req, const char *message) {
    if (req->promise_mode) {
        napi_value msg;
        if (req->deferred_env != NULL &&
            napi_create_string_utf8(req->deferred_env, message, NAPI_AUTO_LENGTH, &msg) ==
                napi_ok) {
            napi_reject_deferred(req->deferred_env, req->deferred, msg);
        }
    } else if (req->responder != NULL) {
        /* A responder may be invoked without an env (abort drain); it must tolerate that. */
        req->responder(NULL, OH_ABILITY_ERROR_BRIDGE, NULL, message, req->responder_data);
    }
    if (req->waiter != NULL) {
        oh_waiter_signal(req->waiter, OH_ABILITY_ERROR_BRIDGE);
    }
}

/* ------------------------------------------------------------------ */
/* TSFN helpers                                                        */
/* ------------------------------------------------------------------ */

static int oh_create_tsfn(napi_env env, napi_value function, const char *name,
                          napi_threadsafe_function_call_js call_js, napi_threadsafe_function *out) {
    napi_value resource_name;
    if (napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resource_name) != napi_ok) {
        return 0;
    }
    if (napi_create_threadsafe_function(env, function, NULL, resource_name, 0, 1, NULL, NULL, NULL,
                                        call_js, out) != napi_ok) {
        return 0;
    }
    return 1;
}

/* ------------------------------------------------------------------ */
/* Bindings (set by render, torn down on re-init/re-render/cleanup)   */
/* ------------------------------------------------------------------ */

void oh_bindings_teardown(void) {
    oh_state_lock();
    napi_threadsafe_function invoke = g_oh_state.invoke_tsfn;
    napi_threadsafe_function invoke_sync = g_oh_state.invoke_sync_tsfn;
    napi_threadsafe_function dispatch = g_oh_state.dispatch_tsfn;
    napi_env env = g_oh_state.env;
    napi_ref sync_ref = g_oh_state.invoke_sync_ref;
    g_oh_state.invoke_tsfn = NULL;
    g_oh_state.invoke_sync_tsfn = NULL;
    g_oh_state.dispatch_tsfn = NULL;
    g_oh_state.invoke_sync_ref = NULL;
    g_oh_state.bindings_valid = 0;
    oh_state_unlock();

    /* Releasing with abort drains queued items through call-js (env == NULL), which wakes the
     * worker-sync waiters instead of leaving them blocked forever. */
    if (invoke != NULL) {
        napi_release_threadsafe_function(invoke, napi_tsfn_abort);
    }
    if (invoke_sync != NULL) {
        napi_release_threadsafe_function(invoke_sync, napi_tsfn_abort);
    }
    if (dispatch != NULL) {
        napi_release_threadsafe_function(dispatch, napi_tsfn_abort);
    }
    if (sync_ref != NULL && env != NULL) {
        napi_delete_reference(env, sync_ref);
    }
}

void oh_bindings_replace(napi_env env, napi_value bindings) {
    napi_value invoke_fn;
    napi_value invoke_sync_fn;
    napi_value dispatch_fn;
    if (napi_get_named_property(env, bindings, "bridgeInvoke", &invoke_fn) != napi_ok ||
        napi_get_named_property(env, bindings, "bridgeInvokeSync", &invoke_sync_fn) != napi_ok ||
        napi_get_named_property(env, bindings, "bridgeDispatch", &dispatch_fn) != napi_ok) {
        OHABILITY_LOG(LOG_ERROR,
                      "render: bindings missing bridgeInvoke/bridgeInvokeSync/bridgeDispatch");
        return;
    }

    napi_threadsafe_function invoke = NULL;
    napi_threadsafe_function invoke_sync = NULL;
    napi_threadsafe_function dispatch = NULL;
    napi_ref sync_ref = NULL;

    int ok =
        oh_create_tsfn(env, invoke_fn, "ohAbilityInvoke", oh_async_call_js, &invoke) &&
        oh_create_tsfn(env, invoke_sync_fn, "ohAbilityInvokeSync", oh_worker_sync_call_js,
                       &invoke_sync) &&
        oh_create_tsfn(env, dispatch_fn, "ohAbilityDispatch", oh_dispatch_call_js, &dispatch) &&
        napi_create_reference(env, invoke_sync_fn, 1, &sync_ref) == napi_ok;

    if (!ok) {
        if (invoke != NULL) {
            napi_release_threadsafe_function(invoke, napi_tsfn_abort);
        }
        if (invoke_sync != NULL) {
            napi_release_threadsafe_function(invoke_sync, napi_tsfn_abort);
        }
        if (dispatch != NULL) {
            napi_release_threadsafe_function(dispatch, napi_tsfn_abort);
        }
        OHABILITY_LOG(LOG_ERROR, "render: failed to build bridge transports");
        return;
    }

    oh_bindings_teardown();

    oh_state_lock();
    g_oh_state.invoke_tsfn = invoke;
    g_oh_state.invoke_sync_tsfn = invoke_sync;
    g_oh_state.dispatch_tsfn = dispatch;
    g_oh_state.invoke_sync_ref = sync_ref;
    g_oh_state.bindings_thread = pthread_self();
    g_oh_state.bindings_valid = 1;
    oh_state_unlock();
}

napi_threadsafe_function oh_bridge_invoke_tsfn(void) {
    oh_state_lock();
    napi_threadsafe_function result = g_oh_state.invoke_tsfn;
    oh_state_unlock();
    return result;
}

napi_threadsafe_function oh_bridge_invoke_sync_tsfn(void) {
    oh_state_lock();
    napi_threadsafe_function result = g_oh_state.invoke_sync_tsfn;
    oh_state_unlock();
    return result;
}

napi_threadsafe_function oh_bridge_dispatch_tsfn(void) {
    oh_state_lock();
    napi_threadsafe_function result = g_oh_state.dispatch_tsfn;
    oh_state_unlock();
    return result;
}

napi_ref oh_bridge_invoke_sync_ref(void) {
    oh_state_lock();
    napi_ref result = g_oh_state.invoke_sync_ref;
    oh_state_unlock();
    return result;
}

int oh_bridge_validate_env(napi_env env) {
    oh_state_lock();
    int ok = g_oh_state.bindings_valid && g_oh_state.env == env;
    oh_state_unlock();
    return ok;
}

/* ------------------------------------------------------------------ */
/* Serial waiters (worker -> main-thread sync)                        */
/*                                                                     */
/* refs == 2 at birth: one for the calling worker, one for the         */
/* completion side (call-js / abort drain). Whoever releases last      */
/* frees the waiter, so a timed-out caller can never wake on freed     */
/* memory and a late drain signal can never touch a freed waiter.      */
/* ------------------------------------------------------------------ */

OHAbility_Waiter *oh_waiter_create(void) {
    OHAbility_Waiter *waiter = (OHAbility_Waiter *)calloc(1, sizeof(*waiter));
    if (waiter == NULL) {
        return NULL;
    }
    pthread_mutex_init(&waiter->mutex, NULL);
    pthread_cond_init(&waiter->cond, NULL);
    waiter->refs = 2;
    waiter->status = OH_ABILITY_ERROR_TIMEOUT;

    oh_state_lock();
    waiter->serial = g_oh_state.next_serial++;
    waiter->next = g_oh_state.waiters;
    g_oh_state.waiters = waiter;
    oh_state_unlock();
    return waiter;
}

void oh_waiter_wait(OHAbility_Waiter *waiter, uint32_t timeout_ms) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (timeout_ms % 1000) * 1000 * 1000;
    if (deadline.tv_nsec >= 1000 * 1000 * 1000) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000 * 1000 * 1000;
    }

    pthread_mutex_lock(&waiter->mutex);
    while (!waiter->done) {
        if (pthread_cond_timedwait(&waiter->cond, &waiter->mutex, &deadline) != 0) {
            break;
        }
    }
    pthread_mutex_unlock(&waiter->mutex);
}

void oh_waiter_signal(OHAbility_Waiter *waiter, int status) {
    pthread_mutex_lock(&waiter->mutex);
    if (!waiter->done) {
        waiter->done = 1;
        waiter->status = status;
        pthread_cond_signal(&waiter->cond);
    }
    pthread_mutex_unlock(&waiter->mutex);
}

static void oh_waiter_unlink(OHAbility_Waiter *waiter) {
    oh_state_lock();
    OHAbility_Waiter **link = &g_oh_state.waiters;
    while (*link != NULL && *link != waiter) {
        link = &(*link)->next;
    }
    if (*link != NULL) {
        *link = waiter->next;
    }
    oh_state_unlock();
}

void oh_waiter_release(OHAbility_Waiter *waiter) {
    if (waiter == NULL) {
        return;
    }
    pthread_mutex_lock(&waiter->mutex);
    int destroy = (--waiter->refs == 0);
    pthread_mutex_unlock(&waiter->mutex);
    if (destroy) {
        oh_waiter_unlink(waiter);
        pthread_mutex_destroy(&waiter->mutex);
        pthread_cond_destroy(&waiter->cond);
        free(waiter);
    }
}

void oh_waiter_abort_all(int status) {
    oh_state_lock();
    OHAbility_Waiter *waiter = g_oh_state.waiters;
    g_oh_state.waiters = NULL;
    oh_state_unlock();
    /* Signal outside the state lock: waiters may free themselves on release. */
    while (waiter != NULL) {
        OHAbility_Waiter *next = waiter->next;
        oh_waiter_signal(waiter, status);
        waiter = next;
    }
}

/* ------------------------------------------------------------------ */
/* Async transport (Promise -> responder / deferred)                  */
/* ------------------------------------------------------------------ */

static napi_value oh_async_resolve(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    void *data = NULL;
    napi_get_cb_info(env, info, &argc, args, NULL, &data);
    OHAbility_AsyncRequest *req = (OHAbility_AsyncRequest *)data;

    if (req->settled) {
        return NULL;
    }
    req->settled = 1;

    napi_value value = argc >= 1 ? args[0] : NULL;
    if (req->promise_mode) {
        if (req->deferred_env == env && value != NULL) {
            napi_resolve_deferred(req->deferred_env, req->deferred, value);
        } else {
            oh_request_fail(req, "bridge Promise resolved with a mismatched environment");
        }
    } else if (req->responder != NULL) {
        req->responder(env, OH_ABILITY_ERROR_OK, value, NULL, req->responder_data);
    }
    free(req);
    return NULL;
}

static napi_value oh_async_reject(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {NULL};
    void *data = NULL;
    napi_get_cb_info(env, info, &argc, args, NULL, &data);
    OHAbility_AsyncRequest *req = (OHAbility_AsyncRequest *)data;

    if (req->settled) {
        return NULL;
    }
    req->settled = 1;

    char *message = NULL;
    if (argc >= 1) {
        napi_value as_string;
        if (napi_coerce_to_string(env, args[0], &as_string) == napi_ok) {
            message = oh_napi_get_string(env, as_string);
        }
    }
    const char *text = (message != NULL && message[0] != '\0') ? message : "bridge call rejected";

    if (req->promise_mode) {
        napi_value msg;
        if (req->deferred_env == env &&
            napi_create_string_utf8(req->deferred_env, text, NAPI_AUTO_LENGTH, &msg) == napi_ok) {
            napi_reject_deferred(req->deferred_env, req->deferred, msg);
        }
    } else if (req->responder != NULL) {
        req->responder(env, OH_ABILITY_ERROR_BRIDGE, NULL, text, req->responder_data);
    }
    free(message);
    free(req);
    return NULL;
}

/*
 * Runs on the ArkTS main thread: builds the request value, calls bridgeInvoke, and attaches
 * Promise handlers. The request becomes owned by the handlers after a successful attach and is
 * freed exactly once when the Promise settles; failure paths free it here.
 */
static void oh_async_call_js(napi_env env, napi_value js_callback, void *context, void *data) {
    (void)context;
    OHAbility_AsyncRequest *req = (OHAbility_AsyncRequest *)data;

    if (env == NULL || js_callback == NULL) {
        /* Abort drain (bindings torn down / environment released): fail the request. The
         * builder never ran, so its data is released here. */
        oh_request_fail(req, "bridge call aborted");
        free(req->builder_data);
        free(req);
        return;
    }

    napi_value request_value = NULL;
    if (req->builder != NULL &&
        req->builder(env, &request_value, req->builder_data) != OH_ABILITY_ERROR_OK) {
        oh_request_fail(req, "bridge request builder failed");
        free(req->builder_data);
        free(req);
        return;
    }
    /* The builder consumed its data; the framework owns it from the moment the call was queued. */
    free(req->builder_data);
    req->builder_data = NULL;
    if (request_value == NULL) {
        napi_get_undefined(env, &request_value);
    }

    napi_value global;
    napi_get_global(env, &global);

    napi_value args[7];
    napi_create_string_utf8(env, req->plugin_id, NAPI_AUTO_LENGTH, &args[0]);
    napi_create_uint32(env, req->version, &args[1]);
    napi_create_string_utf8(env, req->action, NAPI_AUTO_LENGTH, &args[2]);
    napi_create_string_utf8(env, req->request_type, NAPI_AUTO_LENGTH, &args[3]);
    napi_create_string_utf8(env, req->response_type, NAPI_AUTO_LENGTH, &args[4]);
    args[5] = request_value;
    napi_create_uint32(env, req->timeout_ms, &args[6]);

    napi_value result = NULL;
    if (napi_call_function(env, global, js_callback, 7, args, &result) != napi_ok ||
        result == NULL) {
        oh_request_fail(req, "bridgeInvoke call failed");
        free(req);
        return;
    }

    napi_value then_fn;
    napi_valuetype then_type;
    if (napi_get_named_property(env, result, "then", &then_fn) != napi_ok ||
        napi_typeof(env, then_fn, &then_type) != napi_ok || then_type != napi_function) {
        oh_request_fail(req, "bridgeInvoke did not return a Promise");
        free(req);
        return;
    }

    napi_value resolve_cb;
    napi_value reject_cb;
    napi_create_function(env, "ohAbilityResolve", NAPI_AUTO_LENGTH, oh_async_resolve, req,
                         &resolve_cb);
    napi_create_function(env, "ohAbilityReject", NAPI_AUTO_LENGTH, oh_async_reject, req,
                         &reject_cb);
    napi_value then_args[2] = {resolve_cb, reject_cb};
    napi_value ignored;
    if (napi_call_function(env, result, then_fn, 2, then_args, &ignored) != napi_ok) {
        oh_request_fail(req, "failed to attach bridge Promise handlers");
        free(req);
        return;
    }
    /* From here the Promise handlers own the request. */
}

int OHAbility_CallAsync(const char *plugin_id, uint32_t version, const char *action,
                        const char *request_type, const char *response_type,
                        OHAbility_ValueBuilder builder, void *builder_data,
                        OHAbility_ValueResponder responder, void *responder_data,
                        uint32_t timeout_ms) {
    if (responder == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    OHAbility_AsyncRequest *req =
        oh_request_alloc(plugin_id, version, action, request_type, response_type, builder,
                         builder_data, responder, responder_data, timeout_ms);
    if (req == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }

    napi_threadsafe_function tsfn = oh_bridge_invoke_tsfn();
    if (tsfn == NULL) {
        free(req->builder_data);
        free(req);
        return OH_ABILITY_ERROR_NOT_READY;
    }
    napi_status status = napi_call_threadsafe_function(tsfn, req, napi_tsfn_nonblocking);
    if (status != napi_ok) {
        /* The TSFN refused the item (closing): fail the request and free it here. */
        oh_request_fail(req, "bridge transport rejected the request");
        free(req->builder_data);
        free(req);
        return OH_ABILITY_ERROR_BRIDGE;
    }
    return OH_ABILITY_ERROR_OK;
}

/* ------------------------------------------------------------------ */
/* Async transport with a JS Promise (for napi exports)               */
/* ------------------------------------------------------------------ */

typedef struct OHAbility_PromiseBuilder {
    OHAbility_ValueBuilder builder;
    void *data;
} OHAbility_PromiseBuilder;

static int oh_promise_builder(napi_env env, napi_value *out_value, void *data) {
    OHAbility_PromiseBuilder *wrapped = (OHAbility_PromiseBuilder *)data;
    if (wrapped->builder == NULL) {
        napi_get_undefined(env, out_value);
        return OH_ABILITY_ERROR_OK;
    }
    return wrapped->builder(env, out_value, wrapped->data);
}

napi_value OHAbility_CallAsyncPromise(napi_env env, const char *plugin_id, uint32_t version,
                                      const char *action, const char *request_type,
                                      const char *response_type, OHAbility_ValueBuilder builder,
                                      void *builder_data, uint32_t timeout_ms) {
    if (env == NULL) {
        return NULL;
    }

    napi_value promise;
    napi_deferred deferred;
    if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
        return NULL;
    }

    /* The builder is invoked on the main thread inside call-js; wrap it with its data. */
    OHAbility_PromiseBuilder *wrapped = (OHAbility_PromiseBuilder *)malloc(sizeof(*wrapped));
    if (wrapped == NULL) {
        return NULL;
    }
    wrapped->builder = builder;
    wrapped->data = builder_data;

    OHAbility_AsyncRequest *req =
        oh_request_alloc(plugin_id, version, action, request_type, response_type,
                         oh_promise_builder, wrapped, NULL, NULL, timeout_ms);
    if (req == NULL) {
        free(wrapped);
        return NULL;
    }
    req->promise_mode = 1;
    req->deferred_env = env;
    req->deferred = deferred;

    napi_threadsafe_function tsfn = oh_bridge_invoke_tsfn();
    if (tsfn == NULL) {
        oh_request_fail(req, "bridge is not ready (module not rendered)");
        free(req->builder_data); /* the wrapped builder */
        free(req);
        return promise;
    }
    napi_status status = napi_call_threadsafe_function(tsfn, req, napi_tsfn_nonblocking);
    if (status != napi_ok) {
        oh_request_fail(req, "bridge transport rejected the request");
        free(req->builder_data);
        free(req);
    }
    return promise;
}

/* ------------------------------------------------------------------ */
/* Main-thread sync transport                                         */
/* ------------------------------------------------------------------ */

napi_value OHAbility_CallSync(napi_env env, const char *plugin_id, uint32_t version,
                              const char *action, const char *request_type,
                              const char *response_type, napi_value request) {
    if (!oh_bridge_validate_env(env)) {
        napi_throw_error(env, "oh_ability/env",
                         "OHAbility_CallSync requires the ArkTS main-thread environment");
        return NULL;
    }
    if (!oh_validate_identifier("plugin id", plugin_id) ||
        !oh_validate_identifier("action", action) ||
        !oh_validate_identifier("request type", request_type) ||
        !oh_validate_identifier("response type", response_type) || version == 0) {
        napi_throw_error(env, "oh_ability/identifier", "invalid plugin id, action or type name");
        return NULL;
    }

    napi_ref sync_ref = oh_bridge_invoke_sync_ref();
    if (sync_ref == NULL) {
        napi_throw_error(env, "oh_ability/not_ready",
                         "synchronous bridge is not ready (module not rendered)");
        return NULL;
    }
    napi_value invoke_sync;
    if (napi_get_reference_value(env, sync_ref, &invoke_sync) != napi_ok) {
        napi_throw_error(env, "oh_ability/bridge", "failed to borrow bridgeInvokeSync");
        return NULL;
    }

    napi_value global;
    napi_get_global(env, &global);

    napi_value args[6];
    napi_create_string_utf8(env, plugin_id, NAPI_AUTO_LENGTH, &args[0]);
    napi_create_uint32(env, version, &args[1]);
    napi_create_string_utf8(env, action, NAPI_AUTO_LENGTH, &args[2]);
    napi_create_string_utf8(env, request_type, NAPI_AUTO_LENGTH, &args[3]);
    napi_create_string_utf8(env, response_type, NAPI_AUTO_LENGTH, &args[4]);
    if (request == NULL) {
        napi_get_undefined(env, &args[5]);
    } else {
        args[5] = request;
    }

    napi_value result = NULL;
    if (napi_call_function(env, global, invoke_sync, 6, args, &result) != napi_ok) {
        napi_throw_error(env, "oh_ability/bridge", "bridgeInvokeSync call failed");
        return NULL;
    }
    return result;
}

/* ------------------------------------------------------------------ */
/* Worker -> main-thread sync transport                               */
/* ------------------------------------------------------------------ */

static void oh_worker_sync_call_js(napi_env env, napi_value js_callback, void *context,
                                   void *data) {
    (void)context;
    OHAbility_AsyncRequest *req = (OHAbility_AsyncRequest *)data;

    if (env == NULL || js_callback == NULL) {
        /* Abort drain: the waiter may already have timed out and released its reference, but
         * the refcount keeps the waiter alive until this side releases too. */
        if (req->waiter != NULL) {
            oh_waiter_signal(req->waiter, OH_ABILITY_ERROR_CANCELLED);
            oh_waiter_release(req->waiter);
        }
        free(req->builder_data);
        free(req);
        return;
    }

    napi_value request_value = NULL;
    if (req->builder != NULL &&
        req->builder(env, &request_value, req->builder_data) != OH_ABILITY_ERROR_OK) {
        if (req->responder != NULL) {
            req->responder(env, OH_ABILITY_ERROR_BRIDGE, NULL, "bridge request builder failed",
                           req->responder_data);
        }
        if (req->waiter != NULL) {
            oh_waiter_signal(req->waiter, OH_ABILITY_ERROR_BRIDGE);
            oh_waiter_release(req->waiter);
        }
        free(req->builder_data);
        free(req);
        return;
    }
    free(req->builder_data);
    req->builder_data = NULL;
    if (request_value == NULL) {
        napi_get_undefined(env, &request_value);
    }

    napi_value global;
    napi_get_global(env, &global);

    napi_value args[6];
    napi_create_string_utf8(env, req->plugin_id, NAPI_AUTO_LENGTH, &args[0]);
    napi_create_uint32(env, req->version, &args[1]);
    napi_create_string_utf8(env, req->action, NAPI_AUTO_LENGTH, &args[2]);
    napi_create_string_utf8(env, req->request_type, NAPI_AUTO_LENGTH, &args[3]);
    napi_create_string_utf8(env, req->response_type, NAPI_AUTO_LENGTH, &args[4]);
    args[5] = request_value;

    napi_value result = NULL;
    napi_status status = napi_call_function(env, global, js_callback, 6, args, &result);
    if (status != napi_ok || result == NULL) {
        if (req->responder != NULL) {
            req->responder(env, OH_ABILITY_ERROR_BRIDGE, NULL, "bridgeInvokeSync call failed",
                           req->responder_data);
        }
        if (req->waiter != NULL) {
            oh_waiter_signal(req->waiter, OH_ABILITY_ERROR_BRIDGE);
            oh_waiter_release(req->waiter);
        }
        free(req);
        return;
    }

    /* The responder consumes the result on the main thread before the caller wakes. */
    if (req->responder != NULL) {
        req->responder(env, OH_ABILITY_ERROR_OK, result, NULL, req->responder_data);
    }
    if (req->waiter != NULL) {
        oh_waiter_signal(req->waiter, OH_ABILITY_ERROR_OK);
        oh_waiter_release(req->waiter);
    }
    free(req);
}

int OHAbility_CallSyncFromWorker(const char *plugin_id, uint32_t version, const char *action,
                                 const char *request_type, const char *response_type,
                                 OHAbility_ValueBuilder builder, void *builder_data,
                                 OHAbility_ValueResponder responder, void *responder_data) {
    if (responder == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }

    oh_state_lock();
    int on_main_thread =
        g_oh_state.bindings_valid && pthread_equal(pthread_self(), g_oh_state.bindings_thread);
    oh_state_unlock();
    if (on_main_thread) {
        return OH_ABILITY_ERROR_MAIN_THREAD;
    }

    OHAbility_AsyncRequest *req =
        oh_request_alloc(plugin_id, version, action, request_type, response_type, builder,
                         builder_data, responder, responder_data, OH_ABILITY_MAX_TIMEOUT_MS);
    if (req == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }

    OHAbility_Waiter *waiter = oh_waiter_create();
    if (waiter == NULL) {
        free(req);
        return OH_ABILITY_ERROR_BRIDGE;
    }
    req->waiter = waiter;

    napi_threadsafe_function tsfn = oh_bridge_invoke_sync_tsfn();
    if (tsfn == NULL) {
        /* No completion side will ever run: release both references and free directly. */
        oh_waiter_signal(waiter, OH_ABILITY_ERROR_NOT_READY);
        oh_waiter_release(waiter);
        oh_waiter_release(waiter);
        free(req->builder_data);
        free(req);
        return OH_ABILITY_ERROR_NOT_READY;
    }
    napi_status status = napi_call_threadsafe_function(tsfn, req, napi_tsfn_nonblocking);
    if (status != napi_ok) {
        oh_waiter_signal(waiter, OH_ABILITY_ERROR_BRIDGE);
        oh_waiter_release(waiter);
        oh_waiter_release(waiter);
        free(req->builder_data);
        free(req);
        return OH_ABILITY_ERROR_BRIDGE;
    }

    oh_waiter_wait(waiter, OH_ABILITY_MAX_TIMEOUT_MS);

    /* Read the status before releasing the caller's reference; the completion side may free
     * the waiter once both references are gone. */
    pthread_mutex_lock(&waiter->mutex);
    int result = waiter->status;
    pthread_mutex_unlock(&waiter->mutex);
    oh_waiter_release(waiter);
    return result;
}

/* ------------------------------------------------------------------ */
/* Main-thread scheduler (bridgeDispatch)                             */
/* ------------------------------------------------------------------ */

typedef struct OHAbility_MainThreadTask {
    void (*fn)(void *data);
    void *data;
} OHAbility_MainThreadTask;

static void oh_dispatch_call_js(napi_env env, napi_value js_callback, void *context, void *data) {
    (void)env;
    (void)js_callback;
    (void)context;
    OHAbility_MainThreadTask *task = (OHAbility_MainThreadTask *)data;
    if (task != NULL) {
        task->fn(task->data);
        free(task);
    }
}

int OHAbility_WithMainThread(void (*fn)(void *data), void *data) {
    if (fn == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    OHAbility_MainThreadTask *task = (OHAbility_MainThreadTask *)malloc(sizeof(*task));
    if (task == NULL) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    task->fn = fn;
    task->data = data;

    napi_threadsafe_function tsfn = oh_bridge_dispatch_tsfn();
    if (tsfn == NULL) {
        free(task);
        return OH_ABILITY_ERROR_NOT_READY;
    }
    napi_status status = napi_call_threadsafe_function(tsfn, task, napi_tsfn_nonblocking);
    if (status != napi_ok) {
        free(task);
        return OH_ABILITY_ERROR_BRIDGE;
    }
    return OH_ABILITY_ERROR_OK;
}
