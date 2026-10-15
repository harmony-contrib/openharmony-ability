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
 *     (FloatPage keeps its desktop+decorations gating).
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
}

let menuBarSlotBuilder: MenuBarSlotBuilder | null = null;
let menuBarPort: MenuBarPort | null = null;

/**
 * AppStorage key bumped every time the menubar slot is registered;
 * MenuBarSlotHost links to it to re-render on registration. The port needs no
 * signal — all port lookups happen at event time, which is already live.
 */
const MENU_SLOT_VERSION_KEY = "__openharmony_ability_menu_slot_version__";

export function setMenuBarSlotBuilder(builder: MenuBarSlotBuilder): void {
  menuBarSlotBuilder = builder;
  AppStorage.setOrCreate<number>(
    MENU_SLOT_VERSION_KEY,
    (AppStorage.get<number>(MENU_SLOT_VERSION_KEY) ?? 0) + 1,
  );
}

export function getMenuBarSlotBuilder(): MenuBarSlotBuilder | null {
  return menuBarSlotBuilder;
}

export function setMenuBarPort(port: MenuBarPort): void {
  menuBarPort = port;
}

export function getMenuBarPort(): MenuBarPort | null {
  return menuBarPort;
}

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

  aboutToAppear(): void {
    this.slot = getMenuBarSlotBuilder();
  }

  /** Registration (or re-registration) bumped the version — refresh the slot. */
  onSlotRegistered(): void {
    this.slot = getMenuBarSlotBuilder();
  }

  build() {
    if (this.slot) {
      this.slot.builder({ windowId: this.windowId });
    }
  }
}
