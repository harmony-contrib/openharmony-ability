/*
 * ohos.files plugin — file dialog demos (OH_ABILITY_PLUGIN_FILES, default ON).
 * Outbound-only: the ArkTS FilesPlugin owns the DocumentViewPicker flow.
 */
#ifndef PLUGIN_FILES_H
#define PLUGIN_FILES_H

#include <napi/native_api.h>

/* demoFileDialogOpen()/Save(): Promise<string[]> */
napi_value demo_file_dialog_open(napi_env env, napi_callback_info info);
napi_value demo_file_dialog_save(napi_env env, napi_callback_info info);

#endif /* PLUGIN_FILES_H */
