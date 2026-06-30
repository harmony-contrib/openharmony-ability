import common from "@ohos.app.ability.common";
import { Want } from "@kit.AbilityKit";
import { image } from "@kit.ImageKit";
import { statusBarManager } from "@kit.DeskTopExtensionKit";
import { emitter, BusinessError } from "@kit.BasicServicesKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ArkHelper } from "../ability/type";
import { DOMAIN } from './constants';

// Global state
let abilityContext: common.UIAbilityContext | null = null;
let currentAbilityName: string = "";
export let helperRef: ArkHelper | null = null;

export function setAbilityContext(ctx: common.UIAbilityContext): void {
  abilityContext = ctx;
}

export function setHelperRef(ref: ArkHelper | null): void {
  helperRef = ref;
}

// ─── PROXY handlers ───
// Defined once at module level. Handlers dynamically read helperRef at event time.
// Re-registered after each addToStatusBar() to bind to the current ScbServerMessageReceiver.
const iconClickHandler = (event: emitter.EventData): void => {
  console.info('[StatusBar] PROXY iconClickHandler fired!');

  // Auto-restore app from background when tray icon is clicked
  // Uses startAbility() to bring the hidden Ability back to front
  if (abilityContext) {
    try {
      const bundleName = abilityContext.abilityInfo.bundleName;
      const abilityName = currentAbilityName;
      const want: Want = { bundleName, abilityName };
      abilityContext.startAbility(want).then(() => {
        hilog.info(DOMAIN, 'StatusBar', 'startAbility succeeded');
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, 'StatusBar', 'startAbility failed: %{public}s', String(e));
      });
    } catch (e) {
      hilog.warn(DOMAIN, 'StatusBar', 'startAbility error: %{public}s', String(e));
    }
  }

  // Dispatch to Rust _onIconClick handler
  const h = helperRef as ESObject;
  if (h && h._onIconClick) {
    console.info('[StatusBar] dispatching to Rust _onIconClick');
    h._onIconClick(event);
  } else {
    console.warn(`[StatusBar] iconClickHandler: helperRef=${!!h}, hasCallback=${!!(h && h._onIconClick)}`);
  }
};

const menuClickHandler = (event: emitter.EventData): void => {
  console.info('[StatusBar] PROXY menuClickHandler fired!');
  const h = helperRef as ESObject;
  if (h && h._onMenuClick) {
    console.info('[StatusBar] dispatching to Rust _onMenuClick');
    h._onMenuClick(event);
  } else {
    console.warn(`[StatusBar] menuClickHandler: helperRef=${!!h}, hasCallback=${!!(h && h._onMenuClick)}`);
  }
};

// Re-register PROXY handlers on the current ScbServerMessageReceiver.
// Must be called AFTER addToStatusBar() returns, because addToStatusBar internally
// calls initScbServerMessageReceiver which creates a new receiver and wipes any
// previously registered handlers. Calling after addToStatusBar ensures the on()
// binds to the freshly created receiver.
export function reRegisterStatusBarClickHandlers(): void {
  doRegisterStatusBarClickHandlers('rebind-to-current-receiver');
}

function doRegisterStatusBarClickHandlers(reason: string): void {
  try {
    // Remove any stale handlers first (safe to call even if none exist).
    try {
      statusBarManager.off('statusBarIconClick' as 'statusBarIconClick', iconClickHandler as Callback<emitter.EventData>);
    } catch (_) {}
    try {
      statusBarManager.off('rightMenuClick' as 'rightMenuClick', menuClickHandler as Callback<emitter.EventData>);
    } catch (_) {}
    statusBarManager.on('statusBarIconClick' as 'statusBarIconClick', iconClickHandler as Callback<emitter.EventData>);
    statusBarManager.on('rightMenuClick' as 'rightMenuClick', menuClickHandler as Callback<emitter.EventData>);
    console.info(`[StatusBar] PROXY handlers registered (${reason})`);
  } catch (e) {
    const err = e as BusinessError;
    console.error(`[StatusBar] on() registration failed: ${err.code} ${err.message}`);
  }
}

