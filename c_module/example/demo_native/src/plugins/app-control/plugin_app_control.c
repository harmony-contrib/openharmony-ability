/*
 * ohos.app-control plugin (OH_ABILITY_PLUGIN_APP_CONTROL, default ON).
 *
 * Reserved: no demo surface yet. When implemented, the sync main-thread terminate action of the
 * ArkTS AppControlPlugin belongs here behind the same macro.
 */
#include "demo_common.h"

int demo_register_app_control_plugin(void) {
#ifdef OH_ABILITY_PLUGIN_APP_CONTROL
    static const OHAbility_Plugin plugin = {
        .execution = OH_ABILITY_PLUGIN_SYNC_MAIN_THREAD,
        .required_contexts = OH_ABILITY_PLUGIN_CONTEXT_ABILITY,
    };
    return OHAbility_RegisterPlugin("ohos.app-control", &plugin, NULL);
#else
    return OH_ABILITY_ERROR_OK;
#endif
}
