import common from "@ohos.app.ability.common";
import { autoStartupManager, Want } from "@kit.AbilityKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from "@kit.BasicServicesKit";
import { DOMAIN } from './constants';

/**
 * Navigate to the system "App Startup Management" settings page.
 *
 * OHOS does not allow ordinary apps to programmatically enable/disable autostart.
 * This function opens the settings page so the user can manually toggle the switch.
 *
 * @param context - UIAbilityContext
 */
export const openAutostartSettings = async (context: common.UIAbilityContext): Promise<void> => {
  const want: Want = {
    bundleName: 'com.huawei.hmos.settings',
    abilityName: 'com.huawei.hmos.settings.MainAbility',
    uri: 'pc_app_setup_settings'
  };

  try {
    await context.startAbility(want);
    hilog.info(DOMAIN, 'autostart', 'Navigated to autostart settings page');
  } catch (err) {
    const error = err as BusinessError;
    hilog.error(DOMAIN, 'autostart', 'startAbility failed: code=%{public}d, message=%{public}s',
      error.code, error.message);
    throw error;
  }
};

/**
 * Query whether the current app has autostart enabled.
 *
 * Uses `autoStartupManager.getAutoStartupStatusForSelf()` (API 21+).
 * On error 801 (capability not supported, e.g. unsupported device type),
 * silently returns `false`.
 *
 * Note: Version guard (`sdk_api_version >= 21`) is done on the Rust side.
 * This function is only called when the version check passes.
 *
 * @param context - UIAbilityContext (unused, kept for API consistency)
 * @returns true if autostart is enabled, false otherwise
 */
export const getAutostartStatus = async (_context: common.UIAbilityContext): Promise<boolean> => {
  try {
    const isEnabled = await autoStartupManager.getAutoStartupStatusForSelf();
    hilog.info(DOMAIN, 'autostart', 'getAutoStartupStatusForSelf: %{public}s', String(isEnabled));
    return isEnabled;
  } catch (err) {
    const error = err as BusinessError;
    // Error 801: Capability not supported (e.g. TV, unsupported device type)
    if (error.code === 801) {
      hilog.info(DOMAIN, 'autostart', 'autoStartupManager not supported on this device, returning false');
      return false;
    }
    hilog.error(DOMAIN, 'autostart', 'getAutoStartupStatusForSelf failed: code=%{public}d, message=%{public}s',
      error.code, error.message);
    throw error;
  }
};
