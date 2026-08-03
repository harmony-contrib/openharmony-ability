import { Want } from "@kit.AbilityKit";
import { image } from "@kit.ImageKit";
import { statusBarManager } from "@kit.DeskTopExtensionKit";
import { emitter, BusinessError } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  AsyncBridgePlugin,
  BridgeCallContext,
  BridgePluginContext,
  BridgePluginFactory,
  BridgeTypedValue,
} from "@ohos-rs/ability";

const ADD_REQUEST_TYPE = "ohos.statusbar.AddRequest";
const ICON_REQUEST_TYPE = "ohos.statusbar.IconRequest";
const MENU_REQUEST_TYPE = "ohos.statusbar.MenuRequest";
const TIPS_REQUEST_TYPE = "ohos.statusbar.TipsRequest";
const ACTION_REQUEST_TYPE = "ohos.statusbar.ActionRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.statusbar.Acknowledgement";
const CLICK_REQUEST_TYPE = "ohos.statusbar.ClickRequest";
const MENU_CLICK_REQUEST_TYPE = "ohos.statusbar.MenuClickRequest";
const CLICK_RESPONSE_TYPE = "ohos.statusbar.ClickResponse";

interface StatusBarIconData {
  whiteRgba?: Uint8Array | null;
  blackRgba?: Uint8Array | null;
  size: number;
}

interface QuickOperationData {
  abilityName: string;
  title: string;
  height: number;
  moduleName?: string | null;
  loadingStatus?: boolean | null;
}

interface StatusBarMenuActionData {
  abilityName: string;
  moduleName?: string | null;
  menuCode?: string | null;
  notifyOnly?: boolean | null;
}

interface StatusBarSubMenuItemData {
  subTitle: string;
  menuCode?: string | null;
  menuAction: StatusBarMenuActionData;
  selected?: boolean | null;
}

interface StatusBarMenuItemData {
  title: string;
  menuCode?: string | null;
  subMenu?: StatusBarSubMenuItemData[] | null;
  menuAction?: StatusBarMenuActionData | null;
  selected?: boolean | null;
  iconRgba?: Uint8Array | null;
  iconWidth?: number | null;
  iconHeight?: number | null;
}

interface StatusBarItemData {
  icons: StatusBarIconData;
  quickOperation: QuickOperationData;
  statusBarGroupMenu?: StatusBarMenuItemData[][] | null;
  hoverTips?: string | null;
}

class StatusBarAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function parseAddRequest(payload: BridgeTypedValue): StatusBarItemData {
  if (payload.typeName !== ADD_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.statusbar.add requires bridge type ${ADD_REQUEST_TYPE}`);
  }
  return payload.value as StatusBarItemData;
}

function parseIconRequest(payload: BridgeTypedValue): StatusBarIconData {
  if (payload.typeName !== ICON_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.statusbar.update-icon requires bridge type ${ICON_REQUEST_TYPE}`);
  }
  return (payload.value as { icon: StatusBarIconData }).icon;
}

function parseMenuRequest(payload: BridgeTypedValue): StatusBarMenuItemData[][] {
  if (payload.typeName !== MENU_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.statusbar.update-menu requires bridge type ${MENU_REQUEST_TYPE}`);
  }
  return (payload.value as { groups: StatusBarMenuItemData[][] }).groups;
}

function parseTipsRequest(payload: BridgeTypedValue): string {
  if (payload.typeName !== TIPS_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.statusbar.update-tips requires bridge type ${TIPS_REQUEST_TYPE}`);
  }
  const tips = (payload.value as { tips: string }).tips;
  if (typeof tips !== "string" || tips.trim().length === 0 || tips.trim().length > 128) {
    throw new Error("update-tips.tips must be 1..=128 chars");
  }
  return tips.trim();
}

