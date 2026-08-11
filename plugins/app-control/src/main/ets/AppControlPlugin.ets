import { appRecovery } from "@kit.AbilityKit";
import process from "@ohos.process";
import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  SyncPluginBase,
} from "@ohos-rs/ability";

const TERMINATE_REQUEST_TYPE = "ohos.app_control.TerminateRequest";
const TERMINATE_RESPONSE_TYPE = "ohos.app_control.TerminateResponse";
const RESTART_REQUEST_TYPE = "ohos.app_control.RestartRequest";
const RESTART_RESPONSE_TYPE = "ohos.app_control.RestartResponse";
const COLOR_MODE_REQUEST_TYPE = "ohos.app_control.ColorModeRequest";
const COLOR_MODE_RESPONSE_TYPE = "ohos.app_control.ColorModeResponse";

interface TerminateRequest {
  code: number;
}

interface RestartRequest {
  requested: boolean;
}

interface ColorModeRequest {
  mode: number;
}

class AcceptedResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function parseTerminateRequest(payload: BridgeTypedValue): TerminateRequest {
  if (payload.typeName !== TERMINATE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.app-control.terminate requires bridge type ${TERMINATE_REQUEST_TYPE}`);
  }
  const request = payload.value as TerminateRequest;
  if (!Number.isInteger(request?.code)) {
    throw new Error("terminate.code must be an integer");
  }
  return request;
}

function parseRestartRequest(payload: BridgeTypedValue): RestartRequest {
  if (
    payload.typeName !== RESTART_REQUEST_TYPE ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error(`ohos.app-control.restart requires bridge type ${RESTART_REQUEST_TYPE}`);
  }
  const request = payload.value as RestartRequest;
  if (request.requested !== true) {
    throw new Error("restart.requested must be true");
  }
  return request;
}

function parseColorModeRequest(payload: BridgeTypedValue): ColorModeRequest {
  if (payload.typeName !== COLOR_MODE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(
      `ohos.app-control.set-color-mode requires bridge type ${COLOR_MODE_REQUEST_TYPE}`,
    );
  }
  const request = payload.value as ColorModeRequest;
  if (!Number.isInteger(request?.mode) || request.mode < 0 || request.mode > 2) {
    throw new Error("set-color-mode.mode must be 0 (dark), 1 (light) or 2 (follow system)");
  }
  return request;
}

let lastProcessRestartAt: number = 0;

export class AppControlPlugin extends SyncPluginBase {
  readonly id = "ohos.app-control";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  invokeSync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): BridgeTypedValue {
    if (action === "terminate") {
      const request = parseTerminateRequest(payload);
      const manager = new process.ProcessManager();
      manager.exit(request.code);
      return { typeName: TERMINATE_RESPONSE_TYPE, value: new AcceptedResponse(true) };
    }

    if (action === "restart") {
      parseRestartRequest(payload);
      // 3-second cooldown: appRecovery.restartApp() has no onDestroy callback and the
      // process dies immediately; repeated calls before the first restart completes are
      // dropped to avoid a restart loop.
      const now = Date.now();
      if (now - lastProcessRestartAt < 3000) {
        throw new Error("restart is in cooldown; try again later");
      }
      lastProcessRestartAt = now;
      try {
        appRecovery.enableAppRecovery(
          appRecovery.RestartFlag.ALWAYS_RESTART,
          appRecovery.SaveOccasionFlag.SAVE_WHEN_ERROR,
          appRecovery.SaveModeFlag.SAVE_WITH_FILE,
        );
        appRecovery.restartApp();
      } catch (error) {
        if (lastProcessRestartAt === now) {
          lastProcessRestartAt = 0;
        }
        throw new Error(`restartApp failed: ${String(error)}`);
      }
      return { typeName: RESTART_RESPONSE_TYPE, value: new AcceptedResponse(true) };
    }

    if (action === "set-color-mode") {
      const request = parseColorModeRequest(payload);
      try {
        context.abilityContext.getApplicationContext().setColorMode(request.mode);
      } catch (error) {
        throw new Error(`setColorMode failed: ${String(error)}`);
      }
      return { typeName: COLOR_MODE_RESPONSE_TYPE, value: new AcceptedResponse(true) };
    }

    throw new Error(`Unsupported ohos.app-control action '${action}'`);
  }
}
