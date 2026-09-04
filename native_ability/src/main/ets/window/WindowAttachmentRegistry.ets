import { UIContext } from '@kit.ArkUI';
import { FrameNode } from '@ohos.arkui.node';
import web_webview from '@ohos.web.webview';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DOMAIN } from '../helper/constants';

/**
 * Per-window attachment registry, extracted from WindowManager (issue #87 major-5).
 * Owns everything that attaches to a window AFTER creation and must be dropped when
 * the window goes away:
 * - raw attached WebviewControllers (WebviewPlugin.handleControllerAttached)
 * - UIContexts / component root FrameNodes
 * - vibrancy state (persistent blur radius + runtime refresh callbacks)
 * - deferred componentRoot callbacks (webview create racing FloatPage.aboutToAppear)
 *
 * WindowManager keeps facade methods for all of these; nothing outside the window/
 * module imports this class.
 */
export class WindowAttachmentRegistry {
  // Per-window *attached* raw WebviewController (keyed by windowId, sub-windows only).
  // Filled by WebviewPlugin.handleControllerAttached when onControllerAttached fires —
  // at that point data.controller is the live attached controller (runJavaScript works).
  // menu.getTargetController reads this map so Tray Copy/Cut resolve the sub-window's
  // controller instead of falling back to the one-shot main executor.controller.
  private webviewControllers: Map<number, web_webview.WebviewController> = new Map();
  private uiContexts: Map<number, UIContext> = new Map();
  // Per-window component root FrameNode (sub-window mode only). DefaultXComponent in
  // sub-window mode (no moduleName, windowId > 0) creates a root FrameNode and registers
  // it here so WebviewSurface.create can mount webviews into the correct window.
  private componentRoots: Map<number, FrameNode> = new Map();
  // Persistent per-window blur radius (set by applyWindowBlur, read by WebviewPlugin BuildWebview).
  private windowBlurRadii: Map<number, number> = new Map();
  // Runtime blur refresh callbacks registered by WebviewPlugin (one per windowId). When
  // applyWindowBlur is called AFTER a WebviewPlugin webview already exists, this fires
  // so the live Web component's backdropBlur is refreshed via node.update().
  private blurRefreshCallbacks: Map<number, (radius: number) => void> = new Map();
  // Callback registry for plugins that need to react to componentRoot registration.
  // Used by WebviewPlugin to replay deferred webview creates (timing race: webview
  // bridge create arrives ~3ms after TSFN dispatch, but FloatPage.aboutToAppear
  // which registers the componentRoot takes ~69ms).
  // Static: callable before the WindowManager singleton exists (the registry itself
  // needs no instance state for registration).
  private static pendingComponentRootCallbacks: Map<number, Array<() => void>> = new Map();

  static onComponentRootRegistered(windowId: number, callback: () => void): void {
    const list = WindowAttachmentRegistry.pendingComponentRootCallbacks.get(windowId) ?? [];
    list.push(callback);
    WindowAttachmentRegistry.pendingComponentRootCallbacks.set(windowId, list);
  }

  // ─── WebviewController (raw, attached) ───

  // Register the per-window *attached* raw WebviewController. Called from
  // WebviewPlugin.handleControllerAttached (onControllerAttached callback) — by then
  // the controller is attached to a live Web component and runJavaScript is usable.
  // Only sub-windows (windowId > 0) are registered: the main window (id=0) keeps the
  // one-shot primaryWebviewControllerCallback path unchanged (captured first-attach main
  // controller into executor.controller), so this map never diverges from main behavior.
  registerWebviewController(windowId: number, controller: web_webview.WebviewController): void {
    this.webviewControllers.set(windowId, controller);
    hilog.info(DOMAIN, 'WindowManager', 'WebviewController registered for window: %{public}d', windowId);
  }

  // Lookup for menu.getTargetController. Returns undefined for main window (id=0) and
  // any not-yet-attached sub-window — caller falls back to executor.controller.
  getWebviewController(windowId: number): web_webview.WebviewController | undefined {
    return this.webviewControllers.get(windowId);
  }

  // ─── UIContext / component root ───

  // Register UIContext (main window calls in aboutToAppear, sub-window calls after loadContent)
  registerUIContext(windowId: number, ctx: UIContext): void {
    hilog.info(DOMAIN, 'WindowManager', `UIContext registered for window: %{public}d`, windowId);
    this.uiContexts.set(windowId, ctx);
  }

