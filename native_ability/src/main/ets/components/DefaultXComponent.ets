import { NodeContent } from "@kit.ArkUI";
import display from '@ohos.display';
import {
  ArkHelper,
  StatusBarIconRgba,
  WebViewInitData as NativeWebViewInitData,
  WindowAvoidAreaInfo,
} from "../ability/type";
import { exit, objectAssign } from "../helper";
import { Loadable } from "../helper/loadable";
import { requestPermission } from "../helper/permission";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import {
  EmbeddedWebviewManager,
  RustWebviewNodeController,
  WebviewStyle,
  WebviewInitData,
} from "../webview/DefaultWebview";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WindowManager } from "../window/WindowManager";
import { createArkHelper } from "../ability/ArkHelper";
import {
  setAbilityContext,
  setHelperRef,
  helperRef,
  statusBarManager,
  emitter,
  BusinessError,
} from "../helper/StatusBarUtils";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY, MAIN_WINDOW_ID } from '../helper/constants';

export const RouteName = "NativeAbility";

import web_webview from '@ohos.web.webview';

export let primaryWebviewControllerCallback: ((controller: web_webview.WebviewController) => void) | null = null;

export function setPrimaryWebviewControllerCallback(cb: (controller: web_webview.WebviewController) => void): void {
  primaryWebviewControllerCallback = cb;
}

export function clearPrimaryWebviewControllerCallback(): void {
  primaryWebviewControllerCallback = null;
}

@Component
export struct DefaultXComponent {
  // Main window mode: moduleName is non-empty
  @Prop moduleName: string = "";
  // Sub-window mode: windowId is non-zero
  @Prop windowId: number = 0;

  private rootSlot = new NodeContent();
  private webviewController: RustWebviewNodeController | null = null;
  private nativeModule: ESObject;

  // Global ArkHelper instance (window-agnostic)
  private helper: ArkHelper = createArkHelper();

  // Check if this is the main window based on windowId
  private isMainWindow(): boolean {
    const result = this.windowId === MAIN_WINDOW_ID;
    hilog.info(DOMAIN, 'DefaultXComponent', 'isMainWindow() called: windowId=%{public}d, result=%{public}b', 
      this.windowId, result);
    return result;
  }

  // loadMode is read only once in aboutToAppear; no need for @StorageProp reactive binding
  private loadMode: "async" | "sync" = "async";

  aboutToDisappear(): void {
    hilog.info(DOMAIN, 'DefaultXComponent', 'aboutToDisappear for windowId: %{public}d', this.windowId);
    // Clean up this window's controller and UIContext from WindowManager
    try {
      const wm = WindowManager.getInstance();
      wm.removeControllerAndUIContext(this.windowId);
    } catch (e) {
      hilog.warn(DOMAIN, 'DefaultXComponent', 'aboutToDisappear cleanup failed: %{public}s', String(e));
    }
    this.webviewController = null;
  }

