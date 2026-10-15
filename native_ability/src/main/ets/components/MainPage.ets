import { DefaultXComponent } from "./DefaultXComponent";
import { Module } from "../ability/type";
import { getMenuBarPort, MenuBarSlotHost } from "./MenuBarSlot";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { DOMAIN, MAIN_WINDOW_ID } from "../helper/constants";
import { synthesizeDomKeyEvent } from "../helper/key_synthesis";
import { WindowManager } from "../window/WindowManager";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";
import { invokeNativeBackPressInterceptor } from "../runtime/BackPress";

export const RouteName = "NativeAbility";

@Entry({ routeName: RouteName, storage: LocalStorage.getShared() })
@Component
struct MainPage {
  @StorageProp("moduleName") moduleNames: string | string[] = "";
  // Subsequent UIAbility instances receive their windowId via LocalStorage
  @LocalStorageProp("windowId") windowId: number = MAIN_WINDOW_ID;

  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";

  @State private nativeModule: Module | null = null;
  @State private resolvedModuleName: string = "";

  async aboutToAppear(): Promise<void> {
    hilog.info(DOMAIN, "MainPage", "=== MainPage aboutToAppear START ===");
    hilog.info(DOMAIN, "MainPage", "Initializing MAIN WINDOW");

    const moduleName = NativeModuleLoader.resolveModuleNames(this.moduleNames)[0] ?? "";
    if (!moduleName) {
      hilog.error(DOMAIN, "MainPage", "moduleName is empty, cannot initialize main window");
      throw new Error("MainPage.moduleName is required for main window");
    }

    hilog.info(DOMAIN, "MainPage", "Resolved moduleName: %{public}s", moduleName);
    this.resolvedModuleName = moduleName;

    hilog.info(DOMAIN, "MainPage", "Loading native module: %{public}s", moduleName);
    this.nativeModule = await NativeModuleLoader.load(moduleName, this.loadMode);
    hilog.info(DOMAIN, "MainPage", "Native module loaded successfully");
  }

  onBackPress(): boolean {
    return invokeNativeBackPressInterceptor(this.resolvedModuleName);
  }

  build() {
    Stack() {
      Column() {
        // Menubar composition slot (menu plugin; MenuBarSlot.ets seam). The
        // host reads the slot live and mounts nothing until the plugin
        // registers it — menu plugins install after page construction
        // (ui-context requirement), so a construction-time snapshot would
        // never see the registration.
        MenuBarSlotHost({ windowId: this.windowId })
        Row() {
          Column() {
            if (this.resolvedModuleName !== "") {
              DefaultXComponent({ moduleName: this.resolvedModuleName, windowId: this.windowId });
            } else {
              Text("Loading Main Window...").fontSize(20).fontColor(Color.Gray);
            }
          }.width("100%")
        }
        .layoutWeight(1)
        .height("100%")
      }
      .width("100%")
      .height("100%")
      .backgroundColor(Color.Transparent)
      .onKeyPreIme((event: KeyEvent) => {
        // acceptingLifecycle-style guard: main's queue skeleton gates its lifecycle
        // fan-out on NativeAbility.acceptingLifecycle, which is private to the Ability
        // and unreachable from this page. The equivalent readiness signal here is the
        // loaded native module — never consume or forward key events before it exists,
        // so startup/teardown input falls through to the system untouched.
        if (this.nativeModule === null) {
          return false;
        }
        // Menu key handling — clipboard / zoom shortcut blocking per window
        // flags, accelerator dispatch, ESC fullscreen recover — lives in the
        // menu plugin's MenuBarPort implementation (MenuBarSlot.ets seam).
        // Consumed events never reach the synthesizer below.
        const menuPort = getMenuBarPort();
        if (menuPort !== null && menuPort.onKeyPreIme(event, this.windowId)) {
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
    .width("100%")
    .height("100%")
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
          hilog.warn(DOMAIN, "MainPage", "onTouch: WindowManager not ready: %{public}s", String(e));
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
    });
  }
}
