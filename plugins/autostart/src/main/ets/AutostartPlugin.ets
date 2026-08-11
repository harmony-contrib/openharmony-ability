import common from "@ohos.app.ability.common";
import { autoStartupManager, Want } from "@kit.AbilityKit";
import { BusinessError, deviceInfo } from "@kit.BasicServicesKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeTypedValue,
} from "@ohos-rs/ability";

const REQUEST_TYPE = "ohos.autostart.Request";
const ACKNOWLEDGEMENT_TYPE = "ohos.autostart.Acknowledgement";
const STATUS_RESPONSE_TYPE = "ohos.autostart.StatusResponse";

interface AutostartRequest {
  requested: boolean;
}

class AutostartAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class AutostartStatusResponse {
  readonly enabled: boolean;
  readonly supported: boolean;

  constructor(enabled: boolean, supported: boolean) {
    this.enabled = enabled;
    this.supported = supported;
  }
}

function parseRequest(payload: BridgeTypedValue, action: string): AutostartRequest {
  if (
    payload.typeName !== REQUEST_TYPE ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error(`ohos.autostart.${action} requires bridge type ${REQUEST_TYPE}`);
  }
  const request = payload.value as AutostartRequest;
  if (request.requested !== true) {
    throw new Error(`ohos.autostart.${action}.requested must be true`);
  }
  return request;
}

async function openSettings(context: common.UIAbilityContext): Promise<void> {
  const want: Want = {
    bundleName: "com.huawei.hmos.settings",
    abilityName: "com.huawei.hmos.settings.MainAbility",
    uri: "pc_app_setup_settings",
  };
  await context.startAbility(want);
}

let settingsOpenInFlight: Promise<void> | null = null;
let statusQueryInFlight: Promise<AutostartStatusResponse> | null = null;

function openSettingsOnce(context: common.UIAbilityContext): Promise<void> {
  if (settingsOpenInFlight !== null) {
    return settingsOpenInFlight;
  }
  const operation = openSettings(context).finally((): void => {
    if (settingsOpenInFlight === operation) {
      settingsOpenInFlight = null;
    }
  });
  settingsOpenInFlight = operation;
  return operation;
}

async function queryStatus(): Promise<AutostartStatusResponse> {
  if (deviceInfo.sdkApiVersion < 21) {
    return new AutostartStatusResponse(false, false);
  }
  try {
    const enabled = await autoStartupManager.getAutoStartupStatusForSelf();
    return new AutostartStatusResponse(enabled, true);
  } catch (error) {
    const businessError = error as BusinessError;
    if (businessError.code === 801) {
      return new AutostartStatusResponse(false, false);
    }
    throw new Error(
      `getAutoStartupStatusForSelf failed: code=${businessError.code} msg=${businessError.message}`,
    );
  }
}

function queryStatusOnce(): Promise<AutostartStatusResponse> {
  if (statusQueryInFlight !== null) {
    return statusQueryInFlight;
  }
  const operation = queryStatus().finally((): void => {
    if (statusQueryInFlight === operation) {
      statusQueryInFlight = null;
    }
  });
  statusQueryInFlight = operation;
  return operation;
}

export class AutostartPlugin extends AsyncPluginBase {
  readonly id = "ohos.autostart";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    parseRequest(payload, action);
    if (action === "open-settings") {
      try {
        await openSettingsOnce(context.abilityContext);
      } catch (error) {
        const businessError = error as BusinessError;
        throw new Error(
          `open autostart settings failed: code=${businessError.code} msg=${businessError.message}`,
        );
      }
      if (!context.isActive()) {
        throw new Error("Ability was destroyed while autostart settings were opening");
      }
      return {
        typeName: ACKNOWLEDGEMENT_TYPE,
        value: new AutostartAcknowledgement(true),
      };
    }
    if (action === "is-enabled") {
      const response = await queryStatusOnce();
      if (!context.isActive()) {
        throw new Error("Ability was destroyed while autostart status was queried");
      }
      return { typeName: STATUS_RESPONSE_TYPE, value: response };
    }
    throw new Error(`Unsupported ohos.autostart action '${action}'`);
  }
}
