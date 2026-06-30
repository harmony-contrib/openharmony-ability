import common from "@ohos.app.ability.common";
import { updateManager } from "@kit.AppGalleryKit";
import { bundleManager } from "@kit.AbilityKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from "@kit.BasicServicesKit";
import { DOMAIN } from './constants';

export interface CheckResult {
  updateAvailable: boolean;
  currentVersion: string;
  version: string;
  body: string | null;
  date: string | null;
}

/**
 * Check for app updates via AppGallery.
 *
 * This is a pure query — no dialog is shown.
 * On SDK 12 (API 12), `CheckUpdateResult.versionName` is not available (API 20+ only),
 * so `version` will be "unknown" in that case.
 *
 * Always returns a CheckResult object. `updateAvailable` is false when no update exists.
 *
 * @param context - UIAbilityContext
 * @returns CheckResult with updateAvailable flag
 */
export const check = async (context: common.UIAbilityContext): Promise<CheckResult> => {
  try {
    // Check for updates
    const checkResult = await updateManager.checkAppUpdate(context);

    if (checkResult.updateAvailable !== updateManager.UpdateAvailableCode.LATER_VERSION_EXIST) {
      hilog.info(DOMAIN, 'updater.check', 'No update available');
      return {
        updateAvailable: false,
        currentVersion: "unknown",
        version: "unknown",
        body: null,
        date: null,
      };
    }

    // Get current version from bundleManager
    let currentVersion = "unknown";
    try {
      const bundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
      );
      currentVersion = bundleInfo.versionName || "unknown";
    } catch (err) {
      hilog.error(DOMAIN, 'updater.check', 'Failed to get bundle info: %{public}s', JSON.stringify(err));
    }

    // On API 20+, versionName is available in CheckUpdateResult
    // On API 12 (SDK 12), it's not available, so we use "unknown"
    const version = (checkResult as any).versionName || "unknown";

    const result: CheckResult = {
      updateAvailable: true,
      currentVersion: currentVersion,
      version: version,
      body: null,  // AppGallery API does not provide update notes
      date: null,  // AppGallery API does not provide release date
    };

    hilog.info(DOMAIN, 'updater.check', 'Update available: %{public}s -> %{public}s',
      currentVersion, version);
    return result;
  } catch (err) {
    const error = err as BusinessError;
    hilog.error(DOMAIN, 'updater.check', 'checkAppUpdate failed: code=%{public}d, message=%{public}s',
      error.code, error.message);
    throw error;
  }
};

/**
 * Show the system AppGallery update dialog.
 *
 * @param context - UIAbilityContext
 * @returns ShowUpdateResultCode (0=success, 1=failure)
 */
export const showUpdateDialog = async (context: common.UIAbilityContext): Promise<number> => {
  try {
    const resultCode = await updateManager.showUpdateDialog(context);
    hilog.info(DOMAIN, 'updater.showUpdateDialog', 'Dialog result: %{public}d', resultCode);
    return resultCode;
  } catch (err) {
    const error = err as BusinessError;
    hilog.error(DOMAIN, 'updater.showUpdateDialog', 'showUpdateDialog failed: code=%{public}d, message=%{public}s',
      error.code, error.message);
    throw error;
  }
};

/**
 * Download and install the update by showing the system AppGallery dialog.
 *
 * This is the OHOS equivalent of "download and install" — the system dialog
 * drives the entire update flow.
 *
 * @param context - UIAbilityContext
 * @throws Error if dialog fails (SHOW_DIALOG_FAILURE = 1)
 */
export const downloadAndInstall = async (context: common.UIAbilityContext): Promise<void> => {
  const resultCode = await showUpdateDialog(context);

  if (resultCode !== updateManager.ShowUpdateResultCode.SHOW_DIALOG_SUCCESS) {
    throw new Error(`showUpdateDialog returned failure code: ${resultCode}`);
  }

  hilog.info(DOMAIN, 'updater.downloadAndInstall', 'Update dialog shown successfully');
};
