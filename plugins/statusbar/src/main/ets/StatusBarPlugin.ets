import common from "@ohos.app.ability.common";
import process from "@ohos.process";
import { Want } from "@kit.AbilityKit";
import { image } from "@kit.ImageKit";
import { statusBarManager } from "@kit.DeskTopExtensionKit";
import { emitter, BusinessError } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgePluginContext,
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
const MAX_MENU_ITEMS: number = 20;
const MAX_SUB_MENU_ITEMS: number = 20;
const MAX_HOVER_TIPS_LENGTH: number = 128;
const DEFAULT_MENU_ICON_SIZE: number = 24;

interface StatusBarIconData {
  whiteRgba?: Uint8Array | null;
  blackRgba?: Uint8Array | null;
  size: number;
}

interface QuickOperationData {
  abilityName: string;
  title: string;
  height: number;
  /** ArkTS/HAP module for the target extension Ability, not a native bridge module. */
  moduleName?: string | null;
  loadingStatus?: boolean | null;
}

interface StatusBarMenuActionData {
  abilityName: string;
  /** ArkTS/HAP module used in the platform Want, not a native bridge module. */
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

interface ActionRequestPayload {
  action: string;
}

interface StatusBarClickResponse {
  accepted: boolean;
}

interface TipsRequestPayload {
  tips: string;
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

interface AddRequestPayload {
  item: StatusBarItemData;
}

function validateRgba(rgba: Uint8Array, width: number, height: number, label: string): void {
  if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0) {
    throw new Error(`${label} width and height must be positive integers`);
  }
  const expected = width * height * 4;
  if (!Number.isSafeInteger(expected)) {
    throw new Error(`${label} dimensions overflow`);
  }
  if (!(rgba instanceof Uint8Array) || rgba.length !== expected) {
    throw new Error(`${label} rgba length must equal ${expected} (${width}x${height}x4)`);
  }
}

function validateIcon(icon: StatusBarIconData, label: string): void {
  if (typeof icon !== "object" || icon === null) {
    throw new Error(`${label}.icon must be an object`);
  }
  if (!Number.isInteger(icon.size) || icon.size <= 0) {
    throw new Error(`${label}.icon.size must be a positive integer`);
  }
  let variants: number = 0;
  if (icon.whiteRgba !== undefined && icon.whiteRgba !== null) {
    validateRgba(icon.whiteRgba, icon.size, icon.size, `${label}.icon.whiteRgba`);
    variants += 1;
  }
  if (icon.blackRgba !== undefined && icon.blackRgba !== null) {
    validateRgba(icon.blackRgba, icon.size, icon.size, `${label}.icon.blackRgba`);
    variants += 1;
  }
  if (variants === 0) {
    throw new Error(`${label} requires at least one icon variant`);
  }
}

function validateMenuAction(action: StatusBarMenuActionData, label: string): void {
  if (typeof action !== "object" || action === null || typeof action.abilityName !== "string") {
    throw new Error(`${label}.menuAction requires an abilityName string`);
  }
  if (
    action.moduleName !== undefined &&
    action.moduleName !== null &&
    typeof action.moduleName !== "string"
  ) {
    throw new Error(`${label}.menuAction.moduleName must be a string`);
  }
  if (
    action.menuCode !== undefined &&
    action.menuCode !== null &&
    (typeof action.menuCode !== "string" || !action.menuCode.trim())
  ) {
    throw new Error(`${label}.menuAction.menuCode must be a non-empty string`);
  }
  if (
    action.notifyOnly !== undefined &&
    action.notifyOnly !== null &&
    typeof action.notifyOnly !== "boolean"
  ) {
    throw new Error(`${label}.menuAction.notifyOnly must be a boolean`);
  }
}

function registerMenuCode(
  codes: Set<string>,
  code: string | null | undefined,
  label: string,
): void {
  if (code === undefined || code === null) {
    return;
  }
  if (codes.has(code)) {
    throw new Error(`${label}.menuCode '${code}' is duplicated`);
  }
  codes.add(code);
}

function validateMenuItem(item: StatusBarMenuItemData, label: string, codes: Set<string>): void {
  if (typeof item !== "object" || item === null || typeof item.title !== "string") {
    throw new Error(`${label} requires a title string`);
  }
  if (!item.title.trim()) {
    throw new Error(`${label}.title must not be empty`);
  }
  if (
    item.menuCode !== undefined &&
    item.menuCode !== null &&
    (typeof item.menuCode !== "string" || !item.menuCode.trim())
  ) {
    throw new Error(`${label}.menuCode must be a non-empty string`);
  }
  if (item.menuAction !== undefined && item.menuAction !== null) {
    validateMenuAction(item.menuAction, label);
  }
  registerMenuCode(codes, item.menuCode ?? item.menuAction?.menuCode, label);
  if (item.subMenu !== undefined && item.subMenu !== null) {
    if (!Array.isArray(item.subMenu) || item.subMenu.length > MAX_SUB_MENU_ITEMS) {
      throw new Error(`${label}.subMenu must contain at most ${MAX_SUB_MENU_ITEMS} items`);
    }
    for (const sub of item.subMenu) {
      if (typeof sub !== "object" || sub === null || !sub.subTitle?.trim()) {
        throw new Error(`${label}.subMenu requires non-empty subTitle values`);
      }
      if (
        sub.menuCode !== undefined &&
        sub.menuCode !== null &&
        (typeof sub.menuCode !== "string" || !sub.menuCode.trim())
      ) {
        throw new Error(`${label}.subMenu.menuCode must be a non-empty string`);
      }
      validateMenuAction(sub.menuAction, `${label}.subMenu`);
      registerMenuCode(codes, sub.menuCode ?? sub.menuAction.menuCode, `${label}.subMenu`);
      if (
        sub.selected !== undefined &&
        sub.selected !== null &&
        typeof sub.selected !== "boolean"
      ) {
        throw new Error(`${label}.subMenu.selected must be a boolean`);
      }
    }
  }
  if (
    (item.menuAction === undefined || item.menuAction === null) &&
    (item.subMenu === undefined || item.subMenu === null || item.subMenu.length === 0)
  ) {
    throw new Error(`${label} requires menuAction or a non-empty subMenu`);
  }
  if (item.selected !== undefined && item.selected !== null && typeof item.selected !== "boolean") {
    throw new Error(`${label}.selected must be a boolean`);
  }
  if (item.iconRgba !== undefined && item.iconRgba !== null) {
    validateRgba(
      item.iconRgba,
      item.iconWidth ?? DEFAULT_MENU_ICON_SIZE,
      item.iconHeight ?? DEFAULT_MENU_ICON_SIZE,
      `${label}.icon`,
    );
  } else if (item.iconWidth !== undefined || item.iconHeight !== undefined) {
    throw new Error(`${label}.icon dimensions require iconRgba`);
  }
}

function validateGroups(groups: StatusBarMenuItemData[][], label: string): void {
  if (!Array.isArray(groups)) {
    throw new Error(`${label}.groups must be an array`);
  }
  let total: number = 0;
  const codes: Set<string> = new Set();
  for (const group of groups) {
    if (!Array.isArray(group)) {
      throw new Error(`${label}.groups entries must be arrays`);
    }
    total += group.length;
    for (const item of group) {
      validateMenuItem(item, label, codes);
    }
  }
  if (total > MAX_MENU_ITEMS) {
    throw new Error(`${label} supports at most ${MAX_MENU_ITEMS} menu items`);
  }
}

function parseAddRequest(payload: BridgeTypedValue): StatusBarItemData {
  if (
    payload.typeName !== ADD_REQUEST_TYPE ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error(`ohos.statusbar.add requires bridge type ${ADD_REQUEST_TYPE}`);
  }
  const item = (payload.value as AddRequestPayload).item;
  if (typeof item !== "object" || item === null) {
    throw new Error("ohos.statusbar.add.item must be an object");
  }
  validateIcon(item.icons, "add");
  if (
    typeof item.quickOperation !== "object" ||
    item.quickOperation === null ||
    typeof item.quickOperation.abilityName !== "string" ||
    !item.quickOperation.abilityName.trim() ||
    typeof item.quickOperation.title !== "string" ||
    !item.quickOperation.title.trim() ||
    !Number.isInteger(item.quickOperation.height) ||
    item.quickOperation.height <= 0
  ) {
    throw new Error("add.quickOperation requires abilityName, title and a positive height");
  }
  if (
    item.quickOperation.moduleName !== undefined &&
    item.quickOperation.moduleName !== null &&
    typeof item.quickOperation.moduleName !== "string"
  ) {
    throw new Error("add.quickOperation.moduleName must be a string");
  }
  if (
    item.quickOperation.loadingStatus !== undefined &&
    item.quickOperation.loadingStatus !== null &&
    typeof item.quickOperation.loadingStatus !== "boolean"
  ) {
    throw new Error("add.quickOperation.loadingStatus must be a boolean");
  }
  if (item.statusBarGroupMenu !== undefined && item.statusBarGroupMenu !== null) {
    validateGroups(item.statusBarGroupMenu, "add");
  }
  if (
    item.hoverTips !== undefined &&
    item.hoverTips !== null &&
    (typeof item.hoverTips !== "string" ||
      item.hoverTips.trim().length === 0 ||
      item.hoverTips.trim().length > MAX_HOVER_TIPS_LENGTH)
  ) {
    throw new Error(`add.hoverTips must be 1..=${MAX_HOVER_TIPS_LENGTH} chars`);
  }
  return item;
}

interface IconRequestPayload {
  icon: StatusBarIconData;
}

function parseIconRequest(payload: BridgeTypedValue): StatusBarIconData {
  if (
    payload.typeName !== ICON_REQUEST_TYPE ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error(`ohos.statusbar.update-icon requires bridge type ${ICON_REQUEST_TYPE}`);
  }
  const icon = (payload.value as IconRequestPayload).icon;
  validateIcon(icon, "update-icon");
  return icon;
}

interface MenuRequestPayload {
  groups: StatusBarMenuItemData[][];
}

function parseMenuRequest(payload: BridgeTypedValue): StatusBarMenuItemData[][] {
  if (
    payload.typeName !== MENU_REQUEST_TYPE ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error(`ohos.statusbar.update-menu requires bridge type ${MENU_REQUEST_TYPE}`);
  }
  const groups = (payload.value as MenuRequestPayload).groups;
  validateGroups(groups, "update-menu");
  return groups;
}

function parseTipsRequest(payload: BridgeTypedValue): string {
  if (
    payload.typeName !== TIPS_REQUEST_TYPE ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error(`ohos.statusbar.update-tips requires bridge type ${TIPS_REQUEST_TYPE}`);
  }
  const tips = (payload.value as TipsRequestPayload).tips;
  if (
    typeof tips !== "string" ||
    tips.trim().length === 0 ||
    tips.trim().length > MAX_HOVER_TIPS_LENGTH
  ) {
    throw new Error(`update-tips.tips must be 1..=${MAX_HOVER_TIPS_LENGTH} chars`);
  }
  return tips.trim();
}

function parseActionRequest(payload: BridgeTypedValue): string {
  if (
    payload.typeName !== ACTION_REQUEST_TYPE ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error(`ohos.statusbar.predefined-action requires bridge type ${ACTION_REQUEST_TYPE}`);
  }
  const action = (payload.value as ActionRequestPayload).action;
  if (typeof action !== "string" || !action.trim()) {
    throw new Error("predefined-action.action must not be empty");
  }
  return action.trim();
}

function createPixelMap(rgba: Uint8Array, width: number, height: number): image.PixelMap | null {
  try {
    validateRgba(rgba, width, height, "status bar pixel map");
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
  let white: image.PixelMap | null = null;
  let black: image.PixelMap | null = null;
  if (icon.whiteRgba && icon.whiteRgba.length > 0) {
    white = createPixelMap(icon.whiteRgba, icon.size, icon.size);
  }
  if (icon.blackRgba && icon.blackRgba.length > 0) {
    black = createPixelMap(icon.blackRgba, icon.size, icon.size);
  }
  const fallback = white ?? black;
  if (fallback === null) {
    throw new Error("status bar icon PixelMap creation failed");
  }
  return { white: white ?? fallback, black: black ?? fallback };
}

function buildMenuAction(menuAction: StatusBarMenuActionData, abilityName: string): ESObject {
  const action: ESObject = {
    abilityName: menuAction.abilityName.trim() || abilityName,
  };
  if (menuAction.moduleName) {
    action.moduleName = menuAction.moduleName;
  }
  if (menuAction.menuCode) {
    action.menuCode = menuAction.menuCode;
  }
  if (menuAction.notifyOnly !== undefined && menuAction.notifyOnly !== null) {
    action.notifyOnly = menuAction.notifyOnly;
  }
  return action;
}

function buildMenuOptions(
  selected: boolean | null | undefined,
  rgba?: Uint8Array | null,
  width?: number | null,
  height?: number | null,
): ESObject | null {
  const options: ESObject = {};
  if (selected !== undefined && selected !== null) {
    options.selected = selected;
  }
  if (rgba !== undefined && rgba !== null) {
    const pixelMap = createPixelMap(
      rgba,
      width ?? DEFAULT_MENU_ICON_SIZE,
      height ?? DEFAULT_MENU_ICON_SIZE,
    );
    if (pixelMap === null) {
      throw new Error("status bar menu icon PixelMap creation failed");
    }
    options.icon = { white: pixelMap, black: pixelMap };
  }
  return Object.keys(options).length === 0 ? null : options;
}

function buildPlatformGroups(groups: StatusBarMenuItemData[][], abilityName: string): ESObject[][] {
  const result: ESObject[][] = [];
  for (const group of groups) {
    const platformGroup: ESObject[] = [];
    for (const item of group) {
      const platformItem: ESObject = { title: item.title };
      if (item.menuCode) {
        platformItem.menuCode = item.menuCode;
      }
      if (item.menuAction) {
        platformItem.menuAction = buildMenuAction(item.menuAction, abilityName);
      }
      if (item.subMenu) {
        const platformSubMenu: ESObject[] = [];
        for (const sub of item.subMenu) {
          const platformSub: ESObject = {
            subTitle: sub.subTitle,
            menuAction: buildMenuAction(sub.menuAction, abilityName),
          };
          if (sub.menuCode) {
            platformSub.menuCode = sub.menuCode;
          }
          const subOptions: ESObject | null = buildMenuOptions(sub.selected);
          if (subOptions !== null) {
            platformSub.options = subOptions;
          }
          platformSubMenu.push(platformSub);
        }
        platformItem.subMenu = platformSubMenu;
      }
      const options: ESObject | null = buildMenuOptions(
        item.selected,
        item.iconRgba,
        item.iconWidth,
        item.iconHeight,
      );
      if (options !== null) {
        platformItem.options = options;
      }
      platformGroup.push(platformItem);
    }
    result.push(platformGroup);
  }
  return result;
}

const iconClickHandler = (event: emitter.EventData): void => {
  try {
    const clickType = ((event.data as ESObject).clickType as string) ?? "click";
    const context = StatusBarPluginCoordinator.activeContext();
    if (context) {
      const response = context.invokeNativeSync(
        "icon-click",
        CLICK_REQUEST_TYPE,
        CLICK_RESPONSE_TYPE,
        { clickType },
      ) as StatusBarClickResponse;
      if (response === null || typeof response !== "object" || response.accepted !== true) {
        throw new Error("Rust icon-click handler did not accept the event");
      }
    }
  } catch (error) {
    hilog.error(0x0000, "StatusBarPlugin", "icon click dispatch failed: %{public}s", String(error));
  }
};

const menuClickHandler = (event: emitter.EventData): void => {
  try {
    const menuCode = ((event.data as ESObject).menuCode as string) ?? "";
    const context = StatusBarPluginCoordinator.activeContext();
    if (context) {
      const response = context.invokeNativeSync(
        "menu-click",
        MENU_CLICK_REQUEST_TYPE,
        CLICK_RESPONSE_TYPE,
        { menuCode },
      ) as StatusBarClickResponse;
      if (response === null || typeof response !== "object" || response.accepted !== true) {
        throw new Error("Rust menu-click handler did not accept the event");
      }
    }
  } catch (error) {
    hilog.error(0x0000, "StatusBarPlugin", "menu click dispatch failed: %{public}s", String(error));
  }
};

/** Process-level status bar routing. The platform exposes one item, so the latest successful
 * mutating call owns subsequent callbacks; plugin instances never inspect native modules. */
class StatusBarPluginCoordinator {
  private static activeOwner: number | null = null;
  private static activePluginContext: BridgePluginContext | null = null;
  private static iconHandlerRegistered: boolean = false;
  private static menuHandlerRegistered: boolean = false;

  static claim(ownerId: number, context: BridgePluginContext, rebindHandlers: boolean): void {
    StatusBarPluginCoordinator.activeOwner = ownerId;
    StatusBarPluginCoordinator.activePluginContext = context;
    if (rebindHandlers) {
      StatusBarPluginCoordinator.rebindHandlers();
    } else {
      StatusBarPluginCoordinator.ensureHandlers();
    }
  }

  static clearActive(): void {
    StatusBarPluginCoordinator.activeOwner = null;
    StatusBarPluginCoordinator.activePluginContext = null;
    StatusBarPluginCoordinator.removeHandlers();
  }

  static activeContext(): BridgePluginContext | null {
    const context = StatusBarPluginCoordinator.activePluginContext;
    return context?.isActive() === true ? context : null;
  }

  static unregister(ownerId: number): void {
    if (StatusBarPluginCoordinator.activeOwner === ownerId) {
      const context = StatusBarPluginCoordinator.activePluginContext;
      if (context !== null) {
        try {
          statusBarManager.removeFromStatusBar(context.abilityContext);
        } catch (error) {
          hilog.warn(
            0x0000,
            "StatusBarPlugin",
            "status bar cleanup failed: %{public}s",
            String(error),
          );
        }
      }
      StatusBarPluginCoordinator.clearActive();
    }
  }

  private static rebindHandlers(): void {
    // addToStatusBar recreates the platform receiver, invalidating prior registrations.
    StatusBarPluginCoordinator.removeHandlers();
    StatusBarPluginCoordinator.ensureHandlers();
  }

  private static ensureHandlers(): void {
    if (!StatusBarPluginCoordinator.iconHandlerRegistered) {
      try {
        statusBarManager.on(
          "statusBarIconClick" as "statusBarIconClick",
          iconClickHandler as Callback<emitter.EventData>,
        );
        StatusBarPluginCoordinator.iconHandlerRegistered = true;
      } catch (error) {
        hilog.error(
          0x0000,
          "StatusBarPlugin",
          "icon handler registration failed: %{public}s",
          String(error),
        );
      }
    }
    if (!StatusBarPluginCoordinator.menuHandlerRegistered) {
      try {
        statusBarManager.on(
          "rightMenuClick" as "rightMenuClick",
          menuClickHandler as Callback<emitter.EventData>,
        );
        StatusBarPluginCoordinator.menuHandlerRegistered = true;
      } catch (error) {
        hilog.error(
          0x0000,
          "StatusBarPlugin",
          "menu handler registration failed: %{public}s",
          String(error),
        );
      }
    }
  }

  private static removeHandlers(): void {
    if (StatusBarPluginCoordinator.iconHandlerRegistered) {
      try {
        statusBarManager.off(
          "statusBarIconClick" as "statusBarIconClick",
          iconClickHandler as Callback<emitter.EventData>,
        );
      } catch (error) {
        hilog.warn(0x0000, "StatusBarPlugin", "icon unbind failed: %{public}s", String(error));
      }
      StatusBarPluginCoordinator.iconHandlerRegistered = false;
    }
    if (StatusBarPluginCoordinator.menuHandlerRegistered) {
      try {
        statusBarManager.off(
          "rightMenuClick" as "rightMenuClick",
          menuClickHandler as Callback<emitter.EventData>,
        );
      } catch (error) {
        hilog.warn(0x0000, "StatusBarPlugin", "menu unbind failed: %{public}s", String(error));
      }
      StatusBarPluginCoordinator.menuHandlerRegistered = false;
    }
  }
}

let nextStatusBarPluginOwnerId: number = 1;

export class StatusBarPlugin extends AsyncPluginBase {
  readonly id = "ohos.statusbar";
  readonly requires: BridgeContextRequirement[] = ["ability"];
  private readonly ownerId: number = nextStatusBarPluginOwnerId++;

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    const pluginContext = this.getContext();
    const abilityContext = pluginContext.abilityContext;
    const abilityName = abilityContext.abilityInfo.name;

    if (action === "add") {
      const item = parseAddRequest(payload);
      const icons: ESObject = buildIcons(item.icons);
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
        statusBarGroupMenu: buildPlatformGroups(item.statusBarGroupMenu ?? [], abilityName),
      };
      if (item.hoverTips && item.hoverTips.trim().length > 0) {
        opts.hoverTips = item.hoverTips.trim();
      }
      try {
        statusBarManager.addToStatusBar(abilityContext, opts);
        StatusBarPluginCoordinator.claim(this.ownerId, pluginContext, true);
      } catch (error) {
        const err = error as BusinessError;
        throw new Error(`addToStatusBar failed: code=${err.code} msg=${err.message}`);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new StatusBarAcknowledgement(true) };
    }

    if (action === "remove") {
      try {
        statusBarManager.removeFromStatusBar(abilityContext);
        StatusBarPluginCoordinator.clearActive();
      } catch (error) {
        const err = error as BusinessError;
        throw new Error(`removeFromStatusBar failed: code=${err.code} msg=${err.message}`);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new StatusBarAcknowledgement(true) };
    }

    if (action === "update-icon") {
      const icon = parseIconRequest(payload);
      const icons: ESObject = buildIcons(icon);
      try {
        statusBarManager.updateStatusBarIcon(abilityContext, icons);
        StatusBarPluginCoordinator.claim(this.ownerId, pluginContext, false);
      } catch (error) {
        const err = error as BusinessError;
        throw new Error(`updateStatusBarIcon failed: code=${err.code} msg=${err.message}`);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new StatusBarAcknowledgement(true) };
    }

    if (action === "update-menu") {
      const groups = parseMenuRequest(payload);
      const platformGroups: ESObject[][] = buildPlatformGroups(groups, abilityName);
      try {
        statusBarManager.updateStatusBarMenu(abilityContext, platformGroups);
        StatusBarPluginCoordinator.claim(this.ownerId, pluginContext, false);
      } catch (error) {
        const err = error as BusinessError;
        throw new Error(`updateStatusBarMenu failed: code=${err.code} msg=${err.message}`);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new StatusBarAcknowledgement(true) };
    }

    if (action === "update-tips") {
      const tips = parseTipsRequest(payload);
      try {
        await statusBarManager.updateStatusBarHoverTips(abilityContext, tips);
        StatusBarPluginCoordinator.claim(this.ownerId, pluginContext, false);
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

  override onDispose(): void {
    StatusBarPluginCoordinator.unregister(this.ownerId);
  }
}

async function executePredefinedAction(
  context: common.UIAbilityContext,
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
