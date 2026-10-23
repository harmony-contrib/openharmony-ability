import { MenuItemData } from "./menu_types";
import {
  AcceleratorMatcher,
  getAcceleratorMatcher,
  unregisterAcceleratorMatcher,
} from "./accelerator_matcher";
import { image } from "@kit.ImageKit";
import { buffer } from "@kit.ArkTS";
import { FrameNode, SymbolGlyphModifier, window } from "@kit.ArkUI";
import { menuKeyForWindow } from "@ohos-rs/ability";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { deviceInfo, systemDateTime } from "@kit.BasicServicesKit";

import {
  MenuDataCallback,
  getMenuClickHandler,
  notifyMenuWillOpen,
  registerMenuDataCallback,
  unregisterMenuDataCallback,
  menubarVisibilityTracker,
} from "./MenuWindowRegistry";
export {
  MenuDataCallback,
  getMenuClickHandler,
  setMenuClickHandler,
  unregisterMenuClickHandler,
  setMenuWillOpenHandler,
  getMenuBarRecoverFn,
  setMenuBarRecoverFn,
  unregisterMenuBarRecoverFn,
  registerMenuDataCallback,
  getMenuDataCallback,
  waitForMenuDataCallback,
  cancelMenuDataWaiters,
  unregisterMenuDataCallback,
  windowKeyForId,
  isMenubarVisible,
} from "./MenuWindowRegistry";

interface MenuRenderData {
  items: MenuItemData[];
  revision: number;
  menubarId?: string;
}
@Component
export struct MenuBarComponent {
  @Prop windowId: number = 0;
  @Prop menuKey: string = "";
  private menuCallback?: MenuDataCallback;
  private hostMenuKey: string = "";

  private registryKey(): string {
    return this.menuKey || this.hostMenuKey;
  }
  @Prop showMenuBar: boolean = true;
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
  @State private applicationMenu: boolean = false;
  @State private commandMenu: boolean = false;
  @State private applicationMenuName: string | undefined = undefined;

