/*
 * ohos.app-control plugin (OH_ABILITY_PLUGIN_APP_CONTROL, default ON).
 *
 * Reserved: no demo surface yet. When implemented, the sync main-thread terminate action of the
 * ArkTS AppControlPlugin belongs here behind the same macro.
 */
#include "demo_common.h"

int demo_register_app_control_plugin(void) {
#ifdef OH_ABILITY_PLUGIN_APP_CONTROL
    /* Placeholder: the demo does not exercise the ohos.app-control plugin yet. */
    return OH_ABILITY_ERROR_OK;
#else
    return OH_ABILITY_ERROR_OK;
#endif
}
