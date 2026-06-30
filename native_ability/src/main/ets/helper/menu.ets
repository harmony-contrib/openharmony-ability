import { MenuItemData, PredefinedType, AboutMetadataData } from './menu_types';
import web_webview from '@ohos.web.webview';
import window from '@ohos.window';
import display from '@ohos.display';
import common from '@ohos.app.ability.common';
import { Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WindowManager } from '../window/WindowManager';
import { getMenuDataCallback, windowKeyForId } from '../components/MenuBarComponent';
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY, MAIN_WINDOW_ID } from './constants';

// Global executor singleton — shared by Menu and Tray execution paths
let globalExecutor: PredefinedActionExecutor | null = null;

export function setPredefinedActionExecutor(executor: PredefinedActionExecutor): void {
  globalExecutor = executor;
}

export function getPredefinedActionExecutor(): PredefinedActionExecutor | null {
  return globalExecutor;
}

export class PredefinedActionExecutor {
  private controller: web_webview.WebviewController | null = null;
  private win: window.Window | null = null;
  private context: common.UIAbilityContext | null = null;
  private exitFn: (code: number) => void;
  private showAboutFn: ((metadata: AboutMetadataData) => void) | null = null;

  constructor(exitFn: (code: number) => void) {
    this.exitFn = exitFn;
  }

  setController(controller: web_webview.WebviewController): void {
    this.controller = controller;
  }

  setWindow(win: window.Window): void {
    this.win = win;
  }

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  setShowAboutFn(fn: (metadata: AboutMetadataData) => void): void {
    this.showAboutFn = fn;
  }

  /**
   * Hide the entire Ability (app) to background.
   * Equivalent to macOS Cmd+H (hide:) — all windows become invisible, process stays alive.
   * This is an app-level operation, does not depend on window focus.
   */
  private async hideAbility(): Promise<void> {
    await WindowManager.getInstance().hideAbility();
  }

  /**
   * Restore the Ability (app) from background.
   * Called when user clicks the tray icon to bring the app back to foreground.
   * Uses startAbility() to bring the hidden Ability back to front.
   */
  async showAbility(): Promise<void> {
    if (!this.context) {
      hilog.warn(DOMAIN, 'Menu', 'showAbility: context not set');
      return;
    }
    try {
      const bundleName = this.context.abilityInfo.bundleName;
      const abilityName = this.context.abilityInfo.name;
      const want: Want = { bundleName, abilityName };
      await this.context.startAbility(want);
    } catch (e) {
      hilog.warn(DOMAIN, 'Menu', 'showAbility failed: %{public}s', String(e));
    }
  }

