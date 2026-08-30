/*
 * ohos.window plugin (OH_ABILITY_PLUGIN_WINDOW, default ON).
 *
 * Reserved: no demo surface yet. When implemented, outbound actions (for example the sync
 * avoid-area query of the ArkTS WindowPlugin) belong here behind the same macro.
 */
#include "demo_common.h"

int demo_register_window_plugin(void) {
#ifdef OH_ABILITY_PLUGIN_WINDOW
    static const OHAbility_Plugin plugin = {
        .execution = OH_ABILITY_PLUGIN_ASYNC,
        .required_contexts = OH_ABILITY_PLUGIN_CONTEXT_UI,
    };
    return OHAbility_RegisterPlugin("ohos.window", &plugin, NULL);
#else
    return OH_ABILITY_ERROR_OK;
#endif
}
