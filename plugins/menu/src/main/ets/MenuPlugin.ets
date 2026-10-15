import { hilog } from "@kit.PerformanceAnalysisKit";
import { KeyCode } from "@kit.InputKit";
import web_webview from "@ohos.web.webview";
import {
  AsyncPluginBase,
  BridgeAcknowledgement,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  BridgeLifecycleEvent,
  BridgePluginContext,
  BridgePluginHookContext,
  DOMAIN,
  expectBridgeRequestType,
  isClipboardEnabled,
  isZoomHotkeysEnabled,
  setMenuBarPort,
  setMenuBarSlotBuilder,
  setPrimaryWebviewControllerCallback,
  WindowManager,
  type MenuBarPort,
  type MenuBarSlotProps,
} from "@ohos-rs/ability";
import { getAcceleratorMatcher } from "./accelerator_matcher";
import {
  MenuBarComponent,
  getMenuClickHandler,
  getMenuDataCallback,
  getMenuBarRecoverFn,
  isMenubarVisible,
  setMenuClickHandler,
  setMenuWillOpenHandler,
  setMenuBarRecoverFn,
  windowKeyForId,
} from "./MenuBarComponent";
import {
  MenuManager,
  PredefinedActionExecutor,
  getPredefinedActionExecutor,
  setPredefinedActionExecutor,
} from "./menu";
import type { AboutMetadataData, PredefinedType } from "./menu_types";

const SET_MENUBAR_REQUEST_TYPE = "ohos.menu.SetMenubarRequest";
const POPUP_REQUEST_TYPE = "ohos.menu.PopupRequest";
const SET_VISIBLE_REQUEST_TYPE = "ohos.menu.SetVisibleRequest";
const PREDEFINED_REQUEST_TYPE = "ohos.menu.PredefinedRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.menu.Acknowledgement";

/**
 * Menubar composition slot: renders MenuBarComponent into the core pages
 * (MainPage unconditionally, FloatPage under its desktop+decorations gate).
 * Registered at onInstall, before any page content loads.
 */
@Builder
function menuBarBuilder(props: MenuBarSlotProps) {
  MenuBarComponent({
    windowId: props.windowId,
    acceleratorMatcher: getAcceleratorMatcher(props.windowId),
  });
}

/**
 * Core → menu notification port. Implements the key handling that used to live
 * inline in MainPage/FloatPage onKeyPreIme, and resolves the fullscreen-driven
 * visibility notifications WindowManager/NativeAbility emit through
 * getMenuBarPort() into this package's MenuDataCallback registry.
 */
class CoreMenuBarPort implements MenuBarPort {
  onKeyPreIme(event: KeyEvent, windowId: number): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    const matcher = getAcceleratorMatcher(windowId);
    // Block native clipboard shortcuts when with_clipboard(false) (ohos-webview-flag-clipboard)
    if (matcher.matchesClipboardShortcut(event) && !isClipboardEnabled(windowId)) {
      return true;
    }
    // Block native zoom hotkeys when with_zoom_hotkeys(false) (ohos-webview-flag-zoom-hotkeys)
    if (matcher.matchesZoomShortcut(event) && !isZoomHotkeysEnabled(windowId)) {
      return true;
    }
    // Accelerator matching (non-clipboard shortcuts)
    if (matcher.matches(event)) {
      const matchedItem = matcher.getMatchedItem();
      if (matchedItem) {
        const handler = getMenuClickHandler(windowId);
        if (handler) {
          handler(matchedItem);
        }
      }
      return true;
    }
    // ESC to exit fullscreen / restore menubar. All fullscreen entry points
    // (window-API set_fullscreen AND predefined menu fullscreen) hide the
    // menubar via WindowManager.setFullscreen (macOS semantics), so the
    // menubar-invisible condition alone covers every case.
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE && !isMenubarVisible(windowId)) {
      const recoverFn = getMenuBarRecoverFn(windowId);
      if (recoverFn) {
        recoverFn();
      }
      return true;
    }
    return false;
  }

  onMenubarVisibility(windowId: number, visible: boolean): void {
    const cb = getMenuDataCallback(windowKeyForId(windowId));
    cb?.onMenubarVisible?.(visible);
  }

  onMenuShown(windowId: number, shown: boolean): void {
    const cb = getMenuDataCallback(windowKeyForId(windowId));
    cb?.onMenuShown?.(shown);
  }
}

