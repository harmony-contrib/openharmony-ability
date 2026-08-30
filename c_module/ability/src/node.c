/*
 * Built-in `ohos.node` surface plugin facade (Rust NodeExt / NodeSurface parity).
 *
 * The ArkTS half lives in `BridgeHost` (`native_ability`) and is installed automatically ahead
 * of business plugins, so no C-side plugin registration is required — these facades are
 * outbound-only. Rust and C compose the session FrameNode tree through opaque handles;
 * FrameNode values never cross the N-API boundary.
 *
 * Wire contract (verified against BridgeHost.ets):
 *   "create-container"  ohos.node.CreateContainerRequest ->
 * ohos.node.HandleResponse{handle} "append-child"
 * ohos.node.AppendChildRequest{parentHandle,childHandle} ->
 * ohos.node.Acknowledgement{accepted} "mount-into-root"
 * ohos.node.MountIntoRootRequest{handle} -> ohos.node.Acknowledgement{accepted}
 *   "dispose"           ohos.node.DisposeRequest{handle} ->
 * ohos.node.Acknowledgement{accepted}
 */
#include "oh_state.h"

#include <stdlib.h>
#include <string.h>

#define NODE_PLUGIN_ID "ohos.node"
#define NODE_ACTION_CREATE_CONTAINER "create-container"
#define NODE_ACTION_APPEND_CHILD "append-child"
#define NODE_ACTION_MOUNT_INTO_ROOT "mount-into-root"
#define NODE_ACTION_DISPOSE "dispose"
#define NODE_TYPE_CREATE_CONTAINER_REQUEST "ohos.node.CreateContainerRequest"
#define NODE_TYPE_APPEND_CHILD_REQUEST "ohos.node.AppendChildRequest"
#define NODE_TYPE_MOUNT_INTO_ROOT_REQUEST "ohos.node.MountIntoRootRequest"
#define NODE_TYPE_DISPOSE_REQUEST "ohos.node.DisposeRequest"
#define NODE_TYPE_HANDLE_RESPONSE "ohos.node.HandleResponse"
#define NODE_TYPE_ACKNOWLEDGEMENT "ohos.node.Acknowledgement"

typedef enum NodeActionKind {
    NODE_ACTION_KIND_CREATE,
    NODE_ACTION_KIND_APPEND,
    NODE_ACTION_KIND_MOUNT,
    NODE_ACTION_KIND_DISPOSE,
} NodeActionKind;

/* Builder payload: single allocation, freed by the framework after the builder runs. */
typedef struct NodeRequestArgs {
    NodeActionKind kind;
    uint32_t a; /* parent_handle (append-child) or handle (mount/dispose) */
    uint32_t b; /* child_handle (append-child) */
} NodeRequestArgs;

