import {
  BridgeCallContext,
  BridgePluginContext,
  BridgeTypedValue,
  AsyncPluginBase,
  BridgeContextRequirement,
} from "@ohos-rs/ability";

const MENUBAR_REQUEST_TYPE = "ohos.menu.MenuBarRequest";
const POPUP_REQUEST_TYPE = "ohos.menu.PopupRequest";
const VISIBILITY_REQUEST_TYPE = "ohos.menu.VisibilityRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.menu.Acknowledgement";
const CLICK_REQUEST_TYPE = "ohos.menu.ClickRequest";
const CLICK_RESPONSE_TYPE = "ohos.menu.ClickResponse";
const MAX_MENU_ITEMS: number = 512;
const MAX_MENU_DEPTH: number = 16;
const MENU_ITEM_TYPES: Set<string> = new Set([
  "item",
  "submenu",
  "separator",
  "predefined",
  "check",
  "icon",
  "about",
]);

export interface AboutMetadataData {
  name?: string | null;
  version?: string | null;
  shortVersion?: string | null;
  authors?: string[] | null;
  comments?: string | null;
  copyright?: string | null;
  license?: string | null;
  website?: string | null;
}

export interface MenuItemData {
  id: string;
  itemType: string;
  text?: string | null;
  enabled?: boolean | null;
  accelerator?: string | null;
  predefinedType?: string | null;
  checked?: boolean | null;
  icon?: string | null;
  nativeIcon?: string | null;
  submenuItems?: MenuItemData[] | null;
  aboutMetadata?: AboutMetadataData | null;
}

interface MenuBarRequest {
  windowId: string;
  items: MenuItemData[];
  visible?: boolean;
}

interface MenuPopupRequest {
  windowId: string;
  x?: number | null;
  y?: number | null;
  items: MenuItemData[];
}

interface MenuVisibilityRequest {
  windowId: string;
  visible: boolean;
}

interface MenuClickRequest {
  id: string;
  windowId?: string | null;
}

interface MenuClickResponse {
  accepted: boolean;
}

class MenuAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function parseMenuBarRequest(payload: BridgeTypedValue): MenuBarRequest {
  if (
    payload.typeName !== MENUBAR_REQUEST_TYPE ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error(`ohos.menu.set-menubar requires bridge type ${MENUBAR_REQUEST_TYPE}`);
  }
  const request = payload.value as MenuBarRequest;
  if (!request.windowId?.trim()) {
    throw new Error("set-menubar.windowId must not be empty");
  }
  validateMenuItems(request.items, "set-menubar", true, new Set<string>(), 1, 0);
  return request;
}

function parsePopupRequest(payload: BridgeTypedValue): MenuPopupRequest {
  if (
    payload.typeName !== POPUP_REQUEST_TYPE ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error(`ohos.menu.popup requires bridge type ${POPUP_REQUEST_TYPE}`);
  }
  const request = payload.value as MenuPopupRequest;
  if (!request.windowId?.trim()) {
    throw new Error("popup.windowId must not be empty");
  }
  validateMenuItems(request.items, "popup", false, new Set<string>(), 1, 0);
  if (
    (request.x !== undefined && request.x !== null && !Number.isFinite(request.x)) ||
    (request.y !== undefined && request.y !== null && !Number.isFinite(request.y))
  ) {
    throw new Error("popup coordinates must be finite numbers");
  }
  return request;
}

