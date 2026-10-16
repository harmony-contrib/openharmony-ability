import { MenuItemData } from "./menu_types";
import { AcceleratorMatcher, unregisterAcceleratorMatcher } from "./accelerator_matcher";
import { image } from "@kit.ImageKit";
import { buffer } from "@kit.ArkTS";
import { FrameNode, SymbolGlyphModifier } from "@kit.ArkUI";
import { hilog } from "@kit.PerformanceAnalysisKit";

// --- Per-window click handler registry (MW-1) ---
const windowMenuClickHandlers: Map<number, (item: MenuItemData) => void> = new Map();
let menuWillOpenHandler: ((windowId: number) => void) | null = null;

export function setMenuWillOpenHandler(handler: ((windowId: number) => void) | null): void {
  menuWillOpenHandler = handler;
}

export function setMenuClickHandler(windowId: number, handler: (item: MenuItemData) => void): void {
  hilog.info(0x1999, "MenuBar", "setMenuClickHandler registered for windowId=%{public}d", windowId);
  windowMenuClickHandlers.set(windowId, handler);
}

export function getMenuClickHandler(windowId: number): ((item: MenuItemData) => void) | null {
  const handler = windowMenuClickHandlers.get(windowId) ?? null;
  if (!handler) {
    hilog.warn(
      0x1999,
      "MenuBar",
      "getMenuClickHandler NULL for windowId=%{public}d (map size=%{public}d)",
      windowId,
      windowMenuClickHandlers.size,
    );
  }
  return handler;
}

export function unregisterMenuClickHandler(windowId: number): void {
  windowMenuClickHandlers.delete(windowId);
}

// --- Per-window recover function registry (MW-1) ---
const windowRecoverFns: Map<number, () => void> = new Map();

export function setMenuBarRecoverFn(windowId: number, fn: () => void): void {
  windowRecoverFns.set(windowId, fn);
}

export function getMenuBarRecoverFn(windowId: number): (() => void) | null {
  return windowRecoverFns.get(windowId) ?? null;
}

export function unregisterMenuBarRecoverFn(windowId: number): void {
  windowRecoverFns.delete(windowId);
}

// --- Per-window menu data callback registry (MW-5) ---
export interface MenuDataCallback {
  onMenubarJson?: (json: string) => void;
  onMenubarVisible?: (visible: boolean) => void;
  onMenuPopup?: (json: string, x: number, y: number) => void;
  onMenuShown?: (shown: boolean) => void;
}

const menuDataCallbacks: Map<string, MenuDataCallback> = new Map();

export function registerMenuDataCallback(windowKey: string, callback: MenuDataCallback): void {
  menuDataCallbacks.set(windowKey, callback);
}

export function getMenuDataCallback(windowKey: string): MenuDataCallback | undefined {
  return menuDataCallbacks.get(windowKey);
}

export function unregisterMenuDataCallback(windowKey: string): void {
  menuDataCallbacks.delete(windowKey);
}

/**
 * Converts a numeric windowId to the AppStorage key suffix.
 * windowId 0 → "main", others → string representation.
 */
export function windowKeyForId(windowId: number): string {
  return windowId === 0 ? "main" : String(windowId);
}

// --- Per-window menubar visibility tracker (for ESC handler in parent pages) ---
const menubarVisibilityTracker: Map<number, boolean> = new Map();

export function isMenubarVisible(windowId: number): boolean {
  return menubarVisibilityTracker.get(windowId) ?? true;
}

interface MenuRenderData {
  items: MenuItemData[];
  revision: number;
}
@Component
export struct MenuBarComponent {
  @Prop windowId: number = 0;
  /** Shared AcceleratorMatcher instance — the parent (this package's slot
   *  builder, see MenuPlugin.ets) passes the per-window registry instance from
   *  getAcceleratorMatcher(windowId), and this component rebuilds it in-place
   *  when menubar data changes. The key port (CoreMenuBarPort) reads matched
   *  items from the same instance.
   *  Regular property (not @Prop) to share the same reference with parent. */
  acceleratorMatcher: AcceleratorMatcher = new AcceleratorMatcher();

  // --- Callback-driven state (replaces @StorageProp, MW-5) ---
  @State @Watch("onMenuJsonChange") menuJson: string = "[]";
  @State menuShown: boolean = false;
  @State menuX: number = 0;
  @State menuY: number = 0;
  @State @Watch("onMenubarJsonChange") menubarJson: string = "[]";
  @State menubarVisible: boolean = true;

