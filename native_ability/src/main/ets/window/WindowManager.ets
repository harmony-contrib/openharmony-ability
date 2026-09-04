import { window, UIContext } from '@kit.ArkUI';
import { FrameNode } from '@ohos.arkui.node';
import { common } from '@kit.AbilityKit';
import pointer from '@ohos.multimodalInput.pointer';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import display from '@ohos.display';
import * as FloatPage from '../components/FloatPage';
import { getMenuDataCallback, windowKeyForId } from '../components/MenuBarComponent';
import { DOMAIN } from '../helper/constants';
import { clearClipboardEnabled, clearZoomHotkeysEnabled, setClipboardEnabled, setZoomHotkeysEnabled } from '../helper/accelerator_matcher';
import web_webview from '@ohos.web.webview';
import { RectThrottle, WindowRectEventWrap, WindowSizeEventWrap } from './RectThrottle';
import { WindowAttachmentRegistry } from './WindowAttachmentRegistry';

// Event payload types moved to RectThrottle (issue #87 major-5); re-exported here so
// existing importers (`import {...} from "../window/WindowManager"`) keep working.
export { WindowRectEventWrap, WindowSizeEventWrap } from './RectThrottle';

interface WindowEntry {
  window: window.Window;
  storage?: LocalStorage;
  // Phase 2 (design.md D3): per-window windowRectChange handler reference, stored so
  // destroyWindow/removeWindow can call win.off("windowRectChange", handler) to avoid
  // leaking the listener past window destruction.
  rectChangeHandler?: (options: window.RectChangeOptions) => void;
  // Phase 3 (design.md D4): set to true just before destroyWindow()/closeWindow Float
  // path calls win.destroyWindow(). throttledRectDispatch checks this to discard
  // in-flight events for a window being torn down (no consumers left).
  destroying: boolean;
}

// Encapsulates all parameters for sub-window creation, replacing a 10-arg signature.
export interface SubWindowOptions {
  name: string;
  windowId: number;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  decorations?: boolean;
  transparent?: boolean;
  backgroundColor?: number;
}

// Enum of window kinds. All UIAbility windows are equal, no primary/subordinate distinction.
export enum WindowKind {
  UIAbility,  // All UIAbility main windows (id=0 or id>0, equivalent)
  Float,      // Float sub-window created by windowStage.createSubWindow
}

export class WindowManager {
  private static instance: WindowManager | null = null;
  private context: common.UIAbilityContext;
  private uiAbilityStages: Map<number, window.WindowStage> = new Map();
  // Per-instance UIAbilityContext (keyed by windowId). Needed to terminate a
  // specific secondary instance via context.terminateSelf() — the process-level
  // `this.context` only refers to the first instance, so without this map a
  // secondary instance cannot be truly closed (only hidden via hideAbility).
  private uiAbilityContexts: Map<number, common.UIAbilityContext> = new Map();
  private windows: Map<number, WindowEntry> = new Map();
  // Per-window attachments (WebviewControllers / UIContexts / component roots /
  // vibrancy state / deferred componentRoot callbacks). Extracted to its own class
  // (issue #87 major-5); facade methods below keep the WindowManager API unchanged.
  private attachments: WindowAttachmentRegistry = new WindowAttachmentRegistry();
  // Per-window rect/size event throttle (leading+trailing 16ms). Extracted to its
  // own class (issue #87 major-5); throttledRectDispatch below is a facade.
  private rectThrottle: RectThrottle;
  // transparentFlags tracks each UIAbility window's transparent flag (keyed by windowId).
  // Set in registerUIAbilityStage, queried by DefaultXComponent.aboutToAppear to apply
  // setWindowBackgroundColor/setWindowContainerColor after the window is fully ready.
  private transparentFlags: Map<number, boolean> = new Map();

  // windowKinds tracks each window's kind (UIAbility or Float) by windowId.
  // Used by isUIAbilityMainWindow() — windowId=0 is NOT special, all UIAbility
  // windows (id=0 or id>0) are equal and system-managed.
  private windowKinds: Map<number, WindowKind> = new Map();

  // windowOpQueues: Per-window operation serialization queue. Window operations (maximize, recover,
  // fullscreen, minimize) are async Promises that must not overlap — e.g., calling
  // maximize while a fullscreen-exit recover() is still pending causes race conditions.
  // Each window gets its own Promise chain; new ops are appended via .then().
  private windowOpQueues: Map<number, Promise<void>> = new Map();

  // preMaximizeRects: floating rect captured right before maximize(). WMS recover()
  // re-computes the floating position via GetFullScreenToFloatingRect (pointer-anchored —
  // designed for drag-off-titlebar unmaximize), so a programmatic recover() lands the
  // window near the cursor (top-right when triggered from the ❐ title-bar button) instead
  // of the pre-maximize position. recoverWindow() moveTo()s back to the saved rect.
  // has()-guarded on save: a second maximize while already maximized keeps the FIRST
  // floating rect (the current rect would be the maximized one). Cleared on use and in
  // removeWindow.
  private preMaximizeRects: Map<number, window.Rect> = new Map();

  // Track the last focused window via WINDOW_ACTIVE (kept for backward compat / debugging)
  private lastFocusedWindow: window.Window | null = null;
  private lastFocusedWindowId: number = -1;

  // Track the window the user last physically touched (onTouch-based).
  // Unlike WINDOW_ACTIVE, onTouch only fires on actual user touch — immune to
  // cascade broadcasts, GoForeground events, and programmatic showWindow().
  // Semantically equivalent to macOS Key Window / Windows Foreground Window.
  private lastUserInteractedWindowId: number = -1;

  // Pending window action for StatusBar menu race condition fix
  // When a tray menu item is clicked, the system triggers onNewWant → GoForeground
  // which can undo our window operations (minimize/hide/close).
  // Solution: defer window operations until WINDOW_ACTIVE/WINDOW_SHOWN event fires.
  private pendingAction: (() => void) | null = null;
  private cleanupTimer: number | null = null;

  // Phase 2 (design.md D3 注入小节): single rect-change callback that createSubWindow's
  // per-window windowRectChange handler invokes. WindowManager doesn't hold a lifecycle
  // reference, so NativeAbility.onWindowStageCreate registers a callback here that fans
  // out to every lifecycle.windowStageEventCallback.onWindowRectChange(wrapped). The
  // wrapped options carry the windowId (main window = 0, sub-window = the createSubWindow
  // windowId parameter).
  private rectChangeCallback?: (options: WindowRectEventWrap) => void;

  private constructor(context: common.UIAbilityContext) {
    this.context = context;
    // The throttle only needs the window-lifetime `destroying` flag — injected as a
    // probe so RectThrottle stays decoupled from this class's window registry.
    this.rectThrottle = new RectThrottle((wid: number): boolean => {
      const entry = this.windows.get(wid);
      return entry?.destroying === true;
    });
  }

  static init(context: common.UIAbilityContext): void {
    if (!WindowManager.instance) {
      hilog.info(DOMAIN, 'WindowManager', 'WindowManager initialized');
      WindowManager.instance = new WindowManager(context);
    }
  }

  static getInstance(): WindowManager {
    if (!WindowManager.instance) {
      hilog.error(DOMAIN, 'WindowManager', 'WindowManager not initialized');
      throw new Error("WindowManager not initialized");
    }
    return WindowManager.instance;
  }

  // Exposes the UIAbilityContext so NativeAbility.startUIAbility can call
  // context.startAbility without holding its own reference (WindowManager is the
  // shared singleton across EntryAbility instances in the same process).
  getContext(): common.UIAbilityContext {
    return this.context;
  }

  // Whether the primary (first-instance) WindowStage has been registered.
  // Unified registration for all UIAbility WindowStages (id=0 first instance
  // or id>0 subsequent instances — equal, no primary/subordinate distinction).
  // Stores stage in uiAbilityStages, sets windowKinds, and registers focus tracking.
  registerUIAbilityStage(windowId: number, windowStage: window.WindowStage, context: common.UIAbilityContext, transparent: boolean = false): void {
    const wid = Number(windowId);
    this.uiAbilityStages.set(wid, windowStage);
    this.uiAbilityContexts.set(wid, context);
    this.windowKinds.set(wid, WindowKind.UIAbility);
    this.transparentFlags.set(wid, transparent);
    hilog.info(DOMAIN, 'WindowManager', 'UIAbility stage registered: id=%{public}d transparent=%{public}s', wid, String(transparent));

    // Register focus tracking for this window
    try {
      const mainWindow = windowStage.getMainWindowSync();
      this.registerFocusTracking(mainWindow, wid);
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', 'Failed to register focus tracking for id=%{public}d: %{public}s', wid, String(e));
    }

    // Transparency is applied in createWebview (when data.transparent=true),
    // not here — onWindowStageCreate is too early (setWindowBackgroundColor
    // fails with "window state is abnormal"). createWebview runs after the
    // window is fully ready, so setWindowContainerColor succeeds there.
  }