interface SetMenubarRequest {
  jsonData: string;
  windowId: string;
}

interface PopupRequest {
  jsonData: string;
  x?: number;
  y?: number;
  windowId: string;
}

interface SetVisibleRequest {
  visible: boolean;
  windowId: string;
}

interface PredefinedRequest {
  action: string;
  windowId?: string;
}

/**
 * Menu bridge plugin for ArkTS.
 *
 * Routes menu bar and popup operations from the Rust `MenuClient` facade to
 * the existing MenuBarComponent callback registry and PredefinedActionExecutor
 * singleton. Replaces the legacy `onMenuRequest` callback path in
 * NativeAbility.setupMenuPopup.
 *
 * Beyond the bridge actions, this plugin owns the core-facing seams
 * (rs<->ets correspondence: `crates/plugin-menu` ↔ this package):
 *   - onInstall registers the menubar composition slot + notification port
 *     (see components/MenuBarSlot.ets in the core package).
 *   - onLifecycle("window-stage-create") runs the wiring that used to live in
 *     NativeAbility.setupMenuPopup (executor, MenuManager, click/recover
 *     handlers, about dialog, primary webview controller callback). It fires
 *     after BridgeHost.setWindowStage (context.getWindowStage() resolves) and
 *     before the pages load, matching the old ordering.
 *
 * Plugin ID: `ohos.menu`
 * Required contexts: ui-context (for popup positioning within the window)
 */