static int node_build_request(napi_env env, napi_value *out, void *data) {
    NodeRequestArgs *args = (NodeRequestArgs *)data;
    napi_value request;
    if (napi_create_object(env, &request) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    if (args->kind == NODE_ACTION_KIND_APPEND) {
        napi_value value;
        napi_create_uint32(env, args->a, &value);
        napi_set_named_property(env, request, "parentHandle", value);
        napi_create_uint32(env, args->b, &value);
        napi_set_named_property(env, request, "childHandle", value);
    } else if (args->kind == NODE_ACTION_KIND_MOUNT || args->kind == NODE_ACTION_KIND_DISPOSE) {
        napi_value value;
        napi_create_uint32(env, args->a, &value);
        napi_set_named_property(env, request, "handle", value);
    }
    *out = request;
    return OH_ABILITY_ERROR_OK;
}

/* Wraps the caller's responder; freed by the wrapper once the response is consumed. */
typedef struct NodeResponderWrap {
    OHAbility_ValueResponder responder;
    void *data;
} NodeResponderWrap;

/* create-container: extracts the opaque handle (number) before delivering. */
static void node_handle_responder(napi_env env, int status, napi_value value, const char *error,
                                  void *data) {
    NodeResponderWrap *wrap = (NodeResponderWrap *)data;
    if (status == OH_ABILITY_ERROR_OK && value != NULL) {
        napi_value handle;
        if (napi_get_named_property(env, value, "handle", &handle) == napi_ok) {
            wrap->responder(env, OH_ABILITY_ERROR_OK, handle, NULL, wrap->data);
            free(wrap);
            return;
        }
        wrap->responder(env, OH_ABILITY_ERROR_BRIDGE, NULL,
                        "ohos.node create-container returned no handle", wrap->data);
        free(wrap);
        return;
    }
    wrap->responder(env, status, NULL, error, wrap->data);
    free(wrap);
}

/* append-child / mount-into-root / dispose: validates the acknowledgement (Rust ensure()). */
static void node_ack_responder(napi_env env, int status, napi_value value, const char *error,
                               void *data) {
    NodeResponderWrap *wrap = (NodeResponderWrap *)data;
    if (status == OH_ABILITY_ERROR_OK && value != NULL) {
        bool accepted = false;
        napi_value accepted_value;
        if (napi_get_named_property(env, value, "accepted", &accepted_value) == napi_ok) {
            napi_get_value_bool(env, accepted_value, &accepted);
        }
        if (!accepted) {
            wrap->responder(env, OH_ABILITY_ERROR_BRIDGE, NULL,
                            "ohos.node plugin rejected the requested node operation", wrap->data);
            free(wrap);
            return;
        }
    }
    wrap->responder(env, status, NULL, error, wrap->data);
    free(wrap);
}

static int node_call(const char *action, const char *request_type, const char *response_type,
                     NodeActionKind kind, uint32_t a, uint32_t b,
                     OHAbility_ValueResponder responder, void *responder_data, uint32_t timeout_ms,
                     void (*wrapper)(napi_env, int, napi_value, const char *, void *)) {
    if (responder == NULL) {
        return OH_ABILITY_ERROR_INVALID_ARG;
    }
    NodeRequestArgs *args = (NodeRequestArgs *)calloc(1, sizeof(*args));
    NodeResponderWrap *wrap = (NodeResponderWrap *)malloc(sizeof(*wrap));
    if (args == NULL || wrap == NULL) {
        free(args);
        free(wrap);
        return OH_ABILITY_ERROR_BRIDGE;
    }
    args->kind = kind;
    args->a = a;
    args->b = b;
    wrap->responder = responder;
    wrap->data = responder_data;

    int rc = OHAbility_CallAsync(NODE_PLUGIN_ID, action, request_type, response_type,
                                 node_build_request, args, wrapper, wrap, timeout_ms);
    if (rc != OH_ABILITY_ERROR_OK) {
        free(args);
        free(wrap);
    }
    return rc;
}

int OHAbility_NodeCreateContainer(OHAbility_ValueResponder responder, void *responder_data,
                                  uint32_t timeout_ms) {
    return node_call(NODE_ACTION_CREATE_CONTAINER, NODE_TYPE_CREATE_CONTAINER_REQUEST,
                     NODE_TYPE_HANDLE_RESPONSE, NODE_ACTION_KIND_CREATE, 0, 0, responder,
                     responder_data, timeout_ms, node_handle_responder);
}

int OHAbility_NodeAppendChild(uint32_t parent_handle, uint32_t child_handle,
                              OHAbility_ValueResponder responder, void *responder_data,
                              uint32_t timeout_ms) {
    return node_call(NODE_ACTION_APPEND_CHILD, NODE_TYPE_APPEND_CHILD_REQUEST,
                     NODE_TYPE_ACKNOWLEDGEMENT, NODE_ACTION_KIND_APPEND, parent_handle,
                     child_handle, responder, responder_data, timeout_ms, node_ack_responder);
}

int OHAbility_NodeMountIntoRoot(uint32_t handle, OHAbility_ValueResponder responder,
                                void *responder_data, uint32_t timeout_ms) {
    return node_call(NODE_ACTION_MOUNT_INTO_ROOT, NODE_TYPE_MOUNT_INTO_ROOT_REQUEST,
                     NODE_TYPE_ACKNOWLEDGEMENT, NODE_ACTION_KIND_MOUNT, handle, 0, responder,
                     responder_data, timeout_ms, node_ack_responder);
}

int OHAbility_NodeDispose(uint32_t handle, OHAbility_ValueResponder responder, void *responder_data,
                          uint32_t timeout_ms) {
    return node_call(NODE_ACTION_DISPOSE, NODE_TYPE_DISPOSE_REQUEST, NODE_TYPE_ACKNOWLEDGEMENT,
                     NODE_ACTION_KIND_DISPOSE, handle, 0, responder, responder_data, timeout_ms,
                     node_ack_responder);
}
