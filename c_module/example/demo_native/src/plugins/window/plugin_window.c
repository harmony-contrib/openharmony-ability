/*
 * ohos.window plugin (OH_ABILITY_PLUGIN_WINDOW, default ON).
 *
 * Reserved: no demo surface yet. When implemented, outbound actions (for example the sync
 * avoid-area query of the ArkTS WindowPlugin) belong here behind the same macro.
 */
#include "demo_common.h"

int demo_register_window_plugin(void) {
#ifdef OH_ABILITY_PLUGIN_WINDOW
    /* Placeholder: the demo does not exercise the ohos.window plugin yet. */
    return OH_ABILITY_ERROR_OK;
#else
    return OH_ABILITY_ERROR_OK;
#endif
}
