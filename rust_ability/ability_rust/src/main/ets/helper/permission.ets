/*
 * Permission request helper for OpenHarmony
 * This module provides permission request functionality that can be called from native code
 */

import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';

const TAG = 'PermissionHelper';
const APPROVAL: number = 0;

// Permission mapping
const PermissionsMap: Map<string, Permissions> = new Map();
PermissionsMap.set('ohos.permission.WRITE_MEDIA', 'ohos.permission.WRITE_MEDIA');
PermissionsMap.set('ohos.permission.MICROPHONE', 'ohos.permission.MICROPHONE');
PermissionsMap.set('ohos.permission.CAMERA', 'ohos.permission.CAMERA');
PermissionsMap.set('ohos.permission.READ_MEDIA', 'ohos.permission.READ_MEDIA');
PermissionsMap.set('ohos.permission.INTERNET', 'ohos.permission.INTERNET');
PermissionsMap.set('ohos.permission.LOCATION', 'ohos.permission.LOCATION');
PermissionsMap.set('ohos.permission.ACCESS_FINE_LOCATION', 'ohos.permission.ACCESS_FINE_LOCATION');
PermissionsMap.set('ohos.permission.ACCESS_COARSE_LOCATION', 'ohos.permission.ACCESS_COARSE_LOCATION');

/**
 * Request permission from user
 * This is an async function that should be called from native code via threadsafe function
 * 
 * @param context - UIAbilityContext for requesting permission
 * @param permission - Permission string (e.g., 'ohos.permission.MICROPHONE')
 * @param nativeModule - Native module that exports permissionResult function
 * @returns Promise<boolean> - true if granted, false if denied
 */
export async function requestPermission(
  context: common.UIAbilityContext,
  permission: string,
  nativeModule: ESObject | null
): Promise<boolean> {
  if (!context) {
    hilog.error(0x0000, TAG, 'requestPermission: context is null');
    if (nativeModule && typeof nativeModule.permissionResult === 'function') {
      nativeModule.permissionResult(false);
    }
    return false;
  }

  if (!permission) {
    hilog.error(0x0000, TAG, 'requestPermission: permission is null');
    if (nativeModule && typeof nativeModule.permissionResult === 'function') {
      nativeModule.permissionResult(false);
    }
    return false;
  }

  const permissionValue = PermissionsMap.get(permission);
  if (!permissionValue) {
    hilog.warn(0x0000, TAG, `requestPermission: Unknown permission ${permission}, assuming granted`);
    if (nativeModule && typeof nativeModule.permissionResult === 'function') {
      nativeModule.permissionResult(true);
    }
    return true;
  }

  const permissionsList: Array<Permissions> = [permissionValue];

  hilog.info(0x0000, TAG, `requestPermission: Requesting permission ${permission}`);

  try {
    // Create AtManager instance
    const atManager = abilityAccessCtrl.createAtManager();

    // Request permission asynchronously
    const result = await atManager.requestPermissionsFromUser(context, permissionsList);
    const grantStatus: Array<number> = result.authResults;

    // Check if permission is granted
    let granted = false;
    for (let i = 0; i < grantStatus.length; i++) {
      if (grantStatus[i] === APPROVAL) {
        granted = true;
        break;
      }
    }

    hilog.info(0x0000, TAG, `requestPermission: Permission ${permission} ${granted ? 'granted' : 'denied'}`);

    // Notify native code of the result
    if (nativeModule && typeof nativeModule.permissionResult === 'function') {
      nativeModule.permissionResult(granted);
    }

    return granted;
  } catch (err) {
    hilog.error(0x0000, TAG, `requestPermission: Failed to request permission ${permission}, error: ${JSON.stringify(err)}`);
    if (nativeModule && typeof nativeModule.permissionResult === 'function') {
      nativeModule.permissionResult(false);
    }
    return false;
  }
}