  private dismissedDropdownId: string = "";
  private dismissedDropdownAt: number = 0;
  private headingPressId: string = "";
  private headingPressAt: number = 0;
  private restoreFocusId: string | undefined = undefined;

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
        if (index > 0) {
          Divider()
            // An unconstrained divider measures against the popup window width.
            .width(256)
            .color($r("sys.color.ohos_id_color_list_separator"))
            .margin({ left: 12, right: 12 });
        }
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
                    menubarId: data.menubarId,
                  }),
                symbolStartIcon: item.nativeIcon
                  ? this.nativeIconSymbol(item.nativeIcon)
                  : undefined,
              }).enabled(item.enabled ?? true);
            } else if (item.predefinedType === "paste") {
              // MenuItem is a focus leaf; a nested button cannot receive keyboard authorization.
              Row() {
                PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
                  .id(`native-paste-${this.windowId}-${item.id}`)
                  .width(160)
                  .height(40)
                  .align(Alignment.Start)
                  .fontSize($r("sys.float.Body_L"))
                  .fontColor($r("sys.color.font_primary"))
                  // Lower alpha values are forced opaque by the security component.
                  .backgroundColor(0x1a808080)
                  .borderRadius($r("sys.float.corner_radius_level2"))
                  .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                  .enabled(item.enabled ?? true)
                  .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
                    if (result !== PasteButtonOnClickResult.SUCCESS) {
                      hilog.warn(
                        0x1999,
                        "MenuBar",
                        "Native paste authorization failed: %{public}d",
                        result,
                      );
                      try {
                        this.getUIContext()
                          .getPromptAction()
                          .showToast({ message: "Clipboard access was denied" });
                      } catch (error) {
                        hilog.warn(
                          0x1999,
                          "MenuBar",
                          "Cannot show paste error: %{public}s",
                          String(error),
                        );
                      }
                      return;
                    }
                    this.menuShown = false;
                    this.activeDropdownShown = false;
                    const handler = getMenuClickHandler(this.registryKey());
                    if (handler) {
                      handler(item);
                    }
                  })
                Text(item.accelerator ?? "")
                  .fontSize($r("sys.float.Body_L"))
                  .fontColor($r("sys.color.font_secondary"))
                  .textAlign(TextAlign.End)
              }
              .width(280)
              .padding({ left: 0, right: 12 })
              .justifyContent(FlexAlign.SpaceBetween);
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
                  const handler = getMenuClickHandler(this.registryKey());
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
                  Text(item.text ?? "")
                    .fontSize($r("sys.float.Body_M"))
                    .fontColor($r("sys.color.font_primary"))
                  if (item.accelerator) {
                    Blank();
                    Text(item.accelerator)
                      .fontSize($r("sys.float.Body_S"))
                      .fontColor($r("sys.color.font_secondary"))
                      .margin({ left: 16 });
                  }
                }.alignItems(VerticalAlign.Center)
              }
              .enabled(item.enabled ?? true)
              .onClick(() => {
                const handler = getMenuClickHandler(this.registryKey());
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
                  const handler = getMenuClickHandler(this.registryKey());
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
        );
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
      this.RenderMenuItems(data)
    }
    .onKeyPreIme(() => this.isMenuClosing(data.menubarId));
  }

  @Builder
  MenuContent() {
    Menu() {
      this.RenderMenuItems({
        items: this.applicationMenu
          ? this.applicationMenuName === undefined
            ? this.menubarItems
            : (this.menubarItems.find(
                (item: MenuItemData) => item.text === this.applicationMenuName,
              )?.submenuItems ?? [])
          : this.menuItems,
        revision: this.applicationMenu ? this.menubarRevision : this.popupRevision,
      })
    }
    .id(`native-application-menu-${this.windowId}`)
    .focusable(true)
    .onKeyPreIme(() => this.isMenuClosing());
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
                .fontColor([$r("sys.color.icon_primary")])
                .margin({ right: 4 });
            }
            Text(this.getMenubarItem(itemId)?.text ?? "")
              .fontSize($r("sys.float.Body_M"))
              .fontColor($r("sys.color.font_primary"))
          }
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .enabled(this.getMenubarItem(itemId)?.enabled ?? true)
          .opacity(
            (this.getMenubarItem(itemId)?.enabled ?? true)
              ? 1.0
              : $r("sys.float.interactive_disable"),
          )
          .backgroundColor(
            this.activeDropdownId === itemId
              ? $r("sys.color.interactive_pressed")
              : this.hoveredItemId === itemId
                ? $r("sys.color.interactive_hover")
                : Color.Transparent,
          )
          .onAreaChange((_oldArea: Area, area: Area) => {
            this.menubarItemAreas.set(itemId, area);
          })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.headingPressId = itemId;
              this.headingPressAt = event.timestamp;
            } else if (event.type === TouchType.Cancel) {
              this.headingPressId = "";
            }
          })
          .onMouse((event: MouseEvent) => {
            if (event.action === MouseAction.Press) {
              this.headingPressId = itemId;
              this.headingPressAt = event.timestamp;
            }
          })
          .onClick((event: ClickEvent) => {
            // Native dismissal can finish before its triggering press reaches the anchor.
            // Compare that press with dismissal so a later, separate press can still reopen.
            const pressedDuringDismissal =
              this.headingPressId === itemId &&
              this.headingPressAt > 0 &&
              this.headingPressAt <= this.dismissedDropdownAt &&
              (event.source === SourceType.Mouse || event.source === SourceType.TouchScreen);
            const dismissedByPress = pressedDuringDismissal && this.dismissedDropdownId === itemId;
            this.headingPressId = "";
            hilog.info(
              0x1999,
              "MenuBar",
              "dropdown onClick id=%{public}s prevShown=%{public}s prevActive=%{public}s",
              itemId,
              this.activeDropdownShown,
              this.activeDropdownId,
            );
            if (
              (this.activeDropdownShown && this.activeDropdownId === itemId) ||
              dismissedByPress
            ) {
              this.activeDropdownShown = false;
              this.activeDropdownId = "";
              return;
            }
            // Validation covers the whole menubar and requires the application's focus.
            // Switching an open menu must retain that snapshot while ArkUI owns focus.
            if (!this.activeDropdownShown && !pressedDuringDismissal) {
              notifyMenuWillOpen(this.windowId, this.registryKey());
            }
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
              // Keep title dropdowns in their owning window to retain native content focus.
              showInSubWindow: false,
              transition: TransitionEffect.IDENTITY.animation({ duration: 0 }),
              aboutToAppear: () => this.observeDropdownMouse(itemId),
              onAppear: () => {
                this.observeDropdownMouse(itemId);
                this.focusDropdown(itemId);
              },
              aboutToDisappear: () => {
                this.releaseDropdownMouse(itemId);
                hilog.info(
                  0x1999,
                  "MenuBar",
                  "aboutToDisappear activeId=%{public}s",
                  this.activeDropdownId,
                );
                if (this.activeDropdownId === itemId) {
                  this.dismissedDropdownId = itemId;
                  this.dismissedDropdownAt = systemDateTime.getUptime(
                    systemDateTime.TimeType.ACTIVE,
                    true,
                  );
                  this.activeDropdownShown = false;
                }
              },
              onDisappear: () => {
                if (!this.activeDropdownShown && this.activeDropdownId === itemId) {
                  this.activeDropdownId = "";
                }
              },
            },
          )
          .focusable(false);
        },
        (itemId: string) => itemId,
      )
    }
    .width("100%")
    .height(40)
    .backgroundColor($r("sys.color.comp_background_primary"))
    .alignItems(VerticalAlign.Center)
    .focusable(false);
  }

  private switchMenubarOnHover(itemId: string): void {
    const item = this.getMenubarItem(itemId);
    if (
      this.activeDropdownShown &&
      this.activeDropdownId !== itemId &&
      item &&
      item.enabled !== false
    ) {
      // Opening already validated the full menubar before native menu focus took over.
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
        menubarId: itemId,
      })
    }
    .id(this.dropdownNodeId(itemId))
    .focusable(true)
    .onKeyPreIme(() => this.isMenuClosing(itemId));
  }

  private isMenuClosing(menubarId?: string): boolean {
    // ArkUI can deliver queued keys before removing a dismissed popup's focus.
    // Consume them before MenuItem handles Space/Enter; a click that initiated
    // dismissal must still reach its normal onClick callback.
    return menubarId === undefined
      ? !this.menuShown
      : !this.activeDropdownShown || this.activeDropdownId !== menubarId;
  }

  private restorePopupFocus(clearTarget: boolean): void {
    if (this.menuShown || this.restoreFocusId === undefined) {
      return;
    }
    const restoreFocusId = this.restoreFocusId;
    if (clearTarget) {
      this.restoreFocusId = undefined;
    }
    // Window activation arrives after queued keys. Restore the content's node
    // focus in the dismissal callback instead of waiting for that notification.
    try {
      this.getUIContext().getFocusController().requestFocus(restoreFocusId);
    } catch (error) {
      hilog.warn(0x1999, "MenuBar", "Cannot restore native menu focus: %{public}s", String(error));
    }
  }

  private focusDropdown(itemId: string): void {
    if (!this.activeDropdownShown || this.activeDropdownId !== itemId) {
      return;
    }
    // Wait for the native popup window to become focusable, including when
    // switching headings while the previous popup is still disappearing.
    try {
      this.getUIContext().getFocusController().requestFocus(this.dropdownNodeId(itemId));
    } catch (error) {
      hilog.warn(0x1999, "MenuBar", "Cannot focus native menu: %{public}s", String(error));
    }
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
    if (!this.menuKey) {
      // Direct embeddings and legacy builders still belong to their actual window.
      this.hostMenuKey = menuKeyForWindow(window.findWindow(this.getUIContext().getWindowName()));
      this.acceleratorMatcher = getAcceleratorMatcher(this.hostMenuKey);
    }
    // Register callback for this window's menu data (MW-5)
    const windowKey = this.registryKey();
    menubarVisibilityTracker.set(this.registryKey(), this.menubarVisible);
    this.menuCallback = {
      onMenubarJson: (json: string) => {
        this.menubarJson = json;
      },
      onMenubarVisible: (visible: boolean) => {
        this.menubarVisible = visible;
        menubarVisibilityTracker.set(this.registryKey(), visible);
      },
      onMenuPopup: (json: string, x: number, y: number) => {
        this.restoreFocusId = undefined;
        this.applicationMenu = false;
        this.commandMenu = false;
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
      onMenuCommands: (items: MenuItemData[], x: number, y: number, restoreFocusId?: string) => {
        this.restoreFocusId = restoreFocusId;
        this.applicationMenu = false;
        this.commandMenu = true;
        this.popupIconIds.clear();
        this.cleanupStaleIcons();
        this.menuItems = items;
        this.popupRevision++;
        this.menuX = x;
        this.menuY = y;
        this.menuShown = true;
      },
      onApplicationMenu: (
        menuName: string | undefined,
        x: number,
        y: number,
        restoreFocusId?: string,
      ) => {
        if (
          this.menubarItems.length === 0 ||
          (menuName !== undefined &&
            !this.menubarItems.some((item: MenuItemData) => item.text === menuName))
        ) {
          throw new Error(`Application menu '${menuName ?? "all"}' is not available`);
        }
        notifyMenuWillOpen(this.windowId, this.registryKey());
        this.restoreFocusId = restoreFocusId;
        this.applicationMenu = true;
        this.commandMenu = false;
        this.applicationMenuName = menuName;
        this.menuX = x;
        this.menuY = y;
        this.menuShown = true;
      },
    };
    registerMenuDataCallback(windowKey, this.menuCallback);
  }

  aboutToDisappear(): void {
    this.restoreFocusId = undefined;
    for (const itemId of this.dropdownMouseNodes.keys()) {
      this.releaseDropdownMouse(itemId);
    }
    this.menubarItemAreas.clear();
    // Unregister callback and handlers for this window
    const windowKey = this.registryKey();
    if (this.menuCallback && unregisterMenuDataCallback(windowKey, this.menuCallback)) {
      unregisterAcceleratorMatcher(windowKey);
      menubarVisibilityTracker.delete(windowKey);
    }
    this.menuCallback = undefined;

    // Release all icon PixelMaps
    for (const pm of this.iconPixelMaps.values()) {
      pm.release();
    }
    this.iconPixelMaps.clear();
    this.popupIconIds.clear();
    this.menubarIconIds.clear();
  }

  private popupOptions(): ContextMenuOptions {
    return {
      // offset alone is adjusted by native placement and can snap to the origin after maximizing.
      anchorPosition: deviceInfo.sdkApiVersion >= 20 ? { x: this.menuX, y: this.menuY } : undefined,
      offset: deviceInfo.sdkApiVersion >= 20 ? undefined : { x: this.menuX, y: this.menuY },
      // Otherwise the dismissing press reaches the application's trigger and reopens the menu.
      modalMode:
        deviceInfo.sdkApiVersion >= 20
          ? this.applicationMenu || this.commandMenu
            ? ModalMode.TARGET_WINDOW
            : ModalMode.AUTO
          : undefined,
      transition: TransitionEffect.IDENTITY.animation({ duration: 0 }),
      onAppear: () => {
        if (!this.menuShown) {
          return;
        }
        try {
          this.getUIContext()
            .getFocusController()
            .requestFocus(`native-application-menu-${this.windowId}`);
        } catch (error) {
          hilog.warn(
            0x1999,
            "MenuBar",
            "Cannot focus native application menu: %{public}s",
            String(error),
          );
        }
      },
      aboutToDisappear: () => {
        this.menuShown = false;
        this.restorePopupFocus(false);
      },
      onDisappear: () => {
        this.restorePopupFocus(true);
      },
    };
  }

  private applicationPopupOptions(): MenuOptions {
    const options: MenuOptions = this.popupOptions();
    options.showInSubWindow = false;
    return options;
  }

  // --- Build ---

  build() {
    Column() {
      // Menubar row
      if (this.showMenuBar && this.menubarItems.length > 0 && this.menubarVisible) {
        this.MenuBarRow();
      }

      if (this.applicationMenu || this.commandMenu) {
        // These menus belong to the content window. A native context-menu
        // subwindow keeps receiving keys after its closing callback has run.
        Column()
          .width(1)
          .height(1)
          .position({ x: 0, y: 0 })
          .bindMenu(this.menuShown, this.MenuContent, this.applicationPopupOptions())
          .focusable(false);
      } else {
        // Cross-window context menus need bindContextMenu for reliable item clicks.
        Column()
          .width(1)
          .height(1)
          .position({ x: 0, y: 0 })
          .bindContextMenu(this.menuShown, this.MenuContent, this.popupOptions())
          .focusable(false);
      }
    }
    .width("100%")
    .height(this.showMenuBar && this.menubarVisible && this.menubarItems.length > 0 ? 40 : 0)
    .focusable(false);
  }
}
