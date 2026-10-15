import process from "@ohos.process";
import common from "@ohos.app.ability.common";
import { ConfigurationConstant } from "@kit.AbilityKit";
import { BusinessError } from "@kit.BasicServicesKit";
import { Want } from "@kit.AbilityKit";
import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  SyncPluginBase,
} from "@ohos-rs/ability";

const TERMINATE_REQUEST_TYPE = "ohos.app_control.TerminateRequest";
const TERMINATE_RESPONSE_TYPE = "ohos.app_control.TerminateResponse";
const SET_COLOR_MODE_REQUEST_TYPE = "ohos.app_control.SetColorModeRequest";
const SET_COLOR_MODE_RESPONSE_TYPE = "ohos.app_control.SetColorModeResponse";
const HIDE_ABILITY_REQUEST_TYPE = "ohos.app_control.HideAbilityRequest";
const HIDE_ABILITY_RESPONSE_TYPE = "ohos.app_control.HideAbilityResponse";
const SHOW_ABILITY_REQUEST_TYPE = "ohos.app_control.ShowAbilityRequest";
const SHOW_ABILITY_RESPONSE_TYPE = "ohos.app_control.ShowAbilityResponse";

interface TerminateRequest {
  code: number;
}

interface SetColorModeRequest {
  colorMode: number;
}

class TerminateResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class SetColorModeResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class HideAbilityResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class ShowAbilityResponse {
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

function parseSetColorModeRequest(payload: BridgeTypedValue): SetColorModeRequest {
  if (payload.typeName !== SET_COLOR_MODE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(
      `ohos.app-control.set-color-mode requires bridge type ${SET_COLOR_MODE_REQUEST_TYPE}`,
    );
  }
  const request = payload.value as SetColorModeRequest;
  if (!Number.isInteger(request?.colorMode)) {
    throw new Error("set-color-mode.colorMode must be an integer");
  }
  return request;
}

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
      return { typeName: TERMINATE_RESPONSE_TYPE, value: new TerminateResponse(true) };
    }

    if (action === "set-color-mode") {
      const request = parseSetColorModeRequest(payload);
      this.setAppColorMode(request.colorMode, context);
      return { typeName: SET_COLOR_MODE_RESPONSE_TYPE, value: new SetColorModeResponse(true) };
    }

    if (action === "hide-ability") {
      const ctx = context.abilityContext;
      // hideAbility() takes no arguments in the current SDK (fire-and-forget).
      ctx.hideAbility();
      return { typeName: HIDE_ABILITY_RESPONSE_TYPE, value: new HideAbilityResponse(true) };
    }

    if (action === "show-ability") {
      const ctx = context.abilityContext;
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name,
      };
      // startAbility(want) supports Promise (unlike hideAbility which is callback-only).
      // Fire-and-forget: initiate the call and immediately return accepted=true.
      ctx.startAbility(want).catch((e: BusinessError) => {
        console.error(`[AppControl] showAbility failed: ${e.code} ${e.message}`);
      });
      return { typeName: SHOW_ABILITY_RESPONSE_TYPE, value: new ShowAbilityResponse(true) };
    }

    throw new Error(`Unsupported ohos.app-control action '${action}'`);
  }

  private setAppColorMode(code: number, context: BridgeCallContext): void {
    // Map the bridge integer to ConfigurationConstant.ColorMode.
    // 0 → COLOR_MODE_DARK, 1 → COLOR_MODE_LIGHT, default → COLOR_MODE_NOT_SET.
    // Do NOT pass the raw integer to setColorMode — OHOS expects the enum value,
    // and 2 is not a legal ColorMode value (NOT_SET is a distinct constant).
    let colorMode: ConfigurationConstant.ColorMode;
    switch (code) {
      case 0:
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
        break;
      case 1:
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
        break;
      default:
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
        break;
    }

    // Capture only the application context (survives the callback) — the
    // BridgeCallContext itself is only valid during the current N-API callback.
    const applicationContext = context.abilityContext.getApplicationContext();

    // Defer setColorMode to the next event-loop tick to avoid deadlock:
    // setColorMode synchronously triggers onConfigurationUpdate, which calls
    // back into Rust on the main thread. If we are already inside a NAPI
    // callback from Rust (MainThreadSync), this deadlocks the main thread.
    // See ohos-constraints 4.3 and ArkHelper.ets L893-927 for the same pattern.
    setTimeout(() => {
      try {
        applicationContext.setColorMode(colorMode);
      } catch (err) {
        // The ability may have been destroyed between scheduling and execution.
        // Silently swallow — the response was already accepted.
      }
    }, 0);
  }
}
