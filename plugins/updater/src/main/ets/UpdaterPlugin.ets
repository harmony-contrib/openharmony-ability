import { common, bundleManager } from "@kit.AbilityKit";
import { updateManager } from "@kit.AppGalleryKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { BusinessError } from "@kit.BasicServicesKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  DOMAIN,
} from "@ohos-rs/ability";

const TAG = "UpdaterPlugin.ets";

const CHECK_REQUEST_TYPE = "ohos.updater.CheckRequest";
const CHECK_RESPONSE_TYPE = "ohos.updater.CheckResponse";
const DOWNLOAD_AND_INSTALL_REQUEST_TYPE = "ohos.updater.DownloadAndInstallRequest";
const DOWNLOAD_AND_INSTALL_RESPONSE_TYPE = "ohos.updater.DownloadAndInstallResponse";

/** Response carrying the AppGallery update probe result. */
class UpdaterCheckResponse {
  readonly updateAvailable: boolean;
  readonly currentVersion: string;
  readonly version: string;
  // Optional properties: napi-ohos's derive codegen decodes an Option<T> field
  // as T — a PRESENT-but-null value fails with `StringExpected on
  // UpdaterCheckResponse.body`, while an ABSENT property maps to Rust None.
  // Keep them unset when null (same pattern as AccountPlugin.accessToken,
  // device-verified 2026-08-31).
  readonly body?: string;
  readonly date?: string;

  constructor(
    updateAvailable: boolean,
    currentVersion: string,
    version: string,
    body: string | null,
    date: string | null,
  ) {
    this.updateAvailable = updateAvailable;
    this.currentVersion = currentVersion;
    this.version = version;
    if (body !== null) {
      this.body = body;
    }
    if (date !== null) {
      this.date = date;
    }
  }
}

class UpdaterDownloadAndInstallResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

/**
 * Type-safe shape for the optional `versionName` field on `CheckUpdateResult`.
 *
 * On API 20+, `CheckUpdateResult` exposes `versionName`; on API 12 (SDK 12) it
 * does not. ArkTS forbids `any`/`unknown` (arkts-no-any-unknown), so the field
 * is accessed through this interface cast rather than `(checkResult as any)`.
 * The cast is structurally valid: `CheckUpdateResult` carries `updateAvailable`,
 * and `versionName` is optional.
 */
interface VersionedCheckResult {
  versionName?: string;
}

/**
 * AppGallery update bridge plugin (`ohos.updater`).
 *
 * Actions:
 * - `check`              → pure query via `updateManager.checkAppUpdate`; no dialog.
 *   Returns `updateAvailable` plus `currentVersion` / `version` / `body` / `date`.
 * - `downloadAndInstall` → shows the system AppGallery update dialog, which drives
 *   the entire download + install flow (the OHOS equivalent of "download and install").
 *
 * Replaces the former TSFN transport (`helper/updater.ets` + `get_helper()`),
 * whose `set_helper` was never called after the `#[ability]` derive refactor, so
 * update checks silently failed at runtime. Routes through the bridge
 * `bridgeInvoke` which is wired up per Ability session.
 */
export class UpdaterPlugin extends AsyncPluginBase {
  readonly id = "ohos.updater";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }

    if (action === "check") {
      if (payload.typeName !== CHECK_REQUEST_TYPE) {
        throw new Error(`ohos.updater.check requires bridge type ${CHECK_REQUEST_TYPE}`);
      }
      const result = await this.checkForUpdate(context.abilityContext);
      return { typeName: CHECK_RESPONSE_TYPE, value: result };
    }

    if (action === "downloadAndInstall") {
      if (payload.typeName !== DOWNLOAD_AND_INSTALL_REQUEST_TYPE) {
        throw new Error(
          `ohos.updater.downloadAndInstall requires bridge type ${DOWNLOAD_AND_INSTALL_REQUEST_TYPE}`,
        );
      }
      await this.showUpdateDialog(context.abilityContext);
      return {
        typeName: DOWNLOAD_AND_INSTALL_RESPONSE_TYPE,
        value: new UpdaterDownloadAndInstallResponse(true),
      };
    }

    throw new Error(`Unsupported ohos.updater action '${action}'`);
  }

  /**
   * Check for app updates via AppGallery. Pure query — no dialog is shown.
   * On SDK 12 (API 12), `CheckUpdateResult.versionName` is not available
   * (API 20+ only), so `version` falls back to "unknown" in that case.
   */
  private async checkForUpdate(context: common.UIAbilityContext): Promise<UpdaterCheckResponse> {
    try {
      const checkResult = await updateManager.checkAppUpdate(context);

      if (checkResult.updateAvailable !== updateManager.UpdateAvailableCode.LATER_VERSION_EXIST) {
        hilog.info(DOMAIN, TAG, "No update available");
        return new UpdaterCheckResponse(false, "unknown", "unknown", null, null);
      }

      // Get current version from bundleManager.
      let currentVersion = "unknown";
      try {
        const bundleInfo = await bundleManager.getBundleInfoForSelf(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT,
        );
        currentVersion = bundleInfo.versionName || "unknown";
      } catch (err) {
        hilog.error(
          DOMAIN,
          TAG,
          "Failed to get bundle info: %{public}s",
          JSON.stringify(err),
        );
      }

      // On API 20+, versionName is available in CheckUpdateResult. On API 12
      // (SDK 12) it is not — accessed via a typed cast (no `any`/`unknown`).
      const version = (checkResult as VersionedCheckResult).versionName ?? "unknown";

      hilog.info(
        DOMAIN,
        TAG,
        "Update available: %{public}s -> %{public}s",
        currentVersion,
        version,
      );
      return new UpdaterCheckResponse(true, currentVersion, version, null, null);
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(
        DOMAIN,
        TAG,
        "checkAppUpdate failed: code=%{public}d, message=%{public}s",
        error.code,
        error.message,
      );
      throw error;
    }
  }

  /** Show the system AppGallery update dialog (drives download + install). */
  private async showUpdateDialog(context: common.UIAbilityContext): Promise<void> {
    try {
      const resultCode = await updateManager.showUpdateDialog(context);
      if (resultCode !== updateManager.ShowUpdateResultCode.SHOW_DIALOG_SUCCESS) {
        throw new Error(`showUpdateDialog returned failure code: ${resultCode}`);
      }
      hilog.info(DOMAIN, TAG, "Update dialog shown successfully");
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(
        DOMAIN,
        TAG,
        "showUpdateDialog failed: code=%{public}d, message=%{public}s",
        error.code,
        error.message,
      );
      throw error;
    }
  }
}