  /**
   * Restore all windows to foreground.
   * Used by showAll and bringAllToFront predefined actions.
   * On OHOS these are semantically equivalent (unlike macOS where they differ).
   */
  private async restoreAll(): Promise<void> {
    // 1. Restore Ability from hidden/background state
    await this.showAbility();

    // 2. Show all windows (restore from minimized state)
    try {
      const wm = WindowManager.getInstance();
      for (const id of wm.getAllWindowIds()) {
        const w = wm.getWindow(id);
        if (w) {
          try {
            await w.showWindow();
          } catch (e) {
            hilog.warn(DOMAIN, 'Menu', 'showWindow failed for window %{public}d: %{public}s', id, String(e));
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, 'Menu', 'restoreAll window iteration failed: %{public}s', String(e));
    }
  }

  /**
   * Get the target window for window-level operations (Minimize, CloseWindow).
   *
   * Strategy depends on call source:
   * - Window Menu Bar (targetWindowId has value): Use the menu's parent window directly
   * - Tray Menu (targetWindowId is undefined): Use lastUserInteractedWindow (onTouch-based)
   *
   * Fallback chain:
   * 1. targetWindowId (if provided) — Window Menu Bar path
   * 2. WindowManager.getUserInteractedWindow() — last physically touched window (Tray path)
   * 3. Main window (this.win) — final fallback
   */
  private getTargetWindow(targetWindowId?: number): { win: window.Window | null, windowId: number } {
    const wm = WindowManager.getInstance();

    // Strategy 1: Use targetWindowId if provided (Window Menu Bar path)
    if (targetWindowId !== undefined) {
      const win = wm.getWindow(targetWindowId);
      if (win) {
        hilog.info(DOMAIN, 'Menu', 'Using targetWindowId: %{public}d', targetWindowId);
        return { win, windowId: targetWindowId };
      }
    }

    // Strategy 2: Use lastUserInteractedWindow (onTouch-based window targeting)
    // Unlike WINDOW_ACTIVE, onTouch is immune to cascade broadcasts and system events
    const lastInteracted = wm.getUserInteractedWindow();
    if (lastInteracted) {
      const lastInteractedId = wm.getUserInteractedWindowId();
      hilog.info(DOMAIN, 'Menu', 'Using lastUserInteractedWindow: id=%{public}d', lastInteractedId);
      return { win: lastInteracted, windowId: lastInteractedId };
    }

    // Strategy 3: Fallback to main window
    hilog.info(DOMAIN, 'Menu', 'Using main window fallback');
    return { win: this.win, windowId: MAIN_WINDOW_ID };
  }

  private getTargetController(windowId: number): web_webview.WebviewController | null {
    const wm = WindowManager.getInstance();
    const nodeController = wm.getController(windowId);
    return nodeController?.getPrimaryWebviewController() ?? this.controller;
  }

  /**
   * Minimize the target window (macOS-like: window-level operation).
   * - Window Menu Bar: minimize the menu's parent window (targetWindowId provided)
   * - Tray Menu: minimize the last focused window (targetWindowId undefined)
   */
  private async minimizeWindow(targetWindowId?: number): Promise<void> {
    const { win, windowId } = this.getTargetWindow(targetWindowId);
    if (!win) {
      return;
    }

    try {
      await WindowManager.getInstance().minimizeWindow(windowId);
    } catch (e) {
      hilog.warn(DOMAIN, 'Menu', 'minimizeWindow failed: %{public}s', String(e));
    }
  }

  /**
   * Close the target window (macOS-like: window-level operation).
   * - Sub-window (id > 0): notify Rust + destroyWindow via WindowManager
   * - Main window (id = 0): hideAbility() — cannot destroy main window (WindowStage becomes invalid)
   *
   * Target determination:
   * - Window Menu Bar: close the menu's parent window (targetWindowId provided)
   * - Tray Menu: close the last focused window (targetWindowId undefined)
   */
  private async closeWindow(targetWindowId?: number): Promise<void> {
    const { win, windowId } = this.getTargetWindow(targetWindowId);
    if (!win) {
      return;
    }

    const isSubWindow = windowId > 0;

    if (isSubWindow) {
      // Sub-window: notify Rust + use WindowManager.closeWindow()
      try {
        const nativeModule: ESObject = AppStorage.get<ESObject>(NATIVE_MODULE_STORAGE_KEY);
        if (nativeModule && typeof nativeModule.notifyWindowClose === 'function') {
          nativeModule.notifyWindowClose(windowId);
        }
        await WindowManager.getInstance().closeWindow(windowId);
      } catch (e) {
        hilog.warn(DOMAIN, 'Menu', 'Close sub-window failed: %{public}s', String(e));
      }
    } else {
      // Main window: hideAbility (cannot destroyWindow as WindowStage becomes invalid)
      await this.hideAbility();
    }
  }

  async execute(type: PredefinedType, aboutMetadata?: AboutMetadataData, targetWindowId?: number): Promise<void> {
    try {
      // Resolve target window for window operations
      // getTargetWindow() handles both Menu Bar (targetWindowId provided) and Tray (undefined → lastUserInteractedWindow)
      const { win, windowId: resolvedWindowId } = this.getTargetWindow(targetWindowId);

      const windowKey = windowKeyForId(resolvedWindowId);

      // Get target window's webview controller for clipboard/edit operations (fallback to this.controller)
      const targetController = this.getTargetController(resolvedWindowId);

      switch (type) {
        case 'copy': {
          try {
            const raw = await targetController?.runJavaScript('window.getSelection().toString()');
            if (raw) {
              const text = JSON.parse(raw as string);
              if (text) {
                const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text as string);
                const sysPasteboard = pasteboard.getSystemPasteboard();
                await sysPasteboard.setData(pasteData);
              }
            }
          } catch (e) {
            hilog.warn(DOMAIN, 'Menu', 'Clipboard copy failed: %{public}s', String(e));
          }
          break;
        }
        case 'cut': {
          try {
            const raw = await targetController?.runJavaScript('window.getSelection().toString()');
            if (raw) {
              const text = JSON.parse(raw as string);
              if (text) {
                const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text as string);
                const sysPasteboard = pasteboard.getSystemPasteboard();
                await sysPasteboard.setData(pasteData);
                await targetController?.runJavaScript('document.execCommand("delete")');
              }
            }
          } catch (e) {
            hilog.warn(DOMAIN, 'Menu', 'Clipboard cut failed: %{public}s', String(e));
          }
          break;
        }
        case 'paste': {
          try {
            const sysPasteboard = pasteboard.getSystemPasteboard();
            const pasteData = await sysPasteboard.getData();
            const text = pasteData.getPrimaryText();
            if (text) {
              // Use JSON.stringify for safe JS string escaping (prevents JS injection)
              const safeText = JSON.stringify(text);
              await targetController?.runJavaScript(
                `document.execCommand("insertText", false, ${safeText})`
              );
            }
          } catch (e) {
            hilog.warn(DOMAIN, 'Menu', 'Clipboard paste failed: %{public}s', String(e));
          }
          break;
        }
        case 'selectAll':
          await targetController?.runJavaScript('document.execCommand("selectAll")');
          break;
        case 'undo':
          await targetController?.runJavaScript('document.execCommand("undo")');
          break;
        case 'redo':
          await targetController?.runJavaScript('document.execCommand("redo")');
          break;
        case 'minimize':
          await this.minimizeWindow(targetWindowId);
          break;
        case 'hide':
          // Hide entire Ability (app) to background — equivalent to macOS Cmd+H (app-level)
          await this.hideAbility();
          break;
        case 'close':
          // Close the target window — equivalent to macOS Cmd+W (window-level)
          await this.closeWindow(targetWindowId);
          break;
        case 'maximize':
          await win?.maximize();
          break;
        case 'fullscreen': {
          // Hide menubar via callback (MW-5)
          const cb = getMenuDataCallback(windowKey);
          cb?.onMenubarVisible?.(false);
          cb?.onMenuShown?.(false);
          try {
            const displayInfo = display.getDefaultDisplaySync();
            if (displayInfo.width > 800) {
              await win?.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
            } else {
              await win?.setWindowLayoutFullScreen(true);
              await win?.setWindowSystemBarEnable([]);
            }
          } catch (e) {
            await win?.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
          }
          break;
        }
        case 'recover': {
          // Show menubar via callback (MW-5)
          const cb = getMenuDataCallback(windowKey);
          cb?.onMenubarVisible?.(true);
          await win?.recover();
          break;
        }
        case 'quit':
          this.exitFn(0);
          break;
        case 'hideOthers':
          break;
        case 'showAll':
        case 'bringAllToFront':
          await this.restoreAll();
          break;
        case 'about':
          this.showAboutFn?.(aboutMetadata ?? {} as AboutMetadataData);
          break;
        case 'restore':
          break;
      }
    } catch (e) {
      hilog.warn(DOMAIN, 'Menu', 'execute(%{public}s) unhandled error: %{public}s', String(type), String(e));
    }
  }
}