function validateMenuItems(
  items: MenuItemData[],
  action: string,
  allowEmpty: boolean,
  ids: Set<string>,
  depth: number,
  initialCount: number,
): number {
  if (depth > MAX_MENU_DEPTH) {
    throw new Error(`${action} menu tree exceeds the ${MAX_MENU_DEPTH} level depth limit`);
  }
  if (!Array.isArray(items) || (!allowEmpty && items.length === 0)) {
    throw new Error(`${action} requires ${allowEmpty ? "an items array" : "at least one item"}`);
  }
  let itemCount: number = initialCount;
  for (const item of items) {
    itemCount += 1;
    if (itemCount > MAX_MENU_ITEMS) {
      throw new Error(`${action} menu tree exceeds the ${MAX_MENU_ITEMS} item limit`);
    }
    if (!item?.id?.trim() || !MENU_ITEM_TYPES.has(item.itemType)) {
      throw new Error(`${action} menu items require non-empty id and itemType`);
    }
    if (ids.has(item.id)) {
      throw new Error(`${action} menu item id '${item.id}' is duplicated`);
    }
    ids.add(item.id);
    validateOptionalMenuFields(item, action);
    if (item.submenuItems !== undefined && item.submenuItems !== null) {
      itemCount = validateMenuItems(item.submenuItems, action, true, ids, depth + 1, itemCount);
    }
  }
  return itemCount;
}

function validateOptionalMenuFields(item: MenuItemData, action: string): void {
  const stringFields: Array<string | null | undefined> = [
    item.text,
    item.accelerator,
    item.predefinedType,
    item.icon,
    item.nativeIcon,
  ];
  for (const value of stringFields) {
    if (value !== undefined && value !== null && typeof value !== "string") {
      throw new Error(`${action} menu string fields must contain strings`);
    }
  }
  if (item.enabled !== undefined && item.enabled !== null && typeof item.enabled !== "boolean") {
    throw new Error(`${action} menu enabled must be a boolean`);
  }
  if (item.checked !== undefined && item.checked !== null && typeof item.checked !== "boolean") {
    throw new Error(`${action} menu checked must be a boolean`);
  }
  const metadata = item.aboutMetadata;
  if (metadata !== undefined && metadata !== null) {
    if (typeof metadata !== "object") {
      throw new Error(`${action} aboutMetadata must be an object`);
    }
    const metadataStrings: Array<string | null | undefined> = [
      metadata.name,
      metadata.version,
      metadata.shortVersion,
      metadata.comments,
      metadata.copyright,
      metadata.license,
      metadata.website,
    ];
    for (const value of metadataStrings) {
      if (value !== undefined && value !== null && typeof value !== "string") {
        throw new Error(`${action} aboutMetadata string fields must contain strings`);
      }
    }
    if (
      metadata.authors !== undefined &&
      metadata.authors !== null &&
      (!Array.isArray(metadata.authors) ||
        metadata.authors.some((author: string): boolean => typeof author !== "string"))
    ) {
      throw new Error(`${action} aboutMetadata.authors must contain strings`);
    }
  }
}

function parseVisibilityRequest(payload: BridgeTypedValue): MenuVisibilityRequest {
  if (
    payload.typeName !== VISIBILITY_REQUEST_TYPE ||
    typeof payload.value !== "object" ||
    payload.value === null
  ) {
    throw new Error(
      `ohos.menu.set-menubar-visible requires bridge type ${VISIBILITY_REQUEST_TYPE}`,
    );
  }
  const request = payload.value as MenuVisibilityRequest;
  if (!request.windowId?.trim()) {
    throw new Error("set-menubar-visible.windowId must not be empty");
  }
  if (typeof request.visible !== "boolean") {
    throw new Error("set-menubar-visible.visible must be a boolean");
  }
  return request;
}

/**
 * Per-window menubar content store. `MenuBarComponent` subscribes here; the plugin writes
 * here on `set-menubar` / `set-menubar-visible`. Click events are forwarded to Rust through
 * `invokeNativeSync("menu-click", ...)` while the originating callback is active.
 */
class MenuBarRegistry {
  private static readonly windows: Map<string, MenuWindowState> = new Map();
  private static readonly listeners: Map<string, Set<() => void>> = new Map();

  private static key(sessionId: string, windowId: string): string {
    return `${sessionId}:${windowId}`;
  }

