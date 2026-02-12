/*
 * Permission request helper for OpenHarmony.
 * Returns Promise<number | number[]> for single/multiple permission requests.
 */

import abilityAccessCtrl, { Permissions } from "@ohos.abilityAccessCtrl";
import common from "@ohos.app.ability.common";
import hilog from "@ohos.hilog";

const TAG = "PermissionHelper";
const REQUEST_FAILED: number = -1;

function normalizePermission(permission: string | string[]): string[] {
  return Array.isArray(permission) ? permission : [permission];
}

/**
 * Request permission(s) and return auth result code(s).
 * Single input -> single code; array input -> code array with same order.
 */
export async function requestPermission(
  context: common.UIAbilityContext,
  permission: string | string[],
): Promise<number | number[]> {
  const isArrayInput = Array.isArray(permission);

  if (!context) {
    hilog.error(0x0000, TAG, "requestPermission: context is null");
    return isArrayInput ? [] : REQUEST_FAILED;
  }

  const permissionList = normalizePermission(permission).filter((item: string) => !!item);
  if (permissionList.length === 0) {
    hilog.error(0x0000, TAG, "requestPermission: permission is empty");
    return isArrayInput ? [] : REQUEST_FAILED;
  }

  const requestPermissions: Array<Permissions> = permissionList as Array<Permissions>;
  const resultCodes: Array<number> = new Array(permissionList.length).fill(REQUEST_FAILED);

  try {
    const atManager = abilityAccessCtrl.createAtManager();
    const result = await atManager.requestPermissionsFromUser(context, requestPermissions);
    const authResults: Array<number> = result.authResults || [];

    for (let i = 0; i < resultCodes.length; i++) {
      resultCodes[i] = authResults[i] ?? REQUEST_FAILED;
    }
  } catch (err) {
    hilog.error(0x0000, TAG, `requestPermission: failed, error: ${JSON.stringify(err)}`);
  }

  return isArrayInput ? resultCodes : resultCodes[0];
}