  // --- Local state ---
  @State private menuItems: MenuItemData[] = [];
  @State private menubarItems: MenuItemData[] = [];
  @State private activeDropdownId: string = "";
  @State private activeDropdownShown: boolean = false;
  @State private hoveredItemId: string = "";
  @State private popupRevision: number = 0;
  @State private menubarRevision: number = 0;

  private iconPixelMaps: Map<string, image.PixelMap> = new Map();
  private popupIconIds: Set<string> = new Set();
  private menubarIconIds: Set<string> = new Set();
  private menubarItemAreas: Map<string, Area> = new Map();
  private dropdownMouseNodes: Map<string, FrameNode> = new Map();

  // --- Watch handlers ---

  onMenuJsonChange(): void {
    try {
      const items = JSON.parse(this.menuJson) as MenuItemData[];
      this.popupIconIds.clear();
      this.collectIconIds(items, this.popupIconIds);
      this.prepareIcons(items);
      this.cleanupStaleIcons();
      this.menuItems = items;
      this.popupRevision++;
    } catch (e) {
      this.popupIconIds.clear();
      this.cleanupStaleIcons();
      this.menuItems = [];
      this.popupRevision++;
    }
  }

  onMenubarJsonChange(): void {
    try {
      const items = JSON.parse(this.menubarJson) as MenuItemData[];
      this.menubarIconIds.clear();
      this.collectIconIds(items, this.menubarIconIds);
      this.prepareIcons(items);
      this.cleanupStaleIcons();
      this.menubarItems = items.filter((i) => i.type === "submenu" && i.text);
      this.acceleratorMatcher.buildFromItems(items);
      this.menubarRevision++;
      const activeItem = this.getMenubarItem(this.activeDropdownId);
      if (!activeItem || activeItem.enabled === false) {
        this.activeDropdownShown = false;
        this.activeDropdownId = "";
      }
      const submenuDetails = this.menubarItems.map(
        (i) => `${i.text}: [${(i.submenuItems ?? []).map((s) => s.text ?? s.id).join(",")}]`,
      );
      console.info(
        `[Menubar] onMenubarJsonChange: items=${items.length}, ` +
          `submenuItems=${this.menubarItems.length}, details=${submenuDetails.join("; ")}`,
      );
      // Revision keys rebuild popup contents while keeping its anchor mounted.
    } catch (e) {
      this.menubarIconIds.clear();
      this.cleanupStaleIcons();
      this.menubarItems = [];
      this.acceleratorMatcher.buildFromItems([]);
      this.activeDropdownShown = false;
      this.activeDropdownId = "";
      console.error(`[Menubar] onMenubarJsonChange failed: ${e}`);
    }
  }

  // --- Icon management ---

  private prepareIcons(items: MenuItemData[]): void {
    const queue: MenuItemData[] = [...items];
    while (queue.length > 0) {
      const item = queue.shift()!;
      if (item.icon) {
        try {
          const decoded = buffer.from(item.icon, "base64");
          const arrayBuf = decoded.buffer as ArrayBuffer;
          const imageSource = image.createImageSource(arrayBuf);
          const pixelMap = imageSource.createPixelMapSync();
          imageSource.release();
          this.iconPixelMaps.set(item.id, pixelMap);
        } catch (e) {
          console.error(`[Menu] prepareIcons failed for ${item.id}: ${e}`);
        }
      }
      if (item.submenuItems) {
        queue.push(...item.submenuItems);
      }
    }
  }

  private cleanupStaleIcons(): void {
    const liveIds = new Set<string>();
    for (const id of this.popupIconIds) {
      liveIds.add(id);
    }
    for (const id of this.menubarIconIds) {
      liveIds.add(id);
    }
    for (const id of this.iconPixelMaps.keys()) {
      if (!liveIds.has(id)) {
        this.iconPixelMaps.get(id)?.release();
        this.iconPixelMaps.delete(id);
      }
    }
  }

  private collectIconIds(items: MenuItemData[], ids: Set<string>): void {
    const queue: MenuItemData[] = [...items];
    while (queue.length > 0) {
      const item = queue.shift()!;
      if (item.icon) {
        ids.add(item.id);
      }
      if (item.submenuItems) {
        queue.push(...item.submenuItems);
      }
    }
  }

  // --- Native icon resolution ---