  static setMenubar(context: BridgePluginContext, ownerId: number, request: MenuBarRequest): void {
    const key = MenuBarRegistry.key(context.sessionId, request.windowId);
    const current = MenuBarRegistry.windows.get(key);
    MenuBarRegistry.windows.set(key, {
      menubar: request,
      popup: current?.popup ?? null,
      context,
      ownerId,
    });
    MenuBarRegistry.notify(key);
  }

  static setVisible(
    context: BridgePluginContext,
    ownerId: number,
    request: MenuVisibilityRequest,
  ): void {
    const key = MenuBarRegistry.key(context.sessionId, request.windowId);
    const current = MenuBarRegistry.windows.get(key);
    const menubar: MenuBarRequest = current?.menubar ?? {
      windowId: request.windowId,
      items: [],
    };
    MenuBarRegistry.windows.set(key, {
      menubar: {
        windowId: menubar.windowId,
        items: menubar.items,
        visible: request.visible,
      },
      popup: current?.popup ?? null,
      context,
      ownerId,
    });
    MenuBarRegistry.notify(key);
  }

  static setPopup(context: BridgePluginContext, ownerId: number, request: MenuPopupRequest): void {
    const key = MenuBarRegistry.key(context.sessionId, request.windowId);
    const current = MenuBarRegistry.windows.get(key);
    MenuBarRegistry.windows.set(key, {
      menubar: current?.menubar ?? { windowId: request.windowId, items: [] },
      popup: request,
      context,
      ownerId,
    });
    MenuBarRegistry.notify(key);
  }

  static get(sessionId: string, windowId: string): MenuWindowSnapshot {
    const state = MenuBarRegistry.windows.get(MenuBarRegistry.key(sessionId, windowId));
    return {
      menubar: state?.menubar ?? { windowId, items: [] },
      popup: state?.popup ?? null,
    };
  }

  static subscribe(sessionId: string, windowId: string, listener: () => void): () => void {
    const key = MenuBarRegistry.key(sessionId, windowId);
    let set = MenuBarRegistry.listeners.get(key);
    if (!set) {
      set = new Set();
      MenuBarRegistry.listeners.set(key, set);
    }
    set.add(listener);
    return () => {
      set?.delete(listener);
      if (set?.size === 0) {
        MenuBarRegistry.listeners.delete(key);
      }
    };
  }

  static dispatchClick(sessionId: string, windowId: string, id: string): void {
    const key = MenuBarRegistry.key(sessionId, windowId);
    const state = MenuBarRegistry.windows.get(key);
    if (state === undefined || !state.context.isActive()) {
      console.warn("MenuPlugin is not active; menu click dropped");
      return;
    }
    try {
      dispatchMenuClick(state.context, id, windowId);
    } catch (error) {
      console.error(`MenuPlugin failed to dispatch menu click: ${String(error)}`);
    }
    if (state.popup !== null) {
      state.popup = null;
      MenuBarRegistry.notify(key);
    }
  }

  static clearOwner(ownerId: number): void {
    const entries = Array.from(MenuBarRegistry.windows.entries());
    for (const entry of entries) {
      const key = entry[0];
      const state = entry[1];
      if (state.ownerId === ownerId) {
        MenuBarRegistry.windows.delete(key);
        MenuBarRegistry.notify(key);
      }
    }
  }

  private static notify(key: string): void {
    const set = MenuBarRegistry.listeners.get(key);
    if (set) {
      for (const listener of Array.from(set)) {
        listener();
      }
    }
  }
}

interface MenuWindowState {
  menubar: MenuBarRequest;
  popup: MenuPopupRequest | null;
  context: BridgePluginContext;
  ownerId: number;
}

interface MenuWindowSnapshot {
  menubar: MenuBarRequest;
  popup: MenuPopupRequest | null;
}

let nextMenuPluginOwnerId: number = 1;