export class MenuPlugin extends AsyncPluginBase {
  readonly id = "ohos.menu";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];
  private menuManager: MenuManager | null = null;

  onInstall(_context: BridgePluginHookContext): void {
    setMenuBarSlotBuilder(wrapBuilder(menuBarBuilder));
    setMenuBarPort(new CoreMenuBarPort());
  }

  onDispose(): void {
    setMenuWillOpenHandler(null);
  }

  onLifecycle(event: BridgeLifecycleEvent, context: BridgePluginHookContext): void {
    if (event.kind !== "window-stage-create") {
      return;
    }
    try {
      this.setupMenuWiring(context);
    } catch (e) {
      hilog.error(DOMAIN, "MenuPlugin", "setupMenuWiring threw: %{public}s", String(e));
    }
  }

  /**
   * Menu wiring migrated verbatim from NativeAbility.setupMenuPopup. The
   * desktop probe + `__openharmony_ability_is_desktop__` AppStorage flag stay
   * in NativeAbility (they probe the native module, not the menu domain).
   */
  private setupMenuWiring(context: BridgePluginContext): void {
    setMenuWillOpenHandler((windowId: number): void => {
      if (!context.isActive()) {
        return;
      }
      try {
        context.invokeNativeSyncProcessWide("menu-open", "ohos.menu.MenuOpenEvent", "std.bool", {
          windowId: windowId === 0 ? "main" : String(windowId),
        });
      } catch (error) {
        hilog.warn(DOMAIN, "MenuPlugin", "menu-open forward failed: %{public}s", String(error));
      }
    });
    // Forward menubar item clicks / accelerator key presses to the Rust-side
    // plugin-menu bridge `menu-click` main-thread event (process-wide broadcast).
    // plugin-menu decodes MenuClickEvent (typeName "ohos.menu.MenuClickEvent"),
    // forwards over its MENU_EVENT_SENDER (registered by the menu backend) → the menu backend's
    // MENU_EVENT_CHANNEL → MenuEvent::send → frontend onEvent callback.
    // Previously this was `primaryModule.emitMenuEvent` — a legacy NAPI fn that
    // wrote to a dead sink (openharmony-ability's own MENU_EVENT_CHANNEL with no
    // consumer), so menubar clicks and accelerator fires silently dropped.
    const emitMenuEventFn: (menuId: string, windowId?: string) => void = (menuId, windowId) => {
      hilog.info(
        DOMAIN,
        "MenuPlugin",
        "emitMenuEventFn ENTER menuId=%{public}s windowId=%{public}s",
        menuId,
        windowId ?? "main",
      );
      try {
        // The context method injects this plugin's own id ("ohos.menu") —
        // identical to the BridgeHostRegistry.invokeNativeSyncProcessWide call
        // this replaced in NativeAbility.setupMenuPopup.
        context.invokeNativeSyncProcessWide("menu-click", "ohos.menu.MenuClickEvent", "std.bool", {
          menuId,
          windowId: windowId ?? "main",
        });
        hilog.info(DOMAIN, "MenuPlugin", "emitMenuEventFn forwarded menuId=%{public}s ok", menuId);
      } catch (e) {
        hilog.warn(DOMAIN, "MenuPlugin", "emitMenuEvent forward failed: %{public}s", String(e));
      }
    };

    const executor = new PredefinedActionExecutor((code: number) => {
      context.abilityContext.terminateSelf();
    });
    const mainWindow = context.getWindowStage().getMainWindowSync();
    executor.setWindow(mainWindow);
    executor.setContext(context.abilityContext);
    setPredefinedActionExecutor(executor);
    executor.setShowAboutFn((metadata: AboutMetadataData) => {
      const appName = metadata.name ?? "";
      const appVersion = metadata.version ?? "";
      const appCopyright = metadata.copyright ?? "";
      const appAuthors = metadata.authors?.join(", ") ?? "";
      const appComments = metadata.comments ?? "";
      const appWebsite = metadata.website ?? "";

      const lines: string[] = [];
      if (appName) lines.push(appName);
      if (appVersion) lines.push(`Version: ${appVersion}`);
      if (appCopyright) lines.push(appCopyright);
      if (appAuthors) lines.push(`Authors: ${appAuthors}`);
      if (appComments) lines.push(appComments);
      if (appWebsite) lines.push(appWebsite);
      const message = lines.join("\n");
      const title = appName || "About";

      try {
        const uiContext = mainWindow.getUIContext();
        uiContext.showAlertDialog({
          title: title,
          message: message,
          autoCancel: true,
          confirm: {
            value: "OK",
            action: () => {},
          },
        });
      } catch (e) {
        hilog.error(DOMAIN, "MenuPlugin", "Show about dialog failed: %{public}s", String(e));
      }
    });

    const menuManager = new MenuManager(executor, emitMenuEventFn);
    this.menuManager = menuManager;

    setMenuClickHandler(0, (item) => {
      hilog.info(
        DOMAIN,
        "MenuPlugin",
        "menuClickHandler invoked id=%{public}s type=%{public}s",
        item.id,
        item.type,
      );
      menuManager.handleItemClick(item, "main");
    });

    setMenuBarRecoverFn(0, () => {
      // Esc exit from predefined fullscreen: dual-path exit so the title bar /
      // Dock hover hidden on entry (WindowManager.setFullscreen desktop path)
      // are restored too. The internal recover() triggers
      // windowRectChange(RECOVER) → menubar restore (see on("windowRectChange")
      // in NativeAbility, which notifies this plugin's port).
      WindowManager.getInstance().setFullscreen(0, false);
    });

    setPrimaryWebviewControllerCallback((controller: ESObject) => {
      executor.setController(controller as web_webview.WebviewController);
    });

    // NOTE (issue #87 major-4): the legacy `primaryModule.onMenuRequest(...)`
    // registration that used to live in setupMenuPopup never executed — the Rust-side
    // on_menu_request stub discarded the callback (`let _ = callback`). All three
    // of its branches (menubar visibility / popup / menubar json) are served by
    // the MenuPlugin bridge actions set-menubar / popup / set-menubar-visible.
  }

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Menu bridge session is no longer active");
    }

    if (action === "set-menubar") {
      const request = expectBridgeRequestType(
        payload,
        "ohos.menu",
        action,
        SET_MENUBAR_REQUEST_TYPE,
      ) as SetMenubarRequest;
      if (typeof request.jsonData !== "string") {
        throw new Error("set-menubar.jsonData must be a string");
      }
      if (typeof request.windowId !== "string") {
        throw new Error("set-menubar.windowId must be a string");
      }
      const cb = getMenuDataCallback(request.windowId);
      if (!cb) {
        // No MenuBarComponent mounted for this window (e.g. a FloatPage
        // sub-window) or the menubar has not attached yet. Rejecting lets the
        // Rust MenuClient surface the failure instead of caching
        // MENU_HAS_CONTENT as success.
        throw new Error(
          `set-menubar: no menu callback registered for window '${request.windowId}'`,
        );
      }
      cb.onMenubarJson?.(request.jsonData);
      if (request.windowId !== "main") {
        const windowId = Number(request.windowId);
        if (Number.isSafeInteger(windowId) && windowId > 0) {
          setMenuClickHandler(windowId, (item) => {
            this.menuManager?.handleItemClick(item, request.windowId);
          });
        }
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "popup") {
      const request = expectBridgeRequestType(
        payload,
        "ohos.menu",
        action,
        POPUP_REQUEST_TYPE,
      ) as PopupRequest;
      hilog.info(
        DOMAIN,
        "MenuPlugin",
        "popup windowId=%{public}s x=%{public}d y=%{public}d jsonLen=%{public}d",
        request.windowId,
        request.x ?? 0,
        request.y ?? 0,
        request.jsonData.length,
      );
      if (typeof request.jsonData !== "string") {
        throw new Error("popup.jsonData must be a string");
      }
      if (typeof request.windowId !== "string") {
        throw new Error("popup.windowId must be a string");
      }
      const x = request.x ?? 0;
      const y = request.y ?? 0;
      const cb = getMenuDataCallback(request.windowId);
      if (!cb) {
        throw new Error(`popup: no menu callback registered for window '${request.windowId}'`);
      }
      cb.onMenuPopup?.(request.jsonData, x, y);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "set-menubar-visible") {
      const request = expectBridgeRequestType(
        payload,
        "ohos.menu",
        action,
        SET_VISIBLE_REQUEST_TYPE,
      ) as SetVisibleRequest;
      if (typeof request.visible !== "boolean") {
        throw new Error("set-menubar-visible.visible must be a boolean");
      }
      if (typeof request.windowId !== "string") {
        throw new Error("set-menubar-visible.windowId must be a string");
      }
      const cb = getMenuDataCallback(request.windowId);
      if (!cb) {
        throw new Error(
          `set-menubar-visible: no menu callback registered for window '${request.windowId}'`,
        );
      }
      cb.onMenubarVisible?.(request.visible);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "execute-predefined") {
      const request = expectBridgeRequestType(
        payload,
        "ohos.menu",
        action,
        PREDEFINED_REQUEST_TYPE,
      ) as PredefinedRequest;
      if (typeof request.action !== "string" || !request.action) {
        throw new Error("execute-predefined.action must be a non-empty string");
      }
      const executor = getPredefinedActionExecutor();
      if (!executor) {
        hilog.warn(
          DOMAIN,
          "MenuPlugin",
          "execute-predefined: PredefinedActionExecutor not initialized, action: %{public}s",
          request.action,
        );
        throw new Error("PredefinedActionExecutor not initialized");
      }
      const actionType = request.action as PredefinedType;
      // Window operations (minimize/hide/close) are deferred via WindowManager to
      // avoid racing with system foreground transitions, matching the legacy
      // ArkHelper.executePredefinedAction behavior.
      const WINDOW_OPERATIONS: PredefinedType[] = ["minimize", "hide", "close"];
      if (WINDOW_OPERATIONS.includes(actionType)) {
        hilog.info(DOMAIN, "MenuPlugin", "Deferring window operation '%{public}s'", request.action);
        const wm = WindowManager.getInstance();
        wm.setPendingAction(() => {
          executor.execute(actionType);
        });
      } else {
        executor.execute(actionType);
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    throw new Error(`Unsupported ohos.menu action '${action}'`);
  }
}
