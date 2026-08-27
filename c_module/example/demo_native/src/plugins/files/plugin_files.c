/*
 * ohos.files plugin (OH_ABILITY_PLUGIN_FILES, default ON).
 *
 * Wire contract (verified against the ArkTS FilesPlugin):
 *   ohos.files "file-dialog" ohos.files.DialogOptions{type,allowMany,filters...} ->
 *                             ohos.files.DialogResponse{files,filter}
 */
#include <stdlib.h>

#include "demo_common.h"

#ifdef OH_ABILITY_PLUGIN_FILES

static int demo_build_file_dialog(napi_env env, napi_value *out, void *data) {
    int32_t dialog_type = (int32_t)(intptr_t)data;
    static const struct {
        const char *name;
        const char *pattern;
    } FILTERS[] = {
        {"Text", "txt;md"},
        {"Images", "png;jpg"},
    };
    napi_value request;
    if (napi_create_object(env, &request) != napi_ok) {
        return OH_ABILITY_ERROR_BRIDGE;
    }
    demo_object_int32(env, request, "type", dialog_type);
    demo_object_bool(env, request, "allowMany", true);

    napi_value filters;
    napi_create_array_with_length(env, 2, &filters);
    for (size_t i = 0; i < 2; i++) {
        napi_value filter;
        napi_create_object(env, &filter);
        demo_object_string(env, filter, "name", FILTERS[i].name);
        demo_object_string(env, filter, "pattern", FILTERS[i].pattern);
        napi_set_element(env, filters, (uint32_t)i, filter);
    }
    napi_set_named_property(env, request, "filters", filters);
    *out = request;
    return OH_ABILITY_ERROR_OK;
}

static void demo_responder_files(napi_env env, int status, napi_value value, const char *error,
                                 void *data) {
    DemoDeferred *ctx = (DemoDeferred *)data;
    if (status != OH_ABILITY_ERROR_OK || value == NULL) {
        demo_deferred_reject(ctx, env, error != NULL ? error : "file dialog failed");
        free(ctx);
        return;
    }
    napi_value files;
    if (napi_get_named_property(env, value, "files", &files) != napi_ok) {
        demo_deferred_reject(ctx, env, "file dialog response has no files");
        free(ctx);
        return;
    }
    demo_deferred_resolve(ctx, env, files);
    free(ctx);
}

static napi_value demo_file_dialog(napi_env env, napi_callback_info info, int32_t dialog_type) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    int rc = OHAbility_CallAsync("ohos.files", 1, "file-dialog", "ohos.files.DialogOptions",
                                 "ohos.files.DialogResponse", demo_build_file_dialog,
                                 (void *)(intptr_t)dialog_type, demo_responder_files, ctx, 60000);
    if (rc != OH_ABILITY_ERROR_OK) {
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

napi_value demo_file_dialog_open(napi_env env, napi_callback_info info) {
    return demo_file_dialog(env, info, 0); /* OPEN_FILE */
}

napi_value demo_file_dialog_save(napi_env env, napi_callback_info info) {
    return demo_file_dialog(env, info, 1); /* SAVE_FILE */
}

#else /* !OH_ABILITY_PLUGIN_FILES */

napi_value demo_file_dialog_open(napi_env env, napi_callback_info info) {
    (void)info;
    return demo_disabled_promise(env, "ohos.files");
}

napi_value demo_file_dialog_save(napi_env env, napi_callback_info info) {
    (void)info;
    return demo_disabled_promise(env, "ohos.files");
}

#endif /* OH_ABILITY_PLUGIN_FILES */
