import { autoStartupManager, Want } from "@kit.AbilityKit";
import { BusinessError } from "@kit.BasicServicesKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  BridgeAcknowledgement,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

// ── Bridge type name contracts ────────────────────────────────────────────────
// These must match the Rust-side `impl_bridge_napi_type!` TYPE_NAME values.

const ENABLE_REQUEST_TYPE = "ohos.autostart.EnableRequest";
const DISABLE_REQUEST_TYPE = "ohos.autostart.DisableRequest";
const IS_ENABLED_REQUEST_TYPE = "ohos.autostart.IsEnabledRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.autostart.Acknowledgement";
const IS_ENABLED_RESPONSE_TYPE = "ohos.autostart.IsEnabledResponse";

class AutostartIsEnabledResponse {
  readonly enabled: boolean;

  constructor(enabled: boolean) {
    this.enabled = enabled;
  }
}

function ack(accepted: boolean): BridgeTypedValue {
  return {
    typeName: ACKNOWLEDGEMENT_TYPE,
    value: new BridgeAcknowledgement(accepted),
  };
}

export class AutostartPlugin extends AsyncPluginBase {
  readonly id = "ohos.autostart";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }

    if (action === "enable") {
      expectBridgeRequestType(payload, "ohos.autostart", action, ENABLE_REQUEST_TYPE);
      return ack(await this.openAutostartSettings());
    }

    if (action === "disable") {
      expectBridgeRequestType(payload, "ohos.autostart", action, DISABLE_REQUEST_TYPE);
      return ack(await this.openAutostartSettings());
    }

    if (action === "is-enabled") {
      expectBridgeRequestType(payload, "ohos.autostart", action, IS_ENABLED_REQUEST_TYPE);
      const enabled = await this.queryAutostartStatus();
      return {
        typeName: IS_ENABLED_RESPONSE_TYPE,
        value: new AutostartIsEnabledResponse(enabled),
      };
    }

    throw new Error(`Unsupported ohos.autostart action '${action}'`);
  }

  /**
   * Opens the system "App Startup Management" settings page.
   *
   * OHOS does not allow ordinary apps to programmatically enable/disable autostart.
   * This navigates to the settings page so the user can manually toggle the switch.
   *
   * NOTE: `pc_app_setup_settings` is the PC/2in1 device URI verified in the legacy
   * implementation. OHOS documentation also suggests `application_startup_settings`
   * with `want.parameters.pushParams` set to the current bundle name. If device
   * testing reveals `pc_app_setup_settings` does not land on the correct page,
   * switch to `application_startup_settings` + `pushParams`.
   */
  private async openAutostartSettings(): Promise<boolean> {
    const want: Want = {
      bundleName: "com.huawei.hmos.settings",
      abilityName: "com.huawei.hmos.settings.MainAbility",
      uri: "pc_app_setup_settings", // TODO: device-verify; fallback: "application_startup_settings" + pushParams
    };

    try {
      const abilityContext = this.getContext().abilityContext;
      await abilityContext.startAbility(want);
      return true;
    } catch (err) {
      const error = err as BusinessError;
      console.error(`[Autostart] startAbility failed: code=${error.code}, message=${error.message}`);
      return false;
    }
  }

  /**
   * Queries whether autostart is enabled for this application.
   *
   * Uses `autoStartupManager.getAutoStartupStatusForSelf()` (API 21+).
   * On error 801 (capability not supported, e.g. unsupported device type),
   * silently returns `false`.
   *
   * Note: The API version guard (sdk_api_version >= 21) is enforced on the Rust side.
   * This ArkTS method is only called when the version check passes.
   */
  private async queryAutostartStatus(): Promise<boolean> {
    try {
      return await autoStartupManager.getAutoStartupStatusForSelf();
    } catch (err) {
      const error = err as BusinessError;
      if (error.code === 801) {
        // Capability not supported on this device — return false silently.
        return false;
      }
      console.error(`[Autostart] getAutoStartupStatusForSelf failed: code=${error.code}, message=${error.message}`);
      return false;
    }
  }
}
