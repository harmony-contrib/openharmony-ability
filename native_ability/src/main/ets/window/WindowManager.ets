import { window, UIContext } from "@kit.ArkUI";
import { FrameNode } from "@ohos.arkui.node";
import { common } from "@kit.AbilityKit";
import pointer from "@ohos.multimodalInput.pointer";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { BusinessError, deviceInfo } from "@kit.BasicServicesKit";
import display from "@ohos.display";
import * as SubWindowPage from "../components/SubWindowPage";
import { getMenuBarPort } from "../components/MenuBarSlot";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from "../helper/constants";
import {
  clearClipboardEnabled,
  clearZoomHotkeysEnabled,
  isClipboardEnabled,
  isZoomHotkeysEnabled,
  setClipboardEnabled,
  setZoomHotkeysEnabled,
} from "../helper/window_flags";
import { unregisterKeySynthesisController, unregisterWebFocus } from "../helper/key_synthesis";
import web_webview from "@ohos.web.webview";
import {
  RectThrottle,
  WindowRectEventWrap,
  WindowRectSnapshot,
  WindowSizeEventWrap,
} from "./RectThrottle";
import { WindowAttachmentRegistry } from "./WindowAttachmentRegistry";

// Event payload types moved to RectThrottle (issue #87 major-5); re-exported here so
// existing importers (`import {...} from "../window/WindowManager"`) keep working.
export { WindowRectEventWrap, WindowRectSnapshot, WindowSizeEventWrap } from "./RectThrottle";

// Typed focus / avoid-area payloads (HIS #93): the per-window event handlers wrap
// the system callback data with the owning windowId before fanning out to the
// NativeAbility-registered single-slot callbacks.
export interface WindowFocusEventWrap {
  windowId: number;
  focused: boolean;
}

export interface WindowAvoidAreaEventWrap {
  windowId: number;
  type: number;
  area: object;
}

interface WindowEntry {
  window: window.Window;
  storage?: LocalStorage;
  focusOnShow?: boolean;
  // Phase 2 (design.md D3): per-window windowRectChange handler reference, stored so
  // destroyWindow/removeWindow can call win.off("windowRectChange", handler) to avoid
  // leaking the listener past window destruction.
  rectChangeHandler?: (options: window.RectChangeOptions) => void;
  // Per-window handler references for the HIS #93 focus / avoid-area fan-in —
  // stored so removeWindow can win.off(...) them alongside rectChangeHandler.
  avoidAreaChangeHandler?: (options: window.AvoidAreaOptions) => void;
  focusChangeHandler?: (eventType: window.WindowEventType) => void;
  // Phase 3 (design.md D4): set to true just before destroyWindow()/closeWindow sub-window
  // path calls win.destroyWindow(). throttledRectDispatch checks this to discard
  // in-flight events for a window being torn down (no consumers left).
  destroying: boolean;
}

// Encapsulates all parameters for sub-window creation, replacing a 10-arg signature.
export interface SubWindowOptions {
  name: string;
  nativeModuleName?: string;
  windowId: number;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  displayId?: number;
  decorations?: boolean;
  independent?: boolean;
  show?: boolean;
  focus?: boolean;
  modal?: boolean;
  transparent?: boolean;
  backgroundColor?: number;
}

export const INDEPENDENT_WINDOW_ID_PARAMETER = "openharmony.ability.windowId";

interface DeferredAbilityWindow {
  options: SubWindowOptions;
  start: () => void;
  cancel: () => void;
}

interface PendingAbilityWindow {
  options: SubWindowOptions;
  resolve: () => void;
  reject: (error: Error) => void;
  claimed: boolean;
  canceled: boolean;
}

export interface WindowOperationOptions {
  window?: window.Window;
  beforeRun?: () => void;
}

export interface WindowRestoreOptions extends WindowOperationOptions {
  onlyIfMinimized?: boolean;
  focus?: boolean;
}

interface FullscreenRestoreState {
  rect: window.Rect;
  maximized: boolean;
}

export interface WindowPosition {
  x: number;
  y: number;
}

// Enum of window kinds. All UIAbility windows are equal, no primary/subordinate distinction.
export enum WindowKind {
  UIAbility, // All UIAbility main windows (id=0 or id>0, equivalent)
  SubWindow, // Sub-window created by windowStage.createSubWindow
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
  private creatingWindows: Map<number, Promise<number>> = new Map();
  private independentWindowAbility?: string;
  private pendingAbilityWindows: Map<number, PendingAbilityWindow> = new Map();
  private deferredAbilityWindows: Map<number, DeferredAbilityWindow> = new Map();
  private closeInterceptors: Set<(windowId: number) => boolean> = new Set();
  private closeListeners: Map<number, () => Promise<boolean>> = new Map();

  pendingWindowModuleName(windowId: number): string | undefined {
    return this.pendingAbilityWindows.get(windowId)?.options.nativeModuleName;
  }

  registerCloseRequestInterceptor(handler: (windowId: number) => boolean): () => void {
    this.closeInterceptors.add(handler);
    return (): void => {
      this.closeInterceptors.delete(handler);
    };
  }

  requestWindowClose(windowId: number): boolean {
    for (const handler of this.closeInterceptors.values()) {
      if (handler(windowId)) {
        return true;
      }
    }
    return false;
  }

