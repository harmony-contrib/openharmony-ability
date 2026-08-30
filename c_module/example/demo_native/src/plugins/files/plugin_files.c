/*
 * ohos.files plugin (OH_ABILITY_PLUGIN_FILES, default ON).
 *
 * Wire contract (verified against the ArkTS FilesPlugin):
 *   ohos.files "file-dialog" ohos.files.DialogOptions{dialogType,allowMany,filters...} ->
 *                             ohos.files.DialogResponse{files,filter}
 */
#include <stdlib.h>
#include <string.h>

#include "demo_common.h"

#ifdef OH_ABILITY_PLUGIN_FILES

static const OHAbility_Plugin FILES_PLUGIN = {
    .execution = OH_ABILITY_PLUGIN_ASYNC,
    .required_contexts = OH_ABILITY_PLUGIN_CONTEXT_ABILITY,
};

int demo_register_files_plugin(void) {
    return OHAbility_RegisterPlugin("ohos.files", &FILES_PLUGIN, NULL);
}

static int demo_build_file_dialog(napi_env env, napi_value *out, void *data) {
    const char *dialog_type = (const char *)data;
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
    demo_object_string(env, request, "dialogType", dialog_type);
    demo_object_bool(env, request, "allowMany", strcmp(dialog_type, "open-file") == 0);

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

static napi_value demo_file_dialog(napi_env env, napi_callback_info info, const char *dialog_type) {
    (void)info;
    napi_value promise;
    DemoDeferred *ctx = demo_deferred_new(env, &promise);
    if (ctx == NULL) {
        return NULL;
    }
    char *dialog_type_copy = strdup(dialog_type);
    if (dialog_type_copy == NULL) {
        demo_deferred_reject(ctx, env, "file dialog: out of memory");
        free(ctx);
        return promise;
    }
    int rc = OHAbility_CallAsync("ohos.files", "file-dialog", "ohos.files.DialogOptions",
                                 "ohos.files.DialogResponse", demo_build_file_dialog,
                                 dialog_type_copy, demo_responder_files, ctx, 60000);
    if (rc != OH_ABILITY_ERROR_OK) {
        free(dialog_type_copy);
        demo_deferred_reject(ctx, env, "bridge not ready");
        free(ctx);
    }
    return promise;
}

napi_value demo_file_dialog_open(napi_env env, napi_callback_info info) {
    return demo_file_dialog(env, info, "open-file");
}

napi_value demo_file_dialog_save(napi_env env, napi_callback_info info) {
    return demo_file_dialog(env, info, "save-file");
}

#else /* !OH_ABILITY_PLUGIN_FILES */

int demo_register_files_plugin(void) { return OH_ABILITY_ERROR_OK; }

napi_value demo_file_dialog_open(napi_env env, napi_callback_info info) {
    (void)info;
    return demo_disabled_promise(env, "ohos.files");
}

napi_value demo_file_dialog_save(napi_env env, napi_callback_info info) {
    (void)info;
    return demo_disabled_promise(env, "ohos.files");
}

#endif /* OH_ABILITY_PLUGIN_FILES */