  /**
   * Maps a nativeIcon string (e.g. "sys.symbol.ohos_star") to the raw symbol Resource.
   * $r() requires compile-time string literals, so we use a switch/case for known-valid variants
   * (names validated against the SDK's sysResource.js symbol table).
   * Returns null for unmapped icons, which renders as no icon (consistent with Windows/Linux).
   */
  private nativeIconResource(nativeIcon: string): Resource | null {
    switch (nativeIcon) {
      case "sys.symbol.ohos_star":
        return $r("sys.symbol.ohos_star");
      case "sys.symbol.ohos_lock":
        return $r("sys.symbol.ohos_lock");
      case "sys.symbol.ohos_wifi":
        return $r("sys.symbol.ohos_wifi");
      case "sys.symbol.folder":
        return $r("sys.symbol.folder");
      default:
        return null;
    }
  }

  /**
   * Maps a nativeIcon string to a SymbolGlyphModifier (for MenuItem symbolStartIcon).
   */
  private nativeIconSymbol(nativeIcon: string): SymbolGlyphModifier | null {
    const resource = this.nativeIconResource(nativeIcon);
    return resource ? new SymbolGlyphModifier(resource) : null;
  }

  // --- Menu builders ---

  @Builder
  RenderMenuItems(data: MenuRenderData) {
    ForEach(
      this.splitByDivider(data.items),
      (group: MenuItemData[], index: number) => {
        MenuItemGroup() {
          ForEach(
            group,
            (item: MenuItemData) => {
              if (item.type === "submenu") {
                MenuItem({
                  content: item.text ?? "",
                  builder: (): void =>
                    this.SubmenuContent({
                      items: item.submenuItems ?? [],
                      revision: data.revision,
                    }),
                  symbolStartIcon: item.nativeIcon
                    ? this.nativeIconSymbol(item.nativeIcon)
                    : undefined,
                }).enabled(item.enabled ?? true);
              } else if (item.type === "check") {
                MenuItem({
                  content: item.text ?? "",
                  labelInfo: item.accelerator,
                  symbolStartIcon: item.nativeIcon
                    ? this.nativeIconSymbol(item.nativeIcon)
                    : undefined,
                })
                  .enabled(item.enabled ?? true)
                  .selected(item.checked ?? false)
                  .selectIcon(true)
                  .onChange((checked: boolean) => {
                    item.checked = checked;
                    const handler = getMenuClickHandler(this.windowId);
                    if (handler) {
                      handler(item);
                    }
                  });
              } else if (item.type === "icon" && this.iconPixelMaps.has(item.id)) {
                MenuItem() {
                  Row() {
                    Image(this.iconPixelMaps.get(item.id))
                      .width(24)
                      .height(24)
                      .margin({ right: 8 })
                    Text(item.text ?? "").fontSize(14)
                  }
                }
                .enabled(item.enabled ?? true)
                .onClick(() => {
                  const handler = getMenuClickHandler(this.windowId);
                  if (handler) {
                    handler(item);
                  }
                });
              } else {
                MenuItem({
                  content: item.text ?? item.predefinedType ?? "",
                  labelInfo: item.accelerator,
                  symbolStartIcon: item.nativeIcon
                    ? this.nativeIconSymbol(item.nativeIcon)
                    : undefined,
                })
                  .enabled(item.enabled ?? true)
                  .onClick(() => {
                    const handler = getMenuClickHandler(this.windowId);
                    hilog.info(
                      0x1999,
                      "MenuBar",
                      "menuItem onClick id=%{public}s windowId=%{public}d handler=%{public}s",
                      item.id,
                      this.windowId,
                      handler ? "found" : "NULL",
                    );
                    if (handler) {
                      handler(item);
                    }
                  });
              }
            },
            (item: MenuItemData) => item.id,
          )
        };
      },
      (_group: MenuItemData[], index: number) => `${data.revision}:group_${index}`,
    );
  }

  private splitByDivider(items: MenuItemData[]): MenuItemData[][] {
    const groups: MenuItemData[][] = [];
    let current: MenuItemData[] = [];
    for (const item of items) {
      if (
        item.type === "separator" ||
        (item.type === "predefined" && item.predefinedType === "separator")
      ) {
        if (current.length > 0) {
          groups.push(current);
          current = [];
        }
      } else {
        current.push(item);
      }
    }
    if (current.length > 0) {
      groups.push(current);
    }
    return groups;
  }

  @Builder
  SubmenuContent(data: MenuRenderData) {
    Menu() {
      this.RenderMenuItems({ items: data.items, revision: data.revision })
    };
  }

  @Builder
  MenuContent() {
    Menu() {
      this.RenderMenuItems({ items: this.menuItems, revision: this.popupRevision })
    };
  }

