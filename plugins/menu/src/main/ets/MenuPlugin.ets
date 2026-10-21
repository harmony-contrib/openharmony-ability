import { hilog } from "@kit.PerformanceAnalysisKit";
import { KeyCode } from "@kit.InputKit";
import web_webview from "@ohos.web.webview";
import { window } from "@kit.ArkUI";
import { common } from "@kit.AbilityKit";
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
  hasWebviewKeyboardPolicy,
  menuKeyForWindow,
  registerWindowMenuBar,
  getMenuBarPort,
  setPrimaryWebviewControllerCallback,
  WindowManager,
  type MenuBarPort,
  type MenuBarSlotProps,
} from "@ohos-rs/ability";
import { getAcceleratorMatcher, resetAcceleratorModifiers } from "./accelerator_matcher";
import {
  MenuBarComponent,
  getMenuClickHandler,
  getMenuDataCallback,
  type MenuDataCallback,
  waitForMenuDataCallback,
  cancelMenuDataWaiters,
  getMenuBarRecoverFn,
  isMenubarVisible,
  setMenuClickHandler,
  setMenuWillOpenHandler,
  setMenuBarRecoverFn,
  unregisterMenuClickHandler,
  unregisterMenuBarRecoverFn,
  windowKeyForId,
} from "./MenuBarComponent";
import { MenuManager, PredefinedActionExecutor, registerWindowMenuExecutor } from "./menu";
import type { AboutMetadataData, MenuItemData, PredefinedType } from "./menu_types";

const SET_MENUBAR_REQUEST_TYPE = "ohos.menu.SetMenubarRequest";
const POPUP_REQUEST_TYPE = "ohos.menu.PopupRequest";
const POPUP_MENUBAR_REQUEST_TYPE = "ohos.menu.PopupMenubarRequest";
const POPUP_COMMANDS_REQUEST_TYPE = "ohos.menu.PopupCommandsRequest";
const SET_VISIBLE_REQUEST_TYPE = "ohos.menu.SetVisibleRequest";
const PREDEFINED_REQUEST_TYPE = "ohos.menu.PredefinedRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.menu.Acknowledgement";

interface MenuCommandItem {
  id: string;
  text: string;
  enabled: boolean;
}

interface PopupCommandsRequest {
  windowId: string;
  items: MenuCommandItem[];
  x: number;
  y: number;
  restoreFocusId?: string;
}

/**
 * Menubar composition slot: renders MenuBarComponent into the core pages
 * (MainPage, native FloatPage windows, and decorated desktop WebView windows).
 * Registered at onInstall, before any page content loads.
 */
@Builder
function menuBarBuilder(props: MenuBarSlotProps) {
  MenuBarComponent({
    windowId: props.windowId,
    menuKey: props.menuKey ?? "",
    acceleratorMatcher: getAcceleratorMatcher(props.menuKey ?? props.windowId),
    showMenuBar: true,
  });
}

@Builder
function menuPopupBuilder(props: MenuBarSlotProps) {
  MenuBarComponent({
    windowId: props.windowId,
    menuKey: props.menuKey ?? "",
    acceleratorMatcher: getAcceleratorMatcher(props.menuKey ?? props.windowId),
    showMenuBar: false,
  });
}

/**
 * Core → menu notification port. Implements the key handling that used to live
 * inline in MainPage/FloatPage onKeyPreIme, and resolves the fullscreen-driven
 * visibility notifications WindowManager/NativeAbility emit through
 * getMenuBarPort() into this package's MenuDataCallback registry.
 */
class CoreMenuBarPort implements MenuBarPort {
  onHostDisappear?: () => void;
  private readonly handleKeyboardShortcuts: boolean;
  private readonly menuKey: string;
  private readonly win: window.Window;

  constructor(handleKeyboardShortcuts: boolean, menuKey: string, win: window.Window) {
    this.handleKeyboardShortcuts = handleKeyboardShortcuts;
    this.menuKey = menuKey;
    this.win = win;
  }

