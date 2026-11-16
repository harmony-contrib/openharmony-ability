import { DefaultXComponent } from "./DefaultXComponent";
import { WindowTitleBar } from "./WindowTitleBar";
import { Module } from "../ability/type";
import { getMenuBarPort, MenuBarSlotHost } from "./MenuBarSlot";
import { pointer } from "@kit.InputKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { BusinessError, deviceInfo } from "@kit.BasicServicesKit";
import { window as arkWindow, CursorController } from "@kit.ArkUI";
import { display } from "@kit.ArkUI";
import { WindowManager } from "../window/WindowManager";
import { feedCursorFromMouse } from "../helper/cursor_feed";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from "../helper/constants";

// Wire contract: this value and notify_float_window_registered predate the
// #240 component-page rename and are intentionally unchanged - renaming
// either breaks @Entry route registration and the bridge handshake.
export const RouteName = "FloatWindow";

@Entry({ routeName: RouteName, storage: LocalStorage.getShared() })
@Component
struct SubWindowPage {
  // Receive windowId from WindowManager.createSubWindow
  @LocalStorageProp("windowId") windowId: number = 0;
  @LocalStorageProp("nativeModuleName") nativeModuleName: string = "";
  @LocalStorageProp("decorations") decorations: boolean = true;
  // D group: decoration button availability (all available by default). Written by WindowManager.setDecorationFlags.
  @LocalStorageProp("closable") closable: boolean = true;
  @LocalStorageProp("maximizable") maximizable: boolean = true;
  @LocalStorageProp("minimizable") minimizable: boolean = true;
  @LocalStorageProp("resizable") resizable: boolean = true;
  // Window title (set by setWindowTitle → LocalStorage 'title')
  @LocalStorageProp("title") title: string = "";
  @StorageProp("__openharmony_ability_is_desktop__") isDesktop: boolean = false;
  // Maximize toggle state (local UI state, not persisted)
  @State isMaximized: boolean = false;
  @State private windowFocused: boolean = true;

  // Window control
  private windowClass: arkWindow.Window | null = null;
  @State dpiScale: number = 1;
  private cursorController: CursorController | null = null;
  // Fix-variant m6: one-shot guard for the stale-HAR structured warn in
  // onWindowEvent below (#180 focus-notify fold).
  private focusNotifyWarned: boolean = false;

  // Resize tracking
  private startWidth: number = 0;
  private startHeight: number = 0;
  private currentWidth: number = 800;
  private currentHeight: number = 600;

  // Prevent double NAPI notification when window is closed via multiple paths
  private closeNotified: boolean = false;

  private onWindowStatusChange = (status: arkWindow.WindowStatusType): void => {
    // System/tao transitions drive the restore icon, including changes that did
    // not originate from the title-bar button.
    // Apps targeting API < 14 receive FULL_SCREEN for maximized windows. Both
    // states need the recover action and must disable floating drag/resize.
    this.isMaximized =
      status === arkWindow.WindowStatusType.MAXIMIZE ||
      status === arkWindow.WindowStatusType.FULL_SCREEN;
    const nativeModule: Module | undefined = AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
    if (nativeModule && typeof nativeModule.notifyWindowStatus === "function") {
      nativeModule.notifyWindowStatus(this.windowId, status);
    }
  };

  private onWindowEvent = (event: arkWindow.WindowEventType): void => {
    if (event === arkWindow.WindowEventType.WINDOW_ACTIVE) {
      this.windowFocused = true;
    } else if (event === arkWindow.WindowEventType.WINDOW_INACTIVE) {
      this.windowFocused = false;
    }
    // #180: sub-window focus transitions reach tao through the
    // PENDING_WINDOW_FOCUS queue (notifyWindowFocus -> event-loop drain
    // with edge dedup + paired-blur synthesis). The windowFocused state above
    // drives the title-bar visuals; this notify drives the Rust-side
    // Focused/Blurred events -- two consumers, one handler (E-batch fold).
    const nativeModule: Module | undefined = AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
    if (nativeModule && typeof nativeModule.notifyWindowFocus === "function") {
      if (event === arkWindow.WindowEventType.WINDOW_ACTIVE) {
        nativeModule.notifyWindowFocus(this.windowId, true);
      } else if (event === arkWindow.WindowEventType.WINDOW_INACTIVE) {
        nativeModule.notifyWindowFocus(this.windowId, false);
      }
    } else if (!this.focusNotifyWarned) {
      // Fix-variant m6: a stale HAR (native module without notifyWindowFocus)
      // used to silently drop focus transitions. One-time structured warn per
      // SubWindowPage instance instead.
      this.focusNotifyWarned = true;
      hilog.warn(
        DOMAIN,
        "SubWindowPage",
        "windowEvent dropped: native module notifyWindowFocus unavailable (stale HAR?): id=%{public}d",
        this.windowId,
      );
    }
  };

