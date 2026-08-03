import common from "@ohos.app.ability.common";
import { updateManager } from "@kit.AppGalleryKit";
import { bundleManager } from "@kit.AbilityKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { BusinessError } from "@kit.BasicServicesKit";
import {
  BridgeCallContext,
  BridgeTypedValue,
  AsyncPluginBase,
  BridgeContextRequirement,
} from "@ohos-rs/ability";

const CHECK_REQUEST_TYPE = "ohos.updater.CheckRequest";
const CHECK_RESPONSE_TYPE = "ohos.updater.CheckResponse";
const ACKNOWLEDGEMENT_TYPE = "ohos.updater.Acknowledgement";

interface UpdaterCheckRequest {
  requested: boolean;
}

class UpdaterCheckResult {
  readonly updateAvailable: boolean;
  readonly currentVersion: string;
  readonly version: string;
  readonly body: string | null;
  readonly date: string | null;

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
    this.body = body;
    this.date = date;
  }
}

class UpdaterCheckResponse {
  readonly result: UpdaterCheckResult | null;

  constructor(result: UpdaterCheckResult | null) {
    this.result = result;
  }
}

class UpdaterAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function parseCheckRequest(payload: BridgeTypedValue): UpdaterCheckRequest {
  if (payload.typeName !== CHECK_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.updater requires bridge type ${CHECK_REQUEST_TYPE}`);
  }
  return payload.value as UpdaterCheckRequest;
}

async function checkForUpdate(context: common.UIAbilityContext): Promise<UpdaterCheckResult | null> {
  try {
    const checkResult = await updateManager.checkAppUpdate(context);
    if (checkResult.updateAvailable !== updateManager.UpdateAvailableCode.LATER_VERSION_EXIST) {
      hilog.info(0x0000, "UpdaterPlugin", "No update available");
      return null;
    }

    let currentVersion = "unknown";
    try {
      const bundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT,
      );
      currentVersion = bundleInfo.versionName || "unknown";
    } catch (error) {
      hilog.error(
        0x0000,
        "UpdaterPlugin",
        "getBundleInfoForSelf failed: %{public}s",
        JSON.stringify(error),
      );
    }

    // API 20+ exposes versionName; older API levels fall back to "unknown".
    const version = (checkResult as ESObject).versionName as string || "unknown";

    return new UpdaterCheckResult(true, currentVersion, String(version), null, null);
  } catch (error) {
    const err = error as BusinessError;
    hilog.error(
      0x0000,
      "UpdaterPlugin",
      "checkAppUpdate failed: code=%{public}d msg=%{public}s",
      err.code,
      err.message,
    );
    throw new Error(`checkAppUpdate failed: code=${err.code} msg=${err.message}`);
  }
}

async function showUpdateDialog(context: common.UIAbilityContext): Promise<number> {
  const resultCode = await updateManager.showUpdateDialog(context);
  hilog.info(0x0000, "UpdaterPlugin", "showUpdateDialog result: %{public}d", resultCode);
  return resultCode;
}

export class UpdaterPlugin extends AsyncPluginBase {
  readonly id = "ohos.updater";
  readonly version = 1;
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    parseCheckRequest(payload);
    if (action === "check") {
      const result = await checkForUpdate(context.abilityContext);
      if (!context.isActive()) {
        throw new Error("Ability was destroyed while update check was pending");
      }
      return { typeName: CHECK_RESPONSE_TYPE, value: new UpdaterCheckResponse(result) };
    }
    if (action === "download-and-install") {
      const resultCode = await showUpdateDialog(context.abilityContext);
      if (!context.isActive()) {
        throw new Error("Ability was destroyed while update dialog was pending");
      }
      if (resultCode !== updateManager.ShowUpdateResultCode.SHOW_DIALOG_SUCCESS) {
        throw new Error(`showUpdateDialog returned failure code: ${resultCode}`);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new UpdaterAcknowledgement(true) };
    }
    throw new Error(`Unsupported ohos.updater action '${action}'`);
  }
}