  @Builder
  MenuBarRow() {
    Row() {
      ForEach(
        this.menubarItems.map((item: MenuItemData) => item.id),
        (itemId: string) => {
          Row() {
            if (this.getMenubarItem(itemId)?.icon && this.iconPixelMaps.has(itemId)) {
              Image(this.iconPixelMaps.get(itemId)).width(16).height(16).margin({ right: 4 });
            } else if (this.nativeIconResource(this.getMenubarItem(itemId)?.nativeIcon ?? "")) {
              // Top-level nativeIcon: render as a system symbol, mirroring the
              // Image branch above (submenu icon and nativeIcon are mutually exclusive)
              SymbolGlyph(
                this.nativeIconResource(this.getMenubarItem(itemId)?.nativeIcon ?? "") as Resource,
              )
                .fontSize(16)
                .margin({ right: 4 });
            }
            Text(this.getMenubarItem(itemId)?.text ?? "")
              .fontSize(14)
              .fontColor((this.getMenubarItem(itemId)?.enabled ?? true) ? "#333333" : "#999999")
          }
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .enabled(this.getMenubarItem(itemId)?.enabled ?? true)
          .opacity((this.getMenubarItem(itemId)?.enabled ?? true) ? 1.0 : 0.5)
          .backgroundColor(
            this.activeDropdownId === itemId
              ? "#E0E0E0"
              : this.hoveredItemId === itemId
                ? "#EBEBEB"
                : "#F5F5F5",
          )
          .onAreaChange((_oldArea: Area, area: Area) => {
            this.menubarItemAreas.set(itemId, area);
          })
          .onClick(() => {
            hilog.info(
              0x1999,
              "MenuBar",
              "dropdown onClick id=%{public}s prevShown=%{public}s prevActive=%{public}s",
              itemId,
              this.activeDropdownShown,
              this.activeDropdownId,
            );
            if (this.activeDropdownShown && this.activeDropdownId === itemId) {
              this.activeDropdownShown = false;
              this.activeDropdownId = "";
              return;
            }
            menuWillOpenHandler?.(this.windowId);
            this.activeDropdownId = itemId;
            this.activeDropdownShown = true;
          })
          .onHover((isHover: boolean) => {
            this.hoveredItemId = isHover ? itemId : "";
            if (isHover) {
              this.switchMenubarOnHover(itemId);
            }
          })
          .bindMenu(
            this.activeDropdownShown && this.activeDropdownId === itemId,
            this.MenubarDropdownContent(itemId),
            {
              // Keep menubar dropdowns in their owning window so opening them
              // does not blur the native content or race with focus restoration.
              showInSubWindow: false,
              aboutToAppear: () => this.observeDropdownMouse(itemId),
              onAppear: () => this.observeDropdownMouse(itemId),
              aboutToDisappear: () => {
                this.releaseDropdownMouse(itemId);
                hilog.info(
                  0x1999,
                  "MenuBar",
                  "onWillDisappear activeId=%{public}s",
                  this.activeDropdownId,
                );
                if (this.activeDropdownId === itemId) {
                  this.activeDropdownShown = false;
                  this.activeDropdownId = "";
                }
              },
            },
          );
        },
        (itemId: string) => itemId,
      )
    }
    .width("100%")
    .height(40)
    .backgroundColor("#F5F5F5")
    .alignItems(VerticalAlign.Center);
  }

  private switchMenubarOnHover(itemId: string): void {
    const item = this.getMenubarItem(itemId);
    if (
      this.activeDropdownShown &&
      this.activeDropdownId !== itemId &&
      item &&
      item.enabled !== false
    ) {
      menuWillOpenHandler?.(this.windowId);
      this.activeDropdownId = itemId;
    }
  }

  private observeDropdownMouse(itemId: string): void {
    if (
      !this.activeDropdownShown ||
      this.activeDropdownId !== itemId ||
      this.dropdownMouseNodes.has(itemId)
    ) {
      return;
    }
    // The in-window menu wrapper covers the titles and intercepts their hover
    // events. Listen on this dropdown's own wrapper using the public node API;
    // its normal outside-click and keyboard dismissal remain in control.
    let node = this.getUIContext().getFrameNodeById(this.dropdownNodeId(itemId));
    while (node && node.getNodeType() !== "MenuWrapper") {
      node = node.getParent();
    }
    if (node) {
      node.commonEvent.setOnMouse((event: MouseEvent) => this.handleDropdownMouse(event));
      this.dropdownMouseNodes.set(itemId, node);
    }
  }