  // Get UIContext for the specified window
  getUIContext(windowId: number): UIContext | undefined {
    return this.uiContexts.get(windowId);
  }

  // Register component root for a sub-window (called by DefaultXComponent sub-window mode)
  registerComponentRoot(windowId: number, root: FrameNode): void {
    hilog.info(DOMAIN, 'WindowManager', `Component root registered for window: %{public}d`, windowId);
    this.componentRoots.set(windowId, root);
    // Flush any pending callbacks registered by plugins (e.g. webview create deferred
    // due to timing race — webview bridge create arriving before FloatPage.aboutToAppear).
    this.flushPendingComponentRootCallbacks(windowId);
  }

  // Get component root for a sub-window (called by WebviewSurface.create)
  getComponentRoot(windowId: number): FrameNode | undefined {
    const root = this.componentRoots.get(windowId);
    hilog.info(DOMAIN, 'WindowManager', 'getComponentRoot windowId=%{public}d found=%{public}s', windowId, root !== undefined ? 'true' : 'false');
    return root;
  }

  private flushPendingComponentRootCallbacks(windowId: number): void {
    const callbacks = WindowAttachmentRegistry.pendingComponentRootCallbacks.get(windowId);
    if (callbacks === undefined || callbacks.length === 0) {
      return;
    }
    WindowAttachmentRegistry.pendingComponentRootCallbacks.delete(windowId);
    hilog.info(DOMAIN, 'WindowManager', 'Flushing %{public}d pending componentRoot callbacks for window %{public}d', callbacks.length, windowId);
    for (const cb of callbacks) {
      cb();
    }
  }

  // ─── Vibrancy (blur) ───

  // Persist the blur radius for a window; read by WebviewPlugin's BuildWebview at
  // webview creation time. Returns 0 if no blur was set.
  setBlurRadius(windowId: number, radius: number): void {
    this.windowBlurRadii.set(Number(windowId), radius);
  }

  getBlurRadius(windowId: number): number {
    return this.windowBlurRadii.get(Number(windowId)) ?? 0;
  }

  /** Register a runtime blur refresh callback for a window (WebviewPlugin path). Called
   *  by WebviewSurface when a webview is created so later set-blur commands reach it. */
  registerBlurRefreshCallback(windowId: number, cb: (radius: number) => void): void {
    this.blurRefreshCallbacks.set(Number(windowId), cb);
  }

  unregisterBlurRefreshCallback(windowId: number): void {
    this.blurRefreshCallbacks.delete(Number(windowId));
  }

  // Fire the registered refresh callback so a live webview's backdropBlur updates.
  fireBlurRefresh(windowId: number, radius: number): void {
    const refreshCb = this.blurRefreshCallbacks.get(Number(windowId));
    if (refreshCb) {
      hilog.info(DOMAIN, 'WindowManager', 'applyWindowBlur: blurRefreshCb FOUND, invoking id=%{public}d', windowId);
      try {
        refreshCb(radius);
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', 'applyWindowBlur refresh callback failed: %{public}s', String(e));
      }
    } else {
      hilog.warn(DOMAIN, 'WindowManager', 'applyWindowBlur: NO blurRefreshCb registered id=%{public}d (webview not created yet, or path mismatch)', windowId);
    }
  }

  // ─── Cleanup ───

  // Clean up controller and UIContext only (used by DefaultXComponent aboutToDisappear).
  // Does NOT clear blur state (persists for the window's lifetime) or pending
  // componentRoot callbacks (the window itself still exists).
  removeControllerAndUIContext(windowId: number): void {
    const wid = Number(windowId);
    this.webviewControllers.delete(wid);
    this.uiContexts.delete(wid);
    this.componentRoots.delete(wid);
  }

  // Drop ALL per-window attachment state. Called from WindowManager.clearWindowState
  // (single source of truth for both unregisterUIAbilityStage and removeWindow).
  clearWindow(windowId: number): void {
    const wid = Number(windowId);
    this.webviewControllers.delete(wid);
    this.uiContexts.delete(wid);
    this.componentRoots.delete(wid);
    this.windowBlurRadii.delete(wid);
    this.blurRefreshCallbacks.delete(wid);
    WindowAttachmentRegistry.pendingComponentRootCallbacks.delete(wid);
  }

  get blurRefreshCallbackCount(): number {
    return this.blurRefreshCallbacks.size;
  }
}
