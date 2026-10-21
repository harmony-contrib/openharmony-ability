import { window } from "@kit.ArkUI";

/**
 * Core-side extension seam for the menu plugin.
 *
 * rs<->ets correspondence: `crates/plugin-menu` (Rust facade) ↔ `plugins/menu`
 * (ArkTS har). The menu UI cluster (MenuBarComponent / MenuPopup / menu.ets /
 * menu_types / accelerator matcher) lives in the menu package; core pages never
 * import it. Instead they compose the menubar through a registered builder
 * slot, and forward pre-IME key events plus fullscreen-driven visibility
 * notifications to a registered port:
 *
 *   - MainPage / FloatPage render `MenuBarSlotHost` above their content
 *     (native FloatPage windows also mount it in mobile-class builds).
 *   - Their onKeyPreIme menu branches (clipboard / zoom flag blocking,
 *     accelerator dispatch, ESC fullscreen recover) delegate to
 *     `getMenuBarPort().onKeyPreIme`.
 *   - WindowManager.setFullscreen and NativeAbility's windowRectChange(RECOVER)
 *     notify the port instead of pulling MenuDataCallback from the menu package.
 *
 * The menu plugin registers both at `onInstall`. Plugins declaring
 * `requires: ["ui-context"]` install only after DefaultXComponent attaches —
 * i.e. AFTER the hosting page was already constructed — so pages must not
 * snapshot the slot at construction time: MenuBarSlotHost below re-reads the
 * registry on every render and re-renders when a registration bumps the
 * AppStorage version key, mounting the menubar as soon as the plugin
 * installs. When no menu plugin is installed the slot is empty and every port
 * lookup returns null: core degrades to a menu-less window with native
 * clipboard / zoom behavior intact.
 *
 * `wrapBuilder` / `WrappedBuilder` are ambient ArkUI declarations (global UI
 * functions), so no kit import is needed here.
 */

/** Props passed to the registered menubar builder. */
export interface MenuBarSlotProps {
  windowId: number;
  /** Actual window identity; logical zero is local to each component host. */
  menuKey?: string;
}

/** Menubar builder slot. Registered by the menu plugin at install time. */
export type MenuBarSlotBuilder = WrappedBuilder<[MenuBarSlotProps]>;

/**
 * Core → menu-plugin notification port. The menu plugin registers one
 * implementation; core calls it on key and fullscreen-visibility events.
 */
export interface MenuBarPort {
  /**
   * Pre-IME key handling (KeyDown only): clipboard / zoom shortcut blocking per
   * window flags, accelerator dispatch, ESC fullscreen recover. Returns true
   * when the event was consumed and must not reach the webview.
   */
  onKeyPreIme: (event: KeyEvent, windowId: number) => boolean;
  /** Menubar visibility changed for this window (fullscreen toggle, RECOVER). */
  onMenubarVisibility: (windowId: number, visible: boolean) => void;
  /** Popup open state changed for this window (close popups on fullscreen entry). */
  onMenuShown: (windowId: number, shown: boolean) => void;
  /** Clear held modifiers when key-up may be delivered to another window. */
  onWindowFocusLost?: (windowId: number) => void;
  /** Release handlers owned by a page whose window/menu host is disappearing. */
  onHostDisappear?: () => void;
}

let menuBarSlotBuilder: MenuBarSlotBuilder | null = null;
let menuBarPort: MenuBarPort | null = null;

interface WindowMenuBar {
  builder: MenuBarSlotBuilder;
  port: MenuBarPort;
  windowId: number;
}

const windowMenuBars: Map<string, WindowMenuBar> = new Map();

export function menuKeyForWindow(win: window.Window): string {
  return `native:${win.getWindowProperties().id}`;
}

/** Register one window's presentation. A stale owner cannot remove its replacement. */
export function registerWindowMenuBar(
  win: window.Window,
  builder: MenuBarSlotBuilder,
  port: MenuBarPort,
  windowId: number = 0,
): () => boolean {
  const key = menuKeyForWindow(win);
  const registration: WindowMenuBar = { builder, port, windowId };
  windowMenuBars.set(key, registration);
  notifyMenuSlotChanged();
  return (): boolean => {
    if (windowMenuBars.get(key) !== registration) {
      return false;
    }
    windowMenuBars.delete(key);
    notifyMenuSlotChanged();
    return true;
  };
}

