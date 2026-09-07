import { DefaultXComponent } from "./DefaultXComponent";
import { Module } from "../ability/type";
import { Loadable } from "../helper/loadable";
import { AcceleratorMatcher, isClipboardEnabled, isZoomHotkeysEnabled } from "../helper/accelerator_matcher";
import {
  MenuBarComponent,
  getMenuClickHandler,
  getMenuBarRecoverFn,
  isMenubarVisible,
} from "./MenuBarComponent";
import { KeyCode } from "@kit.InputKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DOMAIN, MAIN_WINDOW_ID } from '../helper/constants';
import { synthesizeDomKeyEvent } from '../helper/key_synthesis';
import { WindowManager } from '../window/WindowManager';
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";
import { invokeNativeBackPressInterceptor } from "../runtime/BackPress";

export const RouteName = "NativeAbility";

@Entry({ routeName: RouteName, storage: LocalStorage.getShared() })
@Component
struct MainPage {
  @StorageProp("moduleName") moduleNames: string | string[] = "";
  // Subsequent UIAbility instances receive their windowId via LocalStorage
  @LocalStorageProp('windowId') windowId: number = MAIN_WINDOW_ID;

  private loadMode: "async" | "sync" = "async";

  @State private nativeModule: Module | null = null;
  @State private resolvedModuleName: string = "";

  private acceleratorMatcher: AcceleratorMatcher = new AcceleratorMatcher();

  async aboutToAppear(): Promise<void> {
    hilog.info(DOMAIN, 'MainPage', '=== MainPage aboutToAppear START ===');
    this.loadMode = (AppStorage.get<string>("loadMode") as "async" | "sync") ?? "async";
    hilog.info(DOMAIN, 'MainPage', 'Initializing MAIN WINDOW');

    const moduleName = Loadable.resolvePrimaryModuleName(this.moduleNames);
    if (!moduleName) {
      hilog.error(DOMAIN, 'MainPage', 'moduleName is empty, cannot initialize main window');
      throw new Error("MainPage.moduleName is required for main window");
    }

    hilog.info(DOMAIN, 'MainPage', 'Resolved moduleName: %{public}s', moduleName);
    this.resolvedModuleName = moduleName;

    hilog.info(DOMAIN, 'MainPage', 'Loading native module: %{public}s', moduleName);
    this.nativeModule = await Loadable.load(moduleName, this.loadMode);
    hilog.info(DOMAIN, 'MainPage', 'Native module loaded successfully');
  }

  onBackPress(): boolean {
    try {
      if (typeof this.nativeModule?.onBackPressIntercept === "function") {
        return this.nativeModule.onBackPressIntercept();
      }
      if (typeof this.nativeModule?.on_back_press_intercept === "function") {
        return this.nativeModule.on_back_press_intercept();
      }
    } catch (err) {
      hilog.error(DOMAIN, 'MainPage', 'onBackPress failed: %{public}s', JSON.stringify(err));
    }
    return false;
  }

  build() {
    Stack() {
      Column() {
        MenuBarComponent({
          windowId: this.windowId,
          acceleratorMatcher: this.acceleratorMatcher,
        })

        Row() {
          Column() {
            if (this.resolvedModuleName !== "") {
              DefaultXComponent({ moduleName: this.resolvedModuleName, windowId: this.windowId })
            } else {
              Text("Loading Main Window...")
                .fontSize(20)
                .fontColor(Color.Gray)
            }
          }.width("100%")
        }.layoutWeight(1).height("100%")

      }.width("100%").height("100%")
      .backgroundColor(Color.Transparent)
      .onKeyPreIme((event: KeyEvent) => {
        // Block native clipboard shortcuts when with_clipboard(false) (ohos-webview-flag-clipboard)
        if (event.type === KeyType.Down && this.acceleratorMatcher.matchesClipboardShortcut(event) && !isClipboardEnabled(MAIN_WINDOW_ID)) {
          return true;
        }
        // Block native zoom hotkeys when with_zoom_hotkeys(false) (ohos-webview-flag-zoom-hotkeys)
        if (event.type === KeyType.Down && this.acceleratorMatcher.matchesZoomShortcut(event) && !isZoomHotkeysEnabled(MAIN_WINDOW_ID)) {
          return true;
        }
        // Accelerator matching (non-clipboard shortcuts)
        if (event.type === KeyType.Down && this.acceleratorMatcher.matches(event)) {
          const matchedItem = this.acceleratorMatcher.getMatchedItem();
          if (matchedItem) {
            const handler = getMenuClickHandler(MAIN_WINDOW_ID);
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
        if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE && !isMenubarVisible(MAIN_WINDOW_ID)) {
          const recoverFn = getMenuBarRecoverFn(MAIN_WINDOW_ID);
          if (recoverFn) {
            recoverFn();
          }
          return true;
        }
        // ohos-webview-key-synthesis: forward unconsumed pre-IME key events to
        // the DOM synthesizer (synthetic KeyboardEvents with key/code/repeat
        // dispatched into the webview; ArkWeb's degenerate native key events
        // are suppressed by the injected shim). Interceptor branches above
        // return early, so consumed accelerators never reach the page.
        //
        // Main window only: the suppression shim is injected solely into the
        // main window's webview (keySynthesisScripts, wid===0). Sub-UIAbility
        // instances (id>0) load this same MainPage but get no shim, so feeding
        // them the synthetic stream too would double key events (clean
        // synthetic + unsuppressed degenerate native). They keep the
        // pre-feature degradation, matching the ohos-platform-limitations spec.
        if (this.windowId === MAIN_WINDOW_ID) {
          synthesizeDomKeyEvent(event, this.windowId);
        }
        return false;
      })
    }
    .width('100%')
    .height('100%')
    // Extend content into system safe areas (status bar + navigation bar).
    // Without this, setWindowLayoutFullScreen(true) + white window background
    // causes a white bar at the bottom where the navigation bar area is not
    // covered by any component (ArkUI default safeArea avoidance).
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .backgroundColor(Color.Transparent)
    // Track user touch for tray menu window targeting (D8: migrated from DefaultXComponent).
    // ArkUI onTouch bubbles from child to parent, covering MenuBarComponent + webview + all children.
    // Note: Web component may internally consume some touch events (scroll/zoom).
    // If webview touch tracking is unreliable, add onTouch to DefaultXComponent as fallback.
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        try {
          WindowManager.getInstance().setUserInteractedWindow(this.windowId);
        } catch (e) {
          hilog.warn(DOMAIN, 'MainPage', 'onTouch: WindowManager not ready: %{public}s', String(e));
        }
      }
    })
    // Track mouse cursor position for cursor_position() API.
    // NDK DispatchMouseEvent doesn't fire when cursor is over WebView,
    // so we use ArkTS onMouse which bubbles from all children.
    .onMouse((event: MouseEvent) => {
      if (event.action === MouseAction.Move || event.action === MouseAction.Press) {
        try {
          if (typeof this.nativeModule?.updateCursorPosition === "function") {
            this.nativeModule.updateCursorPosition(event.x, event.y);
          }
        } catch (e) {
          // Silently ignore — cursor tracking is best-effort
        }
      }
    })
  }
}
