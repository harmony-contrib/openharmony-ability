import { appRecovery } from "@kit.AbilityKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeTypedValue,
  DOMAIN,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

const RESTART_REQUEST_TYPE = "ohos.process.RestartRequest";
const RESTART_RESPONSE_TYPE = "ohos.process.RestartResponse";

/**
 * Restart the application via appRecovery.restartApp().
 *
 * Calls enableAppRecovery() before restartApp() to ensure recovery is
 * configured. (Ideally this would be in AbilityStage.onCreate(), but SDK 12
 * hvigor does not support the abilityStage field in module.json5.)
 *
 * Requires module.json5 to set recoverable: true on the target Ability.
 * This is a hard process kill — onDestroy is NOT triggered.
 *
 * @returns 0 on success, -2 on failure
 */
const restartApp = (): number => {
  try {
    hilog.info(DOMAIN, "ProcessPlugin", "enabling appRecovery");
    appRecovery.enableAppRecovery(
      appRecovery.RestartFlag.ALWAYS_RESTART,
      appRecovery.SaveOccasionFlag.SAVE_WHEN_ERROR,
      appRecovery.SaveModeFlag.SAVE_WITH_FILE,
    );
    hilog.info(DOMAIN, "ProcessPlugin", "calling appRecovery.restartApp()");
    appRecovery.restartApp();
    hilog.info(DOMAIN, "ProcessPlugin", "appRecovery.restartApp() returned");
    return 0;
  } catch (err) {
    const error = err as Error;
    hilog.error(DOMAIN, "ProcessPlugin", "appRecovery.restartApp failed: %{public}s", error.message);
    return -2;
  }
};

class RestartResponse {
  readonly code: number;

  constructor(code: number) {
    this.code = code;
  }
}

/**
 * Process control bridge plugin for ArkTS.
 *
 * Routes the restart operation from the Rust `OpenHarmonyApp::restart()`
 * facade to `appRecovery`. Restores the former TSFN transport
 * (`helper/restart.ets`), whose `set_helper` was never called after the
 * `#[ability]` derive refactor.
 *
 * Plugin ID: `ohos.process`
 * Required contexts: none
 */
export class ProcessPlugin extends AsyncPluginBase {
  readonly id = "ohos.process";
  readonly requires: BridgeContextRequirement[] = [];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Process bridge session is no longer active");
    }

    if (action === "restart") {
      expectBridgeRequestType(payload, "ohos.process", action, RESTART_REQUEST_TYPE);
      const code = restartApp();
      return { typeName: RESTART_RESPONSE_TYPE, value: new RestartResponse(code) };
    }

    throw new Error(`Unsupported ohos.process action '${action}'`);
  }
}
