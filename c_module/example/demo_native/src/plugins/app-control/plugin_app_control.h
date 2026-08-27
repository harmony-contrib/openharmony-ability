/*
 * ohos.app-control plugin (OH_ABILITY_PLUGIN_APP_CONTROL, default ON).
 *
 * Reserved: the ArkTS AppControlPlugin (sync main-thread terminate) is registered by the demo
 * app, but the C demo has no app-control surface yet. The macro is honored for build-time
 * symmetry with the other plugins; the registration point below is a no-op placeholder.
 */
#ifndef PLUGIN_APP_CONTROL_H
#define PLUGIN_APP_CONTROL_H

/* Registers the ohos.app-control plugin surface (currently a no-op placeholder). */
int demo_register_app_control_plugin(void);

#endif /* PLUGIN_APP_CONTROL_H */