export function setCurrentAbilityName(name: string): void {
  currentAbilityName = name;
}

export function getAbilityContext(): common.UIAbilityContext {
  return abilityContext as common.UIAbilityContext;
}

export function createPixelMapFromRgba(rgbaData: Uint8Array, size: number): image.PixelMap | null {
  try {
    const expectedLen = size * size * 4;
    if (rgbaData.length !== expectedLen) {
      console.error(`[StatusBar] data length mismatch: got ${rgbaData.length}, expected ${expectedLen}`);
      return null;
    }
    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: size, height: size }
    };
    const pm = image.createPixelMapSync(opts);
    const buf = rgbaData.buffer.slice(rgbaData.byteOffset, rgbaData.byteOffset + rgbaData.byteLength);
    pm.writeBufferToPixelsSync(buf);
    return pm;
  } catch (e) {
    const err = e as BusinessError;
    console.error(`[StatusBar] createPixelMapFromRgba failed: ${err.code} ${err.message}`);
    return null;
  }
}

export function createPixelMapFromRgbaWH(rgbaData: Uint8Array, width: number, height: number): image.PixelMap | null {
  try {
    const expectedLen = width * height * 4;
    if (rgbaData.length !== expectedLen) {
      console.error(`[StatusBar] createPixelMapFromRgbaWH: data length mismatch: got ${rgbaData.length}, expected ${expectedLen} (${width}x${height})`);
      return null;
    }
    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: width, height: height }
    };
    const pm = image.createPixelMapSync(opts);
    const buf = rgbaData.buffer.slice(rgbaData.byteOffset, rgbaData.byteOffset + rgbaData.byteLength);
    pm.writeBufferToPixelsSync(buf);
    return pm;
  } catch (e) {
    const err = e as BusinessError;
    console.error(`[StatusBar] createPixelMapFromRgbaWH failed: ${err.code} ${err.message}`);
    return null;
  }
}

export function fillMenuItemAbilityName(groups: ESObject[][], abilityName: string): void {
  for (const group of groups) {
    for (const item of group) {
      if (item.menuAction && (!item.menuAction.abilityName || item.menuAction.abilityName === '')) {
        // Always fill abilityName with the current ability name.
        // Empty abilityName causes system to show "暂无可用打开方式" toast.
        // When notifyOnly: true and menuCode is set, system fires rightMenuClick event
        // instead of launching the ability, so having abilityName set is safe.
        item.menuAction.abilityName = abilityName;
      }
      if (item.subMenu) {
        for (const sub of item.subMenu) {
          if (sub.menuAction && (!sub.menuAction.abilityName || sub.menuAction.abilityName === '')) {
            sub.menuAction.abilityName = abilityName;
          }
        }
      }
    }
  }
}

export function processMenuItemIcons(groups: ESObject[][]): void {
  for (const group of groups) {
    for (const item of group) {
      if (item.options && item.options.iconRgba) {
        const rgba = item.options.iconRgba as Uint8Array;
        const w = (item.options.iconWidth as number) || 24;
        const h = (item.options.iconHeight as number) || 24;
        const pm = createPixelMapFromRgbaWH(rgba, w, h);
        if (pm) {
          item.options.icon = { white: pm, black: pm };
        }
        delete item.options.iconRgba;
        delete item.options.iconWidth;
        delete item.options.iconHeight;
      }
      if (item.subMenu) {
        for (const sub of item.subMenu) {
          if (sub.options && sub.options.iconRgba) {
            const rgba = sub.options.iconRgba as Uint8Array;
            const w = (sub.options.iconWidth as number) || 24;
            const h = (sub.options.iconHeight as number) || 24;
            const pm = createPixelMapFromRgbaWH(rgba, w, h);
            if (pm) {
              sub.options.icon = { white: pm, black: pm };
            }
            delete sub.options.iconRgba;
            delete sub.options.iconWidth;
            delete sub.options.iconHeight;
          }
        }
      }
    }
  }
}

export { statusBarManager, emitter, BusinessError };