  private detachWindowListeners(): void {
    try {
      this.windowClass?.off("windowStatusChange", this.onWindowStatusChange);
    } catch (error) {
      hilog.warn(
        DOMAIN,
        "SubWindowPage",
        "Detach window status listener: %{public}s",
        String(error),
      );
    }
    try {
      this.windowClass?.off("windowEvent", this.onWindowEvent);
    } catch (error) {
      hilog.warn(
        DOMAIN,
        "SubWindowPage",
        "Detach window focus listener: %{public}s",
        String(error),
      );
    }
  }

  aboutToDisappear(): void {
    this.detachWindowListeners();
    // When the OHOS system close button destroys the sub-window,
    // neither the SubWindowPage x onClick nor the webview onCloseWindow fires.
    // aboutToDisappear is our last chance to notify Rust.
    if (this.closeNotified) {
      return;
    }
    const wm = WindowManager.getInstance();
    if (!wm.getWindow(this.windowId)) {
      // Window already removed by our own close paths — skip
      return;
    }
    hilog.info(
      DOMAIN,
      "SubWindowPage",
      "aboutToDisappear: system close detected for window %{public}d",
      this.windowId,
    );
    this.closeNotified = true;
    try {
      const nativeModule: Module | undefined = AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
      if (this.nativeModuleName && nativeModule?.notifyNativeWindowClose) {
        nativeModule.notifyNativeWindowClose(this.windowId);
      }
      if (nativeModule && typeof nativeModule.notifyWindowClose === "function") {
        nativeModule.notifyWindowClose(this.windowId);
        hilog.info(
          DOMAIN,
          "SubWindowPage",
          "Window %{public}d close notified via NAPI (system close)",
          this.windowId,
        );
      }
      wm.removeWindow(this.windowId);
    } catch (e) {
      hilog.error(
        DOMAIN,
        "SubWindowPage",
        "aboutToDisappear cleanup failed for window %{public}d: %{public}s",
        this.windowId,
        JSON.stringify(e),
      );
    }
  }

  private startMoveFromTitle(event: TouchEvent): void {
    if (event.type !== TouchType.Down || this.isMaximized || deviceInfo.sdkApiVersion < 14) {
      return;
    }
    try {
      this.windowClass?.startMoving()?.catch((err: BusinessError) => {
        hilog.warn(DOMAIN, "SubWindowPage", "startMoving failed: %{public}s", JSON.stringify(err));
      });
    } catch (err) {
      hilog.warn(DOMAIN, "SubWindowPage", "startMoving exception: %{public}s", String(err));
    }
  }

