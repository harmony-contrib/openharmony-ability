import { MenuItemData } from '../helper/menu_types';
import { AcceleratorMatcher } from '../helper/accelerator_matcher';
import { image } from '@kit.ImageKit';
import { buffer } from '@kit.ArkTS';
import { SymbolGlyphModifier } from '@kit.ArkUI';

// --- Per-window click handler registry (MW-1) ---
const windowMenuClickHandlers: Map<number, (item: MenuItemData) => void> = new Map();

export function setMenuClickHandler(windowId: number, handler: (item: MenuItemData) => void): void {
  windowMenuClickHandlers.set(windowId, handler);
}

export function getMenuClickHandler(windowId: number): ((item: MenuItemData) => void) | null {
  return windowMenuClickHandlers.get(windowId) ?? null;
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

@Component
export struct MenuBarComponent {
  @Prop windowId: number = 0;
  /** Shared AcceleratorMatcher instance — parent passes its reference,
   *  this component rebuilds it in-place when menubar data changes.
   *  Parent reads matched item from it in onKeyPreIme.
   *  Regular property (not @Prop) to share the same reference with parent. */
  acceleratorMatcher: AcceleratorMatcher = new AcceleratorMatcher();

  // --- Callback-driven state (replaces @StorageProp, MW-5) ---
  @State @Watch('onMenuJsonChange') menuJson: string = '[]';
  @State menuShown: boolean = false;
  @State menuX: number = 0;
  @State menuY: number = 0;
  @State @Watch('onMenubarJsonChange') menubarJson: string = '[]';
  @State menubarVisible: boolean = true;

  // --- Local state ---
  @State private menuItems: MenuItemData[] = [];
  @State private menubarItems: MenuItemData[] = [];
  @State private activeDropdownId: string = '';
  @State private activeDropdownShown: boolean = false;
  @State private hoveredItemId: string = '';

  private iconPixelMaps: Map<string, image.PixelMap> = new Map();
  private popupIconIds: Set<string> = new Set();
  private menubarIconIds: Set<string> = new Set();

  // --- Watch handlers ---

  onMenuJsonChange(): void {
    try {
      const items = JSON.parse(this.menuJson) as MenuItemData[];
      this.popupIconIds.clear();
      this.collectIconIds(items, this.popupIconIds);
      this.prepareIcons(items);
      this.cleanupStaleIcons();
      this.menuItems = items;
    } catch (e) {
      this.popupIconIds.clear();
      this.cleanupStaleIcons();
      this.menuItems = [];
    }
  }

  onMenubarJsonChange(): void {
    try {
      const items = JSON.parse(this.menubarJson) as MenuItemData[];
      this.menubarIconIds.clear();
      this.collectIconIds(items, this.menubarIconIds);
      this.prepareIcons(items);
      this.cleanupStaleIcons();
      this.menubarItems = items.filter(i => i.type === 'submenu' && i.text);
      this.acceleratorMatcher.buildFromItems(items);
      const submenuDetails = this.menubarItems.map(
        i => `${i.text}: [${(i.submenuItems ?? []).map(s => s.text ?? s.id).join(',')}]`
      );
      console.info(
        `[Menubar] onMenubarJsonChange: items=${items.length}, ` +
        `submenuItems=${this.menubarItems.length}, details=${submenuDetails.join('; ')}`
      );
      // If dropdown is open, close and reopen to force re-render with updated data
      if (this.activeDropdownShown && this.activeDropdownId) {
        this.activeDropdownShown = false;
        setTimeout(() => {
          this.activeDropdownShown = true;
        }, 0);
      }
    } catch (e) {
      this.menubarIconIds.clear();
      this.cleanupStaleIcons();
      this.menubarItems = [];
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
          const decoded = buffer.from(item.icon, 'base64');
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
    for (const [id, pm] of this.iconPixelMaps) {
      if (!liveIds.has(id)) {
        pm.release();
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
   * Maps a nativeIcon string (e.g. "sys.symbol.ohos_star") to a SymbolGlyphModifier.
   * $r() requires compile-time string literals, so we use a switch/case for known-valid variants.
   * Returns null for unmapped icons, which renders as no icon (consistent with Windows/Linux).
   */
  private nativeIconSymbol(nativeIcon: string): SymbolGlyphModifier | null {
    switch (nativeIcon) {
      case 'sys.symbol.ohos_star': return new SymbolGlyphModifier($r('sys.symbol.ohos_star'));
      case 'sys.symbol.ohos_lock': return new SymbolGlyphModifier($r('sys.symbol.ohos_lock'));
      case 'sys.symbol.ohos_wifi': return new SymbolGlyphModifier($r('sys.symbol.ohos_wifi'));
      default: return null;
    }
  }

  // --- Menu builders ---

  @Builder
  RenderMenuItems(items: MenuItemData[]) {
    ForEach(this.splitByDivider(items), (group: MenuItemData[], index: number) => {
      MenuItemGroup() {
        ForEach(group, (item: MenuItemData) => {
          if (item.type === 'submenu') {
            MenuItem({
              content: item.text ?? '',
              builder: (): void => this.SubmenuContent(item.submenuItems ?? []),
              symbolStartIcon: item.nativeIcon ? this.nativeIconSymbol(item.nativeIcon) : undefined,
            })
          } else if (item.type === 'check') {
            MenuItem({
              content: item.text ?? '',
              symbolStartIcon: item.nativeIcon ? this.nativeIconSymbol(item.nativeIcon) : undefined,
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
              })
          } else if (item.type === 'icon' && this.iconPixelMaps.has(item.id)) {
            MenuItem() {
              Row() {
                Image(this.iconPixelMaps.get(item.id))
                  .width(24)
                  .height(24)
                  .margin({ right: 8 })
                Text(item.text ?? '')
                  .fontSize(14)
              }
            }
              .enabled(item.enabled ?? true)
              .onClick(() => {
                const handler = getMenuClickHandler(this.windowId);
                if (handler) {
                  handler(item);
                }
              })
          } else {
            MenuItem({
              content: item.text ?? item.predefinedType ?? '',
              symbolStartIcon: item.nativeIcon ? this.nativeIconSymbol(item.nativeIcon) : undefined,
            })
              .enabled(item.enabled ?? true)
              .onClick(() => {
                const handler = getMenuClickHandler(this.windowId);
                if (handler) {
                  handler(item);
                }
              })
          }
        }, (item: MenuItemData) => item.id)
      }
    }, (_group: MenuItemData[], index: number) => `group_${index}`)
  }

  private splitByDivider(items: MenuItemData[]): MenuItemData[][] {
    const groups: MenuItemData[][] = [];
    let current: MenuItemData[] = [];
    for (const item of items) {
      if (item.type === 'predefined' && item.predefinedType === 'separator') {
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
  SubmenuContent(items: MenuItemData[]) {
    Menu() {
      this.RenderMenuItems(items)
    }
  }

  @Builder
  MenuContent() {
    Menu() {
      this.RenderMenuItems(this.menuItems)
    }
  }

  @Builder
  MenuBarRow() {
    Row() {
      ForEach(this.menubarItems, (item: MenuItemData) => {
        Row() {
          if (item.icon && this.iconPixelMaps.has(item.id)) {
            Image(this.iconPixelMaps.get(item.id))
              .width(16)
              .height(16)
              .margin({ right: 4 })
          }
          Text(item.text ?? '')
            .fontSize(14)
            .fontColor((item.enabled ?? true) ? $r('app.color.menubar_text') : $r('app.color.menubar_text_disabled'))
        }
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .enabled(item.enabled ?? true)
        .opacity((item.enabled ?? true) ? 1.0 : 0.5)
        .backgroundColor(
          this.activeDropdownId === item.id ? $r('app.color.menubar_item_active') :
          this.hoveredItemId === item.id ? $r('app.color.menubar_item_hover') :
          $r('app.color.menubar_bg')
        )
        .onClick(() => {
          this.activeDropdownId = item.id;
          this.activeDropdownShown = true;
        })
        .onHover((isHover: boolean) => {
          this.hoveredItemId = isHover ? item.id : '';
        })
        .bindMenu(
          this.activeDropdownShown && this.activeDropdownId === item.id,
          this.MenubarDropdownContent(item),
          {
            showInSubWindow: true,
            onWillDisappear: () => {
              this.activeDropdownShown = false;
              this.activeDropdownId = '';
            }
          }
        )
      }, (item: MenuItemData) => item.id)
    }
    .width('100%')
    .height(40)
    .backgroundColor($r('app.color.menubar_bg'))
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  MenubarDropdownContent(item: MenuItemData) {
    Menu() {
      this.RenderMenuItems(this.getActiveDropdownItem()?.submenuItems ?? [])
    }
  }

  private getActiveDropdownItem(): MenuItemData | null {
    for (const item of this.menubarItems) {
      if (item.id === this.activeDropdownId) {
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
    // Unregister callback and handlers for this window
    const windowKey = windowKeyForId(this.windowId);
    unregisterMenuDataCallback(windowKey);
    unregisterMenuClickHandler(this.windowId);
    unregisterMenuBarRecoverFn(this.windowId);
    menubarVisibilityTracker.delete(this.windowId);

    // Release all icon PixelMaps
    for (const [, pm] of this.iconPixelMaps) {
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
        this.MenuBarRow()
      }

      // Popup menu anchor (1x1 invisible)
      Column()
        .width(1)
        .height(1)
        .position({ x: 0, y: 0 })
        .bindMenu(this.menuShown, this.MenuContent, {
          anchorPosition: { x: this.menuX, y: this.menuY },
          showInSubWindow: true,
          onWillDisappear: () => {
            this.menuShown = false;
          }
        })
    }
  }
}