/**
 * AppStorage key bumped every time the menubar slot is registered;
 * MenuBarSlotHost links to it to re-render on registration. The port needs no
 * signal — all port lookups happen at event time, which is already live.
 */
const MENU_SLOT_VERSION_KEY = "__openharmony_ability_menu_slot_version__";

export function setMenuBarSlotBuilder(builder: MenuBarSlotBuilder | null): void {
  menuBarSlotBuilder = builder;
  notifyMenuSlotChanged();
}

function notifyMenuSlotChanged(): void {
  AppStorage.setOrCreate<number>(
    MENU_SLOT_VERSION_KEY,
    (AppStorage.get<number>(MENU_SLOT_VERSION_KEY) ?? 0) + 1,
  );
}

export function getMenuBarSlotBuilder(win?: window.Window): MenuBarSlotBuilder | null {
  if (win) return windowMenuBars.get(menuKeyForWindow(win))?.builder ?? menuBarSlotBuilder;
  if (menuBarSlotBuilder) return menuBarSlotBuilder;
  for (const registration of windowMenuBars.values()) return registration.builder;
  return null;
}

export function setMenuBarPort(port: MenuBarPort | null): void {
  menuBarPort = port;
}

export function getMenuBarPort(win?: window.Window): MenuBarPort | null {
  if (!win) return menuBarPort ?? (windowMenuBars.size > 0 ? legacyMenuPort : null);
  return windowMenuBars.get(menuKeyForWindow(win))?.port ?? menuBarPort;
}

// Existing window integrations call getMenuBarPort() and supply the logical ID
// on the port method. Keep that routing until they migrate to actual windows.
// Ambiguous zero retains the first registered root; component callers pass win.
function legacyWindowPort(windowId: number): MenuBarPort | undefined {
  for (const registration of windowMenuBars.values()) {
    if (registration.windowId === windowId) return registration.port;
  }
  return undefined;
}

const legacyMenuPort: MenuBarPort = {
  onKeyPreIme: (event: KeyEvent, windowId: number): boolean =>
    legacyWindowPort(windowId)?.onKeyPreIme(event, windowId) ?? false,
  onMenubarVisibility: (windowId: number, visible: boolean): void =>
    legacyWindowPort(windowId)?.onMenubarVisibility(windowId, visible),
  onMenuShown: (windowId: number, shown: boolean): void =>
    legacyWindowPort(windowId)?.onMenuShown(windowId, shown),
  onWindowFocusLost: (windowId: number): void =>
    legacyWindowPort(windowId)?.onWindowFocusLost?.(windowId),
};

/**
 * Renders the registered menubar builder slot for one window.
 *
 * The slot is read LIVE (registry lookup) instead of being snapshotted at
 * page construction: the menu plugin declares `requires: ["ui-context"]`, so
 * its onInstall — which registers the slot — runs only after
 * DefaultXComponent attaches, strictly after MainPage/FloatPage were already
 * constructed. A construction-time field snapshot would therefore freeze at
 * null forever. The AppStorage version key above (bumped by
 * setMenuBarSlotBuilder) drives a @Watch re-read, so the menubar mounts as
 * soon as the plugin installs. Renders nothing while no plugin is registered.
 */
@Component
export struct MenuBarSlotHost {
  @Prop windowId: number = 0;
  @StorageLink("__openharmony_ability_menu_slot_version__")
  @Watch("onSlotRegistered")
  slotVersion: number = 0;
  @State private slot: MenuBarSlotBuilder | null = null;
  private menuKey: string = "";
  private hostWindow?: window.Window;

  aboutToAppear(): void {
    this.hostWindow = window.findWindow(this.getUIContext().getWindowName());
    this.onSlotRegistered();
  }

  /** Registration (or re-registration) bumped the version — refresh the slot. */
  onSlotRegistered(): void {
    const win = this.hostWindow;
    if (!win) return;
    this.menuKey = menuKeyForWindow(win);
    this.slot = getMenuBarSlotBuilder(win);
  }

  aboutToDisappear(): void {
    // The native window may already be destroyed; use the identity saved at mount.
    (windowMenuBars.get(this.menuKey)?.port ?? menuBarPort)?.onHostDisappear?.();
    this.hostWindow = undefined;
  }

  build() {
    if (this.slot) {
      this.slot.builder({ windowId: this.windowId, menuKey: this.menuKey });
    }
  }
}