  aboutToAppear(): void {
    hilog.info(DOMAIN, "SubWindowPage", "=== SubWindowPage aboutToAppear START ===");
    hilog.info(DOMAIN, "SubWindowPage", "Received windowId: %{public}d", this.windowId);

    if (this.windowId <= 0) {
      hilog.error(
        DOMAIN,
        "SubWindowPage",
        "Invalid windowId: %{public}d. SubWindowPage requires windowId > 0.",
        this.windowId,
      );
      return;
    }

    try {
      const ui = this.getUIContext();
      const winName = ui.getWindowName();
      if (winName) {
        this.windowClass = arkWindow.findWindow(winName);
        if (this.windowClass) {
          try {
            const rect = this.windowClass.getGlobalRect();
            if (rect.width > 0) this.currentWidth = rect.width;
            if (rect.height > 0) this.currentHeight = rect.height;
            hilog.info(
              DOMAIN,
              "SubWindowPage",
              "Got windowClass: left=%{public}d, top=%{public}d, w=%{public}d, h=%{public}d",
              rect.left,
              rect.top,
              this.currentWidth,
              this.currentHeight,
            );
          } catch (e) {
            hilog.error(
              DOMAIN,
              "SubWindowPage",
              "Failed to get window rect: %{public}s",
              JSON.stringify(e),
            );
          }
          // 回灌系统窗口状态到 tao 镜像位(问题五 5.3)。
          // SubWindow 子窗口的 maximize/minimize/fullscreen 系统状态变化经
          // notifyWindowStatus NAPI 入队,runtime-wry drain 路由到对应 tao Window。
          // API 11+;不支持则静默降级。详见 doc/OHOS窗口遗留问题.md。
          try {
            this.windowClass.on("windowStatusChange", this.onWindowStatusChange);
            this.onWindowStatusChange(this.windowClass.getWindowStatus());
          } catch (e) {
            hilog.warn(
              DOMAIN,
              "SubWindowPage",
              "windowStatusChange registration failed: %{public}s",
              String(e),
            );
          }
          try {
            this.windowClass.on("windowEvent", this.onWindowEvent);
            this.windowFocused = this.windowClass.isFocused();
          } catch (error) {
            hilog.warn(
              DOMAIN,
              "SubWindowPage",
              "Window focus tracking failed: %{public}s",
              String(error),
            );
          }
        } else {
          hilog.error(
            DOMAIN,
            "SubWindowPage",
            "findWindow returned null for name: %{public}s",
            winName,
          );
        }
      }
    } catch (e) {
      hilog.error(
        DOMAIN,
        "SubWindowPage",
        "Failed to get windowClass: %{public}s",
        JSON.stringify(e),
      );
    }

    try {
      this.cursorController = this.getUIContext().getCursorController();
    } catch (e) {
      hilog.warn(
        DOMAIN,
        "SubWindowPage",
        "Failed to get CursorController: %{public}s",
        JSON.stringify(e),
      );
    }

    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      this.dpiScale = defaultDisplay.densityPixels;
      hilog.info(DOMAIN, "SubWindowPage", "Display densityPixels: %{public}f", this.dpiScale);
    } catch (e) {
      hilog.warn(
        DOMAIN,
        "SubWindowPage",
        "Failed to get display scale: %{public}s",
        JSON.stringify(e),
      );
    }
  }

  private minimizeWindow(): void {
    try {
      WindowManager.getInstance().minimizeWindow(this.windowId);
    } catch (error) {
      hilog.warn(DOMAIN, "SubWindowPage", "minimize failed: %{public}s", String(error));
    }
  }

  private toggleMaximize(): void {
    try {
      if (this.isMaximized) {
        // recover(), rather than the main-window-only restore(), returns a
        // maximized Float window to its saved floating bounds.
        WindowManager.getInstance().recoverWindow(this.windowId);
      } else {
        WindowManager.getInstance().maximizeWindow(this.windowId);
      }
      // The system status callback updates the icon after the operation succeeds.
    } catch (error) {
      hilog.warn(DOMAIN, "SubWindowPage", "maximize/restore failed: %{public}s", String(error));
    }
  }

  private async closeWindow(): Promise<void> {
    hilog.info(
      DOMAIN,
      "SubWindowPage",
      "Close button clicked for window %{public}d",
      this.windowId,
    );
    if (this.closeNotified) {
      return;
    }
    // Check closable flag BEFORE anything else (问题四: 拦截 API 执行路径)
    // Must be before notifyWindowClose — otherwise Rust triggers close event chain.
    if (!WindowManager.getInstance().getDecorationFlag(this.windowId, "closable")) {
      hilog.warn(
        DOMAIN,
        "SubWindowPage",
        "Close blocked: closable flag not set (window %{public}d)",
        this.windowId,
      );
      return;
    }
    if (WindowManager.getInstance().requestWindowClose(this.windowId)) {
      return;
    }
    this.closeNotified = true;
    try {
      // Notify Rust event loop before destroying the OHOS window,
      // so CloseRequested → Destroyed → WindowsStore cleanup can run.
      const nativeModule: Module | undefined = AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
      if (this.nativeModuleName && nativeModule?.notifyNativeWindowClose) {
        nativeModule.notifyNativeWindowClose(this.windowId);
      }
      if (nativeModule && typeof nativeModule.notifyWindowClose === "function") {
        nativeModule.notifyWindowClose(this.windowId);
        hilog.info(
          DOMAIN,
          "SubWindowPage",
          "Window %{public}d close notified via NAPI",
          this.windowId,
        );
      } else {
        hilog.warn(
          DOMAIN,
          "SubWindowPage",
          "NAPI notifyWindowClose not available for window %{public}d",
          this.windowId,
        );
      }

      // removeWindow BEFORE destroyWindow so that aboutToDisappear
      // sees the window as already handled (consistent with ArkHelper.onCloseWindow)
      WindowManager.getInstance().removeWindow(this.windowId);
      if (this.windowClass) {
        await this.windowClass.destroyWindow();
        hilog.info(
          DOMAIN,
          "SubWindowPage",
          "Window %{public}d destroyed and cleaned up",
          this.windowId,
        );
      }
    } catch (e) {
      hilog.error(
        DOMAIN,
        "SubWindowPage",
        "Failed to close window %{public}d: %{public}s",
        this.windowId,
        String(e),
      );
    }
  }

  build() {
    Stack() {
      Column() {
        // The floating window draws its own title controls. Keep them above the
        // menubar, matching the main window's system title bar and menubar order.
        // (E-batch graft: the gate widens to ours' `decorations || isDesktop` --
        // WindowTitleBar gates its own title/buttons on decorations and keeps
        // only the drag surface when they are off, which is ours' transparent
        // drag-bar behavior for undecorated desktop float windows.)
        if (this.windowClass && (this.decorations || this.isDesktop)) {
          WindowTitleBar({
            title: this.title,
            decorations: this.decorations,
            windowFocused: this.windowFocused,
            maximized: this.isMaximized,
            minimizable: this.minimizable,
            maximizable: this.maximizable,
            closable: this.closable,
            onDrag: (event: TouchEvent) => this.startMoveFromTitle(event),
            onMinimize: () => this.minimizeWindow(),
            onMaximize: () => this.toggleMaximize(),
            onClose: () => {
              this.closeWindow();
            },
          });
        }

        // Native windows need their own menu host and accelerator registry even
        // when the shared library was built for the mobile device class. The
        // menu host stays empty if the application has not supplied any menus.
        // Preserve the existing decoration gate for webview-only float windows.
        if (this.nativeModuleName.length > 0 || (this.isDesktop && this.decorations)) {
          MenuBarSlotHost({ windowId: this.windowId });
        }
        Stack() {
          DefaultXComponent({ moduleName: this.nativeModuleName, windowId: this.windowId })
            .width("100%")
            .height("100%")
        }
        .layoutWeight(1)
        .width("100%")
      }
      .width("100%")
      .height("100%")
      .backgroundColor(Color.Transparent)

      // Desktop resize handles remain available without decorations in floating mode.
      if (this.isDesktop && this.windowClass && this.resizable && !this.isMaximized) {
        // Right edge resize handle
        Row()
          .width(10)
          .height("100%")
          .position({ right: 0 })
          .backgroundColor(Color.Transparent)
          .onHover((isHover: boolean) => {
            if (isHover) {
              this.cursorController?.setCursor(pointer.PointerStyle.WEST_EAST);
            } else {
              this.cursorController?.restoreDefault();
            }
          })
          .gesture(
            PanGesture({ direction: PanDirection.Horizontal })
              .onActionStart(() => {
                this.startWidth = this.currentWidth;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (!this.windowClass) return;
                try {
                  this.currentWidth = Math.round(
                    Math.max(200, this.startWidth + event.offsetX * this.dpiScale),
                  );
                  this.windowClass.resize(this.currentWidth, this.currentHeight);
                } catch (e) {
                  hilog.error(
                    DOMAIN,
                    "SubWindowPage",
                    "Right resize failed: w=%{public}d, h=%{public}d, err=%{public}s",
                    this.currentWidth,
                    this.currentHeight,
                    JSON.stringify(e),
                  );
                }
              }),
          );

        // Bottom edge resize handle
        Row()
          .width("100%")
          .height(10)
          .position({ bottom: 0 })
          .backgroundColor(Color.Transparent)
          .onHover((isHover: boolean) => {
            if (isHover) {
              this.cursorController?.setCursor(pointer.PointerStyle.NORTH_SOUTH);
            } else {
              this.cursorController?.restoreDefault();
            }
          })
          .gesture(
            PanGesture({ direction: PanDirection.Vertical })
              .onActionStart(() => {
                this.startHeight = this.currentHeight;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (!this.windowClass) return;
                try {
                  this.currentHeight = Math.round(
                    Math.max(150, this.startHeight + event.offsetY * this.dpiScale),
                  );
                  this.windowClass.resize(this.currentWidth, this.currentHeight);
                } catch (e) {
                  hilog.error(
                    DOMAIN,
                    "SubWindowPage",
                    "Bottom resize failed: w=%{public}d, h=%{public}d, err=%{public}s",
                    this.currentWidth,
                    this.currentHeight,
                    JSON.stringify(e),
                  );
                }
              }),
          );

        // Bottom-right corner resize handle
        Row()
          .width(15)
          .height(15)
          .position({ right: 0, bottom: 0 })
          .backgroundColor(Color.Transparent)
          .onHover((isHover: boolean) => {
            if (isHover) {
              this.cursorController?.setCursor(pointer.PointerStyle.NORTH_WEST_SOUTH_EAST);
            } else {
              this.cursorController?.restoreDefault();
            }
          })
          .gesture(
            PanGesture({ direction: PanDirection.All })
              .onActionStart(() => {
                this.startWidth = this.currentWidth;
                this.startHeight = this.currentHeight;
              })
              .onActionUpdate((event: GestureEvent) => {
                if (!this.windowClass) return;
                try {
                  this.currentWidth = Math.round(
                    Math.max(200, this.startWidth + event.offsetX * this.dpiScale),
                  );
                  this.currentHeight = Math.round(
                    Math.max(150, this.startHeight + event.offsetY * this.dpiScale),
                  );
                  this.windowClass.resize(this.currentWidth, this.currentHeight);
                } catch (e) {
                  hilog.error(
                    DOMAIN,
                    "SubWindowPage",
                    "Corner resize failed: w=%{public}d, h=%{public}d, err=%{public}s",
                    this.currentWidth,
                    this.currentHeight,
                    JSON.stringify(e),
                  );
                }
              }),
          );
      }
    }
    .width("100%")
    .height("100%")
    .backgroundColor(Color.Transparent)
    .onKeyPreIme((event: KeyEvent) => {
      // Menu key handling — clipboard / zoom shortcut blocking per window
      // flags, accelerator dispatch, ESC fullscreen recover — lives in the
      // menu plugin's MenuBarPort implementation (MenuBarSlot.ets seam).
      const menuPort = getMenuBarPort(arkWindow.findWindow(this.getUIContext().getWindowName()));
      if (menuPort !== null && menuPort.onKeyPreIme(event, this.windowId)) {
        return true;
      }
      return false;
    })
    // Track user touch for tray menu window targeting (D8: migrated from DefaultXComponent).
    // ArkUI onTouch bubbles from child to parent, covering MenuBarComponent + webview + drag bars.
    // Note: Web component may internally consume some touch events (scroll/zoom).
    // If webview touch tracking is unreliable, add onTouch to DefaultXComponent as fallback.
    // onTouch does not compete with Gesture (PanGesture for drag/resize), confirmed by ArkUI docs.
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        try {
          WindowManager.getInstance().setUserInteractedWindow(this.windowId);
        } catch (e) {
          hilog.warn(
            DOMAIN,
            "SubWindowPage",
            "onTouch: WindowManager not ready: %{public}s",
            String(e),
          );
        }
      }
    })
    // ohos-cursor-passthrough 3.3 (root cause 1): feed the process cursor
    // snapshot from sub-windows too. This root-Stack onMouse sits at
    // the same layer as onKeyPreIme/onTouch above; ArkUI onMouse bubbles from
    // the whole subtree (WindowTitleBar + MenuBarSlotHost +
    // DefaultXComponent/webview + resize handles) -- the same mechanism
    // MainPage relies on in
    // production ("NDK DispatchMouseEvent doesn't fire over the WebView,
    // ArkTS onMouse bubbling works", tao event_loop.rs CURSOR_POSITION note).
    // Without this, a cursor over a sub-window left the snapshot at the
    // last main-window coordinate and the consumer's hit-test never matched
    // (ignore stayed true -> the toolbar was unclickable). R2 fallback bit:
    // if the webview ever stops bubbling mouse moves, add onMouse to
    // DefaultXComponent (same reserved-fallback shape as the onTouch note).
    // Move/Press guard mirrors MainPage (Release is never fed -- release-
    // instant coordinates are noise).
    .onMouse((event: MouseEvent) => {
      if (event.action === MouseAction.Move || event.action === MouseAction.Press) {
        // Module reference taken the same way as this page's other NAPI
        // calls (notifyWindowClose/notifyWindowStatus/notifyWindowFocus --
        // SubWindowPage.ets:88/166/175/216/418 pattern): AppStorage is safe
        // here because
        // ProcessInitializer.ets:193-195 seeds NATIVE_MODULE_STORAGE_KEY
        // during process init, before any page feed point can fire. The
        // helper deliberately takes the reference as a parameter -- it never
        // reads AppStorage itself (D2).
        const nativeModule: Module | undefined = AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
        feedCursorFromMouse(nativeModule, event);
      }
    });
  }
}