  private releaseDropdownMouse(itemId: string): void {
    try {
      this.dropdownMouseNodes.get(itemId)?.commonEvent.setOnMouse(undefined);
    } catch (error) {
      hilog.warn(0x1999, "MenuBar", "release dropdown mouse failed: %{public}s", String(error));
    }
    this.dropdownMouseNodes.delete(itemId);
  }

  private dropdownNodeId(itemId: string): string {
    return `ability-menubar-${this.windowId}-${itemId}`;
  }

  private handleDropdownMouse(event: MouseEvent): void {
    if (event.action !== MouseAction.Move) {
      return;
    }
    for (const item of this.menubarItems) {
      const area = this.menubarItemAreas.get(item.id);
      if (
        area &&
        event.windowX >= Number(area.globalPosition.x) &&
        event.windowX < Number(area.globalPosition.x) + Number(area.width) &&
        event.windowY >= Number(area.globalPosition.y) &&
        event.windowY < Number(area.globalPosition.y) + Number(area.height)
      ) {
        this.switchMenubarOnHover(item.id);
        return;
      }
    }
  }

  @Builder
  MenubarDropdownContent(itemId: string) {
    Menu() {
      // Object-literal reference passing keeps an already-open popup reactive.
      this.RenderMenuItems({
        items: this.getMenubarItem(itemId)?.submenuItems ?? [],
        revision: this.menubarRevision,
      })
    }.id(this.dropdownNodeId(itemId));
  }

  private getMenubarItem(itemId: string): MenuItemData | null {
    for (const item of this.menubarItems) {
      if (item.id === itemId) {
        return item;
      }
    }
    return null;
  }

  // --- Lifecycle ---

  aboutToAppear(): void {
    // Register callback for this window's menu data (MW-5)
    const windowKey = windowKeyForId(this.windowId);
    menubarVisibilityTracker.set(this.windowId, this.menubarVisible);
    registerMenuDataCallback(windowKey, {
      onMenubarJson: (json: string) => {
        this.menubarJson = json;
      },
      onMenubarVisible: (visible: boolean) => {
        this.menubarVisible = visible;
        menubarVisibilityTracker.set(this.windowId, visible);
      },
      onMenuPopup: (json: string, x: number, y: number) => {
        hilog.info(
          0x1999,
          "MenuBar",
          "onMenuPopup windowId=%{public}d x=%{public}d y=%{public}d jsonLen=%{public}d",
          this.windowId,
          x,
          y,
          json.length,
        );
        this.menuJson = json;
        this.menuX = x;
        this.menuY = y;
        // Close first, then reopen to re-trigger bindMenu
        this.menuShown = false;
        setTimeout(() => {
          this.menuShown = true;
        }, 0);
      },
      onMenuShown: (shown: boolean) => {
        this.menuShown = shown;
      },
    });
  }

  aboutToDisappear(): void {
    for (const itemId of this.dropdownMouseNodes.keys()) {
      this.releaseDropdownMouse(itemId);
    }
    this.menubarItemAreas.clear();
    // Unregister callback and handlers for this window
    const windowKey = windowKeyForId(this.windowId);
    unregisterMenuDataCallback(windowKey);
    unregisterMenuClickHandler(this.windowId);
    unregisterMenuBarRecoverFn(this.windowId);
    unregisterAcceleratorMatcher(this.windowId);
    menubarVisibilityTracker.delete(this.windowId);

    // Release all icon PixelMaps
    for (const pm of this.iconPixelMaps.values()) {
      pm.release();
    }
    this.iconPixelMaps.clear();
    this.popupIconIds.clear();
    this.menubarIconIds.clear();
  }

  // --- Build ---

  build() {
    Column() {
      // Menubar row
      if (this.menubarItems.length > 0 && this.menubarVisible) {
        this.MenuBarRow();
      }

      // Popup menu anchor (1x1 invisible). Use bindContextMenu (not bindMenu):
      // bindMenu + showInSubWindow on an invisible anchor renders visually but
      // does not deliver pointer events to MenuItem.onClick in the sub-window.
      // bindContextMenu is the documented sub-window menu API (HarmonyOS 5.0.0/API12+),
      // and its MenuItem.onClick fires reliably. Position via `offset` (API12);
      // `anchorPosition` is API20+ and unavailable here.
      Column()
        .width(1)
        .height(1)
        .position({ x: 0, y: 0 })
        .bindContextMenu(this.menuShown, this.MenuContent, {
          offset: { x: this.menuX, y: this.menuY },
          aboutToDisappear: () => {
            this.menuShown = false;
          },
        })
    };
  }
}