function parseActionRequest(payload: BridgeTypedValue): string {
  if (payload.typeName !== ACTION_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.statusbar.predefined-action requires bridge type ${ACTION_REQUEST_TYPE}`);
  }
  const action = (payload.value as { action: string }).action;
  if (typeof action !== "string" || !action.trim()) {
    throw new Error("predefined-action.action must not be empty");
  }
  return action.trim();
}

function createPixelMap(rgba: Uint8Array, width: number, height: number): image.PixelMap | null {
  try {
    if (rgba.length !== width * height * 4) {
      return null;
    }
    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width, height },
    };
    const pixelMap = image.createPixelMapSync(opts);
    const buf = rgba.buffer.slice(rgba.byteOffset, rgba.byteOffset + rgba.byteLength);
    pixelMap.writeBufferToPixelsSync(buf);
    return pixelMap;
  } catch (error) {
    hilog.error(0x0000, "StatusBarPlugin", "createPixelMap failed: %{public}s", String(error));
    return null;
  }
}

function buildIcons(icon: StatusBarIconData): ESObject {
  const icons: ESObject = {};
  if (icon.whiteRgba && icon.whiteRgba.length > 0) {
    const pm = createPixelMap(icon.whiteRgba, icon.size, icon.size);
    if (pm) {
      icons.white = pm;
    }
  }
  if (icon.blackRgba && icon.blackRgba.length > 0) {
    const pm = createPixelMap(icon.blackRgba, icon.size, icon.size);
    if (pm) {
      icons.black = pm;
    }
  }
  return icons;
}

function fillAbilityName(menuAction: StatusBarMenuActionData, abilityName: string): void {
  if (menuAction.abilityName == null) {
    menuAction.abilityName = abilityName;
  }
}

function processGroups(groups: StatusBarMenuItemData[][], abilityName: string): void {
  for (const group of groups) {
    for (const item of group) {
      if (item.menuAction) {
        fillAbilityName(item.menuAction, abilityName);
      }
      if (item.subMenu) {
        for (const sub of item.subMenu) {
          fillAbilityName(sub.menuAction, abilityName);
        }
      }
      if (item.iconRgba) {
        const width = item.iconWidth ?? 24;
        const height = item.iconHeight ?? 24;
        const pm = createPixelMap(item.iconRgba, width, height);
        (item as Record<string, unknown>).icon = pm ? { white: pm, black: pm } : undefined;
        delete (item as Record<string, unknown>).iconRgba;
        delete (item as Record<string, unknown>).iconWidth;
        delete (item as Record<string, unknown>).iconHeight;
      }
    }
  }
}

const iconClickHandler = (event: emitter.EventData): void => {
  const clickType = (event.data as Record<string, unknown>).clickType ?? "click";
  const context = StatusBarPluginHolder.pluginContext;
  if (context) {
    context.invokeNativeSync("icon-click", CLICK_REQUEST_TYPE, CLICK_RESPONSE_TYPE, { clickType });
  }
};

const menuClickHandler = (event: emitter.EventData): void => {
  const menuCode = (event.data as Record<string, unknown>).menuCode ?? "";
  const context = StatusBarPluginHolder.pluginContext;
  if (context) {
    context.invokeNativeSync("menu-click", MENU_CLICK_REQUEST_TYPE, CLICK_RESPONSE_TYPE, {
      menuCode,
    });
  }
};

class StatusBarPluginHolder {
  static pluginContext: BridgePluginContext | null = null;
}

function registerClickHandlers(): void {
  try {
    statusBarManager.off(
      "statusBarIconClick" as const,
      iconClickHandler as Callback<emitter.EventData>,
    );
  } catch (error) {
    hilog.warn(0x0000, "StatusBarPlugin", "unbind failed: %{public}s", String(error));
  }
  try {
    statusBarManager.off(
      "rightMenuClick" as const,
      menuClickHandler as Callback<emitter.EventData>,
    );
  } catch (error) {
    hilog.warn(0x0000, "StatusBarPlugin", "unbind failed: %{public}s", String(error));
  }
  try {
    statusBarManager.on(
      "statusBarIconClick" as const,
      iconClickHandler as Callback<emitter.EventData>,
    );
    statusBarManager.on("rightMenuClick" as const, menuClickHandler as Callback<emitter.EventData>);
  } catch (error) {
    hilog.error(
      0x0000,
      "StatusBarPlugin",
      "click handler registration failed: %{public}s",
      String(error),
    );
  }
}

class StatusBarPlugin implements AsyncBridgePlugin {
  readonly id = "ohos.statusbar";
  readonly version = 1;
  readonly execution = "async" as const;
  readonly requires = ["ability"] as const;
  private readonly pluginContext: BridgePluginContext;

  constructor(pluginContext: BridgePluginContext) {
    this.pluginContext = pluginContext;
    StatusBarPluginHolder.pluginContext = pluginContext;
  }

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    const abilityContext = this.pluginContext.abilityContext;
    const abilityName = abilityContext.abilityInfo.name;

    if (action === "add") {
      const item = parseAddRequest(payload);
      const icons = buildIcons(item.icons);
      if (Object.keys(icons).length === 0) {
        throw new Error("add requires at least one icon variant");
      }
      const quickOperation: ESObject = {
        abilityName: item.quickOperation.abilityName,
        title: item.quickOperation.title,
        height: item.quickOperation.height,
      };
      if (item.quickOperation.moduleName) {
        quickOperation.moduleName = item.quickOperation.moduleName;
      }
      if (
        item.quickOperation.loadingStatus !== undefined &&
        item.quickOperation.loadingStatus !== null
      ) {
        quickOperation.loadingStatus = item.quickOperation.loadingStatus;
      }
      const opts: ESObject = {
        icons,
        quickOperation,
        statusBarGroupMenu: item.statusBarGroupMenu ?? [],
      };
      if (item.statusBarGroupMenu) {
        processGroups(item.statusBarGroupMenu, abilityName);
        opts.statusBarGroupMenu = item.statusBarGroupMenu;
      }
      if (item.hoverTips && item.hoverTips.trim().length > 0) {
        opts.hoverTips = item.hoverTips.trim();
      }
      try {
        statusBarManager.addToStatusBar(abilityContext, opts);
        registerClickHandlers();
      } catch (error) {
        const err = error as BusinessError;
        throw new Error(`addToStatusBar failed: code=${err.code} msg=${err.message}`);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new StatusBarAcknowledgement(true) };
    }

    if (action === "remove") {
      try {
        statusBarManager.removeFromStatusBar(abilityContext);
      } catch (error) {
        const err = error as BusinessError;
        throw new Error(`removeFromStatusBar failed: code=${err.code} msg=${err.message}`);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new StatusBarAcknowledgement(true) };
    }

    if (action === "update-icon") {
      const icon = parseIconRequest(payload);
      const icons = buildIcons(icon);
      if (Object.keys(icons).length === 0) {
        throw new Error("update-icon requires at least one icon variant");
      }
      try {
        statusBarManager.updateStatusBarIcon(abilityContext, icons);
      } catch (error) {
        const err = error as BusinessError;
        throw new Error(`updateStatusBarIcon failed: code=${err.code} msg=${err.message}`);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new StatusBarAcknowledgement(true) };
    }

    if (action === "update-menu") {
      const groups = parseMenuRequest(payload);
      processGroups(groups, abilityName);
      try {
        statusBarManager.updateStatusBarMenu(abilityContext, groups as ESObject[][]);
      } catch (error) {
        const err = error as BusinessError;
        throw new Error(`updateStatusBarMenu failed: code=${err.code} msg=${err.message}`);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new StatusBarAcknowledgement(true) };
    }

    if (action === "update-tips") {
      const tips = parseTipsRequest(payload);
      try {
        statusBarManager.updateStatusBarHoverTips(abilityContext, tips);
      } catch (error) {
        const err = error as BusinessError;
        throw new Error(`updateStatusBarHoverTips failed: code=${err.code} msg=${err.message}`);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new StatusBarAcknowledgement(true) };
    }

    if (action === "predefined-action") {
      const actionType = parseActionRequest(payload);
      await executePredefinedAction(abilityContext, actionType);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new StatusBarAcknowledgement(true) };
    }

    throw new Error(`Unsupported ohos.statusbar action '${action}'`);
  }

  onDispose(): void {
    StatusBarPluginHolder.pluginContext = null;
  }
}

async function executePredefinedAction(
  context: BridgePluginContext["abilityContext"],
  actionType: string,
): Promise<void> {
  if (actionType === "show" || actionType === "show-all") {
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name,
    };
    await context.startAbility(want);
    return;
  }
  if (actionType === "quit" || actionType === "exit") {
    const process = await import("@ohos.process");
    new process.ProcessManager().exit(0);
    return;
  }
  // minimize / maximize / restore act on the main window.
  const windowStage = context.windowStage;
  if (!windowStage) {
    throw new Error(`predefined action '${actionType}' requires a window stage`);
  }
  const mainWindow = windowStage.getMainWindowSync();
  if (actionType === "minimize") {
    await mainWindow.minimize();
    return;
  }
  if (actionType === "maximize") {
    await mainWindow.maximize();
    return;
  }
  if (actionType === "restore" || actionType === "recover") {
    await mainWindow.restore();
    return;
  }
  throw new Error(`Unsupported predefined action '${actionType}'`);
}

export function createStatusBarPlugin(): BridgePluginFactory {
  return {
    id: "ohos.statusbar",
    version: 1,
    execution: "async",
    requires: ["ability"],
    create: (context: BridgePluginContext): AsyncBridgePlugin => new StatusBarPlugin(context),
  };
}