  unregisterUIAbilityStage(windowId: number): void {
    const wid = Number(windowId);
    this.uiAbilityStages.delete(wid);
    this.clearWindowState(wid);
    hilog.info(DOMAIN, 'WindowManager', 'UIAbility stage unregistered: id=%{public}d', wid);
  }

  // Single source of truth for per-window state cleanup (issue #87 major-5): both
  // unregisterUIAbilityStage and removeWindow delegate here, so the two paths can
  // never drift apart again (they had diverged: one cleared transparentFlags/
  // windowKinds, the other preMaximizeRects).
  private clearWindowState(wid: number): void {
    this.uiAbilityContexts.delete(wid);
    this.windowKinds.delete(wid);
    this.transparentFlags.delete(wid);
    this.attachments.clearWindow(wid);
    this.windowOpQueues.delete(wid);
    this.preMaximizeRects.delete(wid);
    this.rectThrottle.clearWindow(wid);
  }

  // Whether the given window is a UIAbility main window.
  // Such windows are system-managed: win.resize()/moveWindowTo() return 1300002,
  // decorations are system-provided, and per-button enable flags are no-ops.
  // windowId=0 alone must NOT be used for this judgement — a subsequent UIAbility
  // instance has id>0 but is still a system-managed main window.
  isUIAbilityMainWindow(windowId: number): boolean {
    const wid = Number(windowId);
    return this.windowKinds.get(wid) === WindowKind.UIAbility;
  }

  // Query whether a UIAbility window was created with transparent=true.
  isTransparent(windowId: number): boolean {
    const wid = Number(windowId);
    return this.transparentFlags.get(wid) === true;
  }

  // Serialize an async window operation per-window. Each window gets its own Promise
  // chain; new ops are appended via .then() so they wait for the previous op to settle.
  // Errors in one op do NOT block subsequent ops (the chain always continues via .catch).
  // This prevents race conditions like fullscreen-exit (recover) racing with a subsequent
  // maximize call.
  private serializeOp(windowId: number, op: () => Promise<void>): void {
    const wid = Number(windowId);
    const prev = this.windowOpQueues.get(wid) ?? Promise.resolve();
    hilog.debug(DOMAIN, 'WindowManager', 'serializeOp: window %{public}d queued (had prior=%{public}s)', wid, String(prev !== Promise.resolve()));
    const next = prev.then(op).catch((err: ESObject) => {
      hilog.warn(DOMAIN, 'WindowManager', 'serializeOp: window %{public}d op failed: %{public}s', wid, String(err?.message ?? err));
    });
    this.windowOpQueues.set(wid, next);
  }

