import common from "@ohos.app.ability.common";
import display from "@ohos.display";
import { Want } from "@kit.AbilityKit";
import { image } from "@kit.ImageKit";
import { statusBarManager } from "@kit.DeskTopExtensionKit";
import { emitter, BusinessError } from "@kit.BasicServicesKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DOMAIN } from './constants';
import { BridgeHostRegistry } from '../bridge/BridgeHost';

// Global state
let abilityContext: common.UIAbilityContext | null = null;
let currentAbilityName: string = "";
export function setAbilityContext(ctx: common.UIAbilityContext): void {
  abilityContext = ctx;
}

// ─── PROXY handlers ───
// Defined once at module level. Re-registered after each addToStatusBar() to
// bind to the current ScbServerMessageReceiver.
// (Removed) helperRef / setHelperRef dispatch — `set_helper` is never called
// after the #[ability] derive refactor, so helperRef was always null and the
// _onIconClick / _onMenuClick branches were dead (always warned).
// iconClickHandler: startAbility app restore + bridge forward to Rust
// (the tray backend → TrayIconEvent::Click → frontend on_tray_icon_click).
// menuClickHandler forwards menu-click the same way.
const iconClickHandler = (event: emitter.EventData): void => {
  // [DIAG-A] unconditional entry log — confirms whether the ScbServerMessageReceiver
  // dispatches ANY status bar click event to this handler. If icon clicks fire but
  // menuClickHandler never does, the rightMenuClick path specifically is broken.
  hilog.info(DOMAIN, 'StatusBar', 'iconClickHandler fired');

  // Auto-restore app from background when tray icon is clicked.
  // Uses startAbility() to bring the hidden Ability back to front.
  // D4 specified amendment (openspec multi-uiability-windows): under
  // launchType "specified" + AbilityStage.onAcceptWant, a bare self-targeting
  // startAbility routes to the live primary instance — AMS pulls it back to
  // the top of the stack. This is the only mechanism that also covers the
  // context.hideAbility()-hidden state (window-level showWindow cannot —
  // device-proven regression under the interim "standard" +
  // showWindowMethod variant, 2026-09-15).
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

  // Forward to Rust (the tray backend → TrayIconEvent::Click). Mirrors
  // menuClickHandler. click_type comes from event.data.iconClickType (fb33ff1
  // precedent); statusBarIconClick only fires for left click (right click goes
  // through rightMenuClick), so fall back to "leftClick" when the field is
  // absent. Emission is unconditional — Rust/frontend decides what to do.
  try {
    const data = event?.data as ESObject;
    let clickType = data?.iconClickType as string;
    if (clickType === undefined || clickType === null || clickType === '') {
      clickType = 'leftClick';
    }
    hilog.info(DOMAIN, 'StatusBar', 'iconClickHandler forwarding clickType=%{public}s', clickType);
    BridgeHostRegistry.invokeNativeSyncProcessWide(
      'ohos.statusbar',
      'icon-click',
      'ohos.statusbar.IconClickEvent',
      'std.bool',
      { clickType },
    );
    hilog.info(DOMAIN, 'StatusBar', 'iconClickHandler forwarded clickType=%{public}s ok', clickType);
  } catch (e) {
    hilog.warn(DOMAIN, 'StatusBar', 'iconClickHandler forward failed: %{public}s', String(e));
  }
};

const menuClickHandler = (event: emitter.EventData): void => {
  // [DIAG-A] unconditional entry log — if this never fires, the system is not
  // dispatching rightMenuClick to this handler (receiver wiring / notifyOnly path).
  hilog.info(DOMAIN, 'StatusBar', 'menuClickHandler ENTER');
  try {
    const data = event?.data as ESObject;
    hilog.info(DOMAIN, 'StatusBar', 'menuClickHandler raw data: %{public}s', String(data));
    const menuCode = data?.menuCode as string;
    if (menuCode === undefined || menuCode === null || menuCode === '') {
      hilog.warn(DOMAIN, 'StatusBar', 'menuClickHandler: no menuCode in event');
      return;
    }
    hilog.info(DOMAIN, 'StatusBar', 'menuClickHandler forwarding menuCode=%{public}s', menuCode);
    BridgeHostRegistry.invokeNativeSyncProcessWide(
      'ohos.statusbar',
      'menu-click',
      'ohos.statusbar.MenuClickEvent',
      'std.bool',
      { menuCode },
    );
    hilog.info(DOMAIN, 'StatusBar', 'menuClickHandler forwarded menuCode=%{public}s ok', menuCode);
  } catch (e) {
    hilog.warn(DOMAIN, 'StatusBar', 'menuClickHandler forward failed: %{public}s', String(e));
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
    // [DIAG-A] hilog (not console.info) — console is stripped in release builds.
    hilog.info(DOMAIN, 'StatusBar', 'PROXY handlers registered (%{public}s)', reason);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, 'StatusBar', 'on() registration failed: %{public}d %{public}s', err.code, err.message);
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
    // Copy napi-provided Uint8Array into a standard JS-managed buffer.
    // napi external buffers (from Rust `Vec<u8>` across the bridge) have an
    // unusable `.buffer` (undefined / detached), so `rgbaData.buffer.slice`
    // throws "Cannot read property slice of undefined". The clipboard plugin
    // hits the same wall and copies first — mirror that. See ClipboardPlugin.
    const jsArr = new Uint8Array(rgbaData.length);
    jsArr.set(rgbaData);
    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: size, height: size }
    };
    const pm = image.createPixelMapSync(opts);
    pm.writeBufferToPixelsSync(jsArr.buffer);

    // Density-correct the PixelMap to the status-bar icon slot (24vp × display
    // density, in physical px). statusBarManager rejects a fixed-px PixelMap
    // ("The size of the pixelmap exceeds the limit." → 401 "check param error").
    // The OHOS reference authors icons at 24vp and decodes via
    // createImageSource().createPixelMap() which yields density-corrected px; we
    // mirror that by scaling here. Density is queried from the display API
    // (Rust has no access to it). See spec §7.4.
    let target = size;
    let density = 1;
    let scaled = false;
    try {
      density = display.getDefaultDisplaySync().densityPixels;
      target = Math.round(24 * density);
    } catch (e) {
      hilog.warn(DOMAIN, "StatusBarUtils", "createPixelMapFromRgba: density query failed, using src size: %{public}s", String(e));
    }
    // Use template-string interpolation — hilog's %{public}f/%d positional
    // placeholders misbehave when a float arg precedes an int (observed
    // "density=}f target=1.900000"), making the actual scaleSync ratio
    // unverifiable. A plain string is unambiguous.
    hilog.info(DOMAIN, "StatusBarUtils", `createPixelMapFromRgba: src=${size} density=${density} target=${target}`);
    if (target > 0 && target !== size) {
      const ratio = target / size;
      pm.scaleSync(ratio, ratio);
      scaled = true;
    }
    hilog.info(DOMAIN, "StatusBarUtils", `createPixelMapFromRgba: scaled=${scaled} (ratio=${scaled ? (target / size) : 1})`);
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
    // Copy napi-provided Uint8Array into a standard JS-managed buffer (see above).
    const jsArr = new Uint8Array(rgbaData.length);
    jsArr.set(rgbaData);
    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: width, height: height }
    };
    const pm = image.createPixelMapSync(opts);
    pm.writeBufferToPixelsSync(jsArr.buffer);
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
