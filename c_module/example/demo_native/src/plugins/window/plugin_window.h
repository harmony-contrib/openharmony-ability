/*
 * ohos.window plugin (OH_ABILITY_PLUGIN_WINDOW, default ON).
 *
 * Reserved: the ArkTS WindowPlugin (sync avoid-area queries) is registered by the demo app, but
 * the C demo has no window-plugin surface yet. The macro is honored for build-time symmetry
 * with the other plugins; the registration point below is a no-op placeholder.
 */
#ifndef PLUGIN_WINDOW_H
#define PLUGIN_WINDOW_H

/* Registers the ohos.window plugin surface (currently a no-op placeholder). */
int demo_register_window_plugin(void);

#endif /* PLUGIN_WINDOW_H */