  private registerCloseListener(win: window.Window, windowId: number): void {
    if (deviceInfo.sdkApiVersion < 15 || this.closeListeners.has(windowId)) {
      return;
    }
    const listener = async (): Promise<boolean> => this.requestWindowClose(windowId);
    try {
      win.on("windowWillClose", listener);
      this.closeListeners.set(windowId, listener);
    } catch (error) {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "Could not intercept window close: %{public}s",
        String(error),
      );
    }
  }

  private removeCloseListener(windowId: number): void {
    const listener = this.closeListeners.get(windowId);
    if (listener) {
      try {
        this.getWindow(windowId)?.off("windowWillClose", listener);
      } catch (error) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          "Could not detach window close: %{public}s",
          String(error),
        );
      }
      this.closeListeners.delete(windowId);
    }
  }
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

  // windowKinds tracks each window's kind (UIAbility or SubWindow) by windowId.
  // Used by isUIAbilityMainWindow() — windowId=0 is NOT special, all UIAbility
  // windows (id=0 or id>0) are equal and system-managed.
  private windowKinds: Map<number, WindowKind> = new Map();

  // windowOpQueues: Per-window operation serialization queue. Window operations (maximize, recover,
  // fullscreen, minimize) are async Promises that must not overlap — e.g., calling
  // maximize while a fullscreen-exit recover() is still pending causes race conditions.
  // Each window gets its own Promise chain; new ops are appended via .then().
  private windowOpQueues: WeakMap<window.Window, Promise<void>> = new WeakMap();

  // preMaximizeRects: floating rect captured right before maximize(). WMS recover()
  // re-computes the floating position via GetFullScreenToFloatingRect (pointer-anchored —
  // designed for drag-off-titlebar unmaximize), so a programmatic recover() lands the
  // window near the cursor (top-right when triggered from the ❐ title-bar button) instead
  // of the pre-maximize position. recoverWindow() moveTo()s back to the saved rect.
  // has()-guarded on save: a second maximize while already maximized keeps the FIRST
  // floating rect (the current rect would be the maximized one). Cleared on use and in
  // removeWindow.
  private preMaximizeRects: WeakMap<window.Window, window.Rect> = new WeakMap();
  private fullscreenRestoreStates: WeakMap<window.Window, FullscreenRestoreState> = new WeakMap();

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
  private focusChangeCallback?: (options: WindowFocusEventWrap) => void;
  private avoidAreaChangeCallback?: (options: WindowAvoidAreaEventWrap) => void;

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
      hilog.info(DOMAIN, "WindowManager", "WindowManager initialized");
      WindowManager.instance = new WindowManager(context);
    }
  }

  static getInstance(): WindowManager {
    if (!WindowManager.instance) {
      hilog.error(DOMAIN, "WindowManager", "WindowManager not initialized");
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
  // Stores stage in uiAbilityStages, sets windowKinds, notifies the Rust handshake registry (D7),
  // and registers focus tracking (HIS: opt-out via trackWindow=false — used by
  // his independent-window family, whose ability windows track focus themselves).
  // D4b: whether a UIAbility instance has already registered its stage for
  // windowId. STATIC and throw-free by design: the NativeAbility onCreate
  // plain-relaunch guard runs BEFORE ProcessInitializer calls WindowManager.init
  // (ProcessInitializer.ets) — getInstance() would throw "not initialized" and
  // abort onCreate, freezing the app on the start window. Returning false while
  // uninitialized is also semantically right: no instance means no registered
  // stage, so a first cold launch takes the normal path.
  static isStageRegistered(windowId: number): boolean {
    return (
      WindowManager.instance !== null &&
      WindowManager.instance.uiAbilityStages.has(Number(windowId))
    );
  }

  registerUIAbilityStage(
    windowId: number,
    windowStage: window.WindowStage,
    context: common.UIAbilityContext,
    transparent: boolean = false,
    trackWindow: boolean = true,
  ): void {
    const wid = Number(windowId);
    this.uiAbilityStages.set(wid, windowStage);
    this.uiAbilityContexts.set(wid, context);
    this.windowKinds.set(wid, WindowKind.UIAbility);
    this.transparentFlags.set(wid, transparent);
    hilog.info(
      DOMAIN,
      "WindowManager",
      "UIAbility stage registered: id=%{public}d transparent=%{public}s",
      wid,
      String(transparent),
    );

    // Report the stage registration to the Rust handshake registry (design.md
    // D7, openspec multi-uiability-windows). The spawn side (tao Window::new →
    // start-ui-ability) registered this id as pending with an event-loop waker;
    // this NAPI call flips the registry entry and wakes the loop so queued
    // webview ops for this window dispatch on the next pass. The old-framework
    // caller (ArkHelper.ets) was dropped in the bridge-facade migration, which
    // left register_ui_ability_stage a dead export — this is its replacement
    // call site. The native module is process-level (single Rust registry
    // shared by all UIAbility instances, NG4), so the AppStorage-stored module
    // is the right handle regardless of which instance registers.
    // (HIS's main dropped this block — his deferredAbilityWindows/
    // pendingAbilityWindows mechanism covers his independent-window family,
    // but not this Rust-side pending-waker chain, so it stays.)
    const nativeModule: ESObject = AppStorage.get<ESObject>(NATIVE_MODULE_STORAGE_KEY);
    if (nativeModule && typeof nativeModule.registerUiAbilityStage === "function") {
      try {
        nativeModule.registerUiAbilityStage(wid);
      } catch (e) {
        // Not a C5 (NAPI re-entrant) context: this method runs from
        // onWindowStageCreate — an OS lifecycle callback whose NAPI call is
        // ArkTS-initiated, not a Rust-into-ArkTS re-entry — so hilog.error
        // is safe here and keeps the domain tag for hilog-side filtering
        // (unlike setPointerStyle below, which IS called back from Rust and
        // needs the console fallback).
        hilog.error(
          DOMAIN,
          "WindowManager",
          "registerUiAbilityStage NAPI call failed for id=%{public}d (Rust handshake registry not notified): %{public}s",
          wid,
          String(e),
        );
      }
    } else {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "nativeModule.registerUiAbilityStage unavailable; Rust handshake registry not notified for id=%{public}d",
        wid,
      );
    }

    // Register focus tracking for this window
    try {
      const mainWindow = windowStage.getMainWindowSync();
      if (trackWindow) {
        this.registerFocusTracking(mainWindow, wid);
        this.registerCloseListener(mainWindow, wid);
      }
    } catch (e) {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "Failed to register focus tracking for id=%{public}d: %{public}s",
        wid,
        String(e),
      );
    }

    // Transparency is applied in createWebview (when data.transparent=true),
    // not here — onWindowStageCreate is too early (setWindowBackgroundColor
    // fails with "window state is abnormal"). createWebview runs after the
    // window is fully ready, so setWindowContainerColor succeeds there.
  }

  unregisterUIAbilityStage(windowId: number): void {
    const wid = Number(windowId);
    if (wid === 0) {
      for (const deferredId of Array.from(this.deferredAbilityWindows.keys())) {
        this.cancelDeferredWindowCreation(deferredId);
      }
    }
    this.removeCloseListener(wid);
    this.clearWindowState(wid);
    this.uiAbilityStages.delete(wid);
    const pending = this.pendingAbilityWindows.get(wid);
    if (pending && !pending.canceled) {
      // A native setter or content load can outlive its destroyed WindowStage.
      pending.canceled = true;
      pending.reject(new Error(`Ability window ${wid} creation was canceled`));
    }
    hilog.info(DOMAIN, "WindowManager", "UIAbility stage unregistered: id=%{public}d", wid);
  }

  // Single source of truth for per-window state cleanup (issue #87 major-5): both
  // unregisterUIAbilityStage and removeWindow delegate here, so the two paths can
  // never drift apart again (they had diverged: one cleared transparentFlags/
  // windowKinds, the other preMaximizeRects; a later accelerator-flags duplicate
  // in removeWindow was folded back into this sink — review finding F4).
  private clearWindowState(wid: number): void {
    const win = this.getWindow(wid);
    if (win) {
      this.windowOpQueues.delete(win);
      this.preMaximizeRects.delete(win);
      this.fullscreenRestoreStates.delete(win);
      clearClipboardEnabled(wid, win);
      clearZoomHotkeysEnabled(wid, win);
    }
    this.uiAbilityContexts.delete(wid);
    this.windowKinds.delete(wid);
    this.transparentFlags.delete(wid);
    this.attachments.clearWindow(wid);
    this.rectThrottle.clearWindow(wid);
    // Phase 6 (design.md D13): a spawned UIAbility window closes via terminateSelf,
    // which bypasses removeWindow — the focus/interaction trackers and the
    // key-synthesis controller had no removal point on the UIAbility teardown path
    // and leaked one entry per closed instance across create/destroy rounds (E4
    // ten-round check). The attachment-backed maps (blur radii, refresh callbacks,
    // deferred componentRoot callbacks) are cleared by attachments.clearWindow above.
    // (Per-window accelerator flags are cleared in the `win` block above — kept on
    // HIS's (windowId, win) form; both forms hit the same window_flags registry.)
    if (this.lastFocusedWindowId === wid) {
      // Clear BOTH the id and the Window reference — keeping the object would
      // pin the destroyed ability's window and block GC (audit note on A9).
      this.lastFocusedWindowId = -1;
      this.lastFocusedWindow = null;
    }
    if (this.lastUserInteractedWindowId === wid) {
      this.lastUserInteractedWindowId = -1;
    }
    // Key-synthesis controllers are registered for ALL windows (incl. main) but
    // this map has no other removal point. Skip wid 0: the primary's controller
    // outlives its stage teardown (continuation-restore reuses it).
    if (wid !== 0) {
      unregisterKeySynthesisController(wid);
      unregisterWebFocus(wid);
    }
  }

  // Whether the given window is a UIAbility main window.
  // Such windows are system-managed: resize()/moveWindowTo() dispatches DO run --
  // the effect is governed by the system WM (e.g. freeform clamping); error
  // 1300002 only surfaces transiently when the window state is abnormal, it is
  // not the expected outcome of these calls (see tao facade docs,
  // committer Eulogizethesun/tauri#170). Decorations are system-provided, and
  // setDecorationFlags throws for UIAbility main windows (#238); sub-windows
  // honor per-button flags.
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

  /** API 20 requires an opaque inactive color; composite against the window's theme. */
  inactiveContainerColor(win: window.Window, color: number): string {
    const alpha = (color >>> 24) / 255;
    let background = 0xff000000;
    if (alpha < 1) {
      try {
        background =
          win
            .getUIContext()
            .getHostContext()
            ?.resourceManager.getColorSync($r("sys.color.comp_background_primary").id) ??
          background;
      } catch (error) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          "Inactive window theme lookup failed: %{public}s",
          String(error),
        );
      }
    }
    const red = Math.round(
      ((color >>> 16) & 255) * alpha + ((background >>> 16) & 255) * (1 - alpha),
    );
    const green = Math.round(
      ((color >>> 8) & 255) * alpha + ((background >>> 8) & 255) * (1 - alpha),
    );
    const blue = Math.round((color & 255) * alpha + (background & 255) * (1 - alpha));
    return (
      "#" + ((0xff000000 | (red << 16) | (green << 8) | blue) >>> 0).toString(16).padStart(8, "0")
    );
  }

  /** Bound phone-local placement using the resized window's physical dimensions. */
  async resolveWindowPosition(
    win: window.Window,
    x: number,
    y: number,
    displayId?: number,
  ): Promise<WindowPosition> {
    // Explicit display moves use global coordinates. Do not clamp them against a
    // default display's local rectangle; desktop/freeform positions are also retained.
    if (deviceInfo.deviceType !== "phone" || displayId !== undefined) {
      return { x, y };
    }
    const area = await display.getDefaultDisplaySync().getAvailableArea();
    const rect = win.getWindowProperties().windowRect;
    return {
      x: Math.max(area.left, Math.min(x, area.left + Math.max(0, area.width - rect.width))),
      y: Math.max(area.top, Math.min(y, area.top + Math.max(0, area.height - rect.height))),
    };
  }

  // Serialize an async window operation per-window. Each window gets its own Promise
  // chain; new ops are appended via .then() so they wait for the previous op to settle.
  // Errors in one op do NOT block subsequent ops (the chain always continues via .catch).
  // This prevents race conditions like fullscreen-exit (recover) racing with a subsequent
  // maximize call.
  serializeOp(
    windowId: number,
    op: () => Promise<void>,
    win: window.Window | undefined = this.getWindow(windowId),
  ): Promise<void> {
    const wid = Number(windowId);
    if (!win) {
      return Promise.reject(new Error(`Window ${wid} is not ready for an operation`));
    }
    // Logical zero is local to a component host. Native Window objects retain
    // independent queues and snapshots even when callers use the same alias.
    const prev = this.windowOpQueues.get(win) ?? Promise.resolve();
    hilog.debug(
      DOMAIN,
      "WindowManager",
      "serializeOp: window %{public}d queued (had prior=%{public}s)",
      wid,
      String(this.windowOpQueues.has(win)),
    );
    // Return the actual result to awaitable callers. Only the queue tail recovers
    // failures, so a rejected operation does not block later operations.
    // (This subsumes ours' #219 serializeOpTracked variant: the returned promise
    // rejects with the original failure while the stored queue tail is the
    // failure-neutralized continuation — tracked semantics by default.)
    const result = prev.then(op);
    const next = result.catch((err: ESObject) => {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "serializeOp: window %{public}d op failed: %{public}s",
        wid,
        String(err?.message ?? err),
      );
    });
    this.windowOpQueues.set(win, next);
    return result;
  }

  // Apply transparent background + container color to a UIAbility main window.
  // Called by DefaultXComponent.aboutToAppear (window fully ready there).
  // Active is transparent; inactive uses the opaque theme background required by API 20.
  async applyTransparentBackground(windowId: number): Promise<void> {
    const wid = Number(windowId);
    const isTrans = this.isTransparent(wid);
    hilog.debug(
      DOMAIN,
      "WindowManager",
      "applyTransparentBackground: windowId=%{public}d isTransparent=%{public}s",
      wid,
      String(isTrans),
    );
    if (!isTrans) {
      return;
    }
    const stage = this.uiAbilityStages.get(wid);
    if (!stage) {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "applyTransparentBackground: no stage for id=%{public}d",
        wid,
      );
      return;
    }
    try {
      const mainWindow = await stage.getMainWindow();
      mainWindow.setWindowBackgroundColor("#00000000");
      hilog.info(
        DOMAIN,
        "WindowManager",
        "applyTransparentBackground: windowId=%{public}d setWindowBackgroundColor transparent OK",
        wid,
      );
      if (deviceInfo.sdkApiVersion >= 20) {
        try {
          mainWindow.setWindowContainerColor(
            "#00000000",
            this.inactiveContainerColor(mainWindow, 0),
          );
          hilog.info(
            DOMAIN,
            "WindowManager",
            "applyTransparentBackground: windowId=%{public}d setWindowContainerColor OK (active=transparent inactive=theme)",
            wid,
          );
        } catch (containerErr) {
          const error = containerErr as BusinessError;
          hilog.warn(
            DOMAIN,
            "WindowManager",
            "applyTransparentBackground: windowId=%{public}d setWindowContainerColor failed: code=%{public}d",
            wid,
            error.code,
          );
        }
      }
    } catch (e) {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "applyTransparentBackground: windowId=%{public}d failed: %{public}s",
        wid,
        String(e),
      );
    }
  }

  // Register WINDOW_ACTIVE listener for focus tracking
  // Also listens for RESUMED/WINDOW_ACTIVE to consume pending actions
  private registerFocusTracking(win: window.Window, windowId: number): void {
    const handler = (eventType: window.WindowEventType): void => {
      // Track last focused window
      if (eventType === window.WindowEventType.WINDOW_ACTIVE) {
        this.lastFocusedWindow = win;
        this.lastFocusedWindowId = windowId;
        hilog.info(DOMAIN, "WindowManager", "Last focused window updated: id=%{public}d", windowId);
        this.focusChangeCallback?.({ windowId, focused: true });
      } else if (eventType === window.WindowEventType.WINDOW_INACTIVE) {
        this.focusChangeCallback?.({ windowId, focused: false });
      }
      if (
        eventType === window.WindowEventType.WINDOW_INACTIVE ||
        eventType === window.WindowEventType.WINDOW_HIDDEN
      ) {
        getMenuBarPort(win)?.onWindowFocusLost?.(windowId);
      }

      // Consume pending action when system foreground transition completes
      // WINDOW_ACTIVE: window gained focus (marks end of foreground transition)
      // WINDOW_SHOWN: window is visible (alternative trigger)
      if (
        eventType === window.WindowEventType.WINDOW_ACTIVE ||
        eventType === window.WindowEventType.WINDOW_SHOWN
      ) {
        if (this.hasPendingAction()) {
          hilog.info(
            DOMAIN,
            "WindowManager",
            "System foreground transition complete (event: %{public}s), executing pending action",
            eventType === window.WindowEventType.WINDOW_ACTIVE ? "WINDOW_ACTIVE" : "WINDOW_SHOWN",
          );
          this.consumePendingAction();
        }
      }
    };
    win.on("windowEvent", handler);
    const entry = this.windows.get(windowId);
    if (entry) {
      entry.focusChangeHandler = handler;
    }
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
  // Called from page root Stack.onTouch() (MainPage/SubWindowPage, D8) when the user physically touches a window.
  // ArkUI onTouch bubbles from child to parent, covering MenuBarComponent + webview + drag bars.
  // Used by tray menu to determine which window to operate on.
  setUserInteractedWindow(windowId: number): void {
    this.lastUserInteractedWindowId = windowId;
    hilog.info(DOMAIN, "WindowManager", "User interacted with window: id=%{public}d", windowId);
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
      const finish = () => {
        try {
          win.off("windowEvent", onWindowEvent);
        } catch (_) {}
      };
      const doMinimize = () => {
        if (consumed) return;
        consumed = true;
        finish();
        hilog.info(DOMAIN, "WindowManager", "minimizeWithRestoreGuard: minimizing (settled)");
        win
          .minimize()
          .then(() => resolve())
          .catch((err: ESObject) => {
            hilog.warn(
              DOMAIN,
              "WindowManager",
              "minimizeWithRestoreGuard minimize failed: %{public}s",
              JSON.stringify(err),
            );
            resolve();
          });
      };
      const onWindowEvent = (eventType: window.WindowEventType) => {
        if (!consumed && eventType === window.WindowEventType.WINDOW_ACTIVE) {
          hilog.info(DOMAIN, "WindowManager", "minimizeWithRestoreGuard: WINDOW_ACTIVE fired");
          doMinimize();
        }
      };
      try {
        win.on("windowEvent", onWindowEvent);
      } catch (_) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          "minimizeWithRestoreGuard: windowEvent unsupported, direct minimize",
        );
        win
          .minimize()
          .then(() => resolve())
          .catch(() => resolve());
        return;
      }
      hilog.info(
        DOMAIN,
        "WindowManager",
        "minimizeWithRestoreGuard: waiting for WINDOW_ACTIVE (50ms fallback)",
      );
      setTimeout(doMinimize, 50);
    });
  }

  minimizeWindow(windowId: number): void {
    // 拦截:FLAG_MINIMIZABLE 为 0 时,不允许最小化(问题四:语义错位修复)
    if (!this.getDecorationFlag(windowId, "minimizable")) {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "minimizeWindow blocked: minimizable flag not set (window %{public}d)",
        windowId,
      );
      return;
    }
    this.withWindow(windowId, "minimizeWindow", (win: window.Window) => {
      // Serialize: minimize can race with maximize/recover/fullscreen. The guard's
      // Promise keeps the serialization slot held until the deferred minimize
      // settles, preserving op ordering.
      this.serializeOp(windowId, () =>
        this.minimizeWithRestoreGuard(win).then(() => {
          // Only reset tracking if the minimized window was the last interacted one
          if (this.lastUserInteractedWindowId === windowId) {
            this.resetUserInteractionTracking();
          }
        }),
      );
    });
  }

  focusWindow(windowId: number): void {
    this.withWindow(windowId, "focusWindow", (win: window.Window) => {
      this.fireAndForget(win.raiseToAppTop(), "focusWindow", windowId, () => {
        hilog.debug(
          DOMAIN,
          "WindowManager",
          "focusWindow: window %{public}d raised to top",
          windowId,
        );
      });
    });
  }

  setWindowFocusable(windowId: number, focusable: boolean): void {
    this.withWindow(windowId, "setWindowFocusable", (win: window.Window) => {
      this.fireAndForget(win.setWindowFocusable(focusable), "setWindowFocusable", windowId, () => {
        hilog.debug(
          DOMAIN,
          "WindowManager",
          "setWindowFocusable: window %{public}d focusable=%{public}s",
          windowId,
          String(focusable),
        );
      });
    });
  }

  setWindowTouchable(windowId: number, touchable: boolean): void {
    // setWindowTouchable returns a Promise; 401/1300002/1300003 reject asynchronously;
    // the unified fireAndForget catch prevents the unhandled-reject crash (Rust does
    // not perceive the failure — TSFN fire-and-forget, see set_window_touchable docs).
    this.withWindow(windowId, "setWindowTouchable", (win: window.Window) => {
      this.fireAndForget(win.setWindowTouchable(touchable), "setWindowTouchable", windowId, () => {
        hilog.debug(
          DOMAIN,
          "WindowManager",
          "setWindowTouchable: window %{public}d touchable=%{public}s",
          windowId,
          String(touchable),
        );
      });
    });
  }

  // ─── Window operations (ohos-window-ops) ───

  moveWindowTo(windowId: number, x: number, y: number): void {
    this.withWindow(windowId, "moveWindowTo", (win: window.Window) => {
      this.fireAndForget(win.moveWindowTo(x, y), "moveWindowTo", Number(windowId));
    });
  }

  resizeWindow(windowId: number, reqWidth: number, reqHeight: number): void {
    // Phone-form clamp (see createSubWindow for the full rationale): keep
    // resize targets inside the display so set_size can't push window
    // content off-screen on phones. Values at or below the display size
    // pass through untouched; PC/2in1 are not gated here at all.
    let width = reqWidth;
    let height = reqHeight;
    if (deviceInfo.deviceType === "phone") {
      try {
        const d = display.getDefaultDisplaySync();
        width = Math.min(width, Math.floor(d.width));
        height = Math.min(height, Math.floor(d.height));
      } catch (e) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          `Phone clamp skipped (display query failed): %{public}s`,
          String(e),
        );
      }
    }
    this.withWindow(windowId, "resizeWindow", (win: window.Window) => {
      this.fireAndForget(win.resize(width, height), "resizeWindow", Number(windowId));
    });
  }

  // --- pre-maximize rect snapshot helpers (shared with WindowPlugin's tao bridge path) ---
  // WMS recover() re-anchors the floating rect to the pointer (GetFullScreenToFloatingRect);
  // these snapshot/restore the pre-maximize position so any maximize→recover pair —
  // SubWindowPage title-bar buttons OR the tao set_maximized bridge (WindowPlugin.windowCommand,
  // which cannot delegate to maximizeWindow/recoverWindow without losing its await
  // completion semantics) — lands back where it started.
  snapshotPreMaximizeRect(_windowId: number, win: window.Window): void {
    // has-guard: if already maximized, keep the first snapshot — the live rect
    // would be the maximized fullscreen one.
    if (!this.preMaximizeRects.has(win)) {
      this.preMaximizeRects.set(win, win.getWindowProperties().windowRect);
    }
  }

  async restorePreMaximizeRect(windowId: number, win: window.Window): Promise<void> {
    const wid = Number(windowId);
    const saved = this.preMaximizeRects.get(win);
    if (!saved) {
      return;
    }
    this.preMaximizeRects.delete(win);
    try {
      await win.moveTo(saved.left, saved.top);
    } catch (err) {
      // Position restore is best-effort: the caller's recover() already succeeded —
      // a moveTo failure must not surface as a recover failure.
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "restorePreMaximizeRect %{public}d moveTo failed: %{public}s",
        wid,
        JSON.stringify(err),
      );
    }
  }

  maximizeWindow(windowId: number): void {
    // 拦截:FLAG_MAXIMIZABLE 为 0 时,不允许最大化(问题四:语义错位修复)
    if (!this.getDecorationFlag(windowId, "maximizable")) {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "maximizeWindow blocked: maximizable flag not set (window %{public}d)",
        windowId,
      );
      return;
    }
    this.withWindow(windowId, "maximizeWindow", (win: window.Window) => {
      // Serialize: maximize can race with fullscreen-exit (recover) or minimize.
      this.serializeOp(windowId, () => {
        // Snapshot the floating rect BEFORE maximizing (see snapshotPreMaximizeRect).
        this.snapshotPreMaximizeRect(windowId, win);
        // Use FOLLOW_APP_IMMERSIVE_SETTING (not ENTER_IMMERSIVE) to preserve the existing
        // fullscreen layout mode. ENTER_IMMERSIVE explicitly enters fullscreen on maximize and
        // exits it on recover, causing a layout gap (white bar at bottom where navigation bar was).
        // FOLLOW_APP_IMMERSIVE_SETTING preserves setWindowLayoutFullScreen(true) set at init.
        return win.maximize(window.MaximizePresentation.FOLLOW_APP_IMMERSIVE_SETTING).then(() => {
          hilog.info(DOMAIN, "WindowManager", "maximizeWindow %{public}d OK", windowId);
        });
      });
    });
  }

  // #219: async + awaited by the set-topmost bridge arm -- a failed
  // setWindowTopmost (801 non-freeform / 1300002 abnormal state / permission
  // denial) now rejects into the ack chain instead of the fire-and-forget warn.
  // The API14 capability guard below stays a documented no-op (device
  // capability, not an op failure).
  async setWindowTopmost(windowId: number, topmost: boolean): Promise<void> {
    // win.setWindowTopmost() is API14+. Requires ohos.permission.WINDOW_TOPMOST
    // (system_grant, declared in module.json5). Main window only -- sub-windows
    // will error (non-fatal). Only effective in freeform window mode; returns 801
    // on devices without freeform support (phone/tablet).
    if (deviceInfo.sdkApiVersion < 14) {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "setWindowTopmost: API14+ required, current %{public}d; no-op",
        deviceInfo.sdkApiVersion,
      );
      return;
    }
    const win = this.getWindow(windowId);
    if (!win) {
      throw new Error(`setWindowTopmost: window ${windowId} not found`);
    }
    await win.setWindowTopmost(topmost);
    hilog.info(
      DOMAIN,
      "WindowManager",
      "setWindowTopmost %{public}d topmost=%{public}s OK",
      windowId,
      String(topmost),
    );
  }

  // #219: async + awaited by the set-title bridge arm -- a failed
  // setWindowTitle (or an unknown/destroyed window) rejects into the ack chain
  // instead of the fire-and-forget warn (committer #219 fake-ack fix).
  async setWindowTitle(windowId: number, title: string): Promise<void> {
    const win = this.getWindow(windowId);
    if (!win) {
      throw new Error(`setWindowTitle: window ${windowId} not found`);
    }
    // win.setWindowTitle(title) is Promise form (1 arg). Main window + sub-windows
    // both support title text (icon is NOT changeable at runtime). No extra permission
    // for main window. Only visible when window decorations are enabled (decorEnabled=true).
    // Also update LocalStorage 'title' so the sub-window host page's
    // @LocalStorageProp('title') (SubWindowPage) refreshes
    // the title bar text.
    const entry = this.windows.get(windowId);
    if (entry?.storage) {
      entry.storage.setOrCreate("title", title);
    }
    await win.setWindowTitle(title);
    hilog.info(
      DOMAIN,
      "WindowManager",
      'setWindowTitle %{public}d title="%{public}s" OK',
      windowId,
      title,
    );
  }

  setWindowLimits(windowId: number, minW: number, minH: number, maxW: number, maxH: number): void {
    // win.setWindowLimits() is API11+. Params are px (0 = no limit / system default).
    // WindowLimits fields: minWidth/minHeight/maxWidth/maxHeight (NOT minWindowWidth etc.)
    // ⚠️ Triggers OnSizeChange — caller must not invoke frequently on main window (appfreeze risk).
    //
    // Min slots 0→1 translation: the system treats minWidth/minHeight = 0 as "keep
    // the current limits", NOT as "lift them" (verified on HAD-W32 PC / API 23:
    // setWindowLimits({minWidth: 0, ...}) returns the previous min unchanged, so
    // tao's set_min_inner_size(None) — which dispatches 0 — could never lift a
    // previously-set minimum). 1px is clamped by the system to its product-level
    // absolute minimum (608×136 outer on the reference PC), which IS the semantic
    // "no app-level minimum" under the intersection-of-limits model. Max slots keep
    // 0 — the system maps maxWidth/maxHeight = 0 to its own default ceiling
    // (7296×7296 on the reference PC), so no translation is needed there.
    this.withWindow(windowId, "setWindowLimits", (win: window.Window) => {
      const limits: window.WindowLimits = {
        minWidth: Math.max(minW, 1),
        minHeight: Math.max(minH, 1),
        maxWidth: maxW,
        maxHeight: maxH,
      };
      this.fireAndForget(
        win.setWindowLimits(limits),
        "setWindowLimits",
        windowId,
        (actual: window.WindowLimits) => {
          hilog.info(
            DOMAIN,
            "WindowManager",
            "setWindowLimits %{public}d OK: min=%{public}dx%{public}d max=%{public}dx%{public}d",
            windowId,
            actual.minWidth,
            actual.minHeight,
            actual.maxWidth,
            actual.maxHeight,
          );
        },
      );
    });
  }

  // #219: async + tracked -- showWindowMethod's minimized-main-window branch
  // awaits this, so a failed restore rejects into the show command's ack chain
  // instead of a fake success ack. Serialization (restore can race with
  // maximize/recover/fullscreen) keeps serializeOp's chain semantics (chain
  // continues, caller sees the failure). HIS's options form adds the
  // onlyIfMinimized/focus/beforeRun hooks used by his independent-window family.
  restoreWindow(windowId: number, options: WindowRestoreOptions = {}): Promise<void> {
    const win = options.window ?? this.getWindow(windowId);
    return this.serializeOp(
      windowId,
      async (): Promise<void> => {
        options.beforeRun?.();
        if (!win) {
          throw new Error(`restoreWindow: window ${windowId} not found`);
        }
        // Inspect the state after earlier maximize/recover/minimize operations settle.
        if (options.onlyIfMinimized && win.getWindowStatus() !== window.WindowStatusType.MINIMIZE) {
          if (options.focus) {
            await win.showWindow();
          }
          return;
        }
        // API14 guard (win.restore() is API14+). The Rust path (restore_window)
        // already guards; throwing here surfaces the same failure into the
        // awaiting ack chain (#219) — the pre-merge ours' form was no-op+warn,
        // but under the tracked serializeOp semantics surfacing is the contract.
        if (deviceInfo.sdkApiVersion < 14) {
          throw new Error("Restoring a window requires API 14 or later");
        }
        // FOLLOW_APP_IMMERSIVE_SETTING preserves the existing fullscreen layout,
        // so no setWindowLayoutFullScreen(true) needed after restore.
        await win.restore();
        hilog.info(DOMAIN, "WindowManager", "restoreWindow %{public}d OK", windowId);
      },
      win,
    );
  }

  recoverWindow(windowId: number): void {
    this.withWindow(windowId, "recoverWindow", (win: window.Window) => {
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
          if (this.preMaximizeRects.has(win)) {
            await this.restorePreMaximizeRect(windowId, win);
            hilog.info(
              DOMAIN,
              "WindowManager",
              "recoverWindow %{public}d OK (restored pre-maximize rect)",
              windowId,
            );
          } else {
            hilog.info(
              DOMAIN,
              "WindowManager",
              "recoverWindow %{public}d OK (no pre-maximize rect; WMS default position)",
              windowId,
            );
          }
        }),
      );
    });
  }

  // #219: async -- the show command's bridge arm awaits this, so a failed
  // restore/show rejects into the ack chain instead of a fake success ack.
  async showWindowMethod(windowId: number): Promise<void> {
    // UIAbility main window: a minimized window is in MINIMIZE state.
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
        // restoreWindow's onlyIfMinimized option re-checks MINIMIZE state (HIS);
        // awaited so a failure rejects into the show command's ack chain (#219).
        await this.restoreWindow(windowId, { onlyIfMinimized: true });
        return;
      }
      // D4b plain-relaunch duplicate guard (fallback when the AbilityStage
      // onAcceptWant route is bypassed): when the window is not
      // minimized — backgrounded, covered, or already visible — raise it to
      // the top. showWindow() on a main window raises an already-shown window
      // without un-maximizing it; the F3/D un-maximize hazard only applies to
      // restore()/set_visible, which stay confined to the minimized branch.
      const win = this.getWindow(windowId);
      if (!win) {
        throw new Error(`showWindowMethod: window ${windowId} not found`);
      }
      await win.showWindow().then(() => {
        hilog.info(DOMAIN, "WindowManager", "showWindowMethod raise %{public}d OK", windowId);
      });
      return;
    }
    // Sub-window: showWindow() restores from minimize.
    // (hideWindow was dropped with ours' side: dead code in both trees — the
    // hide command routes through minimizeWindow, which gates on the
    // minimizable decoration flag and defers until WINDOW_ACTIVE.)
    const win = this.getWindow(windowId);
    if (!win) {
      throw new Error(`showWindowMethod: window ${windowId} not found`);
    }
    await win.showWindow();
    hilog.info(DOMAIN, "WindowManager", "showWindowMethod %{public}d OK", windowId);
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
  // The predefined menu fullscreen (plugins/menu menu.ets PredefinedActionExecutor)
  // and the Esc exit path (MenuPlugin's setMenuBarRecoverFn) both delegate to
  // setFullscreenAsync directly (HIS's #87 menu reorg — ours' NativeAbility-side
  // recoverFn wiring moved with the menu into the plugin, same semantics).
  // #219: async + tracked — the awaiting arms (window-API set_fullscreen,
  // predefined menu) reject into the ack chain instead of a fake success ack.
  // HIS's exit path additionally restores the pre-fullscreen rect/maximized
  // state (fullscreenRestoreStates) — a superset of ours' plain recover() exit.
  setFullscreen(windowId: number, on: boolean): void {
    this.fireAndForget(this.setFullscreenAsync(windowId, on), "setFullscreen", windowId);
  }

  async setFullscreenAsync(
    windowId: number,
    on: boolean,
    options: WindowOperationOptions = {},
  ): Promise<void> {
    await this.waitForWindowCreation(windowId);
    const win = options.window ?? this.getWindow(windowId);
    return this.serializeOp(
      windowId,
      async (): Promise<void> => {
        options.beforeRun?.();
        if (!win) {
          throw new Error(`setFullscreen: window ${windowId} not found`);
        }
        const isDesktop = display.getDefaultDisplaySync().width > 800;
        if (isDesktop) {
          if (on) {
            const previous = this.fullscreenRestoreStates.get(win) ?? {
              rect: win.getWindowProperties().windowRect,
              maximized: win.getWindowStatus() === window.WindowStatusType.MAXIMIZE,
            };
            await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
            this.fullscreenRestoreStates.set(win, previous);
            await win.setTitleAndDockHoverShown(false, false);
          } else {
            const previous = this.fullscreenRestoreStates.get(win);
            await win.recover();
            if (previous?.maximized) {
              await win.maximize(window.MaximizePresentation.EXIT_IMMERSIVE);
            } else if (previous && previous.rect.width > 0 && previous.rect.height > 0) {
              // WMS recover() places the floating window near the pointer. Fullscreen
              // exit must instead restore the bounds from before entering fullscreen.
              await win.resize(previous.rect.width, previous.rect.height);
              await win.moveWindowTo(previous.rect.left, previous.rect.top);
            }
            await win.setTitleAndDockHoverShown(true, true);
            this.fullscreenRestoreStates.delete(win);
          }
        } else {
          try {
            await win.setWindowLayoutFullScreen(on);
            await win.setWindowSystemBarEnable(on ? [] : ["status", "navigation"]);
          } catch (error) {
            hilog.warn(
              DOMAIN,
              "WindowManager",
              "Fullscreen layout failed, trying window mode: %{public}s",
              String(error),
            );
            if (on) {
              await win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
            } else {
              await win.recover();
            }
          }
        }
        // Menubar follows fullscreen state (macOS semantics, design.md MW-5/D3):
        // hide on entry, restore on exit. Centralized here so ALL fullscreen
        // entry points (window-API set_fullscreen, predefined menu fullscreen,
        // Esc exit) behave identically. The exit path is additionally covered by
        // the windowRectChange(RECOVER) → onMenubarVisibility(true) handler in
        // NativeAbility (D3) — double-restore is idempotent.
        const menuPort = getMenuBarPort(win);
        menuPort?.onMenubarVisibility(windowId, !on);
        if (on) {
          menuPort?.onMenuShown(windowId, false);
        }
      },
      win,
    );
  }
  // Group D decoration button bitfield: bit0 closable, bit1 maximizable, bit2 minimizable, bit3 resizable.
  // Only applies to sub-windows (writes LocalStorage). The UIAbility main window's
  // three decoration buttons are OS-managed: no API maps to the enable/disable flag
  // semantics (@ohos.window offers style injection via setDecorButtonStyle, whole-bar
  // visibility via setWindowDecorVisible, and per-button visibility via
  // setWindowTitleButtonVisible (API 14+), but none disables the operations
  // themselves) -- issue #238.
  // Read a decoration flag from LocalStorage (问题四: 拦截 API 执行路径)
  // key: 'closable' | 'maximizable' | 'minimizable' | 'resizable'
  // Returns true if not set (default = all available, backward compatible)
  getDecorationFlag(windowId: number, key: string): boolean {
    const entry = this.windows.get(windowId);
    if (!entry || !entry.storage) {
      return true; // default: allowed (no storage = main window or not yet initialized)
    }
    const val = entry.storage.get<boolean>(key);
    return val === undefined ? true : val;
  }

  setDecorationFlags(windowId: number, flags: number): void {
    if (this.isUIAbilityMainWindow(windowId)) {
      // Issue #238: the former hilog no-op acked a fake success for a request
      // the platform cannot honor. Throw so the bridge arm rejects the invoke
      // instead (#219 unknown-window throw pattern); sub-windows DO honor the
      // flags (LocalStorage-driven sub-window page buttons).
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "setDecorationFlags: UIAbility main window (id=%{public}d) not supported",
        windowId,
      );
      throw new Error(
        `setDecorationFlags: setting decoration buttons is not supported on the OpenHarmony main window (window ${windowId}); sub-windows support it`,
      );
    }
    const entry = this.windows.get(windowId);
    if (!entry || !entry.storage) {
      // #219: an unknown/destroyed window is a real failure -- throw so the
      // bridge arm rejects the invoke instead of acking success.
      throw new Error(`setDecorationFlags: window ${windowId} not found`);
    }
    entry.storage.setOrCreate("closable", (flags & 1) !== 0);
    entry.storage.setOrCreate("maximizable", (flags & 2) !== 0);
    entry.storage.setOrCreate("minimizable", (flags & 4) !== 0);
    entry.storage.setOrCreate("resizable", (flags & 8) !== 0);
  }

  // Group E cursor: @ohos.multimodalInput.pointer
  // #219: a failed pointer visibility flip propagates as an async rejection —
  // the set-cursor-visible bridge arm awaits this and rejects the invoke
  // instead of acking success. (Ours' former sync try/catch rethrow could not
  // see Promise rejections; HIS's async form is the correct carrier.)
  async setPointerVisible(visible: boolean): Promise<void> {
    await pointer.setPointerVisible(visible);
  }

  setPointerStyle(windowId: number, style: number): void {
    // pointer.setPointerStyleSync needs the REAL OHOS window ID (from getWindowProperties().id),
    // not tao's placeholder windowId (0 for main window). Passing 0 succeeds but has no effect.
    // NOTE: this body is NAPI-reentrant when reached through the legacy sync path (C5) --
    // bare hilog would throw "Argc mismatch"; keep the console fallback for logging.
    // #219: failures now propagate (unknown window / setPointerStyleSync throw) so
    // the set-cursor-icon bridge arm can reject the invoke instead of acking success.
    const win = this.getWindow(windowId);
    if (!win) {
      console.warn(`[WindowManager] setPointerStyle: window ${windowId} not found`);
      throw new Error(`setPointerStyle: window ${windowId} not found`);
    }
    try {
      const realWindowId = win.getWindowProperties().id;
      pointer.setPointerStyleSync(realWindowId, style as pointer.PointerStyle);
      // success log removed (issue #231): this body is NAPI-reentrant (C5) --
      // the failure console below is the exemption that reports real errors.
    } catch (err) {
      console.error(`[WindowManager] setPointerStyle ${windowId} failed: ${JSON.stringify(err)}`);
      throw err as Error;
    }
  }

  // Resolve tao's windowId (0 = main window placeholder) to the REAL OHOS window ID
  // (getWindowProperties().id) required by native OH_WindowManager_* C APIs.
  // NOTE: called from Rust via NAPI func.call — hilog is FORBIDDEN in this body
  // (NAPI re-entrancy throws "Argc mismatch"); failure is expressed as -1.
  getRealWindowId(windowId: number): number {
    try {
      const win = this.getWindow(windowId);
      if (!win) {
        return -1;
      }
      const id = win.getWindowProperties().id;
      return typeof id === "number" ? id : -1;
    } catch (_err) {
      return -1;
    }
  }

  isMaximized(windowId: number): boolean {
    const win = this.getWindow(windowId);
    if (!win) {
      return false;
    }
    return win.getWindowStatus() === window.WindowStatusType.MAXIMIZE;
  }

  isMinimized(windowId: number): boolean {
    const win = this.getWindow(windowId);
    if (!win) {
      return false;
    }
    return win.getWindowStatus() === window.WindowStatusType.MINIMIZE;
  }

  // Destroy a window and clean up all resources.
  // Works for both main window (id=0) and sub-windows.
  async destroyWindow(windowId: number): Promise<void> {
    // 拦截:FLAG_CLOSABLE 为 0 时,不允许关闭(问题四:语义错位修复)
    if (!this.getDecorationFlag(windowId, "closable")) {
      // #219/#238: throw instead of the old warn+return so the close arm
      // rejects the invoke rather than acking a fake success.
      throw new Error(`Window ${windowId} is not closable`);
    }
    if (this.isUIAbilityMainWindow(windowId)) {
      const context = this.uiAbilityContexts.get(Number(windowId));
      if (!context) {
        throw new Error(`No Ability context for window ${windowId}`);
      }
      await context.terminateSelf();
      if (this.uiAbilityContexts.get(windowId) === context) {
        this.removeWindow(windowId);
        this.unregisterUIAbilityStage(windowId);
      }
      return;
    }
    // Sub-window path: delegated to destroyFloatingWindow, which carries ours'
    // D4 semantic (destroying=true so in-flight throttled rect events are
    // discarded — no consumers left after destroy) in HIS's tracked form.
    await this.destroyFloatingWindow(windowId);
  }

  // Close a window for real (not hide).
  // - UIAbility main window (id=0 first instance or id>0 subsequent instance):
  //   terminate the Ability instance via context.terminateSelf(). This truly
  //   closes the instance (removed from recent tasks), distinct from hideAbility
  //   which only backgrounds it. The first instance (id=0) terminating == app
  //   exit; secondary instances (id>0) terminating == that instance only exits.
  // - SubWindow: win.destroyWindow() + removeWindow cleanup.
  async closeWindow(windowId: number): Promise<void> {
    if (this.isUIAbilityMainWindow(windowId)) {
      // HIS's #219 form: throw when no context instead of ours' warn +
      // hideAbility fallback. The fallback was known-dead on PC (StartOptions
      // check rejected it), and swallowing the failure would fake-ack the
      // Rust-side close. The rejection surfaces through the ack chain.
      const context = this.uiAbilityContexts.get(windowId);
      if (!context) {
        throw new Error(`No Ability context for window ${windowId}`);
      }
      await context.terminateSelf();
      return;
    }
    // HIS's #219 form: delegate to destroyFloatingWindow (the tracked
    // sub-window close). Ours' inline form carried the same D4 destroying
    // flag; the flag now lives inside destroyFloatingWindow.
    await this.destroyFloatingWindow(windowId);
  }

  private async destroyFloatingWindow(windowId: number): Promise<void> {
    const entry = this.windows.get(windowId);
    if (!entry) {
      return;
    }
    entry.destroying = true;
    try {
      await entry.window.destroyWindow();
    } catch (error) {
      // Tracked rethrow (HIS's #219 form, ≡ ours' D4 semantics): reset the
      // destroying flag so a retry can proceed, and let the rejection
      // propagate into the ack chain instead of warn-and-swallow.
      entry.destroying = false;
      throw error as Error;
    }
    // Native teardown can unregister the window before its Promise settles.
    // Entry-identity guard: only remove if THIS entry still owns the id (a
    // replacement window registered under the same id must not be torn down).
    if (this.windows.get(windowId) === entry) {
      this.removeWindow(windowId);
    }
  }

  private logNotFound(op: string, windowId: number): void {
    hilog.warn(DOMAIN, "WindowManager", `%{public}s: window %{public}d not found`, op, windowId);
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
  private fireAndForget<T>(
    p: Promise<T>,
    op: string,
    windowId: number,
    onSuccess?: (v: T) => void,
  ): void {
    p.then((v: T) => {
      if (onSuccess) {
        onSuccess(v);
      }
    }).catch((err: ESObject) => {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "%{public}s %{public}d failed: %{public}s",
        op,
        windowId,
        JSON.stringify(err),
      );
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
        hilog.warn(
          DOMAIN,
          "WindowManager",
          "hideWithRestoreGuard: main window not found, direct hide",
        );
        this.doHideAbility()
          .then(() => resolve())
          .catch(() => resolve());
        return;
      }
      let consumed = false;
      const finish = () => {
        try {
          win.off("windowEvent", onWindowEvent);
        } catch (_) {}
      };
      const doHide = () => {
        if (consumed) return;
        consumed = true;
        finish();
        hilog.info(DOMAIN, "WindowManager", "hideWithRestoreGuard: hiding (settled)");
        this.doHideAbility()
          .then(() => resolve())
          .catch(() => resolve());
      };
      const onWindowEvent = (eventType: window.WindowEventType) => {
        if (!consumed && eventType === window.WindowEventType.WINDOW_ACTIVE) {
          hilog.info(DOMAIN, "WindowManager", "hideWithRestoreGuard: WINDOW_ACTIVE fired");
          doHide();
        }
      };
      try {
        win.on("windowEvent", onWindowEvent);
      } catch (_) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          "hideWithRestoreGuard: windowEvent unsupported, direct hide",
        );
        this.doHideAbility()
          .then(() => resolve())
          .catch(() => resolve());
        return;
      }
      hilog.info(
        DOMAIN,
        "WindowManager",
        "hideWithRestoreGuard: waiting for WINDOW_ACTIVE (50ms fallback)",
      );
      setTimeout(doHide, 50);
    });
  }

  private async doHideAbility(): Promise<void> {
    if (!this.context) {
      hilog.warn(DOMAIN, "WindowManager", "hideAbility: context not set");
      return;
    }
    try {
      await this.context.hideAbility();
      this.resetUserInteractionTracking();
    } catch (e) {
      hilog.warn(DOMAIN, "WindowManager", "hideAbility failed: %{public}s", String(e));
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
    hilog.info(
      DOMAIN,
      "WindowManager",
      "Pending action set, waiting for system foreground transition",
    );

    // Start safety net cleanup timer (2s)
    this.cleanupTimer = setTimeout(() => {
      if (this.pendingAction) {
        hilog.warn(DOMAIN, "WindowManager", "Pending action timeout (2s), cleaning up stale state");
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

    hilog.info(
      DOMAIN,
      "WindowManager",
      "Consuming pending action after system foreground transition",
    );
    try {
      action();
      return true;
    } catch (e) {
      hilog.error(
        DOMAIN,
        "WindowManager",
        "Failed to execute pending action: %{public}s",
        String(e),
      );
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
      hilog.info(DOMAIN, "WindowManager", "Cleanup timer cancelled");
    }
  }

  clearPendingAction(): void {
    if (this.pendingAction) {
      hilog.info(DOMAIN, "WindowManager", "Clearing pending action without execution");
      this.pendingAction = null;
    }
    this.cancelCleanupTimer();
  }

  async waitForWindowCreation(windowId: number): Promise<void> {
    if (this.isWindowCreationDeferred(windowId)) {
      throw new Error(`Window ${windowId} is not ready: show the deferred window first`);
    }
    const creation = this.creatingWindows.get(windowId);
    if (creation) {
      await creation;
    }
  }

  async createSubWindow(opts: SubWindowOptions): Promise<number> {
    if (this.creatingWindows.has(opts.windowId)) {
      throw new Error(`Window ${opts.windowId} is already being created`);
    }
    const creation = this.createSubWindowImpl(opts);
    this.creatingWindows.set(opts.windowId, creation);
    try {
      return await creation;
    } finally {
      this.creatingWindows.delete(opts.windowId);
    }
  }

  setIndependentWindowAbility(abilityName: string | undefined): void {
    this.independentWindowAbility = abilityName?.trim() || undefined;
  }

  hasPendingAbilityWindow(windowId: number): boolean {
    const pending = this.pendingAbilityWindows.get(windowId);
    return pending !== undefined && !pending.claimed && !pending.canceled;
  }

  isWindowCreationDeferred(windowId: number): boolean {
    return this.deferredAbilityWindows.has(windowId);
  }

  /** Mutate creation parameters without foregrounding a hidden Ability. */
  configureDeferredWindow(
    windowId: number,
    configure: (options: SubWindowOptions) => void,
  ): boolean {
    const deferred = this.deferredAbilityWindows.get(windowId);
    if (!deferred) {
      return false;
    }
    configure(deferred.options);
    return true;
  }

  startDeferredWindowCreation(windowId: number): void {
    const deferred = this.deferredAbilityWindows.get(windowId);
    if (deferred) {
      this.deferredAbilityWindows.delete(windowId);
      deferred.start();
    }
  }

  cancelDeferredWindowCreation(windowId: number): void {
    const deferred = this.deferredAbilityWindows.get(windowId);
    if (deferred) {
      this.deferredAbilityWindows.delete(windowId);
      deferred.cancel();
    }
  }

  private async createAbilityWindow(opts: SubWindowOptions, abilityName: string): Promise<number> {
    if (opts.show === false) {
      // startAbility foregrounds a main window even if its content never calls
      // showWindow. Keep hidden workspaces logical until the caller shows them.
      const requested = await new Promise<boolean>((resolve) => {
        this.deferredAbilityWindows.set(opts.windowId, {
          options: opts,
          start: (): void => resolve(true),
          cancel: (): void => resolve(false),
        });
      });
      if (!requested) {
        return opts.windowId;
      }
    }
    let contentReady = false;
    let launchComplete = false;
    const ready = new Promise<void>((resolve, reject) => {
      this.pendingAbilityWindows.set(opts.windowId, {
        options: opts,
        resolve: (): void => {
          contentReady = true;
          // Keep creation rejectable if its stage closes before startAbility finishes.
          if (launchComplete) {
            resolve();
          }
        },
        reject,
        claimed: false,
        canceled: false,
      });
    });
    const pending = this.pendingAbilityWindows.get(opts.windowId);
    if (!pending) {
      throw new Error(`Missing creation request for Ability window ${opts.windowId}`);
    }
    const timeout = setTimeout(() => {
      pending.canceled = true;
      pending.reject(new Error(`Timed out creating Ability window ${opts.windowId}`));
    }, 30000);
    try {
      const previousFocusedWindowId =
        this.lastFocusedWindowId >= 0 && this.lastFocusedWindowId !== opts.windowId
          ? this.lastFocusedWindowId
          : 0;
      const parameters: Record<string, Object> = {};
      parameters[INDEPENDENT_WINDOW_ID_PARAMETER] = opts.windowId;
      await Promise.all([
        ready,
        this.context
          .startAbility(
            {
              bundleName: this.context.abilityInfo.bundleName,
              moduleName: this.context.abilityInfo.moduleName,
              abilityName,
              parameters,
            },
            {
              withAnimation: false,
              hideStartWindow: deviceInfo.sdkApiVersion >= 20 ? true : undefined,
              windowLeft: opts.x,
              windowTop: opts.y,
              windowWidth: opts.width,
              windowHeight: opts.height,
              displayId: opts.displayId,
            },
          )
          .then((): void => {
            launchComplete = true;
            if (contentReady) {
              pending.resolve();
            }
          }),
      ]);
      if (pending.canceled) {
        throw new Error(`Ability window ${opts.windowId} creation was canceled`);
      }
      if (
        opts.focus === false &&
        previousFocusedWindowId !== opts.windowId &&
        (this.lastFocusedWindowId < 0 ||
          this.lastFocusedWindowId === opts.windowId ||
          this.lastFocusedWindowId === previousFocusedWindowId)
      ) {
        await this.restorePreviousFocusAfterAbilityLaunch(opts.windowId, previousFocusedWindowId);
      }
      return opts.windowId;
    } catch (error) {
      pending.canceled = true;
      const context = this.uiAbilityContexts.get(opts.windowId);
      if (context) {
        try {
          await context.terminateSelf();
        } catch (cleanupError) {
          hilog.warn(
            DOMAIN,
            "WindowManager",
            "Ability window rollback failed: %{public}s",
            String(cleanupError),
          );
        }
        this.removeWindow(opts.windowId);
        this.unregisterUIAbilityStage(opts.windowId);
      }
      throw error as Error;
    } finally {
      clearTimeout(timeout);
      this.pendingAbilityWindows.delete(opts.windowId);
    }
  }

  private async restorePreviousFocusAfterAbilityLaunch(
    launchedWindowId: number,
    previousWindowId: number,
  ): Promise<void> {
    const previousWindow = this.getWindow(previousWindowId);
    if (!previousWindow) {
      return;
    }
    try {
      if (previousWindow.getWindowStatus() === window.WindowStatusType.MINIMIZE) {
        return;
      }
    } catch {
      // Ignore window status lookup failures and still try focus restoration.
    }
    const launchedWindow = this.getWindow(launchedWindowId);
    if (launchedWindow) {
      try {
        const sourceId = launchedWindow.getWindowProperties().id;
        const targetId = previousWindow.getWindowProperties().id;
        if (sourceId > 0 && targetId > 0 && sourceId !== targetId) {
          await window.shiftAppWindowFocus(sourceId, targetId);
        }
      } catch (error) {
        hilog.debug(
          DOMAIN,
          "WindowManager",
          "shiftAppWindowFocus after non-activating launch failed: %{public}s",
          String(error),
        );
      }
    }
    try {
      if (deviceInfo.sdkApiVersion >= 20 && !this.isUIAbilityMainWindow(previousWindowId)) {
        await previousWindow.showWindow({ focusOnShow: true });
      } else {
        await previousWindow.showWindow();
      }
    } catch (error) {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "Restoring focus to window %{public}d after non-activating launch failed: %{public}s",
        previousWindowId,
        String(error),
      );
    }
  }

  async attachAbilityWindow(
    windowId: number,
    stage: window.WindowStage,
    context: common.UIAbilityContext,
  ): Promise<void> {
    const pending = this.pendingAbilityWindows.get(windowId);
    if (!pending || pending.claimed || pending.canceled) {
      throw new Error(`No pending creation for Ability window ${windowId}`);
    }
    pending.claimed = true;
    try {
      // The shared content initializer owns this window's listeners. The new
      // UIAbility supplies a separate termination callback, not another Rust app.
      this.registerUIAbilityStage(
        windowId,
        stage,
        context,
        pending.options.transparent ?? false,
        false,
      );
      await this.initializeSubWindow(stage.getMainWindowSync(), pending.options);
      if (pending.canceled) {
        throw new Error(`Ability window ${windowId} creation was canceled`);
      }
      pending.resolve();
    } catch (error) {
      pending.reject(error as Error);
    }
  }

  private async createSubWindowImpl(opts: SubWindowOptions): Promise<number> {
    const name = opts.name;
    const windowId = opts.windowId;

    // Reject unsupported requests before creating or registering any platform resource.
    if (opts.displayId !== undefined && deviceInfo.sdkApiVersion < 15) {
      throw new Error("Moving a sub-window to a display requires API 15");
    }
    if (this.windows.has(windowId) || this.uiAbilityStages.has(windowId)) {
      throw new Error(`Window ${windowId} already exists`);
    }

    // Validate windowId: sub-window ID must be greater than 0
    if (windowId <= 0) {
      hilog.error(
        DOMAIN,
        "WindowManager",
        `Invalid windowId: %{public}d. Sub-window creation requires windowId > 0.`,
        windowId,
      );
      throw new Error(`Invalid windowId: ${windowId}. Must be greater than 0.`);
    }

    // Check if windowStage has been set
    // HIS's form: fetch the stage once (createSubWindowWithOptions needs the
    // stage object below, not just a has() probe).
    const mainStage = this.uiAbilityStages.get(0);
    if (!mainStage) {
      hilog.error(DOMAIN, "WindowManager", "WindowStage not set. Call setWindowStage() first.");
      throw new Error("WindowStage not set");
    }

    // HIS's independent-window routing (kept intact per structural decision):
    // 2in1/tablet + independent + non-modal + a native module name + a
    // configured ability → the window becomes a separate UIAbility instance
    // (createAbilityWindow) instead of a primary-stage sub-window.
    if (
      opts.independent &&
      opts.modal !== true &&
      opts.nativeModuleName &&
      this.independentWindowAbility &&
      (deviceInfo.deviceType === "2in1" || deviceInfo.deviceType === "tablet")
    ) {
      return this.createAbilityWindow(opts, this.independentWindowAbility);
    }

    hilog.info(
      DOMAIN,
      "WindowManager",
      `Creating sub-window via windowStage: %{public}s, id: %{public}d`,
      name,
      windowId,
    );

    let win: window.Window;
    try {
      // Use windowStage.createSubWindow(name) instead of window.createWindow(config)
      // API19+: use createSubWindowWithOptions with maximizeSupported:true — win.maximize()
      // on a sub-window is rejected by WMS (1300004 "Only support main or sub Window")
      // unless the sub-window declared maximize capability at creation
      // (SubWindowOptions.maximizeSupported defaults to false). title/decorEnabled are
      // required fields (API11+); decorEnabled:false keeps the system decoration off —
      // SubWindowPage draws its own title bar. On non-2in1/Tablet devices maximizeSupported
      // is silently ignored (documented no-op), so it is safe to always pass on API19+.
      // This also unlocks maximize for the menu PredefinedMenuItem 'maximize' path and
      // setFullscreen's maximize(ENTER_IMMERSIVE) on sub-windows (same WMS gate).
      // Stage routing: always uiAbilityStages.get(0) (primary). A 2026-09-16 zero-code
      // experiment (openspec multi-uiability-windows B3/OQ2) proved createSubWindowWithOptions
      // DOES run on a spawned UIAbility stage (creation+render+input all work), but the
      // system close-cascades ALL sub-windows when that stage's instance is destroyed —
      // owner semantics (like Windows WebviewWindowBuilder.parent). Production keeps
      // sub-windows on the primary stage so they outlive individual instance destruction;
      // per-instance sub-windows remain a documented-not-implemented option. (HIS deleted
      // this comment in the reorg; it documents why his mainStage routing is the way it is.)
      if (deviceInfo.sdkApiVersion >= 19) {
        const windowOptions: window.SubWindowOptions = {
          title: "",
          decorEnabled: false,
          maximizeSupported: true,
          isModal: opts.modal ?? false,
        };
        if (deviceInfo.sdkApiVersion >= 26 && opts.independent === true) {
          windowOptions.zLevelAboveParentLoosened = true;
        }
        win = await mainStage.createSubWindowWithOptions(name, windowOptions);
      } else {
        // API<19: maximizeSupported does not exist in the SDK typings — plain path.
        win = await mainStage.createSubWindow(name);
      }
      hilog.info(DOMAIN, "WindowManager", `Sub-window created successfully: %{public}d`, windowId);
    } catch (err) {
      hilog.error(
        DOMAIN,
        "WindowManager",
        `Failed to create sub-window: %{public}s`,
        JSON.stringify(err),
      );
      throw err as Error;
    }

    try {
      return await this.initializeSubWindow(win, opts);
    } catch (error) {
      const entry = this.windows.get(windowId);
      if (entry) {
        entry.destroying = true;
      }
      // Rollback is not a user close action: decoration flags must not veto it.
      try {
        await win.destroyWindow();
      } catch (cleanupError) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          "Sub-window %{public}d rollback failed: %{public}s",
          windowId,
          String(cleanupError),
        );
      } finally {
        this.removeWindow(windowId);
        if (this.lastFocusedWindow === win) {
          this.lastFocusedWindow = null;
          this.lastFocusedWindowId = -1;
        }
      }
      throw error as Error;
    }
  }

  private async initializeSubWindow(win: window.Window, opts: SubWindowOptions): Promise<number> {
    const windowId = opts.windowId;
    const pending = this.pendingAbilityWindows.get(windowId);
    const ensureCreationActive = (): void => {
      if (pending && (pending.canceled || !this.uiAbilityStages.has(windowId))) {
        throw new Error(`Ability window ${windowId} creation was canceled`);
      }
    };
    // Geometry defaults — `let` because the phone-form clamp below may shrink
    // them into the display rect. (Grafted from ours' monolithic createSubWindow
    // head: HIS's split computes geometry here in the shared initializer, so the
    // clamp now also covers ability windows — harmless, since those are
    // 2in1/tablet-only where the phone gate never fires.)
    let width: number = opts.width ?? 800;
    let height: number = opts.height ?? 600;
    let x: number = opts.x ?? 100;
    let y: number = opts.y ?? 100;
    const displayId = opts.displayId;
    const decorations = opts.decorations ?? true;
    const transparent = opts.transparent ?? false;
    const backgroundColor = opts.backgroundColor;

    // Phone-form creation clamp (2026-10-09 Mate 70 report): tauri's default
    // window geometry is 800×600 LOGICAL, which arrives here already scaled
    // to physical px (2600×1950 at density 3.25). WMS honors oversized
    // sub-window rects literally, so on a 1216×2688 phone screen the created
    // window is 2.1× wider than the display and its content's close
    // affordance lands ~1400px off-screen — the reported popup could only be
    // closed after dragging it back on-screen. Clamp creation geometry into
    // the display rect on phones. PC/2in1 keep literal geometry (verified
    // 305-case green; 2in1 screens are large enough that tauri defaults
    // never exceed them).
    if (deviceInfo.deviceType === "phone") {
      try {
        const d = display.getDefaultDisplaySync();
        const maxW = Math.floor(d.width);
        const maxH = Math.floor(d.height);
        const clampedW = Math.min(width, maxW);
        const clampedH = Math.min(height, maxH);
        // Re-anchor the top-left into the visible rect — the default 100,100
        // anchor would leave a full-width window's right edge off-screen.
        const clampedX = Math.min(Math.max(x, 0), maxW - clampedW);
        const clampedY = Math.min(Math.max(y, 0), maxH - clampedH);
        if (clampedW !== width || clampedH !== height || clampedX !== x || clampedY !== y) {
          hilog.info(
            DOMAIN,
            "WindowManager",
            `Phone clamp: window %{public}d %{public}dx%{public}d@%{public}d,%{public}d -> %{public}dx%{public}d@%{public}d,%{public}d (display %{public}dx%{public}d)`,
            windowId,
            width,
            height,
            x,
            y,
            clampedW,
            clampedH,
            clampedX,
            clampedY,
            maxW,
            maxH,
          );
          width = clampedW;
          height = clampedH;
          x = clampedX;
          y = clampedY;
        }
      } catch (e) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          `Phone clamp skipped (display query failed): %{public}s`,
          String(e),
        );
      }
    }

    // Use LocalStorage to pass windowId and decorations, ensuring isolation between windows
    let storage = new LocalStorage();
    storage.setOrCreate("windowId", windowId);
    // HIS's additions: nativeModuleName for the sub-window host page's module
    // bridge, and ability main windows never take sub-window decorations.
    storage.setOrCreate("nativeModuleName", opts.nativeModuleName ?? "");
    storage.setOrCreate("decorations", this.isUIAbilityMainWindow(windowId) ? false : decorations);
    // D group decoration flags default (all available; setDecorationFlags updates them)
    storage.setOrCreate("closable", true);
    storage.setOrCreate("maximizable", true);
    storage.setOrCreate("minimizable", true);
    storage.setOrCreate("resizable", true);
    // Title (set by setWindowTitle → updates this via setWindowTitle impl)
    storage.setOrCreate("title", "");
    // UNION: HIS's WindowEntry carries focusOnShow (modal windows skip focus
    // steal on show; showWindow consults it); ours' explicit kind registration
    // below removes the implicit "absent means SubWindow" dependency that
    // HIS's tree relies on (his only ever writes the UIAbility key).
    this.windows.set(windowId, {
      window: win,
      storage,
      focusOnShow: opts.modal === true ? undefined : (opts.focus ?? true),
      destroying: false,
    });
    // Register the SubWindow kind explicitly. isUIAbilityMainWindow reads this map --
    // today sub-windows work only because a MISSING key is treated as "not a
    // UIAbility main window". Making the kind explicit removes that implicit
    // "absent means SubWindow" dependency (removeWindow's windowKinds.delete above
    // stays idempotent).
    this.windowKinds.set(windowId, WindowKind.SubWindow);

    // Phase 2 (design.md D3): register this sub-window's windowRectChange handler.
    // This is the only clean registration point for sub-windows -- createSubWindow
    // holds both `win` and `windowId`. The handler wraps { windowId, reason, rect } and
    // invokes the single rectChangeCallback (registered by NativeAbility.onWindowStageCreate
    // to fan out to lifecycles), so the Rust window_rect_change closure routes the rect
    // into the per-window HashMap at key windowId (design.md D2/D4). Registered BEFORE
    // loadContentByName so early rect changes (resize to target size) are captured.
    // The handler reference is stored in the WindowEntry so destroyWindow/removeWindow
    // can win.off("windowRectChange", handler) to avoid leaking the listener.
    let rectChangeHandler: ((options: window.RectChangeOptions) => void) | undefined = (
      options: window.RectChangeOptions,
    ): void => {
      try {
        // Phase 3 (design.md D5): deep-copy rect fields — do not store system object ref.
        // Phase 3 (design.md D3): route through per-window throttle (leading+trailing 16ms).
        // Issue Eulogizethesun/tauri#97: attach the same moment's drawableRect
        // (sync getWindowProperties snapshot) so the Rust inner-rect cache
        // tracks the system-defined inner value — omitted when unreadable.
        const wrapped: WindowRectEventWrap = {
          windowId,
          reason: options.reason,
          rect: {
            left: options.rect.left,
            top: options.rect.top,
            width: options.rect.width,
            height: options.rect.height,
          },
          drawable: WindowManager.readDrawableRect(win),
        };
        this.throttledRectDispatch(
          windowId,
          wrapped,
          (w: object) => {
            this.rectChangeCallback?.(w as WindowRectEventWrap);
          },
          "rect",
        );
      } catch (e) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          `Sub-window rectChange handler failed for %{public}d: %{public}s`,
          windowId,
          String(e),
        );
      }
    };
    try {
      win.on("windowRectChange", rectChangeHandler);
    } catch (e) {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        `Failed to register windowRectChange for sub-window %{public}d: %{public}s`,
        windowId,
        String(e),
      );
      rectChangeHandler = undefined;
    }
    if (rectChangeHandler) {
      let entry = this.windows.get(windowId);
      if (entry) {
        entry.rectChangeHandler = rectChangeHandler;
      }
    }

    const avoidAreaChangeHandler = (options: window.AvoidAreaOptions): void => {
      this.avoidAreaChangeCallback?.({
        windowId,
        type: options.type,
        area: options.area,
      });
    };
    try {
      win.on("avoidAreaChange", avoidAreaChangeHandler);
      const entry = this.windows.get(windowId);
      if (entry) {
        entry.avoidAreaChangeHandler = avoidAreaChangeHandler;
      }
    } catch (error) {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "Failed to register avoidAreaChange for sub-window %{public}d: %{public}s",
        windowId,
        String(error),
      );
    }

    // Register focus tracking for sub-window
    this.registerFocusTracking(win, windowId);
    this.registerCloseListener(win, windowId);

    try {
      hilog.info(
        DOMAIN,
        "WindowManager",
        `Loading content: SubWindowPage for window %{public}d`,
        windowId,
      );
      await win.loadContentByName(SubWindowPage.RouteName, storage);
      // HIS's gate: reject a canceled ability-window creation at the first
      // post-load checkpoint (his FloatPage host did this; ours' SubWindowPage
      // host inherits it).
      ensureCreationActive();
      hilog.info(
        DOMAIN,
        "WindowManager",
        `UI content loaded successfully for window: %{public}d`,
        windowId,
      );

      // Review R13: seed this sub-window's rect caches right after its content
      // loads. The windowRectChange registration above deliberately runs
      // pre-load to catch early rect changes, but those events carry no
      // drawableRect (unreadable before loadContent) and the Rust side updates
      // the outer/drawable pair atomically — so they seed nothing at all. This
      // snapshot restores the initial-size signal (the first dispatchable
      // Resized for sub-windows) and fills inner_rects (chrome is 0 for
      // decorEnabled:false sub-windows; the pair keeps semantics uniform).
      try {
        const snapshot = WindowManager.readWindowRectSnapshot(win);
        if (snapshot) {
          const wrapped: WindowRectEventWrap = {
            windowId,
            reason: window.RectChangeReason.UNDEFINED,
            rect: snapshot.rect,
            drawable: snapshot.drawable,
          };
          this.throttledRectDispatch(
            windowId,
            wrapped,
            (w: object) => {
              this.rectChangeCallback?.(w as WindowRectEventWrap);
            },
            "rect",
          );
        }
      } catch (e) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          `Rect cache seed failed for window %{public}d: %{public}s`,
          windowId,
          String(e),
        );
      }

      // Register sub-window's UIContext
      try {
        const uiCtx = win.getUIContext();
        if (uiCtx) {
          this.registerUIContext(windowId, uiCtx);
          hilog.info(
            DOMAIN,
            "WindowManager",
            `Sub-window UIContext registered for window: %{public}d`,
            windowId,
          );
        }
      } catch (e) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          `Failed to get UIContext for window %{public}d: %{public}s`,
          windowId,
          JSON.stringify(e),
        );
      }
    } catch (err) {
      hilog.error(
        DOMAIN,
        "WindowManager",
        `Failed to load content for window %{public}d: %{public}s`,
        windowId,
        JSON.stringify(err),
      );
      throw err as Error;
    }

    try {
      // Apply transparent/backgroundColor settings
      if (transparent) {
        hilog.info(
          DOMAIN,
          "WindowManager",
          `Setting sub-window %{public}d to transparent`,
          windowId,
        );
        await win.setWindowBackgroundColor("#00000000");
        // HIS's gate: a canceled ability-window creation stops here (before
        // any further property writes on a half-dead window).
        ensureCreationActive();
        // Sub-windows ALSO have a window container layer. Without setting
        // it transparent, an opaque container sits between the window background
        // and ArkUI content — blocking backdropBlur from sampling through the
        // transparent window to content behind it (vibrancy/frosted glass effect).
        // This was removed in aca6b53 by mistake (comment incorrectly claimed
        // sub-windows have no container); restoring the original behavior.
        if (deviceInfo.sdkApiVersion >= 20) {
          try {
            // HIS's form (matches the resolved applyTransparentBackground):
            // setWindowContainerColor is a sync API — no await — and the
            // inactive layer keeps the theme color instead of forcing black.
            win.setWindowContainerColor("#00000000", this.inactiveContainerColor(win, 0));
            hilog.info(
              DOMAIN,
              "WindowManager",
              `SubWindow %{public}d container color set to transparent (API %{public}d)`,
              windowId,
              deviceInfo.sdkApiVersion,
            );
          } catch (containerErr) {
            const error = containerErr as BusinessError;
            if (error.code === 801) {
              hilog.debug(
                DOMAIN,
                "WindowManager",
                "setWindowContainerColor not supported (error 801)",
              );
            } else if (error.code === 201) {
              hilog.error(
                DOMAIN,
                "WindowManager",
                "setWindowContainerColor permission denied (error 201): missing ohos.permission.SET_WINDOW_TRANSPARENT",
              );
            } else {
              hilog.warn(
                DOMAIN,
                "WindowManager",
                `Sub-window container color failed: code=%{public}d`,
                error.code,
              );
            }
          }
        } else {
          // setWindowContainerColor is API 20+; below that the container layer
          // stays opaque, so a transparent sub-window shows no visible blur
          // (vibrancy) effect. Non-fatal: the window itself still works.
          // (HIS deleted this else-branch; ours' explicit degraded-mode warn
          // is kept — it is the only diagnostic that the blur effect will not
          // appear on API<20.)
          hilog.warn(
            DOMAIN,
            "WindowManager",
            `Sub-window %{public}d transparent container requires API20+, current %{public}d; container stays opaque (no visible blur)`,
            windowId,
            deviceInfo.sdkApiVersion,
          );
        }
      } else if (backgroundColor !== undefined) {
        const colorStr = "#" + backgroundColor.toString(16).padStart(8, "0");
        hilog.info(
          DOMAIN,
          "WindowManager",
          `Setting window %{public}d background color to %{public}s`,
          windowId,
          colorStr,
        );
        await win.setWindowBackgroundColor(colorStr);
        ensureCreationActive();
      }

      // HIS's geometry application form — a superset of ours' plain
      // resize→move→show: only sub-windows / floating mains get placed;
      // displayId-aware positioning (moveWindowToGlobal for multi-display);
      // show-gating for hidden workspaces (opts.show === false); API20+
      // focusOnShow honoring the modal/focus options; and position re-apply
      // after show (2in1 repositions floating windows on show). Ours' phone
      // clamp upstream still bounds width/height/x/y before they reach here.
      const canPlace =
        !this.isUIAbilityMainWindow(windowId) ||
        win.getWindowStatus() === window.WindowStatusType.FLOATING;
      const position = canPlace
        ? await this.resolveWindowPosition(win, x, y, displayId)
        : undefined;
      ensureCreationActive();
      if (canPlace) {
        await win.resize(width, height);
        ensureCreationActive();
      }
      const applyPosition = async (): Promise<void> => {
        if (!position) {
          return;
        }
        if (displayId === undefined) {
          await win.moveWindowTo(position.x, position.y);
        } else {
          await win.moveWindowToGlobal(position.x, position.y, { displayId });
        }
        ensureCreationActive();
      };
      await applyPosition();
      if (opts.show !== false) {
        if (deviceInfo.sdkApiVersion >= 20 && opts.modal !== true) {
          await win.showWindow({ focusOnShow: opts.focus ?? true });
          ensureCreationActive();
        } else {
          await win.showWindow();
          ensureCreationActive();
        }
      }
      // Showing a floating window can reposition it on 2in1.
      await applyPosition();
      hilog.info(DOMAIN, "WindowManager", `Window initialized: %{public}d`, windowId);
    } catch (err) {
      hilog.error(
        DOMAIN,
        "WindowManager",
        `Failed to resize/move/show window: %{public}s`,
        JSON.stringify(err),
      );
      throw err as Error;
    }

    return windowId;
  }

  // HIS's accessor: the focusOnShow entry field captured at creation
  // (modal → undefined, else opts.focus ?? true). Consulted by the
  // show-after-minimize path to restore the original focus intent.
  focusOnShow(windowId: number): boolean | undefined {
    return this.windows.get(windowId)?.focusOnShow;
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
        hilog.warn(DOMAIN, "WindowManager", "Failed to get main window: %{public}s", String(e));
        return undefined;
      }
    }
    // Subsequent UIAbility instance main windows live on their own WindowStage.
    const secStage = this.uiAbilityStages.get(wid);
    if (secStage) {
      try {
        return secStage.getMainWindowSync();
      } catch (e) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          "Failed to get subsequent main window %{public}d: %{public}s",
          wid,
          String(e),
        );
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
  // Sub-window: LocalStorage setOrCreate('decorations') -- SubWindowPage @LocalStorageProp reactively re-renders.
  // Returns whether the window kind was handled: a sub-window storage write and a successful
  // UIAbility setWindowDecorVisible return true; a missing window, a thrown system call,
  // or an unknown window kind return false (the plugin handler surfaces that as an error).
  // Note (HIS's family extends the entry population): `windows` entries are created by
  // initializeSubWindow for BOTH sub-windows and HIS's ability windows; the storage write
  // below guards the ability-main case with the isUIAbilityMainWindow ternary. HIS's void
  // form dropped the return contract — ours' boolean form kept (callers that ignore it
  // still compile).
  setDecorations(windowId: number, decorations: boolean): boolean {
    hilog.info(
      DOMAIN,
      "WindowManager",
      "setDecorations %{public}d decorations=%{public}s ENTER",
      windowId,
      String(decorations),
    );
    // Sub-window: write LocalStorage to drive SubWindowPage title bar show/hide
    const entry = this.windows.get(windowId);
    if (entry && entry.storage) {
      // HIS's ternary: an ability main window routed through
      // initializeSubWindow does carry a windows entry here — it must never
      // take sub-window decorations.
      entry.storage.setOrCreate(
        "decorations",
        this.isUIAbilityMainWindow(windowId) ? false : decorations,
      );
      hilog.info(
        DOMAIN,
        "WindowManager",
        `Decorations set to %{public}s for sub-window %{public}d (LocalStorage)`,
        String(decorations),
        windowId,
      );
      return true;
    }
    // UIAbility main window: call setWindowDecorVisible directly to control the system title bar
    if (this.isUIAbilityMainWindow(windowId)) {
      const win = this.getWindow(windowId);
      if (!win) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          "setDecorations: main window %{public}d not found",
          windowId,
        );
        return false;
      }
      try {
        win.setWindowDecorVisible(decorations);
        if (deviceInfo.sdkApiVersion >= 14) {
          // HIS's graft: the main window can retain its three-button overlay
          // after its title bar is hidden — setWindowDecorVisible alone does
          // not cover the button strip, so mirror the visibility there too.
          // (HIS called this from the plugin arm; with ours' delegation the
          // plugin no longer touches win, so it moved into this success path.)
          win.setWindowTitleButtonVisible(decorations, decorations, decorations);
        }
        hilog.info(
          DOMAIN,
          "WindowManager",
          "setDecorations %{public}d setWindowDecorVisible(%{public}s) OK",
          windowId,
          String(decorations),
        );
        // Decor visibility changes the drawable area WITHOUT changing the
        // window rect, so the system fires no windowRectChange here
        // (device-probed 2026-10-12,
        // faultlogs/tao27-f2-decor-toggle-probe-20261012.md): the Rust
        // inner-rect cache went stale and no Resized fired. Push synthetic
        // rect changes — a fresh getWindowProperties() pair through the same
        // throttled channel the real handler uses (same wrap shape as the
        // floating sub-window post-load seed in createSubWindow); the Rust-side
        // rect dedup makes a push with not-yet-settled (stale) properties a
        // no-op. Immediate push covers the synchronous-property case; the
        // delayed one lands after the ArkUI layout settles (~11-18ms
        // observed on HAD-W32). (HIS dropped this with his void reorg; the
        // probe evidence makes it load-bearing — kept.)
        this.pushSyntheticRectChange(windowId);
        setTimeout(() => this.pushSyntheticRectChange(windowId), 100);
        return true;
      } catch (err) {
        // 801: device not supported (phones); 1300002: abnormal window state. Does not affect other logic.
        hilog.warn(
          DOMAIN,
          "WindowManager",
          "setDecorations %{public}d setWindowDecorVisible failed: %{public}s",
          windowId,
          JSON.stringify(err),
        );
      }
    }
    // Unknown window kind, or the ability-main call threw above: the window
    // kind was not handled — signal the caller (the plugin arm surfaces this
    // as an error instead of acking success).
    return false;
  }

  /** Synthetic rect-change push after a decor visibility change: reads a
   *  fresh windowRect+drawableRect snapshot pair and dispatches it through
   *  the same throttled rect channel the real windowRectChange handler uses
   *  (the rectChangeCallback fan-out registered by NativeAbility). The Rust
   *  window_rect_change closure updates the inner-rect cache from the pair
   *  and the ContentRectChange dedup suppresses unchanged rects, so a
   *  redundant or not-yet-settled push is a no-op. */
  private pushSyntheticRectChange(windowId: number): void {
    const win = this.getWindow(windowId);
    if (!win) {
      return;
    }
    try {
      const snapshot = WindowManager.readWindowRectSnapshot(win);
      if (!snapshot) {
        return;
      }
      const wrapped: WindowRectEventWrap = {
        windowId,
        reason: window.RectChangeReason.UNDEFINED,
        rect: snapshot.rect,
        drawable: snapshot.drawable,
      };
      this.throttledRectDispatch(
        windowId,
        wrapped,
        (w: object) => {
          this.rectChangeCallback?.(w as WindowRectEventWrap);
        },
        "rect",
      );
      hilog.info(
        DOMAIN,
        "WindowManager",
        "pushSyntheticRectChange %{public}d drawable=%{public}s",
        windowId,
        JSON.stringify(snapshot.drawable),
      );
    } catch (e) {
      hilog.warn(
        DOMAIN,
        "WindowManager",
        "pushSyntheticRectChange %{public}d failed: %{public}s",
        windowId,
        String(e),
      );
    }
  }

  setWindowBackgroundColor(windowId: number, color: number): void {
    const colorStr = "#" + color.toString(16).padStart(8, "0");
    hilog.info(
      DOMAIN,
      "WindowManager",
      `setWindowBackgroundColor: windowId=%{public}d, color=%{public}s`,
      windowId,
      colorStr,
    );
    // UIAbility main windows (first id=0 or subsequent id>0): set on the stage's main window
    if (this.isUIAbilityMainWindow(windowId)) {
      try {
        const mainWindow = this.getWindow(windowId);
        if (!mainWindow) {
          hilog.warn(
            DOMAIN,
            "WindowManager",
            `setWindowBackgroundColor: main window %{public}d not found`,
            windowId,
          );
          return;
        }
        mainWindow.setWindowBackgroundColor(colorStr);
        // NOTE: setWindowContainerColor is NOT called here — it controls the window
        // container layer (incl. title bar area) and is only set at creation time
        // (applyTransparentBackground). Calling it at runtime with the same color
        // for active+inactive overwrites the title bar. setWindowBackgroundColor
        // only affects the window background, not the container.
      } catch (e) {
        hilog.error(
          DOMAIN,
          "WindowManager",
          `Failed to set main window background: %{public}s`,
          String(e),
        );
      }
    } else {
      const entry = this.windows.get(windowId);
      if (entry?.window) {
        try {
          entry.window.setWindowBackgroundColor(colorStr);
        } catch (err) {
          hilog.error(
            DOMAIN,
            "WindowManager",
            `Sub-window %{public}d background failed: %{public}s`,
            windowId,
            String(err),
          );
        }
      }
    }
  }

  // Window vibrancy: apply blur to the WebView container.
  // Blur API selection (WebviewPlugin's BuildWebview):
  // - transparent=true (main window): `backgroundBlurStyle` — samples content behind the window
  // - transparent=false (opaque sub-windows): `backdropBlur` -- blurs in-surface pixels
  // The radius is persisted (WindowAttachmentRegistry) and consumed when the webview node
  // is built; a live webview is refreshed through the registered callback. HIS's reworded
  // one-liner also notes the native XComponent consumes the pending radius on attach
  // (fireSurfaceBlurRefresh below) — both facts live here now.
  applyWindowBlur(windowId: number, radius: number): void {
    // windowId arrives from Rust NAPI as i64 → BigInt (1n). Normalize to number
    // so it matches the ArkTS number keys used by the per-window Maps.
    const id = Number(windowId);
    hilog.info(
      DOMAIN,
      "WindowManager",
      "applyWindowBlur: ENTER rawWindowId=%{public}s id=%{public}d radius=%{public}f blurCbSize=%{public}d",
      String(windowId),
      id,
      radius,
      this.attachments.blurRefreshCallbackCount,
    );
    this.attachments.setBlurRadius(id, radius);
    this.attachments.fireBlurRefresh(id, radius);
    this.attachments.fireSurfaceBlurRefresh(id, radius);
  }

  /** Register a runtime blur refresh callback for a window (WebviewPlugin path). Called
   *  by WebviewSurface when a webview is created so later set-blur commands reach it. */
  registerBlurRefreshCallback(windowId: number, cb: (radius: number) => void): void {
    this.attachments.registerBlurRefreshCallback(windowId, cb);
  }

  unregisterBlurRefreshCallback(windowId: number): void {
    this.attachments.unregisterBlurRefreshCallback(windowId);
  }

  registerSurfaceBlurCallback(windowId: number, cb: (radius: number) => void): () => void {
    return this.attachments.registerSurfaceBlurCallback(windowId, cb);
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

  registerFocusChangeCallback(cb: (options: WindowFocusEventWrap) => void): void {
    this.focusChangeCallback = cb;
  }

  unregisterFocusChangeCallback(): void {
    this.focusChangeCallback = undefined;
  }

  registerAvoidAreaChangeCallback(cb: (options: WindowAvoidAreaEventWrap) => void): void {
    this.avoidAreaChangeCallback = cb;
  }

  unregisterAvoidAreaChangeCallback(): void {
    this.avoidAreaChangeCallback = undefined;
  }

  unregisterRectChangeCallback(): void {
    this.rectChangeCallback = undefined;
  }

  /**
   * Issue Eulogizethesun/tauri#97: synchronous drawableRect read for
   * rect-change wraps. One getWindowProperties() snapshot — the system's own
   * inner rect (position relative to the window, size = drawable area, px),
   * replacing the removed window-rect − content-rect decor estimate (whose
   * async races produced garbage values and the shrinking-window bug).
   * Returns undefined when the call throws (window not created / content not
   * loaded) or the rect is degenerate — callers omit the field and the Rust
   * side keeps its last snapshot. Never returns an estimated value.
   */
  static readDrawableRect(win: window.Window): window.Rect | undefined {
    try {
      const drawable = win.getWindowProperties().drawableRect;
      if (drawable.width > 0 && drawable.height > 0) {
        // Typed local first — object literals into a union return type are an
        // arkts-no-untyped-obj-literals compile risk.
        const rect: window.Rect = {
          left: drawable.left,
          top: drawable.top,
          width: drawable.width,
          height: drawable.height,
        };
        return rect;
      }
    } catch (e) {
      hilog.debug(
        DOMAIN,
        "WindowManager",
        "readDrawableRect: getWindowProperties unavailable: %{public}s",
        String(e),
      );
    }
    return undefined;
  }

  /**
   * Review R13: post-load seed snapshot — the WM (outer) rect AND the drawable
   * (inner) rect from one getWindowProperties() call, both field-copied (not
   * system object refs, per design.md D5). Returns undefined when the call
   * throws or EITHER rect is degenerate: a seed must never plant half a pair
   * (that is exactly the torn state the Rust side's pair-in/pair-out contract
   * rejects — see set_window_rects), so callers skip the seed entirely and the
   * pre-event fallback stays. Never returns an estimated value.
   */
  static readWindowRectSnapshot(win: window.Window): WindowRectSnapshot | undefined {
    try {
      const props = win.getWindowProperties();
      const outer = props.windowRect;
      const drawable = props.drawableRect;
      if (outer.width > 0 && outer.height > 0 && drawable.width > 0 && drawable.height > 0) {
        const snapshot: WindowRectSnapshot = {
          rect: {
            left: outer.left,
            top: outer.top,
            width: outer.width,
            height: outer.height,
          },
          drawable: {
            left: drawable.left,
            top: drawable.top,
            width: drawable.width,
            height: drawable.height,
          },
        };
        return snapshot;
      }
    } catch (e) {
      hilog.debug(
        DOMAIN,
        "WindowManager",
        "readWindowRectSnapshot: getWindowProperties unavailable: %{public}s",
        String(e),
      );
    }
    return undefined;
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
  // Only non-main windows (windowId > 0 — sub-windows or spawned UIAbility instances)
  // are registered: the primary window (id=0) keeps the one-shot
  // primaryWebviewControllerCallback path unchanged (captured first-attach main
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

  unregisterComponentRoot(windowId: number): void {
    this.attachments.unregisterComponentRoot(windowId);
  }

  // Static facade over WindowAttachmentRegistry.onComponentRootRegistered (used by
  // WebviewPlugin to replay deferred webview creates — timing race: webview bridge
  // create arrives ~3ms after TSFN dispatch, but SubWindowPage.aboutToAppear which
  // registers the componentRoot takes ~69ms). Static so it works exactly as before.
  static onComponentRootRegistered(windowId: number, callback: () => void): void {
    WindowAttachmentRegistry.onComponentRootRegistered(windowId, callback);
  }

  // Get component root for a sub-window (called by WebviewSurface.create)
  getComponentRoot(windowId: number): FrameNode | undefined {
    return this.attachments.getComponentRoot(windowId);
  }

  // Clean up controller and UIContext only (used by DefaultXComponent aboutToDisappear)
  // Does not remove from windows Map (managed by SubWindowPage's destroyWindow path)
  removeControllerAndUIContext(windowId: number): void {
    this.attachments.removeControllerAndUIContext(windowId);
    hilog.info(
      DOMAIN,
      "WindowManager",
      "Controller and UIContext removed for windowId: %{public}d",
      windowId,
    );
  }

  // Apply per-webview clipboard / zoom-hotkey intercept flags for a window.
  // Called from WebviewPlugin.create (sub-window path) using payload.clipboard /
  // payload.zoomHotkeys. Undefined leaves the default (true = ArkWeb native).
  // Clearing happens in clearWindowState — the single cleanup sink reused by
  // both removeWindow and unregisterUIAbilityStage (review finding F4 folded
  // the list there) — do not clear per-webview (siblings share a window).
  // Cross-platform note: on OHOS `clipboard=false` blocks keyboard Ctrl+C/X/V (onKeyPreIme
  // swallows them), whereas on Windows (webview2) the `clipboard` property only gates JS
  // execCommand clipboard access, not keyboard. Sub-windows needing Ctrl+C must call
  // .enable_clipboard_access(). This matches the spec intent (see audit APPROVED WITH NOTES).
  // See ohos-webview-flag-clipboard / ohos-webview-flag-zoom-hotkeys specs.
  setWebviewFlags(
    windowId: number,
    clipboard?: boolean,
    zoomHotkeys?: boolean,
    win?: window.Window,
  ): void {
    // Record the WebView policy even for omitted flags. Preserve any policy
    // already configured by another WebView in this window.
    setClipboardEnabled(windowId, clipboard ?? isClipboardEnabled(windowId, win), win);
    setZoomHotkeysEnabled(windowId, zoomHotkeys ?? isZoomHotkeysEnabled(windowId, win), win);
  }

  // Remove window: clean up all per-window state to prevent memory leaks.
  // The shared cleanup list lives in clearWindowState (also used by
  // unregisterUIAbilityStage); this method additionally detaches the
  // window-registry-specific pieces (rect listener, entry).
  removeWindow(windowId: number): void {
    // HIS's close-listener detach (his close family): drop the registered
    // close-requested listener before the window goes away.
    this.removeCloseListener(windowId);
    hilog.info(DOMAIN, "WindowManager", `Removing window %{public}d from all maps`, windowId);
    // Phase 2 (design.md D3): detach this window's windowRectChange listener before
    // dropping the Window reference so the native side stops delivering rect changes
    // for a window that no longer exists (prevents post-destroy callbacks / leaks).
    const entry = this.windows.get(windowId);
    if (entry?.focusChangeHandler) {
      try {
        entry.window.off("windowEvent", entry.focusChangeHandler);
      } catch (error) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          "off windowEvent failed for %{public}d: %{public}s",
          windowId,
          String(error),
        );
      }
    }
    if (entry?.rectChangeHandler) {
      try {
        entry.window.off("windowRectChange", entry.rectChangeHandler);
      } catch (e) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          `off windowRectChange failed for %{public}d: %{public}s`,
          windowId,
          String(e),
        );
      }
    }
    // HIS's avoid-area detach (his #93): the sub-window avoidAreaChange
    // handler registered in initializeSubWindow must be explicitly off()'d —
    // it is not auto-removed with the window.
    if (entry?.avoidAreaChangeHandler) {
      try {
        entry.window.off("avoidAreaChange", entry.avoidAreaChangeHandler);
      } catch (error) {
        hilog.warn(
          DOMAIN,
          "WindowManager",
          "off avoidAreaChange failed for %{public}d: %{public}s",
          windowId,
          String(error),
        );
      }
    }
    // Clear user interaction tracking if this window was the last interacted one
    if (this.lastUserInteractedWindowId === windowId) {
      this.lastUserInteractedWindowId = -1;
      hilog.info(DOMAIN, "WindowManager", "Cleared lastUserInteractedWindowId (removed window)");
    }
    // Shared per-window state (kinds/attachments/op-queues/pre-maximize/throttle
    // /accelerator flags) — clearWindowState is the single cleanup sink.
    // Ordering (HIS's, required by the WeakMap-keyed sink): windows.delete
    // comes AFTER clearWindowState so the sink's getWindow(win)-keyed cleanup
    // (op queues / pre-maximize / fullscreen-restore states) can still resolve
    // this window's entry — ours' number-keyed form allowed delete-first, the
    // merged WeakMap form does not.
    this.clearWindowState(windowId);
    this.windows.delete(windowId);
    // Belt-and-braces (HIS): the per-window accelerator flags are cleared
    // unconditionally here too — clearWindowState's win-block skips them when
    // the window object is already unresolvable, and they are keyed by
    // windowId in the accelerator registry, not by the Window object.
    // removeWindow is the window-lifetime sink — not removeWebview
    // (per-webview), which would prematurely clear flags still in use by
    // sibling webviews in the same window.
    clearClipboardEnabled(windowId);
    clearZoomHotkeysEnabled(windowId);
  }
}