  onKeyPreIme(event: KeyEvent, windowId: number): boolean {
    if (!this.handleKeyboardShortcuts) {
      return false;
    }
    const matcher = getAcceleratorMatcher(this.menuKey);
    matcher.trackModifiers(event);
    if (event.type !== KeyType.Down) {
      return false;
    }
    // WebView restrictions precede application accelerators. Native windows
    // have no WebView policy, so their registered clipboard actions work too.
    if (hasWebviewKeyboardPolicy(windowId, this.win)) {
      if (matcher.matchesClipboardShortcut(event) && !isClipboardEnabled(windowId, this.win)) {
        return true;
      }
      if (matcher.matchesZoomShortcut(event) && !isZoomHotkeysEnabled(windowId, this.win)) {
        return true;
      }
      // Let ArkWeb handle ordinary editing shortcuts, including undo/redo.
      if (matcher.matchesNativeClipboardShortcut(event)) {
        return false;
      }
    }
    if (matcher.matches(event)) {
      const matchedItem = matcher.getMatchedItem();
      if (matchedItem) {
        const handler = getMenuClickHandler(this.menuKey);
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
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE && !isMenubarVisible(this.menuKey)) {
      const recoverFn = getMenuBarRecoverFn(this.menuKey);
      if (recoverFn) {
        recoverFn();
      }
      return true;
    }
    return false;
  }

  onMenubarVisibility(windowId: number, visible: boolean): void {
    const cb = getMenuDataCallback(this.menuKey);
    cb?.onMenubarVisible?.(visible);
  }

  onMenuShown(windowId: number, shown: boolean): void {
    const cb = getMenuDataCallback(this.menuKey);
    cb?.onMenuShown?.(shown);
  }

  onWindowFocusLost(windowId: number): void {
    resetAcceleratorModifiers(this.menuKey);
  }
}

interface SetMenubarRequest {
  jsonData: string;
  windowId: string;
}

export interface MenuPluginOptions {
  /** Disable when the native renderer resolves shortcuts using its own focus context. */
  handleKeyboardShortcuts?: boolean;
  /** Hide the menu row when the application provides its own native-menu trigger. */
  showMenuBar?: boolean;
}

interface PopupMenubarRequest {
  windowId: string;
  menuName?: string;
  x: number;
  y: number;
  restoreFocusId?: string;
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

interface WindowMenuBinding {
  key: string;
  window: window.Window;
  port: MenuBarPort;
  release: () => boolean;
  executor: PredefinedActionExecutor;
  releaseExecutor: () => void;
  releaseController: () => void;
}

/** Window-owned menu UI and instance-scoped native callbacks. */
export class MenuPlugin extends AsyncPluginBase {
  readonly id = "ohos.menu";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];
  private readonly bindings: Map<string, WindowMenuBinding> = new Map();
  private readonly options: MenuPluginOptions;
  private ownerContext?: BridgePluginContext;

  constructor(options: MenuPluginOptions = {}) {
    super();
    this.options = {
      showMenuBar: options.showMenuBar ?? true,
      handleKeyboardShortcuts: options.handleKeyboardShortcuts ?? true,
    };
  }

  onInstall(context: BridgePluginHookContext): void {
    this.ownerContext = context;
    this.bindWindow(0, context.getWindow(), context);
  }

  onDispose(): void {
    for (const binding of this.bindings.values()) {
      this.releaseBinding(binding);
    }
    this.bindings.clear();
    this.ownerContext = undefined;
  }

  private releaseBinding(binding: WindowMenuBinding): void {
    binding.releaseController();
    binding.releaseExecutor();
    if (binding.release()) {
      cancelMenuDataWaiters(binding.key);
      setMenuWillOpenHandler(null, binding.key);
      unregisterMenuClickHandler(binding.key);
      unregisterMenuBarRecoverFn(binding.key);
    }
    if (this.bindings.get(binding.key) === binding) this.bindings.delete(binding.key);
  }