  // Apply transparent background + container color to a UIAbility main window.
  // Called by DefaultXComponent.aboutToAppear (window fully ready there).
  // active=transparent, inactive=opaque white (inactive alpha=0 triggers error 401).
  async applyTransparentBackground(windowId: number): Promise<void> {
    const wid = Number(windowId);
    const isTrans = this.isTransparent(wid);
    hilog.debug(DOMAIN, 'WindowManager', 'applyTransparentBackground: windowId=%{public}d isTransparent=%{public}s', wid, String(isTrans));
    if (!isTrans) {
      return;
    }
    const stage = this.uiAbilityStages.get(wid);
    if (!stage) {
      hilog.warn(DOMAIN, 'WindowManager', 'applyTransparentBackground: no stage for id=%{public}d', wid);
      return;
    }
    try {
      const mainWindow = await stage.getMainWindow();
      mainWindow.setWindowBackgroundColor('#00000000');
      hilog.info(DOMAIN, 'WindowManager', 'applyTransparentBackground: windowId=%{public}d setWindowBackgroundColor transparent OK', wid);
      if (deviceInfo.sdkApiVersion >= 20) {
        try {
          mainWindow.setWindowContainerColor('#00000000', '#FFFFFFFF');
          hilog.info(DOMAIN, 'WindowManager', 'applyTransparentBackground: windowId=%{public}d setWindowContainerColor transparent OK (active=transparent inactive=white)', wid);
        } catch (containerErr: any) {
          hilog.warn(DOMAIN, 'WindowManager', 'applyTransparentBackground: windowId=%{public}d setWindowContainerColor failed: code=%{public}d', wid, containerErr.code);
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', 'applyTransparentBackground: windowId=%{public}d failed: %{public}s', wid, String(e));
    }
  }

  // Register WINDOW_ACTIVE listener for focus tracking
  // Also listens for RESUMED/WINDOW_ACTIVE to consume pending actions
  private registerFocusTracking(win: window.Window, windowId: number): void {
    win.on('windowEvent', (eventType: window.WindowEventType) => {
      // Track last focused window
      if (eventType === window.WindowEventType.WINDOW_ACTIVE) {
        this.lastFocusedWindow = win;
        this.lastFocusedWindowId = windowId;
        hilog.info(DOMAIN, 'WindowManager', 'Last focused window updated: id=%{public}d', windowId);
      }

      // Consume pending action when system foreground transition completes
      // WINDOW_ACTIVE: window gained focus (marks end of foreground transition)
      // WINDOW_SHOWN: window is visible (alternative trigger)
      if (eventType === window.WindowEventType.WINDOW_ACTIVE ||
          eventType === window.WindowEventType.WINDOW_SHOWN) {
        if (this.hasPendingAction()) {
          hilog.info(DOMAIN, 'WindowManager',
            'System foreground transition complete (event: %{public}s), executing pending action',
            eventType === window.WindowEventType.WINDOW_ACTIVE ? 'WINDOW_ACTIVE' : 'WINDOW_SHOWN');
          this.consumePendingAction();
        }
      }

    });
  }

  // Get the last focused window via WINDOW_ACTIVE (kept for backward compat)
  getFocusedWindow(): window.Window | null {
    return this.lastFocusedWindow;
  }

  // Get the last focused window ID
  getFocusedWindowId(): number {
    return this.lastFocusedWindowId;
  }

  // ─── User Interaction Tracking (onTouch-based window targeting) ───
  //
  // Called from page root Stack.onTouch() (MainPage/FloatPage, D8) when the user physically touches a window.
  // ArkUI onTouch bubbles from child to parent, covering MenuBarComponent + webview + drag bars.
  // Used by tray menu to determine which window to operate on.
  setUserInteractedWindow(windowId: number): void {
    this.lastUserInteractedWindowId = windowId;
    hilog.info(DOMAIN, 'WindowManager', 'User interacted with window: id=%{public}d', windowId);
  }

  // Get the window the user last physically touched (for Tray menu path)
  getUserInteractedWindow(): window.Window | null {
    if (this.lastUserInteractedWindowId < 0) {
      return null;
    }
    return this.getWindow(this.lastUserInteractedWindowId) ?? null;
  }

  // Get the ID of the window the user last physically touched
  getUserInteractedWindowId(): number {
    return this.lastUserInteractedWindowId;
  }

  // Reset user interaction tracking after window becomes invisible (minimize/hide/close).
  // Subsequent tray menu operations will fall back to main window.
  resetUserInteractionTracking(): void {
    this.lastUserInteractedWindowId = -1;
  }

  // ─── Window Operation Wrappers ───
  // These wrappers ensure resetUserInteractionTracking() is called after operations
  // that make a window invisible (minimize/hide/close).

  /**
   * Minimize with guard against OHOS system focus restoration.
   *
   * When a status-bar tray menu closes, the system may automatically restore
   * focus to the main window (WINDOW_ACTIVE). If win.minimize() runs
   * immediately, the system's focus restoration can race ahead and pop the
   * window back ("flash": shrink then restore). Defer minimize() until
   * WINDOW_ACTIVE settles; if it never fires, a 50ms timeout falls back to
   * direct minimize. Mirrors the fb33ff1 minimizeWithRestoreGuard.
   *
   * Returns a Promise that resolves only after win.minimize() settles, so the
   * serializeOp slot stays held for the whole deferred minimize — a subsequent
   * queued op (maximize/recover) cannot reorder ahead of it.
   */
  private minimizeWithRestoreGuard(win: window.Window): Promise<void> {
    return new Promise<void>((resolve) => {
      let consumed = false;
      const finish = () => { try { win.off('windowEvent', onWindowEvent); } catch (_) {} };
      const doMinimize = () => {
        if (consumed) return;
        consumed = true;
        finish();
        hilog.info(DOMAIN, 'WindowManager', 'minimizeWithRestoreGuard: minimizing (settled)');
        win.minimize().then(() => resolve())
          .catch((err: ESObject) => {
            hilog.warn(DOMAIN, 'WindowManager', 'minimizeWithRestoreGuard minimize failed: %{public}s', JSON.stringify(err));
            resolve();
          });
      };
      const onWindowEvent = (eventType: window.WindowEventType) => {
        if (!consumed && eventType === window.WindowEventType.WINDOW_ACTIVE) {
          hilog.info(DOMAIN, 'WindowManager', 'minimizeWithRestoreGuard: WINDOW_ACTIVE fired');
          doMinimize();
        }
      };
      try {
        win.on('windowEvent', onWindowEvent);
      } catch (_) {
        hilog.warn(DOMAIN, 'WindowManager', 'minimizeWithRestoreGuard: windowEvent unsupported, direct minimize');
        win.minimize().then(() => resolve()).catch(() => resolve());
        return;
      }
      hilog.info(DOMAIN, 'WindowManager', 'minimizeWithRestoreGuard: waiting for WINDOW_ACTIVE (50ms fallback)');
      setTimeout(doMinimize, 50);
    });
  }

  minimizeWindow(windowId: number): void {
    // 拦截:FLAG_MINIMIZABLE 为 0 时,不允许最小化(问题四:语义错位修复)
    if (!this.getDecorationFlag(windowId, 'minimizable')) {
      hilog.warn(DOMAIN, 'WindowManager', 'minimizeWindow blocked: minimizable flag not set (window %{public}d)', windowId);
      return;
    }
    this.withWindow(windowId, 'minimizeWindow', (win: window.Window) => {
      // Serialize: minimize can race with maximize/recover/fullscreen. The guard's
      // Promise keeps the serialization slot held until the deferred minimize
      // settles, preserving op ordering.
      this.serializeOp(windowId, () =>
        this.minimizeWithRestoreGuard(win).then(() => {
          // Only reset tracking if the minimized window was the last interacted one
          if (this.lastUserInteractedWindowId === windowId) {
            this.resetUserInteractionTracking();
          }
        })
      );
    });
  }

  focusWindow(windowId: number): void {
    this.withWindow(windowId, 'focusWindow', (win: window.Window) => {
      this.fireAndForget(win.raiseToAppTop(), 'focusWindow', windowId, () => {
        hilog.debug(DOMAIN, 'WindowManager', 'focusWindow: window %{public}d raised to top', windowId);
      });
    });
  }

  setWindowFocusable(windowId: number, focusable: boolean): void {
    this.withWindow(windowId, 'setWindowFocusable', (win: window.Window) => {
      this.fireAndForget(win.setWindowFocusable(focusable), 'setWindowFocusable', windowId, () => {
        hilog.debug(DOMAIN, 'WindowManager', 'setWindowFocusable: window %{public}d focusable=%{public}s', windowId, String(focusable));
      });
    });
  }

  setWindowTouchable(windowId: number, touchable: boolean): void {
    // setWindowTouchable returns a Promise; 401/1300002/1300003 reject asynchronously;
    // the unified fireAndForget catch prevents the unhandled-reject crash (Rust does
    // not perceive the failure — TSFN fire-and-forget, see set_window_touchable docs).
    this.withWindow(windowId, 'setWindowTouchable', (win: window.Window) => {
      this.fireAndForget(win.setWindowTouchable(touchable), 'setWindowTouchable', windowId, () => {
        hilog.debug(DOMAIN, 'WindowManager', 'setWindowTouchable: window %{public}d touchable=%{public}s', windowId, String(touchable));
      });
    });
  }

  // ─── Window operations (ohos-window-ops) ───

  moveWindowTo(windowId: number, x: number, y: number): void {
    this.withWindow(windowId, 'moveWindowTo', (win: window.Window) => {
      this.fireAndForget(win.moveWindowTo(x, y), 'moveWindowTo', Number(windowId));
    });
  }

  resizeWindow(windowId: number, width: number, height: number): void {
    this.withWindow(windowId, 'resizeWindow', (win: window.Window) => {
      this.fireAndForget(win.resize(width, height), 'resizeWindow', Number(windowId));
    });
  }

  // --- pre-maximize rect snapshot helpers (shared with WindowPlugin's tao bridge path) ---
  // WMS recover() re-anchors the floating rect to the pointer (GetFullScreenToFloatingRect);
  // these snapshot/restore the pre-maximize position so any maximize→recover pair —
  // FloatPage title-bar buttons OR the tao set_maximized bridge (WindowPlugin.windowCommand,
  // which cannot delegate to maximizeWindow/recoverWindow without losing its await
  // completion semantics) — lands back where it started.
  snapshotPreMaximizeRect(windowId: number, win: window.Window): void {
    const wid = Number(windowId);
    // has-guard: if already maximized, keep the first snapshot — the live rect
    // would be the maximized fullscreen one.
    if (!this.preMaximizeRects.has(wid)) {
      this.preMaximizeRects.set(wid, win.getWindowProperties().windowRect);
    }
  }

  async restorePreMaximizeRect(windowId: number, win: window.Window): Promise<void> {
    const wid = Number(windowId);
    const saved = this.preMaximizeRects.get(wid);
    if (!saved) { return; }
    this.preMaximizeRects.delete(wid);
    try {
      await win.moveTo(saved.left, saved.top);
    } catch (err) {
      // Position restore is best-effort: the caller's recover() already succeeded —
      // a moveTo failure must not surface as a recover failure.
      hilog.warn(DOMAIN, 'WindowManager', 'restorePreMaximizeRect %{public}d moveTo failed: %{public}s', wid, JSON.stringify(err));
    }
  }

  maximizeWindow(windowId: number): void {
    // 拦截:FLAG_MAXIMIZABLE 为 0 时,不允许最大化(问题四:语义错位修复)
    if (!this.getDecorationFlag(windowId, 'maximizable')) {
      hilog.warn(DOMAIN, 'WindowManager', 'maximizeWindow blocked: maximizable flag not set (window %{public}d)', windowId);
      return;
    }
    this.withWindow(windowId, 'maximizeWindow', (win: window.Window) => {
      // Serialize: maximize can race with fullscreen-exit (recover) or minimize.
      this.serializeOp(windowId, () => {
        // Snapshot the floating rect BEFORE maximizing (see snapshotPreMaximizeRect).
        this.snapshotPreMaximizeRect(windowId, win);
        // Use FOLLOW_APP_IMMERSIVE_SETTING (not ENTER_IMMERSIVE) to preserve the existing
        // fullscreen layout mode. ENTER_IMMERSIVE explicitly enters fullscreen on maximize and
        // exits it on recover, causing a layout gap (white bar at bottom where navigation bar was).
        // FOLLOW_APP_IMMERSIVE_SETTING preserves setWindowLayoutFullScreen(true) set at init.
        return win.maximize(window.MaximizePresentation.FOLLOW_APP_IMMERSIVE_SETTING).then(() => {
          hilog.info(DOMAIN, 'WindowManager', 'maximizeWindow %{public}d OK', windowId);
        });
      });
    });
  }

  setWindowTopmost(windowId: number, topmost: boolean): void {
    // win.setWindowTopmost() is API14+. Requires ohos.permission.WINDOW_TOPMOST
    // (system_grant, declared in module.json5). Main window only — Float sub-windows
    // will error (non-fatal). Only effective in freeform window mode; returns 801
    // on devices without freeform support (phone/tablet).
    if (deviceInfo.sdkApiVersion < 14) {
      hilog.warn(DOMAIN, 'WindowManager', 'setWindowTopmost: API14+ required, current %{public}d; no-op', deviceInfo.sdkApiVersion);
      return;
    }
    this.withWindow(windowId, 'setWindowTopmost', (win: window.Window) => {
      // 801: non-freeform device/state; sub-window call; 1300002: window state abnormal — non-fatal
      this.fireAndForget(win.setWindowTopmost(topmost), 'setWindowTopmost', windowId, () => {
        hilog.info(DOMAIN, 'WindowManager', 'setWindowTopmost %{public}d topmost=%{public}s OK', windowId, String(topmost));
      });
    });
  }

  setWindowTitle(windowId: number, title: string): void {
    // win.setWindowTitle(title) is Promise form (1 arg). Main window + Float sub-windows
    // both support title text (icon is NOT changeable at runtime). No extra permission
    // for main window. Only visible when window decorations are enabled (decorEnabled=true).
    this.withWindow(windowId, 'setWindowTitle', (win: window.Window) => {
      // Also update LocalStorage 'title' so FloatPage @LocalStorageProp('title') refreshes the title bar text.
      const entry = this.windows.get(windowId);
      if (entry?.storage) {
        entry.storage.setOrCreate('title', title);
      }
      this.fireAndForget(win.setWindowTitle(title), 'setWindowTitle', windowId, () => {
        hilog.info(DOMAIN, 'WindowManager', 'setWindowTitle %{public}d title="%{public}s" OK', windowId, title);
      });
    });
  }

  setWindowLimits(windowId: number, minW: number, minH: number, maxW: number, maxH: number): void {
    // win.setWindowLimits() is API11+. Params are px (0 = no limit / system default).
    // WindowLimits fields: minWidth/minHeight/maxWidth/maxHeight (NOT minWindowWidth etc.)
    // ⚠️ Triggers OnSizeChange — caller must not invoke frequently on main window (appfreeze risk).
    this.withWindow(windowId, 'setWindowLimits', (win: window.Window) => {
      const limits: window.WindowLimits = {
        minWidth: minW,
        minHeight: minH,
        maxWidth: maxW,
        maxHeight: maxH,
      };
      this.fireAndForget(win.setWindowLimits(limits), 'setWindowLimits', windowId, (actual: window.WindowLimits) => {
        hilog.info(DOMAIN, 'WindowManager', 'setWindowLimits %{public}d OK: min=%{public}dx%{public}d max=%{public}dx%{public}d',
          windowId, actual.minWidth, actual.minHeight, actual.maxWidth, actual.maxHeight);
      });
    });
  }

  restoreWindow(windowId: number): void {
    // Mirror the Rust-side API14 guard (win.restore() is API14+). The Rust path
    // (restore_window) already guards, so this is defense-in-depth for any direct
    // ArkTS caller; on API<14 it is a no-op+warn instead of throwing.
    if (deviceInfo.sdkApiVersion < 14) {
      hilog.warn(DOMAIN, 'WindowManager', 'restoreWindow: win.restore() requires API14+, current %{public}d; no-op', deviceInfo.sdkApiVersion);
      return;
    }
    this.withWindow(windowId, 'restoreWindow', (win: window.Window) => {
      // Serialize: restore can race with maximize/recover/fullscreen.
      this.serializeOp(windowId, () =>
        // FOLLOW_APP_IMMERSIVE_SETTING preserves the existing fullscreen layout,
        // so no setWindowLayoutFullScreen(true) needed after restore.
        win.restore().then(() => {
          hilog.info(DOMAIN, 'WindowManager', 'restoreWindow %{public}d OK', windowId);
        })
      );
    });
  }

  recoverWindow(windowId: number): void {
    this.withWindow(windowId, 'recoverWindow', (win: window.Window) => {
      // Serialize: recover can race with a pending maximize or fullscreen-enter.
      this.serializeOp(windowId, () =>
        // FOLLOW_APP_IMMERSIVE_SETTING preserves the existing fullscreen layout,
        // so no setWindowLayoutFullScreen(true) needed after recover.
        win.recover().then(async () => {
          // recover() positions the restored floating window via WMS
          // GetFullScreenToFloatingRect — pointer-anchored, designed for drag-off-
          // titlebar unmaximize — NOT the pre-maximize rect (device-verified: a
          // window created at [0,0] came back at [1913,0], i.e. under the cursor /
          // top-right where the ❐ button was clicked). moveTo() the rect snapshotted
          // in maximizeWindow() to restore the original position. Size is NOT
          // re-applied: GetFullScreenToFloatingRect preserves the floating w/h.
          if (this.preMaximizeRects.has(Number(windowId))) {
            await this.restorePreMaximizeRect(windowId, win);
            hilog.info(DOMAIN, 'WindowManager', 'recoverWindow %{public}d OK (restored pre-maximize rect)', windowId);
          } else {
            hilog.info(DOMAIN, 'WindowManager', 'recoverWindow %{public}d OK (no pre-maximize rect; WMS default position)', windowId);
          }
        })
      );
    });
  }

  showWindowMethod(windowId: number): void {
    // UIAbility main window: hideWindow did win.minimize() → window is in MINIMIZE state.
    // showWindow() cannot restore from MINIMIZE (it only shows a hidden window / raises an
    // already-shown main window to the top). The documented inverse of minimize() for the
    // main window is restore() (the minimize() API doc links restore() for restoration;
    // API14+, guarded inside restoreWindow). This replaces the prior
    // startAbility(instanceKey='main') path: under launchType "standard" (tauri-cli
    // template) instanceKey is ignored and every startAbility spawns a DUPLICATE
    // EntryAbility. The demo masked this (its module.json5 omits launchType → singleton →
    // onNewWant). Restore only when actually minimized so a redundant set_visible(true) on
    // a visible maximized window does not un-maximize it. (PR#45 review F3/D)
    if (this.isUIAbilityMainWindow(windowId)) {
      if (this.isMinimized(windowId)) {
        this.restoreWindow(windowId);
      }
      return;
    }
    // Sub-window: showWindow() restores from minimize (symmetric with hideWindow's minimize).
    this.withWindow(windowId, 'showWindowMethod', (win: window.Window) => {
      this.fireAndForget(win.showWindow(), 'showWindowMethod', windowId, () => {
        hilog.info(DOMAIN, 'WindowManager', 'showWindowMethod %{public}d OK', windowId);
      });
    });
  }

  // hide: main window uses win.minimize() (hideAbility not supported on PC/2in1 — StartOptions check failed).
  // show: main window uses restore() — the documented inverse of minimize() (see showWindowMethod).
  // Sub-window: minimize + showWindow (symmetric, works).
  hideWindow(windowId: number): void {
    this.withWindow(windowId, 'hideWindow', (win: window.Window) => {
      this.fireAndForget(win.minimize(), 'hideWindow', windowId, () => {
        hilog.info(DOMAIN, 'WindowManager', 'hideWindow(minimize) %{public}d OK', windowId);
      });
    });
  }

  // set_fullscreen → dual-path immersive fullscreen based on screen form factor.
  // Desktop / 2in1 (display width > 800): maximize(ENTER_IMMERSIVE) + hide title
  //   bar / Dock hover via setTitleAndDockHoverShown(false,false). Exit via
  //   recover() + setTitleAndDockHoverShown(true,true).
  // Mobile (display width <= 800): setWindowLayoutFullScreen(true) +
  //   setWindowSystemBarEnable([]) to hide BOTH status + nav bars. Exit via
  //   setWindowLayoutFullScreen(false) + setWindowSystemBarEnable(['status','navigation']).
  // setTitleAndDockHoverShown is a PC/2in1-only API and would throw on phones,
  // so it must not be called on the mobile path.
  // Any failure in the primary path falls back to the desktop immersive maximize.
  // The predefined menu fullscreen (menu.ets PredefinedActionExecutor) and the
  // Esc exit path (NativeAbility menubar recoverFn) both delegate here.
  setFullscreen(windowId: number, on: boolean): void {
    this.withWindow(windowId, 'setFullscreen', (win: window.Window) => {
      hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d on=%{public}s ENTER', windowId, String(on));

      // Menubar follows fullscreen state (macOS semantics, design.md MW-5/D3):
      // hide on entry, restore on exit. Centralized here so ALL fullscreen
      // entry points (window-API set_fullscreen, predefined menu fullscreen,
      // Esc exit) behave identically. The exit path is additionally covered by
      // the windowRectChange(RECOVER) → onMenubarVisible(true) handler in
      // NativeAbility (D3) — double-restore is idempotent.
      const menuCb = getMenuDataCallback(windowKeyForId(windowId));
      menuCb?.onMenubarVisible?.(on ? false : true);
      if (on) {
        menuCb?.onMenuShown?.(false);
      }

      const isDesktop = display.getDefaultDisplaySync().width > 800;

      // Serialize the entire multi-step fullscreen chain per-window. Without this,
      // a rapid fullscreen-on → fullscreen-off sequence (e.g., auto-test with 400ms
      // delay) causes the off chain to race with the still-pending on chain, leaving
      // the window in a half-fullscreen state that breaks subsequent maximize.
      this.serializeOp(windowId, async () => {
        if (on) {
          if (isDesktop) {
            // Desktop / 2in1: maximize(ENTER_IMMERSIVE) → hide title bar + Dock hover
            await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
            hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d maximize(ENTER_IMMERSIVE) OK', windowId);
            await win.setTitleAndDockHoverShown(false, false);
            hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d setTitleAndDockHoverShown(false,false) OK', windowId);
          } else {
            // Mobile: setWindowLayoutFullScreen(true) → hide status + nav bars
            try {
              await win.setWindowLayoutFullScreen(true);
              hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d setWindowLayoutFullScreen(true) OK', windowId);
              await win.setWindowSystemBarEnable([]);
              hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d setWindowSystemBarEnable([]) OK', windowId);
            } catch (_err) {
              // Fallback to desktop immersive maximize
              await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
            }
          }
        } else {
          if (isDesktop) {
            // Desktop / 2in1: recover() → show title bar + Dock hover
            await win.recover();
            hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d recover() OK', windowId);
            await win.setTitleAndDockHoverShown(true, true);
            hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d setTitleAndDockHoverShown(true,true) OK', windowId);
          } else {
            // Mobile: setWindowLayoutFullScreen(false) → restore status + nav bars
            try {
              await win.setWindowLayoutFullScreen(false);
              hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d setWindowLayoutFullScreen(false) OK', windowId);
              await win.setWindowSystemBarEnable(['status', 'navigation']);
              hilog.info(DOMAIN, 'WindowManager', 'setFullscreen %{public}d setWindowSystemBarEnable([status,navigation]) OK', windowId);
            } catch (_err) {
              // Fallback to desktop recover
              await win.recover();
            }
          }
        }
      });
    });
  }

  // Group D decoration button bitfield: bit0 closable, bit1 maximizable, bit2 minimizable, bit3 resizable.
  // Only applies to Float sub-windows (writes LocalStorage); UIAbility main window is a no-op
  // (decorations are system-provided).
  // Read a decoration flag from LocalStorage (问题四: 拦截 API 执行路径)
  // key: 'closable' | 'maximizable' | 'minimizable' | 'resizable'
  // Returns true if not set (default = all available, backward compatible)
  getDecorationFlag(windowId: number, key: string): boolean {
    const entry = this.windows.get(windowId);
    if (!entry || !entry.storage) {
      return true;  // default: allowed (no storage = main window or not yet initialized)
    }
    const val = entry.storage.get<boolean>(key);
    return val === undefined ? true : val;
  }

  setDecorationFlags(windowId: number, flags: number): void {
    if (this.isUIAbilityMainWindow(windowId)) {
      hilog.info(DOMAIN, 'WindowManager', 'setDecorationFlags: UIAbility main window (id=%{public}d) no-op', windowId);
      return;
    }
    const entry = this.windows.get(windowId);
    if (!entry || !entry.storage) {
      hilog.warn(DOMAIN, 'WindowManager', 'setDecorationFlags: window %{public}d not found', windowId);
      return;
    }
    entry.storage.setOrCreate('closable', (flags & 1) !== 0);
    entry.storage.setOrCreate('maximizable', (flags & 2) !== 0);
    entry.storage.setOrCreate('minimizable', (flags & 4) !== 0);
    entry.storage.setOrCreate('resizable', (flags & 8) !== 0);
  }

  // Group E cursor: @ohos.multimodalInput.pointer
  setPointerVisible(visible: boolean): void {
    try { pointer.setPointerVisible(visible); }
    catch (err) { hilog.warn(DOMAIN, 'WindowManager', 'setPointerVisible failed: %{public}s', JSON.stringify(err)); }
  }

  setPointerStyle(windowId: number, style: number): void {
    // pointer.setPointerStyleSync needs the REAL OHOS window ID (from getWindowProperties().id),
    // not tao's placeholder windowId (0 for main window). Passing 0 succeeds but has no effect.
    // NOTE: called from Rust via NAPI func.call (via ArkHelper.setPointerStyle) — bare hilog
    // in this sync body throws "Argc mismatch" (NAPI re-entrancy, C5): the success log would
    // turn a success into a reported failure, and the catch log would swallow the original err.
    // Use console fallback (same escape hatch as safeLogError / getRealWindowId below).
    const win = this.getWindow(windowId);
    if (!win) { console.warn(`[WindowManager] setPointerStyle: window ${windowId} not found`); return; }
    try {
      const realWindowId = win.getWindowProperties().id;
      pointer.setPointerStyleSync(realWindowId, style as pointer.PointerStyle);
      console.info(`[WindowManager] setPointerStyle taoId=${windowId} realId=${realWindowId} style=${style} OK`);
    } catch (err) { console.error(`[WindowManager] setPointerStyle ${windowId} failed: ${JSON.stringify(err)}`); }
  }

  // Resolve tao's windowId (0 = main window placeholder) to the REAL OHOS window ID
  // (getWindowProperties().id) required by native OH_WindowManager_* C APIs.
  // NOTE: called from Rust via NAPI func.call — hilog is FORBIDDEN in this body
  // (NAPI re-entrancy throws "Argc mismatch"); failure is expressed as -1.
  getRealWindowId(windowId: number): number {
    try {
      const win = this.getWindow(windowId);
      if (!win) { return -1; }
      const id = win.getWindowProperties().id;
      return (typeof id === 'number') ? id : -1;
    } catch (_err) {
      return -1;
    }
  }

  isMaximized(windowId: number): boolean {
    const win = this.getWindow(windowId);
    if (!win) { return false; }
    return win.getWindowStatus() === window.WindowStatusType.MAXIMIZE;
  }

  isMinimized(windowId: number): boolean {
    const win = this.getWindow(windowId);
    if (!win) { return false; }
    return win.getWindowStatus() === window.WindowStatusType.MINIMIZE;
  }

  // Destroy a window and clean up all resources.
  // Works for both main window (id=0) and sub-windows.
  async destroyWindow(windowId: number): Promise<void> {
    // 拦截:FLAG_CLOSABLE 为 0 时,不允许关闭(问题四:语义错位修复)
    if (!this.getDecorationFlag(windowId, 'closable')) {
      hilog.warn(DOMAIN, 'WindowManager', 'destroyWindow blocked: closable flag not set (window %{public}d)', windowId);
      return;
    }
    const win = this.getWindow(windowId);
    if (!win) {
      hilog.warn(DOMAIN, 'WindowManager', 'destroyWindow: window %{public}d not found', windowId);
      return;
    }
    // Phase 3 (design.md D4): set destroying=true before win.destroyWindow() so
    // in-flight throttled events are discarded (no consumers left after destroy).
    const entry = this.windows.get(windowId);
    if (entry) {
      entry.destroying = true;
    }
    try {
      await win.destroyWindow();
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', 'destroyWindow failed for %{public}d: %{public}s', windowId, String(e));
    }
    this.removeWindow(windowId);
  }

  // Close a window for real (not hide).
  // - UIAbility main window (id=0 first instance or id>0 subsequent instance):
  //   terminate the Ability instance via context.terminateSelf(). This truly
  //   closes the instance (removed from recent tasks), distinct from hideAbility
  //   which only backgrounds it. The first instance (id=0) terminating == app
  //   exit; secondary instances (id>0) terminating == that instance only exits.
  // - Float sub-window: win.destroyWindow() + removeWindow cleanup.
  async closeWindow(windowId: number): Promise<void> {
    if (this.isUIAbilityMainWindow(windowId)) {
      const ctx = this.uiAbilityContexts.get(Number(windowId));
      if (ctx) {
        hilog.info(DOMAIN, 'WindowManager', 'closeWindow: terminateSelf for UIAbility id=%{public}d', windowId);
        try {
          await ctx.terminateSelf();
        } catch (e) {
          hilog.warn(DOMAIN, 'WindowManager', 'closeWindow: terminateSelf failed for id=%{public}d: %{public}s', windowId, String(e));
        }
      } else {
        hilog.warn(DOMAIN, 'WindowManager', 'closeWindow: no context for UIAbility id=%{public}d (not registered?), falling back to hideAbility', windowId);
        await this.hideAbility();
      }
      return;
    }
    const win = this.getWindow(windowId);
    if (!win) {
      hilog.warn(DOMAIN, 'WindowManager', 'closeWindow: window %{public}d not found', windowId);
      return;
    }
    // Phase 3 (design.md D4): set destroying=true before win.destroyWindow() (Float path).
    const entry = this.windows.get(windowId);
    if (entry) {
      entry.destroying = true;
    }
    try {
      await win.destroyWindow();
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', 'closeWindow destroy failed for %{public}d: %{public}s', windowId, String(e));
    }
    // removeWindow handles conditional resetUserInteractionTracking
    this.removeWindow(windowId);
  }

  private logNotFound(op: string, windowId: number): void {
    hilog.warn(DOMAIN, 'WindowManager', `%{public}s: window %{public}d not found`, op, windowId);
  }

  // ─── Boilerplate helpers (issue #87 major-5) ───
  // Centralize the two repeated patterns that used to be hand-written at every
  // window-op site: (1) getWindow null-check + warn + return; (2) fire-and-forget
  // Promise .then(ok-log).catch(warn-log).

  // Run `fn` with the window handle if it exists; otherwise warn-and-return.
  // The windowId is normalized (i64→BigInt NAPI marshalling) once, here.
  private withWindow(windowId: number, op: string, fn: (win: window.Window) => void): void {
    const wid = Number(windowId);
    const win = this.getWindow(wid);
    if (!win) {
      this.logNotFound(op, wid);
      return;
    }
    fn(win);
  }

  // Fire-and-forget a window-op Promise: optional success callback, unified failure
  // warn. The .catch runs in a Promise async callback (NOT a NAPI-reentrant call
  // stack), so hilog is safe here. The catch prevents unhandled-reject crashes;
  // Rust does not perceive the failure (TSFN fire-and-forget).
  private fireAndForget<T>(p: Promise<T>, op: string, windowId: number, onSuccess?: (v: T) => void): void {
    p.then((v: T) => {
      if (onSuccess) {
        onSuccess(v);
      }
    }).catch((err: ESObject) => {
      hilog.warn(DOMAIN, 'WindowManager', '%{public}s %{public}d failed: %{public}s', op, windowId, JSON.stringify(err));
    });
  }

  // Hide the entire Ability (app) to background.
  // Equivalent to macOS Cmd+H (hide:) — all windows become invisible, process stays alive.
  async hideAbility(): Promise<void> {
    await this.hideWithRestoreGuard();
  }

  /**
   * Hide with guard against OHOS system focus restoration.
   *
   * Same race as minimizeWithRestoreGuard, but for context.hideAbility(): when a
   * status-bar tray menu closes, the system restores focus to the app
   * (startSceneFromOther, focusedOnShow:true → RequestSceneSessionActivation).
   * If hideAbility() runs immediately, that activation can land AFTER the hide
   * request and pull the scene back to the foreground, undoing the hide.
   * Defer the hide until the main window's WINDOW_ACTIVE settles; if it never
   * fires, a 50ms timeout falls back to direct hide. Mirrors the proven
   * minimizeWithRestoreGuard pattern. Intentionally NOT wrapped in
   * serializeOp: hide is an AbilityManager-level app op, not a per-window
   * WMS op.
   */
  private hideWithRestoreGuard(): Promise<void> {
    return new Promise<void>((resolve) => {
      const win = this.getWindow(0);
      if (!win) {
        hilog.warn(DOMAIN, 'WindowManager', 'hideWithRestoreGuard: main window not found, direct hide');
        this.doHideAbility().then(() => resolve()).catch(() => resolve());
        return;
      }
      let consumed = false;
      const finish = () => { try { win.off('windowEvent', onWindowEvent); } catch (_) {} };
      const doHide = () => {
        if (consumed) return;
        consumed = true;
        finish();
        hilog.info(DOMAIN, 'WindowManager', 'hideWithRestoreGuard: hiding (settled)');
        this.doHideAbility().then(() => resolve()).catch(() => resolve());
      };
      const onWindowEvent = (eventType: window.WindowEventType) => {
        if (!consumed && eventType === window.WindowEventType.WINDOW_ACTIVE) {
          hilog.info(DOMAIN, 'WindowManager', 'hideWithRestoreGuard: WINDOW_ACTIVE fired');
          doHide();
        }
      };
      try {
        win.on('windowEvent', onWindowEvent);
      } catch (_) {
        hilog.warn(DOMAIN, 'WindowManager', 'hideWithRestoreGuard: windowEvent unsupported, direct hide');
        this.doHideAbility().then(() => resolve()).catch(() => resolve());
        return;
      }
      hilog.info(DOMAIN, 'WindowManager', 'hideWithRestoreGuard: waiting for WINDOW_ACTIVE (50ms fallback)');
      setTimeout(doHide, 50);
    });
  }

  private async doHideAbility(): Promise<void> {
    if (!this.context) {
      hilog.warn(DOMAIN, 'WindowManager', 'hideAbility: context not set');
      return;
    }
    try {
      await this.context.hideAbility();
      this.resetUserInteractionTracking();
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', 'hideAbility failed: %{public}s', String(e));
    }
  }

  // ─── Pending Action Management (StatusBar menu race condition) ───
  //
  // When a tray menu item is clicked, the system triggers onNewWant → GoForeground
  // which can undo window operations executed in the menu click callback.
  //
  // Solution: defer window operations until RESUMED/WINDOW_ACTIVE event fires,
  // indicating the system's foreground transition is complete.
  //
  // Flow:
  // 1. Tray menu click → setPendingAction(action) + start 2s cleanup timer
  // 2. System triggers onNewWant → cancelCleanupTimer()
  // 3. RESUMED/WINDOW_ACTIVE fires → consumePendingAction() executes the action
  // 4. If onNewWant never fires (edge case), cleanup timer clears state after 2s

  setPendingAction(action: () => void): void {
    // Clear any existing pending action
    this.clearPendingAction();

    this.pendingAction = action;
    hilog.info(DOMAIN, 'WindowManager',
      'Pending action set, waiting for system foreground transition');

    // Start safety net cleanup timer (2s)
    this.cleanupTimer = setTimeout(() => {
      if (this.pendingAction) {
        hilog.warn(DOMAIN, 'WindowManager', 'Pending action timeout (2s), cleaning up stale state');
        this.pendingAction = null;
      }
      this.cleanupTimer = null;
    }, 2000);
  }

  consumePendingAction(): boolean {
    if (!this.pendingAction) {
      return false;
    }

    const action = this.pendingAction;
    this.pendingAction = null;

    // Cancel cleanup timer since we're executing the action
    this.cancelCleanupTimer();

    hilog.info(DOMAIN, 'WindowManager', 'Consuming pending action after system foreground transition');
    try {
      action();
      return true;
    } catch (e) {
      hilog.error(DOMAIN, 'WindowManager', 'Failed to execute pending action: %{public}s', String(e));
      return false;
    }
  }

  hasPendingAction(): boolean {
    return this.pendingAction !== null;
  }

  cancelCleanupTimer(): void {
    if (this.cleanupTimer !== null) {
      clearTimeout(this.cleanupTimer);
      this.cleanupTimer = null;
      hilog.info(DOMAIN, 'WindowManager', 'Cleanup timer cancelled');
    }
  }

  clearPendingAction(): void {
    if (this.pendingAction) {
      hilog.info(DOMAIN, 'WindowManager', 'Clearing pending action without execution');
      this.pendingAction = null;
    }
    this.cancelCleanupTimer();
  }

  async createSubWindow(opts: SubWindowOptions): Promise<number> {
    const { name, windowId, width = 800, height = 600, x = 100, y = 100,
            decorations = true, transparent = false, backgroundColor } = opts;

    // Validate windowId: sub-window ID must be greater than 0
    if (windowId <= 0) {
      hilog.error(DOMAIN, 'WindowManager', `Invalid windowId: %{public}d. Sub-window creation requires windowId > 0.`, windowId);
      throw new Error(`Invalid windowId: ${windowId}. Must be greater than 0.`);
    }

    // Check if windowStage has been set
    if (!this.uiAbilityStages.has(0)) {
      hilog.error(DOMAIN, 'WindowManager', 'WindowStage not set. Call setWindowStage() first.');
      throw new Error('WindowStage not set');
    }

    hilog.info(DOMAIN, 'WindowManager', `Creating sub-window via windowStage: %{public}s, id: %{public}d`, name, windowId);

    let win: window.Window;
    try {
      // Use windowStage.createSubWindow(name) instead of window.createWindow(config)
      // API19+: use createSubWindowWithOptions with maximizeSupported:true — win.maximize()
      // on a sub-window is rejected by WMS (1300004 "Only support main or sub Window")
      // unless the sub-window declared maximize capability at creation
      // (SubWindowOptions.maximizeSupported defaults to false). title/decorEnabled are
      // required fields (API11+); decorEnabled:false keeps the system decoration off —
      // FloatPage draws its own title bar. On non-2in1/Tablet devices maximizeSupported
      // is silently ignored (documented no-op), so it is safe to always pass on API19+.
      // This also unlocks maximize for the menu PredefinedMenuItem 'maximize' path and
      // setFullscreen's maximize(ENTER_IMMERSIVE) on sub-windows (same WMS gate).
      if (deviceInfo.sdkApiVersion >= 19) {
        const opts: window.SubWindowOptions = {
          title: '',
          decorEnabled: false,
          maximizeSupported: true,
        };
        win = await this.uiAbilityStages.get(0)?.createSubWindowWithOptions(name, opts);
      } else {
        // API<19: maximizeSupported does not exist in the SDK typings — plain path.
        win = await this.uiAbilityStages.get(0)?.createSubWindow(name);
      }
      hilog.info(DOMAIN, 'WindowManager', `Sub-window created successfully: %{public}d`, windowId);
    } catch (err) {
      hilog.error(DOMAIN, 'WindowManager', `Failed to create sub-window: %{public}s`, JSON.stringify(err));
      throw err;
    }
    
    // Use LocalStorage to pass windowId and decorations, ensuring isolation between windows
    let storage = new LocalStorage();
    storage.setOrCreate('windowId', windowId);
    storage.setOrCreate('decorations', decorations);
    // D group decoration flags default (all available; setDecorationFlags updates them)
    storage.setOrCreate('closable', true);
    storage.setOrCreate('maximizable', true);
    storage.setOrCreate('minimizable', true);
    storage.setOrCreate('resizable', true);
    // Title (set by setWindowTitle → updates this via setWindowTitle impl)
    storage.setOrCreate('title', '');
    this.windows.set(windowId, { window: win, storage, destroying: false });

    // Phase 2 (design.md D3): register this sub-window's windowRectChange handler.
    // This is the only clean registration point for Float sub-windows — createSubWindow
    // holds both `win` and `windowId`. The handler wraps { windowId, reason, rect } and
    // invokes the single rectChangeCallback (registered by NativeAbility.onWindowStageCreate
    // to fan out to lifecycles), so the Rust window_rect_change closure routes the rect
    // into the per-window HashMap at key windowId (design.md D2/D4). Registered BEFORE
    // loadContentByName so early rect changes (resize to target size) are captured.
    // The handler reference is stored in the WindowEntry so destroyWindow/removeWindow
    // can win.off("windowRectChange", handler) to avoid leaking the listener.
    let rectChangeHandler: ((options: window.RectChangeOptions) => void) | undefined =
      (options: window.RectChangeOptions): void => {
        try {
          // Phase 3 (design.md D5): deep-copy rect fields — do not store system object ref.
          // Phase 3 (design.md D3): route through per-window throttle (leading+trailing 16ms).
          const wrapped: WindowRectEventWrap = {
            windowId,
            reason: options.reason,
            rect: { left: options.rect.left, top: options.rect.top, width: options.rect.width, height: options.rect.height }
          };
          this.throttledRectDispatch(windowId, wrapped, (w: object) => {
            this.rectChangeCallback?.(w as WindowRectEventWrap);
          }, 'rect');
        } catch (e) {
          hilog.warn(DOMAIN, 'WindowManager', `Sub-window rectChange handler failed for %{public}d: %{public}s`, windowId, String(e));
        }
      };
    try {
      win.on("windowRectChange", rectChangeHandler);
    } catch (e) {
      hilog.warn(DOMAIN, 'WindowManager', `Failed to register windowRectChange for sub-window %{public}d: %{public}s`, windowId, String(e));
      rectChangeHandler = undefined;
    }
    if (rectChangeHandler) {
      let entry = this.windows.get(windowId);
      if (entry) {
        entry.rectChangeHandler = rectChangeHandler;
      }
    }

    // Register focus tracking for sub-window
    this.registerFocusTracking(win, windowId);

    try {
      hilog.info(DOMAIN, 'WindowManager', `Loading content: FloatPage for window %{public}d`, windowId);
      await win.loadContentByName(FloatPage.RouteName, storage);
      hilog.info(DOMAIN, 'WindowManager', `UI content loaded successfully for window: %{public}d`, windowId);
      
      // Register sub-window's UIContext
      try {
        const uiCtx = win.getUIContext();
        if (uiCtx) {
          this.registerUIContext(windowId, uiCtx);
          hilog.info(DOMAIN, 'WindowManager', `Sub-window UIContext registered for window: %{public}d`, windowId);
        }
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', `Failed to get UIContext for window %{public}d: %{public}s`, windowId, JSON.stringify(e));
      }
    } catch (err) {
      hilog.error(DOMAIN, 'WindowManager', `Failed to load content for window %{public}d: %{public}s`, windowId, JSON.stringify(err));
      throw err;
    }
    
    try {
      // Apply transparent/backgroundColor settings
      if (transparent) {
        hilog.info(DOMAIN, 'WindowManager', `Setting Float window %{public}d to transparent`, windowId);
        await win.setWindowBackgroundColor('#00000000');
        // Float sub-windows ALSO have a window container layer. Without setting
        // it transparent, an opaque container sits between the window background
        // and ArkUI content — blocking backdropBlur from sampling through the
        // transparent window to content behind it (vibrancy/frosted glass effect).
        // This was removed in aca6b53 by mistake (comment incorrectly claimed
        // sub-windows have no container); restoring the original behavior.
        if (deviceInfo.sdkApiVersion >= 20) {
          try {
            await win.setWindowContainerColor('#00000000', '#00000000');
            hilog.info(DOMAIN, 'WindowManager', `Float window %{public}d container color set to transparent (API %{public}d)`, windowId, deviceInfo.sdkApiVersion);
          } catch (containerErr: any) {
            if (containerErr.code === 801) {
              hilog.debug(DOMAIN, 'WindowManager', 'setWindowContainerColor not supported (error 801)');
            } else if (containerErr.code === 201) {
              hilog.error(DOMAIN, 'WindowManager', 'setWindowContainerColor permission denied (error 201): missing ohos.permission.SET_WINDOW_TRANSPARENT');
            } else {
              hilog.warn(DOMAIN, 'WindowManager', `Float window container color failed: code=%{public}d`, containerErr.code);
            }
          }
        }
      } else if (backgroundColor !== undefined) {
        const colorStr = '#' + backgroundColor.toString(16).padStart(8, '0');
        hilog.info(DOMAIN, 'WindowManager', `Setting window %{public}d background color to %{public}s`, windowId, colorStr);
        await win.setWindowBackgroundColor(colorStr);
      }

      hilog.info(DOMAIN, 'WindowManager', `Resizing window %{public}d to %{public}dx%{public}d`, windowId, width, height);
      await win.resize(width, height);
      hilog.info(DOMAIN, 'WindowManager', `Moving window %{public}d to %{public}d,%{public}d`, windowId, x, y);
      await win.moveWindowTo(x, y);
      await win.showWindow();
      hilog.info(DOMAIN, 'WindowManager', `Window shown: %{public}d`, windowId);
    } catch (err) {
      hilog.error(DOMAIN, 'WindowManager', `Failed to resize/move/show window: %{public}s`, JSON.stringify(err));
      throw err;
    }

    return windowId;
  }
  
  getWindow(id: number): window.Window | undefined {
    // Normalize i64→BigInt marshalling from Rust NAPI: Number() is a no-op when id
    // arrives as a number, but fixes the main-window (id=0) lookup when id arrives as
    // BigInt (0n === 0 is false in JS, which would silently miss the windowStage branch
    // and the number-keyed Map). Centralizing here covers all callers.
    const wid = Number(id);
    // First main window (id=0) lives on the primary windowStage.
    if (wid === 0 && this.uiAbilityStages.has(0)) {
      try {
        return this.uiAbilityStages.get(0)?.getMainWindowSync();
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', 'Failed to get main window: %{public}s', String(e));
        return undefined;
      }
    }
    // Subsequent UIAbility instance main windows live on their own WindowStage.
    const secStage = this.uiAbilityStages.get(wid);
    if (secStage) {
      try {
        return secStage.getMainWindowSync();
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', 'Failed to get subsequent main window %{public}d: %{public}s', wid, String(e));
        return undefined;
      }
    }
    const entry = this.windows.get(wid);
    return entry?.window;
  }

  getAllWindowIds(): number[] {
    const ids = Array.from(this.windows.keys());
    // Include main window (id=0) if windowStage is set
    if (this.uiAbilityStages.has(0) && !ids.includes(0)) {
      ids.unshift(0);
    }
    // Include subsequent UIAbility main windows
    for (const sid of this.uiAbilityStages.keys()) {
      if (!ids.includes(sid)) {
        ids.push(sid);
      }
    }
    return ids;
  }

  // setDecorations: controls visibility of window decorations (title bar).
  // Main UIAbility window: win.setWindowDecorVisible(decorations) — PC/2in1 window decoration API (since API 20).
  //   Reference implementation: demo3signature/entry/src/main/ets/pages/Index.ets toggleWindowDecor.
  //   The old implementation used hideSystemBar/showSystemBar (status bar, since deleted),
  //   which was wrong — status bar != title bar.
  //   May be unsupported on phones (throws 801); the catch fallback does not affect other logic.
  // Float sub-window: LocalStorage setOrCreate('decorations') — FloatPage @LocalStorageProp reactively re-renders.
  setDecorations(windowId: number, decorations: boolean): void {
    hilog.info(DOMAIN, 'WindowManager', 'setDecorations %{public}d decorations=%{public}s ENTER', windowId, String(decorations));
    // Float sub-window: write LocalStorage to drive FloatPage title bar show/hide
    const entry = this.windows.get(windowId);
    if (entry && entry.storage) {
      entry.storage.setOrCreate('decorations', decorations);
      hilog.info(DOMAIN, 'WindowManager', `Decorations set to %{public}s for Float window %{public}d (LocalStorage)`, String(decorations), windowId);
    }
    // UIAbility main window: call setWindowDecorVisible directly to control the system title bar
    if (this.isUIAbilityMainWindow(windowId)) {
      const win = this.getWindow(windowId);
      if (!win) {
        hilog.warn(DOMAIN, 'WindowManager', 'setDecorations: main window %{public}d not found', windowId);
        return;
      }
      try {
        win.setWindowDecorVisible(decorations);
        hilog.info(DOMAIN, 'WindowManager', 'setDecorations %{public}d setWindowDecorVisible(%{public}s) OK', windowId, String(decorations));
      } catch (err) {
        // 801: device not supported (phones); 1300002: abnormal window state. Does not affect other logic.
        hilog.warn(DOMAIN, 'WindowManager', 'setDecorations %{public}d setWindowDecorVisible failed: %{public}s', windowId, JSON.stringify(err));
      }
    }
  }

  setWindowBackgroundColor(windowId: number, color: number): void {
    const colorStr = '#' + color.toString(16).padStart(8, '0');
    hilog.info(DOMAIN, 'WindowManager', `setWindowBackgroundColor: windowId=%{public}d, color=%{public}s`, windowId, colorStr);
    // UIAbility main windows (first id=0 or subsequent id>0): set on the stage's main window
    if (this.isUIAbilityMainWindow(windowId)) {
      try {
        const mainWindow = this.getWindow(windowId);
        if (!mainWindow) {
          hilog.warn(DOMAIN, 'WindowManager', `setWindowBackgroundColor: main window %{public}d not found`, windowId);
          return;
        }
        mainWindow.setWindowBackgroundColor(colorStr);
        // NOTE: setWindowContainerColor is NOT called here — it controls the window
        // container layer (incl. title bar area) and is only set at creation time
        // (applyTransparentBackground). Calling it at runtime with the same color
        // for active+inactive overwrites the title bar. setWindowBackgroundColor
        // only affects the window background, not the container.
      } catch (e) {
        hilog.error(DOMAIN, 'WindowManager', `Failed to set main window background: %{public}s`, String(e));
      }
    } else {
      const entry = this.windows.get(windowId);
      if (entry?.window) {
        try {
          entry.window.setWindowBackgroundColor(colorStr);
        } catch (err) {
          hilog.error(DOMAIN, 'WindowManager', `Sub-window %{public}d background failed: %{public}s`, windowId, String(err));
        }
      }
    }
  }

  // Window vibrancy: apply blur to the WebView container.
  // Blur API selection (WebviewPlugin's BuildWebview):
  // - transparent=true (main window): `backgroundBlurStyle` — samples content behind the window
  // - transparent=false (opaque, Float sub-windows): `backdropBlur` — blurs in-surface pixels
  // The radius is persisted (WindowAttachmentRegistry) and consumed when the webview node
  // is built; a live webview is refreshed through the registered callback.
  applyWindowBlur(windowId: number, radius: number): void {
    // windowId arrives from Rust NAPI as i64 → BigInt (1n). Normalize to number
    // so it matches the ArkTS number keys used by the per-window Maps.
    const id = Number(windowId);
    hilog.info(DOMAIN, 'WindowManager',
      'applyWindowBlur: ENTER rawWindowId=%{public}s id=%{public}d radius=%{public}f blurCbSize=%{public}d',
      String(windowId), id, radius, this.attachments.blurRefreshCallbackCount);
    this.attachments.setBlurRadius(id, radius);
    this.attachments.fireBlurRefresh(id, radius);
  }

  /** Register a runtime blur refresh callback for a window (WebviewPlugin path). Called
   *  by WebviewSurface when a webview is created so later set-blur commands reach it. */
  registerBlurRefreshCallback(windowId: number, cb: (radius: number) => void): void {
    this.attachments.registerBlurRefreshCallback(windowId, cb);
  }

  unregisterBlurRefreshCallback(windowId: number): void {
    this.attachments.unregisterBlurRefreshCallback(windowId);
  }

  /**
   * Phase 3 (design.md D2/D4/D6): per-window leading+trailing throttle for rect/size
   * events. Implementation lives in RectThrottle (extracted, issue #87 major-5);
   * this facade keeps the WindowManager call sites (NativeAbility, BridgeHost,
   * createSubWindow) unchanged.
   */
  throttledRectDispatch(
    windowId: number,
    payload: object,
    dispatchFn: (w: object) => void,
    kind: string,
  ): void {
    this.rectThrottle.dispatch(windowId, payload, dispatchFn, kind);
  }

  /** Phase 2 (design.md D3 注入小节): register the single rect-change fan-out callback.
   *  Called by NativeAbility.onWindowStageCreate; createSubWindow's per-window
   *  windowRectChange handler wraps { windowId, reason, rect } and invokes it, which
   *  forwards to every lifecycle.windowStageEventCallback.onWindowRectChange. */
  registerRectChangeCallback(cb: (options: WindowRectEventWrap) => void): void {
    this.rectChangeCallback = cb;
  }

  unregisterRectChangeCallback(): void {
    this.rectChangeCallback = undefined;
  }

  /** Get the current blur radius for a window (set by applyWindowBlur). Used by WebviewPlugin
   *  BuildWebview to apply the blur at webview creation time. Returns 0 if no blur was set. */
  getPendingBlur(windowId: number): number {
    return this.attachments.getBlurRadius(windowId);
  }

  // ─── Per-window attachment facades (implementation in WindowAttachmentRegistry) ───

  // Register the per-window *attached* raw WebviewController. Called from
  // WebviewPlugin.handleControllerAttached (onControllerAttached callback) — by then
  // the controller is attached to a live Web component and runJavaScript is usable.
  // Only sub-windows (windowId > 0) are registered: the main window (id=0) keeps the
  // one-shot primaryWebviewControllerCallback path unchanged (captured first-attach main
  // controller into executor.controller), so this map never diverges from main behavior.
  registerWebviewController(windowId: number, controller: web_webview.WebviewController): void {
    this.attachments.registerWebviewController(windowId, controller);
  }

  // Lookup for menu.getTargetController. Returns undefined for main window (id=0) and
  // any not-yet-attached sub-window — caller falls back to executor.controller.
  getWebviewController(windowId: number): web_webview.WebviewController | undefined {
    return this.attachments.getWebviewController(windowId);
  }

  // Register UIContext (main window calls in aboutToAppear, sub-window calls after loadContent)
  registerUIContext(windowId: number, ctx: UIContext): void {
    this.attachments.registerUIContext(windowId, ctx);
  }

  // Get UIContext for the specified window
  getUIContext(windowId: number): UIContext | undefined {
    return this.attachments.getUIContext(windowId);
  }

  // Register component root for a sub-window (called by DefaultXComponent sub-window mode)
  registerComponentRoot(windowId: number, root: FrameNode): void {
    this.attachments.registerComponentRoot(windowId, root);
  }

  // Static facade over WindowAttachmentRegistry.onComponentRootRegistered (used by
  // WebviewPlugin to replay deferred webview creates — timing race: webview bridge
  // create arrives ~3ms after TSFN dispatch, but FloatPage.aboutToAppear which
  // registers the componentRoot takes ~69ms). Static so it works exactly as before.
  static onComponentRootRegistered(windowId: number, callback: () => void): void {
    WindowAttachmentRegistry.onComponentRootRegistered(windowId, callback);
  }

  // Get component root for a sub-window (called by WebviewSurface.create)
  getComponentRoot(windowId: number): FrameNode | undefined {
    return this.attachments.getComponentRoot(windowId);
  }

  // Clean up controller and UIContext only (used by DefaultXComponent aboutToDisappear)
  // Does not remove from windows Map (managed by FloatPage's destroyWindow path)
  removeControllerAndUIContext(windowId: number): void {
    this.attachments.removeControllerAndUIContext(windowId);
    hilog.info(DOMAIN, 'WindowManager', 'Controller and UIContext removed for windowId: %{public}d', windowId);
  }

  // Apply per-webview clipboard / zoom-hotkey intercept flags for a window.
  // Called from WebviewPlugin.create (sub-window path) using payload.clipboard /
  // payload.zoomHotkeys. Undefined leaves the default (true = ArkWeb native).
  // Clearing happens in removeWindow; do not clear per-webview (siblings share a window).
  // Cross-platform note: on OHOS `clipboard=false` blocks keyboard Ctrl+C/X/V (onKeyPreIme
  // swallows them), whereas on Windows (webview2) the `clipboard` property only gates JS
  // execCommand clipboard access, not keyboard. Sub-windows needing Ctrl+C must call
  // .enable_clipboard_access(). This matches the spec intent (see audit APPROVED WITH NOTES).
  // See ohos-webview-flag-clipboard / ohos-webview-flag-zoom-hotkeys specs.
  setWebviewFlags(windowId: number, clipboard?: boolean, zoomHotkeys?: boolean): void {
    if (clipboard !== undefined) {
      setClipboardEnabled(windowId, clipboard);
    }
    if (zoomHotkeys !== undefined) {
      setZoomHotkeysEnabled(windowId, zoomHotkeys);
    }
  }

  // Remove window: clean up all per-window state to prevent memory leaks.
  // The shared cleanup list lives in clearWindowState (also used by
  // unregisterUIAbilityStage); this method additionally detaches the
  // window-registry-specific pieces (rect listener, entry, accelerator flags).
  removeWindow(windowId: number): void {
    hilog.info(DOMAIN, 'WindowManager', `Removing window %{public}d from all maps`, windowId);
    // Phase 2 (design.md D3): detach this window's windowRectChange listener before
    // dropping the Window reference so the native side stops delivering rect changes
    // for a window that no longer exists (prevents post-destroy callbacks / leaks).
    const entry = this.windows.get(windowId);
    if (entry?.rectChangeHandler) {
      try {
        entry.window.off("windowRectChange", entry.rectChangeHandler);
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', `off windowRectChange failed for %{public}d: %{public}s`, windowId, String(e));
      }
    }
    // Clear user interaction tracking if this window was the last interacted one
    if (this.lastUserInteractedWindowId === windowId) {
      this.lastUserInteractedWindowId = -1;
      hilog.info(DOMAIN, 'WindowManager', 'Cleared lastUserInteractedWindowId (removed window)');
    }
    this.windows.delete(windowId);
    // Shared per-window state (kinds/attachments/op-queues/pre-maximize/throttle).
    this.clearWindowState(windowId);
    // Clear per-window accelerator flags (clipboard / zoom-hotkey intercepts).
    // These are keyed by windowId and set in WebviewPlugin.create; without
    // clearing here they leak past window destruction. removeWindow is the
    // window-lifetime sink — not removeWebview (per-webview), which would
    // prematurely clear flags still in use by sibling webviews in the same window.
    clearClipboardEnabled(windowId);
    clearZoomHotkeysEnabled(windowId);
  }
}