export class MenuPlugin extends AsyncPluginBase {
  readonly id = "ohos.menu";
  readonly requires: BridgeContextRequirement[] = [];
  private readonly ownerId: number = nextMenuPluginOwnerId++;

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    const context = this.getContext();
    if (action === "set-menubar") {
      const request = parseMenuBarRequest(payload);
      MenuBarRegistry.setMenubar(context, this.ownerId, request);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new MenuAcknowledgement(true) };
    }

    if (action === "set-menubar-visible") {
      const request = parseVisibilityRequest(payload);
      MenuBarRegistry.setVisible(context, this.ownerId, request);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new MenuAcknowledgement(true) };
    }

    if (action === "popup") {
      const request = parsePopupRequest(payload);
      MenuBarRegistry.setPopup(context, this.ownerId, request);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new MenuAcknowledgement(true) };
    }

    throw new Error(`Unsupported ohos.menu action '${action}'`);
  }

  override onDispose(): void {
    MenuBarRegistry.clearOwner(this.ownerId);
  }
}

/** Dispatches a menu click to the Rust facade while the current callback is active. */
export function dispatchMenuClick(
  context: BridgePluginContext,
  id: string,
  windowId: string,
): void {
  const click: MenuClickRequest = { id, windowId };
  const response = context.invokeNativeSync(
    "menu-click",
    CLICK_REQUEST_TYPE,
    CLICK_RESPONSE_TYPE,
    click,
  ) as MenuClickResponse;
  if (response === null || typeof response !== "object" || response.accepted !== true) {
    throw new Error("Rust menu-click handler did not accept the event");
  }
}

interface FlattenedMenuItem {
  item: MenuItemData;
  depth: number;
}

function isMenuSeparator(item: MenuItemData): boolean {
  return (
    item.itemType === "separator" ||
    (item.itemType === "predefined" && item.predefinedType === "separator")
  );
}

function hasSubmenu(item: MenuItemData): boolean {
  return (
    item.submenuItems !== undefined && item.submenuItems !== null && item.submenuItems.length > 0
  );
}

function menuItemLabel(item: MenuItemData): string {
  const text = item.text ?? item.aboutMetadata?.name ?? item.predefinedType ?? "";
  const checked = item.checked === true ? "✓ " : "";
  const accelerator = item.accelerator ? `    ${item.accelerator}` : "";
  return `${checked}${text}${accelerator}`;
}

function flattenMenuItems(items: MenuItemData[], depth: number = 0): FlattenedMenuItem[] {
  const flattened: FlattenedMenuItem[] = [];
  for (const item of items) {
    flattened.push({ item, depth });
    if (hasSubmenu(item)) {
      flattened.push(...flattenMenuItems(item.submenuItems!, depth + 1));
    }
  }
  return flattened;
}

/**
 * Business-placeable menubar host. Place it at the top of a window layout; it renders the
 * per-window menubar published by `ohos.menu` and forwards clicks back to Rust.
 */
@Component
export struct MenuBarComponent {
  @StorageProp("bridgeSessionId") bridgeSessionId: string = "";
  windowId: string = "main";
  @State private items: MenuItemData[] = [];
  @State private visible: boolean = true;
  @State private openMenu: string = "";
  private unsubscribe?: () => void;