  onLifecycle(event: BridgeLifecycleEvent, context: BridgePluginHookContext): void {
    if (event.kind === "ui-context-destroy" || event.kind === "window-stage-destroy") {
      this.onDispose();
    } else if (event.kind === "ui-context-ready") {
      this.ownerContext = context;
      this.bindWindow(0, context.getWindow(), context);
    }
  }

  private resolveWindow(windowId: string, context: BridgePluginContext): window.Window {
    if (windowId === "main" || windowId === "0") return context.getWindow();
    const id = Number(windowId);
    const win =
      Number.isSafeInteger(id) && id > 0 ? WindowManager.getInstance().getWindow(id) : undefined;
    if (!win) throw new Error(`No menu window '${windowId}'`);
    return win;
  }

  private async menuCallback(
    windowId: string,
    context: BridgeCallContext,
  ): Promise<MenuDataCallback> {
    const win = this.resolveWindow(windowId, context);
    const binding = this.bindWindow(
      windowId === "main" ? 0 : Number(windowId),
      win,
      this.ownerContext ?? context,
    );
    const callback = await waitForMenuDataCallback(binding.key, context);
    if (!context.isActive() || context.isCancelled())
      throw new Error("Menu attachment was cancelled");
    if (getMenuBarPort(win) !== binding.port)
      throw new Error("Menu ownership changed before attachment");
    return callback;
  }

