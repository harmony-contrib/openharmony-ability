/*
 * ohos.webview plugin (OH_ABILITY_PLUGIN_WEBVIEW, default ON).
 *
 * Inbound: a C plugin answers the ArkTS-originated sync events (before-engine-init /
 * engine-initialized / controller-attached / controller-removed / navigation-request /
 * download-start / download-end / title-change), installs the custom "demoweb" scheme handler
 * and the window.test JavaScript proxy on controller-attached.
 * Outbound: the webview demo exports (create / composed / bottom / evaluate / style ops) call
 * the ohos.webview plugin actions through the bridge.
 */
#ifndef PLUGIN_WEBVIEW_H
#define PLUGIN_WEBVIEW_H

#include <napi/native_api.h>

/* Registers the ohos.webview inbound plugin + the custom scheme (returns OK when disabled). */
int demo_register_webview_plugin(void);

napi_value demo_set_background_color(napi_env env, napi_callback_info info);
napi_value demo_set_visible(napi_env env, napi_callback_info info);
napi_value demo_create_webview(napi_env env, napi_callback_info info);
napi_value demo_create_composed_webview(napi_env env, napi_callback_info info);
napi_value demo_create_bottom_webview(napi_env env, napi_callback_info info);
napi_value demo_evaluate_webview_script(napi_env env, napi_callback_info info);

#endif /* PLUGIN_WEBVIEW_H */
