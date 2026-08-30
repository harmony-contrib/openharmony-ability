/*
 * ohos.url plugin — openLink demo (OH_ABILITY_PLUGIN_URL, default ON).
 * Outbound-only: the ArkTS UrlPlugin owns `UIAbilityContext.openLink`.
 */
#ifndef PLUGIN_URL_H
#define PLUGIN_URL_H

#include <napi/native_api.h>

int demo_register_url_plugin(void);

/* demoOpenUrl(): Promise<void> */
napi_value demo_open_url(napi_env env, napi_callback_info info);

#endif /* PLUGIN_URL_H */