  async aboutToAppear(): Promise<void> {
    // Read loadMode once from AppStorage (avoids reactive re-render on AppStorage changes)
    this.loadMode = (AppStorage.get<string>("loadMode") as "async" | "sync") ?? "async";
    hilog.info(DOMAIN, 'DefaultXComponent', '=== aboutToAppear START ===');
    hilog.info(DOMAIN, 'DefaultXComponent', 'Props -> moduleName: "%{public}s", windowId: %{public}d',
      this.moduleName, this.windowId);

    setAbilityContext(this.getUIContext().getHostContext() as common.UIAbilityContext);
    // Only set helperRef for main window. Sub-windows (FloatPage) create their own
    // ArkHelper but must NOT overwrite the global helperRef, because:
    // - Rust's init_tray_tsfn() sets _onIconClick/_onMenuClick only on the main window's helper
    // - The statusBarManager PROXY callback reads helperRef to dispatch click events
    // - If a FloatPage overwrites helperRef, the PROXY reads a helper without NAPI callbacks
    if (this.isMainWindow()) {
      setHelperRef(this.helper);
    }

    try {
      // Register UIContext to WindowManager
      const uiCtx = this.getUIContext();
      if (uiCtx) {
        try {
          const wm = WindowManager.getInstance();
          wm.registerUIContext(this.windowId, uiCtx);
          hilog.info(DOMAIN, 'DefaultXComponent', 'UIContext registered for window %{public}d', this.windowId);
        } catch (e) {
          hilog.error(DOMAIN, 'DefaultXComponent', 'Failed to register UIContext: %{public}s', JSON.stringify(e));
        }
      }

      // Initialize webviewController
      this.webviewController = new RustWebviewNodeController(uiCtx);
      hilog.info(DOMAIN, 'DefaultXComponent', 'RustWebviewNodeController created');

      if (this.isMainWindow()) {
        // Main window mode: call render to set up helper and XComponent
        hilog.info(DOMAIN, 'DefaultXComponent', 'Entering MAIN WINDOW logic');
        const moduleName = this.moduleName.trim();
        if (!moduleName) {
          hilog.error(DOMAIN, 'DefaultXComponent', 'moduleName is empty, cannot initialize main window');
          throw new Error("DefaultXComponent.moduleName is required for main window");
        }

        hilog.info(DOMAIN, 'DefaultXComponent', 'Loading native module: %{public}s', moduleName);
        this.nativeModule = await Loadable.load(moduleName, this.loadMode);
        hilog.info(DOMAIN, 'DefaultXComponent', 'Native module loaded, calling render()');

        // Store NAPI module reference in AppStorage so ArkHelper can access
        // notifyWindowClose() for proper sub-window close lifecycle.
        // All windows share the same native module loaded from the .so,
        // so multiple XComponent creations just overwrite with the same reference.
        AppStorage.setOrCreate<ESObject>(NATIVE_MODULE_STORAGE_KEY, this.nativeModule);

        this.nativeModule.render(this.helper, this.rootSlot);
        hilog.info(DOMAIN, 'DefaultXComponent', 'render() completed');

        // Register main window to WindowManager (id=0)
        try {
          const wm = WindowManager.getInstance();
          wm.registerController(MAIN_WINDOW_ID, this.webviewController);
          hilog.info(DOMAIN, 'DefaultXComponent', 'Main window registered to WindowManager with id=%{public}d', MAIN_WINDOW_ID);
        } catch (err) {
          hilog.warn(DOMAIN, 'DefaultXComponent', 'Failed to register main window to WindowManager: %{public}s',
            JSON.stringify(err));
        }
      } else {
        // Sub-window mode: register to WindowManager
        hilog.info(DOMAIN, 'DefaultXComponent', 'Entering SUB WINDOW logic');
        if (this.windowId === MAIN_WINDOW_ID) {
          hilog.error(DOMAIN, 'DefaultXComponent', 'windowId is MAIN_WINDOW_ID but not main window, this should not happen');
          return;
        }

        hilog.info(DOMAIN, 'DefaultXComponent', 'Registering sub-window controller with id: %{public}d', this.windowId);
        const wm = WindowManager.getInstance();
        wm.registerController(this.windowId, this.webviewController);
        hilog.info(DOMAIN, 'DefaultXComponent', 'Sub-window controller registered');
      }
    } catch (err) {
      hilog.error(DOMAIN, 'DefaultXComponent', 'aboutToAppear FAILED: %{public}s', JSON.stringify(err));
      throw err;
    }
  }

  build() {
    Stack() {
      ContentSlot(this.rootSlot)
      Row() {
        Column() {
          NodeContainer(this.webviewController)
            .height("100%")
            .width("100%")
        }
        .width("100%")
        .backgroundColor(Color.Transparent)
      }
      .height("100%")
      .backgroundColor(Color.Transparent)
    }
    .backgroundColor(Color.Transparent);
  }
}
