import { DefaultXComponent } from "./DefaultXComponent";
import { Module } from "../ability/type";
import { getMenuBarPort, MenuBarSlotHost } from "./MenuBarSlot";
import { pointer } from "@kit.InputKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { BusinessError, deviceInfo } from "@kit.BasicServicesKit";
import { window as arkWindow, CursorController } from "@kit.ArkUI";
import { display } from "@kit.ArkUI";
import { WindowManager } from "../window/WindowManager";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from "../helper/constants";

export const RouteName = "FloatWindow";

interface Position {
  x: number;
  y: number;
}

@Entry({ routeName: RouteName, storage: LocalStorage.getShared() })
@Component
struct FloatPage {
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

  // Window control
  private windowClass: arkWindow.Window | null = null;
  @State @Watch("moveAndSetWindow") windowPosition: Position = { x: 100, y: 100 };
  @State dpiScale: number = 1;
  private cursorController: CursorController | null = null;

  // Resize tracking
  private startWidth: number = 0;
  private startHeight: number = 0;
  private currentWidth: number = 800;
  private currentHeight: number = 600;

  // Prevent double NAPI notification when window is closed via multiple paths
  private closeNotified: boolean = false;

  aboutToDisappear(): void {
    // When the OHOS system close button destroys the sub-window,
    // neither the FloatPage × onClick nor the webview onCloseWindow fires.
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
      "FloatPage",
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
          "FloatPage",
          "Window %{public}d close notified via NAPI (system close)",
          this.windowId,
        );
      }
      wm.removeWindow(this.windowId);
    } catch (e) {
      hilog.error(
        DOMAIN,
        "FloatPage",
        "aboutToDisappear cleanup failed for window %{public}d: %{public}s",
        this.windowId,
        JSON.stringify(e),
      );
    }
  }

  moveAndSetWindow() {
    this.windowClass?.moveWindowTo(this.windowPosition.x, this.windowPosition.y);
  }

  private startMoveFromTitle(event: TouchEvent): void {
    if (event.type !== TouchType.Down || this.isMaximized || deviceInfo.sdkApiVersion < 14) {
      return;
    }
    try {
      this.windowClass?.startMoving()?.catch((err: BusinessError) => {
        hilog.warn(DOMAIN, "FloatPage", "startMoving failed: %{public}s", JSON.stringify(err));
      });
    } catch (err) {
      hilog.warn(DOMAIN, "FloatPage", "startMoving exception: %{public}s", String(err));
    }
  }

  aboutToAppear(): void {
    hilog.info(DOMAIN, "FloatPage", "=== FloatPage aboutToAppear START ===");
    hilog.info(DOMAIN, "FloatPage", "Received windowId: %{public}d", this.windowId);

    if (this.windowId <= 0) {
      hilog.error(
        DOMAIN,
        "FloatPage",
        "Invalid windowId: %{public}d. FloatPage requires windowId > 0.",
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
            this.windowPosition = { x: rect.left, y: rect.top };
            if (rect.width > 0) this.currentWidth = rect.width;
            if (rect.height > 0) this.currentHeight = rect.height;
            hilog.info(
              DOMAIN,
              "FloatPage",
              "Got windowClass: left=%{public}d, top=%{public}d, w=%{public}d, h=%{public}d",
              rect.left,
              rect.top,
              this.currentWidth,
              this.currentHeight,
            );
          } catch (e) {
            hilog.error(
              DOMAIN,
              "FloatPage",
              "Failed to get window rect: %{public}s",
              JSON.stringify(e),
            );
          }
          // 回灌系统窗口状态到 tao 镜像位(问题五 5.3)。
          // Float 子窗口的 maximize/minimize/fullscreen 系统状态变化经
          // notifyWindowStatus NAPI 入队,runtime-wry drain 路由到对应 tao Window。
          // API 11+;不支持则静默降级。详见 doc/OHOS窗口遗留问题.md。
          try {
            this.windowClass.on("windowStatusChange", (statusType: arkWindow.WindowStatusType) => {
              // G9: drive the maximize/restore button icon from the actual system status,
              // so it stays in sync when maximize/restore is triggered by the system or by
              // the tao mirror (apply_window_status), not only on button click.
              this.isMaximized = statusType === arkWindow.WindowStatusType.MAXIMIZE;
              const nativeModule: Module | undefined =
                AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
              if (nativeModule && typeof nativeModule.notifyWindowStatus === "function") {
                nativeModule.notifyWindowStatus(this.windowId, statusType);
              }
            });
            // seed 初始态(同时驱动按钮图标 + NAPI 镜像位)。
            const initialStatus = this.windowClass.getWindowStatus();
            this.isMaximized = initialStatus === arkWindow.WindowStatusType.MAXIMIZE;
            const nativeModule: Module | undefined =
              AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
            if (nativeModule && typeof nativeModule.notifyWindowStatus === "function") {
              nativeModule.notifyWindowStatus(this.windowId, initialStatus);
            }
          } catch (e) {
            hilog.warn(
              DOMAIN,
              "FloatPage",
              "windowStatusChange registration failed: %{public}s",
              String(e),
            );
          }
        } else {
          hilog.error(
            DOMAIN,
            "FloatPage",
            "findWindow returned null for name: %{public}s",
            winName,
          );
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, "FloatPage", "Failed to get windowClass: %{public}s", JSON.stringify(e));
    }

    try {
      this.cursorController = this.getUIContext().getCursorController();
    } catch (e) {
      hilog.warn(
        DOMAIN,
        "FloatPage",
        "Failed to get CursorController: %{public}s",
        JSON.stringify(e),
      );
    }

    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      this.dpiScale = defaultDisplay.densityPixels;
      hilog.info(DOMAIN, "FloatPage", "Display densityPixels: %{public}f", this.dpiScale);
    } catch (e) {
      hilog.warn(DOMAIN, "FloatPage", "Failed to get display scale: %{public}s", JSON.stringify(e));
    }
  }

  build() {
    Stack() {
      Column() {
        // The floating window draws its own title controls. Keep them above the
        // menubar, matching the main window's system title bar and menubar order.
        // decorations=false on desktop retains a transparent drag bar.
        if (this.windowClass && (this.decorations || this.isDesktop)) {
          Row() {
            // Title text (left, occupies remaining space)
            Row() {
              Text(this.title)
                .fontSize(13)
                .fontColor("#333333")
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ left: 12 })
            }
            .height(40)
            .layoutWeight(1)
            .onTouch((event: TouchEvent) => this.startMoveFromTitle(event))

            // Minimize button — always visible when decorations=true;
            // interception is in WindowManager.minimizeWindow (getDecorationFlag check)
            if (this.decorations) {
              Button() {
                SymbolGlyph($r("sys.symbol.minus"))
                  .fontSize(20)
                  .fontColor(["#666666"])
              }
              .width(32)
              .height(32)
              .borderRadius(16)
              .backgroundColor("#f0f0f0")
              .margin({ top: 4, right: 4 })
              .onClick(() => {
                try {
                  WindowManager.getInstance().minimizeWindow(this.windowId);
                } catch (err) {
                  hilog.warn(
                    DOMAIN,
                    "FloatPage",
                    "minimize failed: %{public}s",
                    JSON.stringify(err),
                  );
                }
              });
            }

            // Maximize/restore button — always visible when decorations=true;
            // interception is in WindowManager.maximizeWindow (getDecorationFlag check)
            if (this.decorations) {
              Button() {
                SymbolGlyph(
                  this.isMaximized ? $r("sys.symbol.square_and_square") : $r("sys.symbol.square"),
                )
                  .fontSize(20)
                  .fontColor(["#666666"])
              }
              .width(32)
              .height(32)
              .borderRadius(16)
              .backgroundColor("#f0f0f0")
              .margin({ top: 4, right: 4 })
              .onClick(() => {
                try {
                  if (this.isMaximized) {
                    // recover() switches MAXIMIZE/FULL_SCREEN → FLOATING (API11+) — the
                    // documented inverse of maximize(). restore() is main-window-only
                    // (restores a minimized MAIN window on 2in1, API14+); on a maximized
                    // Float sub-window it is the wrong API. Mirrors tao set_maximized(false)
                    // → recover_window (plugin-window bridge).
                    WindowManager.getInstance().recoverWindow(this.windowId);
                  } else {
                    WindowManager.getInstance().maximizeWindow(this.windowId);
                  }
                  // isMaximized is driven by windowStatusChange (G9) — no optimistic
                  // toggle here, so the icon always reflects the actual system state
                  // once the status-change callback fires (also covers system/tao triggers).
                } catch (err) {
                  hilog.warn(
                    DOMAIN,
                    "FloatPage",
                    "maximize/restore failed: %{public}s",
                    JSON.stringify(err),
                  );
                }
              });
            }

            // Close button — always visible when decorations=true;
            // interception is in WindowManager.destroyWindow (getDecorationFlag check)
            if (this.decorations) {
              Button() {
                Image($r("sys.media.ohos_ic_public_cancel"))
                  .width(20)
                  .height(20)
                  .fillColor("#666666")
              }
              .width(32)
              .height(32)
              .borderRadius(16)
              .backgroundColor("#f0f0f0")
              .margin({ top: 4, right: 8 })
              .onClick(async () => {
                hilog.info(
                  DOMAIN,
                  "FloatPage",
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
                    "FloatPage",
                    "Close blocked: closable flag not set (window %{public}d)",
                    this.windowId,
                  );
                  return;
                }
                this.closeNotified = true;
                try {
                  // Notify Rust event loop before destroying the OHOS window,
                  // so CloseRequested → Destroyed → WindowsStore cleanup can run.
                  const nativeModule: Module | undefined =
                    AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
                  if (this.nativeModuleName && nativeModule?.notifyNativeWindowClose) {
                    nativeModule.notifyNativeWindowClose(this.windowId);
                  }
                  if (nativeModule && typeof nativeModule.notifyWindowClose === "function") {
                    nativeModule.notifyWindowClose(this.windowId);
                    hilog.info(
                      DOMAIN,
                      "FloatPage",
                      "Window %{public}d close notified via NAPI",
                      this.windowId,
                    );
                  } else {
                    hilog.warn(
                      DOMAIN,
                      "FloatPage",
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
                      "FloatPage",
                      "Window %{public}d destroyed and cleaned up",
                      this.windowId,
                    );
                  }
                } catch (e) {
                  hilog.error(
                    DOMAIN,
                    "FloatPage",
                    "Failed to close window %{public}d: %{public}s",
                    this.windowId,
                    JSON.stringify(e),
                  );
                }
              });
            }
          }
          .width("100%")
          .height(40);
        }

        // Menubar (only on desktop when menu items are available and decorations are enabled).
        // MenuBarSlotHost reads the slot live, including late plugin registration.
        if (this.isDesktop && this.decorations) {
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

      // 3. Resize handles (on desktop, always available regardless of decorations)
      if (this.isDesktop && this.windowClass && this.resizable) {
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
                    "FloatPage",
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
                    "FloatPage",
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
                    "FloatPage",
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
      const menuPort = getMenuBarPort();
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
            "FloatPage",
            "onTouch: WindowManager not ready: %{public}s",
            String(e),
          );
        }
      }
    });
  }
}