export class MenuManager {
  private executor: PredefinedActionExecutor;
  private emitMenuEventFn: (menuId: string, windowId?: string) => void;
  private currentWindowId: string = "main";
  private currentWindowIdNumeric: number = MAIN_WINDOW_ID;

  constructor(executor: PredefinedActionExecutor, emitMenuEventFn: (menuId: string, windowId?: string) => void) {
    this.executor = executor;
    this.emitMenuEventFn = emitMenuEventFn;
  }

  popupFromJson(jsonData: string, x?: number, y?: number, windowId?: string): void {
    try {
      const wid = windowId ?? "main";
      this.currentWindowId = wid;
      this.currentWindowIdNumeric = wid === "main" ? MAIN_WINDOW_ID : Number(wid);

      // Use callback to push data to the correct MenuBarComponent instance (MW-5)
      const cb = getMenuDataCallback(wid);
      if (cb) {
        cb.onMenuPopup?.(jsonData, x ?? 0, y ?? 0);
      } else {
        console.error(`[Menu] No callback registered for window "${wid}"`);
      }
    } catch (e) {
      console.error('[Menu] Failed to popup menu:', e);
    }
  }

  handleItemClick(item: MenuItemData): void {
    if (item.type === 'predefined' && item.predefinedType) {
      this.executor.execute(item.predefinedType, item.aboutMetadata, this.currentWindowIdNumeric);
    } else {
      this.emitMenuEventFn(item.id, this.currentWindowId);
    }
  }
}
