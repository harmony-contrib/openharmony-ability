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

export interface AboutMetadataData {
  name?: string | null;
  version?: string | null;
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

class MenuAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function parseMenuBarRequest(payload: BridgeTypedValue): MenuBarRequest {
  if (payload.typeName !== MENUBAR_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.menu.set-menubar requires bridge type ${MENUBAR_REQUEST_TYPE}`);
  }
  const request = payload.value as MenuBarRequest;
  if (!request.windowId?.trim()) {
    throw new Error("set-menubar.windowId must not be empty");
  }
  return request;
}

function parsePopupRequest(payload: BridgeTypedValue): MenuPopupRequest {
  if (payload.typeName !== POPUP_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.menu.popup requires bridge type ${POPUP_REQUEST_TYPE}`);
  }
  const request = payload.value as MenuPopupRequest;
  if (!request.windowId?.trim()) {
    throw new Error("popup.windowId must not be empty");
  }
  if (!request.items || request.items.length === 0) {
    throw new Error("popup requires at least one item");
  }
  return request;
}

function parseVisibilityRequest(payload: BridgeTypedValue): MenuVisibilityRequest {
  if (payload.typeName !== VISIBILITY_REQUEST_TYPE || typeof payload.value !== "object") {
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
export class MenuBarRegistry {
  private static readonly menubars: Map<string, MenuBarRequest> = new Map();
  private static readonly listeners: Map<string, Set<() => void>> = new Map();

  private static key(sessionId: string, moduleName: string, windowId: string): string {
    return `${sessionId}:${moduleName}:${windowId}`;
  }

  static setMenubar(sessionId: string, moduleName: string, request: MenuBarRequest): void {
    const key = MenuBarRegistry.key(sessionId, moduleName, request.windowId);
    MenuBarRegistry.menubars.set(key, request);
    MenuBarRegistry.notify(key);
  }

  static setVisible(sessionId: string, moduleName: string, request: MenuVisibilityRequest): void {
    const key = MenuBarRegistry.key(sessionId, moduleName, request.windowId);
    const current = MenuBarRegistry.menubars.get(key);
    if (current) {
      MenuBarRegistry.menubars.set(key, { ...current, visible: request.visible });
    }
    MenuBarRegistry.notify(key);
  }

  static get(sessionId: string, moduleName: string, windowId: string): MenuBarRequest {
    const key = MenuBarRegistry.key(sessionId, moduleName, windowId);
    return MenuBarRegistry.menubars.get(key) ?? { windowId, items: [] };
  }

  static subscribe(
    sessionId: string,
    moduleName: string,
    windowId: string,
    listener: () => void,
  ): () => void {
    const key = MenuBarRegistry.key(sessionId, moduleName, windowId);
    let set = MenuBarRegistry.listeners.get(key);
    if (!set) {
      set = new Set();
      MenuBarRegistry.listeners.set(key, set);
    }
    set.add(listener);
    return () => {
      set?.delete(listener);
    };
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

export class MenuPlugin extends AsyncPluginBase {
  readonly id = "ohos.menu";
  readonly version = 1;
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    const sessionId = MenuPluginHolder.context?.sessionId ?? "";
    const moduleName = MenuPluginHolder.context?.moduleName ?? "";

    if (action === "set-menubar") {
      const request = parseMenuBarRequest(payload);
      MenuBarRegistry.setMenubar(sessionId, moduleName, request);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new MenuAcknowledgement(true) };
    }

    if (action === "set-menubar-visible") {
      const request = parseVisibilityRequest(payload);
      MenuBarRegistry.setVisible(sessionId, moduleName, request);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new MenuAcknowledgement(true) };
    }

    if (action === "popup") {
      const request = parsePopupRequest(payload);
      // A context popup is a transient overlay stored under the window key; the page decides
      // where to render it. Coordinates are forwarded as-is.
      MenuBarRegistry.setMenubar(sessionId, moduleName, {
        windowId: request.windowId,
        items: request.items,
      });
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new MenuAcknowledgement(true) };
    }

    throw new Error(`Unsupported ohos.menu action '${action}'`);
  }
}

/** Dispatches a menu click to the Rust facade while the current callback is active. */
export function dispatchMenuClick(
  context: BridgePluginContext,
  id: string,
  windowId: string,
): void {
  const click: MenuClickRequest = { id, windowId };
  context.invokeNativeSync("menu-click", CLICK_REQUEST_TYPE, CLICK_RESPONSE_TYPE, click);
}

/**
 * Business-placeable menubar host. Place it at the top of a window layout; it renders the
 * per-window menubar published by `ohos.menu` and forwards clicks back to Rust.
 */
@Component
export struct MenuBarComponent {
  @StorageProp("bridgeSessionId") bridgeSessionId: string = "";
  moduleName: string = "";
  windowId: string = "main";
  @State private items: MenuItemData[] = [];
  @State private visible: boolean = true;
  @State private openMenu: string = "";
  private unsubscribe?: () => void;
  private pluginContext?: BridgePluginContext;

  aboutToAppear(): void {
    const moduleName = this.moduleName.trim();
    if (!moduleName || !this.bridgeSessionId) {
      throw new Error("MenuBarComponent requires moduleName and an active bridgeSessionId");
    }
    const refresh = (): void => {
      const data = MenuBarRegistry.get(this.bridgeSessionId, moduleName, this.windowId);
      this.items = data.items;
      this.visible = data.visible ?? true;
    };
    refresh();
    this.unsubscribe = MenuBarRegistry.subscribe(
      this.bridgeSessionId,
      moduleName,
      this.windowId,
      refresh,
    );
  }

  aboutToDisappear(): void {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  private handleItemClick(item: MenuItemData, windowId: string): void {
    if (item.submenuItems && item.submenuItems.length > 0) {
      this.openMenu = this.openMenu === item.id ? "" : item.id;
      return;
    }
    this.openMenu = "";
    MenuPluginHolder.dispatch(this.bridgeSessionId, this.moduleName, item.id, windowId);
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
                .onClick(() => this.handleItemClick(item, this.windowId))
              if (this.openMenu === item.id && item.submenuItems) {
                Column() {
                  ForEach(
                    item.submenuItems,
                    (child: MenuItemData) => {
                      Text(child.text ?? "")
                        .fontSize(13)
                        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                        .onClick(() => this.handleItemClick(child, this.windowId));
                    },
                    (child: MenuItemData) => child.id,
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

/** Static click forwarder bridging the component and the plugin's live context. */
class MenuPluginHolder {
  static context: BridgePluginContext | null = null;

  static dispatch(sessionId: string, moduleName: string, id: string, windowId: string): void {
    const context = MenuPluginHolder.context;
    if (!context) {
      console.warn("MenuPlugin is not installed; menu click dropped");
      return;
    }
    dispatchMenuClick(context, id, windowId);
  }
}