  private bindWindow(
    windowId: number,
    mainWindow: window.Window,
    context: BridgePluginContext,
  ): WindowMenuBinding {
    const key = menuKeyForWindow(mainWindow);
    const existing = this.bindings.get(key);
    if (existing?.window === mainWindow && getMenuBarPort(mainWindow) === existing.port)
      return existing;
    if (existing) this.releaseBinding(existing);
    setMenuWillOpenHandler((): void => {
      if (!context.isActive()) {
        return;
      }
      try {
        context.invokeNativeSync("menu-open", "ohos.menu.MenuOpenEvent", "std.bool", {
          windowId: windowId === 0 ? "main" : String(windowId),
        });
      } catch (error) {
        hilog.warn(DOMAIN, "MenuPlugin", "menu-open forward failed: %{public}s", String(error));
      }
    }, key);
    const emitMenuEventFn: (menuId: string, windowId?: string) => void = (menuId, windowId) => {
      hilog.info(
        DOMAIN,
        "MenuPlugin",
        "emitMenuEventFn ENTER menuId=%{public}s windowId=%{public}s",
        menuId,
        windowId ?? "main",
      );
      try {
        context.invokeNativeSync("menu-click", "ohos.menu.MenuClickEvent", "std.bool", {
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
    executor.setWindow(mainWindow);
    executor.setContext(mainWindow.getUIContext().getHostContext() as common.UIAbilityContext);
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

    setMenuClickHandler(key, (item) => {
      hilog.info(
        DOMAIN,
        "MenuPlugin",
        "menuClickHandler invoked id=%{public}s type=%{public}s",
        item.id,
        item.type,
      );
      if (context.isActive()) menuManager.handleItemClick(item, windowKeyForId(windowId));
    });

    setMenuBarRecoverFn(key, () => {
      // Esc exit from predefined fullscreen: dual-path exit so the title bar /
      // Dock hover hidden on entry (WindowManager.setFullscreen desktop path)
      // are restored too. The internal recover() triggers
      // windowRectChange(RECOVER) → menubar restore (see on("windowRectChange")
      // in NativeAbility, which notifies this plugin's port).
      WindowManager.getInstance()
        .setFullscreenAsync(windowId, false, { window: mainWindow })
        .catch((error: Error): void => {
          hilog.warn(DOMAIN, "MenuPlugin", "Menu recover failed: %{public}s", String(error));
        });
    });

    const releaseController = setPrimaryWebviewControllerCallback((controller: ESObject) => {
      executor.setController(controller as web_webview.WebviewController);
    }, mainWindow);

    const port = new CoreMenuBarPort(this.options.handleKeyboardShortcuts ?? true, key, mainWindow);
    const binding: WindowMenuBinding = {
      key,
      window: mainWindow,
      port,
      executor,
      releaseController,
      releaseExecutor: registerWindowMenuExecutor(mainWindow, executor),
      release: registerWindowMenuBar(
        mainWindow,
        this.options.showMenuBar ? wrapBuilder(menuBarBuilder) : wrapBuilder(menuPopupBuilder),
        port,
        windowId,
      ),
    };
    port.onHostDisappear = (): void => this.releaseBinding(binding);
    this.bindings.set(key, binding);
    return binding;
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
      const cb = await this.menuCallback(request.windowId, context);
      cb.onMenubarJson?.(request.jsonData);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "popup-menubar") {
      const request = expectBridgeRequestType(
        payload,
        "ohos.menu",
        action,
        POPUP_MENUBAR_REQUEST_TYPE,
      ) as PopupMenubarRequest;
      if (
        typeof request.windowId !== "string" ||
        request.windowId.length === 0 ||
        (request.menuName !== undefined && typeof request.menuName !== "string") ||
        (request.restoreFocusId !== undefined &&
          (typeof request.restoreFocusId !== "string" ||
            request.restoreFocusId.trim().length === 0)) ||
        typeof request.x !== "number" ||
        !Number.isFinite(request.x) ||
        typeof request.y !== "number" ||
        !Number.isFinite(request.y)
      ) {
        throw new Error("popup-menubar requires a window, optional menu name and finite position");
      }
      const callback = (await this.menuCallback(request.windowId, context)).onApplicationMenu;
      if (!callback) {
        throw new Error(
          `popup-menubar: no menu callback registered for window '${request.windowId}'`,
        );
      }
      callback(request.menuName, request.x, request.y, request.restoreFocusId);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    if (action === "popup-commands") {
      const request = expectBridgeRequestType(
        payload,
        "ohos.menu",
        action,
        POPUP_COMMANDS_REQUEST_TYPE,
      ) as PopupCommandsRequest;
      const identifiers: Set<string> = new Set();
      if (
        !request ||
        typeof request.windowId !== "string" ||
        request.windowId.length === 0 ||
        (request.restoreFocusId !== undefined &&
          (typeof request.restoreFocusId !== "string" ||
            request.restoreFocusId.trim().length === 0)) ||
        typeof request.x !== "number" ||
        !Number.isFinite(request.x) ||
        request.x < 0 ||
        typeof request.y !== "number" ||
        !Number.isFinite(request.y) ||
        request.y < 0 ||
        !Array.isArray(request.items) ||
        request.items.length === 0 ||
        request.items.length > 128 ||
        request.items.some((item: MenuCommandItem): boolean => {
          if (
            !item ||
            typeof item.id !== "string" ||
            item.id.trim().length === 0 ||
            typeof item.text !== "string" ||
            item.text.trim().length === 0 ||
            typeof item.enabled !== "boolean" ||
            identifiers.has(item.id)
          ) {
            return true;
          }
          identifiers.add(item.id);
          return false;
        })
      ) {
        throw new Error("Invalid command menu window, items or position");
      }
      const callback = (await this.menuCallback(request.windowId, context)).onMenuCommands;
      if (!callback) {
        throw new Error(
          `popup-commands: no menu callback registered for window '${request.windowId}'`,
        );
      }
      const items = request.items.map(
        (item: MenuCommandItem): MenuItemData => ({
          id: item.id,
          type: "item",
          text: item.text,
          enabled: item.enabled,
        }),
      );
      callback(items, request.x, request.y, request.restoreFocusId);
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
      const cb = await this.menuCallback(request.windowId, context);
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
      const cb = await this.menuCallback(request.windowId, context);
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
      const windowId = request.windowId ?? "main";
      const executor = this.bindWindow(
        windowId === "main" ? 0 : Number(windowId),
        this.resolveWindow(windowId, context),
        this.ownerContext ?? context,
      ).executor;
      const actionType = request.action as PredefinedType;
      await executor.execute(actionType, undefined, windowId === "main" ? 0 : Number(windowId));
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    throw new Error(`Unsupported ohos.menu action '${action}'`);
  }
}