  aboutToAppear(): void {
    if (!this.bridgeSessionId) {
      throw new Error("MenuBarComponent requires an active bridgeSessionId");
    }
    const refresh = (): void => {
      const data = MenuBarRegistry.get(this.bridgeSessionId, this.windowId).menubar;
      this.items = data.items;
      this.visible = data.visible ?? true;
    };
    refresh();
    this.unsubscribe = MenuBarRegistry.subscribe(this.bridgeSessionId, this.windowId, refresh);
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  private handleItemClick(item: MenuItemData, windowId: string, topLevel: boolean): void {
    if (item.enabled === false || isMenuSeparator(item)) {
      return;
    }
    if (hasSubmenu(item)) {
      if (topLevel) {
        this.openMenu = this.openMenu === item.id ? "" : item.id;
      }
      return;
    }
    this.openMenu = "";
    MenuBarRegistry.dispatchClick(this.bridgeSessionId, windowId, item.id);
  }

  build() {
    Row() {
      if (this.visible) {
        ForEach(
          this.items,
          (item: MenuItemData) => {
            Column() {
              Text(item.text ?? "")
                .fontSize(14)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .onClick(() => this.handleItemClick(item, this.windowId, true))
              if (this.openMenu === item.id && item.submenuItems) {
                Column() {
                  ForEach(
                    flattenMenuItems(item.submenuItems),
                    (entry: FlattenedMenuItem) => {
                      if (isMenuSeparator(entry.item)) {
                        Divider().color("#D8D8D8").margin({ top: 3, bottom: 3 });
                      } else {
                        Text(menuItemLabel(entry.item))
                          .fontSize(13)
                          .fontColor(entry.item.enabled === false ? "#999999" : "#222222")
                          .padding({
                            left: 16 + entry.depth * 12,
                            right: 16,
                            top: 6,
                            bottom: 6,
                          })
                          .onClick(() => this.handleItemClick(entry.item, this.windowId, false));
                      }
                    },
                    (entry: FlattenedMenuItem) => entry.item.id,
                  )
                }
                .backgroundColor(Color.White)
                .border({ width: 1, color: "#E0E0E0" })
                .shadow({ radius: 8, color: "#33000000", offsetY: 2 });
              }
            };
          },
          (item: MenuItemData) => item.id,
        );
      }
    }
    .width("100%")
    .height(this.visible ? 36 : 0)
    .backgroundColor("#F5F5F5")
    .alignItems(VerticalAlign.Center);
  }
}

/**
 * Business-placeable context-menu overlay. Put it in the same window `Stack` as the content that
 * owns `windowId`; `popup` updates its items and optional position without any module routing.
 */
@Component
export struct MenuPopupComponent {
  @StorageProp("bridgeSessionId") bridgeSessionId: string = "";
  windowId: string = "main";
  @State private items: MenuItemData[] = [];
  @State private x: number = 0;
  @State private y: number = 0;
  @State private visible: boolean = false;
  private unsubscribe?: () => void;

  aboutToAppear(): void {
    if (!this.bridgeSessionId) {
      throw new Error("MenuPopupComponent requires an active bridgeSessionId");
    }
    const refresh = (): void => {
      const popup = MenuBarRegistry.get(this.bridgeSessionId, this.windowId).popup;
      this.items = popup?.items ?? [];
      this.x = popup?.x ?? 0;
      this.y = popup?.y ?? 0;
      this.visible = popup !== null;
    };
    refresh();
    this.unsubscribe = MenuBarRegistry.subscribe(this.bridgeSessionId, this.windowId, refresh);
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  private handleItemClick(item: MenuItemData): void {
    if (item.enabled === false || isMenuSeparator(item) || hasSubmenu(item)) {
      return;
    }
    MenuBarRegistry.dispatchClick(this.bridgeSessionId, this.windowId, item.id);
  }

  build() {
    if (this.visible) {
      Column() {
        ForEach(
          flattenMenuItems(this.items),
          (entry: FlattenedMenuItem) => {
            if (isMenuSeparator(entry.item)) {
              Divider().color("#D8D8D8").margin({ top: 3, bottom: 3 });
            } else {
              Text(menuItemLabel(entry.item))
                .width("100%")
                .fontSize(13)
                .fontColor(entry.item.enabled === false ? "#999999" : "#222222")
                .padding({
                  left: 12 + entry.depth * 12,
                  right: 12,
                  top: 7,
                  bottom: 7,
                })
                .onClick(() => this.handleItemClick(entry.item));
            }
          },
          (entry: FlattenedMenuItem) => entry.item.id,
        )
      }
      .width(220)
      .position({ x: this.x, y: this.y })
      .backgroundColor(Color.White)
      .border({ width: 1, color: "#D8D8D8" })
      .borderRadius(6)
      .shadow({ radius: 10, color: "#33000000", offsetY: 3 });
    }
  }
}
