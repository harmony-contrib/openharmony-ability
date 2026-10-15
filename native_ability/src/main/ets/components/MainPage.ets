import { DefaultXComponent } from "./DefaultXComponent";
import { Module } from "../ability/type";
import { Loadable } from "../helper/loadable";
import {
  AcceleratorMatcher,
  isClipboardEnabled,
  isZoomHotkeysEnabled,
} from "../helper/accelerator_matcher";
import {
  MenuBarComponent,
  getMenuClickHandler,
  getMenuBarRecoverFn,
  isMenubarVisible,
} from "./MenuBarComponent";
import { KeyCode } from "@kit.InputKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { DOMAIN, MAIN_WINDOW_ID } from "../helper/constants";
import { synthesizeDomKeyEvent, isWebFocused } from "../helper/key_synthesis";
import { WindowManager } from "../window/WindowManager";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";
import { invokeNativeBackPressInterceptor } from "../runtime/BackPress";

export const RouteName = "NativeAbility";

@Entry({ routeName: RouteName, storage: LocalStorage.getShared() })
@Component
struct MainPage {
  @StorageProp("moduleName") moduleNames: string | string[] = "";
  // Subsequent UIAbility instances receive their windowId via LocalStorage
  @LocalStorageProp('windowId') windowId: number = MAIN_WINDOW_ID;
  // Bridge session id (design.md D6/D12): the primary instance's own session,
  // or the shared session id for a joined spawned instance. Delivered through
  // the per-instance LocalStorage built in NativeAbility.loadWindowStageContent
  // — NOT AppStorage, which is a process-global single value a spawned
  // instance would overwrite mid-attachment. Passed down to
  // DefaultXComponent as a plain @Prop.
  @LocalStorageProp('bridgeSessionId') bridgeSessionId: string = "";

  private loadMode: "async" | "sync" = "async";

  @State private nativeModule: Module | null = null;
  @State private resolvedModuleName: string = "";

  private acceleratorMatcher: AcceleratorMatcher = new AcceleratorMatcher();

  async aboutToAppear(): Promise<void> {
    hilog.info(DOMAIN, "MainPage", "=== MainPage aboutToAppear START ===");
    this.loadMode = (AppStorage.get<string>("loadMode") as "async" | "sync") ?? "async";
    hilog.info(DOMAIN, "MainPage", "Initializing MAIN WINDOW");

    const moduleName = Loadable.resolvePrimaryModuleName(this.moduleNames);
    if (!moduleName) {
      hilog.error(DOMAIN, "MainPage", "moduleName is empty, cannot initialize main window");
      throw new Error("MainPage.moduleName is required for main window");
    }

    hilog.info(DOMAIN, "MainPage", "Resolved moduleName: %{public}s", moduleName);
    this.resolvedModuleName = moduleName;

    hilog.info(DOMAIN, "MainPage", "Loading native module: %{public}s", moduleName);
    this.nativeModule = await Loadable.load(moduleName, this.loadMode);
    hilog.info(DOMAIN, "MainPage", "Native module loaded successfully");
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
      hilog.error(DOMAIN, "MainPage", "onBackPress failed: %{public}s", JSON.stringify(err));
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
              DefaultXComponent({
                moduleName: this.resolvedModuleName,
                windowId: this.windowId,
                bridgeSessionId: this.bridgeSessionId,
              })
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
        // Track modifier down/up for EVERY event (issue #111 residue root
        // cause, 2026-09-22 device finding): every matcher branch below is
        // KeyType.Down-gated, so modifier KEYUP events never reached
        // AcceleratorMatcher.trackModifiers — a released Ctrl left the
        // module-level bit stuck indefinitely (device: bare J still assembled
        // "ctrl+j" 2min15s after the only Ctrl press; menu-close handoff lost
        // the keyup 3/3 with real keyboard). The menu sub-window's
        // Menu.onKeyEvent tracks both Down and Up, which is why the residue
        // only manifested once the keyup landed on a page handler.
        this.acceleratorMatcher.trackModifiers(event);
        // Block native clipboard shortcuts when with_clipboard(false) (ohos-webview-flag-clipboard)
        if (
          event.type === KeyType.Down &&
          this.acceleratorMatcher.matchesClipboardShortcut(event) &&
          !isClipboardEnabled(this.windowId)
        ) {
          return true;
        }
        // Block native zoom hotkeys when with_zoom_hotkeys(false) (ohos-webview-flag-zoom-hotkeys)
        if (
          event.type === KeyType.Down &&
          this.acceleratorMatcher.matchesZoomShortcut(event) &&
          !isZoomHotkeysEnabled(this.windowId)
        ) {
          return true;
        }
        // Accelerator matching (non-clipboard shortcuts)
        if (event.type === KeyType.Down && this.acceleratorMatcher.matches(event)) {
          const matchedItem = this.acceleratorMatcher.getMatchedItem();
          if (matchedItem) {
            const handler = getMenuClickHandler(this.windowId);
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
        if (
          event.type === KeyType.Down &&
          event.keyCode === KeyCode.KEYCODE_ESCAPE &&
          !isMenubarVisible(this.windowId)
        ) {
          const recoverFn = getMenuBarRecoverFn(this.windowId);
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
          // Rust-side key forward (issue Eulogizethesun/tauri#109): the NDK
          // XComponent key path never fires in webview apps (the render node
          // is not in the ArkUI focus chain — no focusable, Web grabs focus
          // on load and overlays it), so tao's WindowEvent::KeyboardInput was
          // dead. onKeyPreIme sees every key the web sees — feed them to Rust
          // through the same Event::Input dispatch the NDK path would have
          // used. Gated on Web focus: focused ⇒ NDK structurally silent ⇒ no
          // double dispatch; unfocused (menu bar / GL-style apps) ⇒ gate
          // closed ⇒ NDK path stays exclusive (and webview-less apps are
          // unchanged, per the key-synthesis spec). Same fall-through position
          // as the DOM synthesis — keys consumed by the interceptors above
          // are NOT forwarded (the shell already acted on them).
          if (
            isWebFocused(MAIN_WINDOW_ID) &&
            typeof this.nativeModule?.notifyKeyEvent === "function"
          ) {
            this.nativeModule.notifyKeyEvent(
              event.keyCode,
              event.type === KeyType.Down ? 0 : 1,
              event.deviceId,
            );
          }
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
