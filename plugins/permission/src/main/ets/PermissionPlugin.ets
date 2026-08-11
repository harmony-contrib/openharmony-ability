import abilityAccessCtrl, { Permissions } from "@ohos.abilityAccessCtrl";
import hilog from "@ohos.hilog";
import {
  BridgeCallContext,
  BridgeTypedValue,
  AsyncPluginBase,
  BridgeContextRequirement,
} from "@ohos-rs/ability";

const TAG = "PermissionBridgePlugin";
const REQUEST_FAILED = -1;
const PERMISSION_REQUEST_TYPE = "ohos.permission.PermissionRequest";
const PERMISSION_RESPONSE_TYPE = "ohos.permission.PermissionResponse";

interface PermissionRequestPayload {
  permissions: string[];
}

class PermissionResponse {
  readonly codes: number[];

  constructor(codes: number[]) {
    this.codes = codes;
  }
}

function parsePermissions(payload: BridgeTypedValue): string[] {
  try {
    if (payload.typeName !== PERMISSION_REQUEST_TYPE || typeof payload.value !== "object") {
      throw new Error(`requires bridge type ${PERMISSION_REQUEST_TYPE}`);
    }
    const request = payload.value as PermissionRequestPayload;
    if (!request || !Array.isArray(request.permissions) || request.permissions.length === 0) {
      throw new Error("permissions must be a non-empty array");
    }
    if (request.permissions.some((permission) => !permission?.trim())) {
      throw new Error("permissions must contain only non-empty strings");
    }
    return request.permissions;
  } catch (error) {
    throw new Error(`Invalid permission request: ${String(error)}`);
  }
}

export class PermissionPlugin extends AsyncPluginBase {
  readonly id = "ohos.permission";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (action !== "request") {
      throw new Error(`Unsupported ohos.permission action '${action}'`);
    }
    const permissions = parsePermissions(payload);
    const codes: number[] = [];
    for (let index = 0; index < permissions.length; index++) {
      codes.push(REQUEST_FAILED);
    }
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const result = await manager.requestPermissionsFromUser(
        context.abilityContext,
        permissions as Permissions[],
      );
      const authResults = result.authResults || [];
      for (let index = 0; index < codes.length; index++) {
        codes[index] = authResults[index] ?? REQUEST_FAILED;
      }
    } catch (error) {
      hilog.error(0x0000, TAG, `request failed: ${String(error)}`);
    }
    if (!context.isActive()) {
      throw new Error("Ability was destroyed while permission request was pending");
    }
    return { typeName: PERMISSION_RESPONSE_TYPE, value: new PermissionResponse(codes) };
  }
}
