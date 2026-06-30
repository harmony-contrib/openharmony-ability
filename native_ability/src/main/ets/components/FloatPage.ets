import { DefaultXComponent } from "./DefaultXComponent";
import {
  MenuBarComponent,
  getMenuClickHandler,
  getMenuBarRecoverFn,
  isMenubarVisible,
} from "./MenuBarComponent";
import { AcceleratorMatcher } from "../helper/accelerator_matcher";
import { KeyCode, pointer } from "@kit.InputKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window as arkWindow, CursorController } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { WindowManager } from '../window/WindowManager';
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from '../helper/constants';

export const RouteName = "FloatWindow";

interface Position {
  x: number,
  y: number
}

@Entry({ routeName: RouteName, storage: LocalStorage.getShared() })
@Component
struct FloatPage {
  // Receive windowId from WindowManager.createSubWindow
  @LocalStorageProp('windowId') windowId: number = 0;
  @LocalStorageProp('decorations') decorations: boolean = true;
  @StorageProp("__openharmony_ability_is_desktop__") isDesktop: boolean = false;

  // Window control
  private windowClass: arkWindow.Window | null = null;
  @State @Watch("moveAndSetWindow") windowPosition: Position = { x: 100, y: 100 };
  @State dpiScale: number = 1;
  private cursorController: CursorController | null = null;
  private acceleratorMatcher: AcceleratorMatcher = new AcceleratorMatcher();

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
    hilog.info(DOMAIN, 'FloatPage', 'aboutToDisappear: system close detected for window %{public}d', this.windowId);
    this.closeNotified = true;
    try {
      const nativeModule: ESObject = AppStorage.get<ESObject>(NATIVE_MODULE_STORAGE_KEY);
      if (nativeModule && typeof nativeModule.notifyWindowClose === 'function') {
        nativeModule.notifyWindowClose(this.windowId);
        hilog.info(DOMAIN, 'FloatPage', 'Window %{public}d close notified via NAPI (system close)', this.windowId);
      }
      wm.removeWindow(this.windowId);
    } catch (e) {
      hilog.error(DOMAIN, 'FloatPage', 'aboutToDisappear cleanup failed for window %{public}d: %{public}s', this.windowId, JSON.stringify(e));
    }
  }

  moveAndSetWindow() {
    this.windowClass?.moveWindowTo(this.windowPosition.x, this.windowPosition.y);
  }

  aboutToAppear(): void {
    hilog.info(DOMAIN, 'FloatPage', '=== FloatPage aboutToAppear START ===');
    hilog.info(DOMAIN, 'FloatPage', 'Received windowId: %{public}d', this.windowId);

    if (this.windowId <= 0) {
      hilog.error(DOMAIN, 'FloatPage', 'Invalid windowId: %{public}d. FloatPage requires windowId > 0.', this.windowId);
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
            hilog.info(DOMAIN, 'FloatPage', 'Got windowClass: left=%{public}d, top=%{public}d, w=%{public}d, h=%{public}d', rect.left, rect.top, this.currentWidth, this.currentHeight);
          } catch (e) {
            hilog.error(DOMAIN, 'FloatPage', 'Failed to get window rect: %{public}s', JSON.stringify(e));
          }
        } else {
          hilog.error(DOMAIN, 'FloatPage', 'findWindow returned null for name: %{public}s', winName);
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, 'FloatPage', 'Failed to get windowClass: %{public}s', JSON.stringify(e));
    }

    try {
      this.cursorController = this.getUIContext().getCursorController();
    } catch (e) {
      hilog.warn(DOMAIN, 'FloatPage', 'Failed to get CursorController: %{public}s', JSON.stringify(e));
    }

    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      this.dpiScale = defaultDisplay.densityPixels;
      hilog.info(DOMAIN, 'FloatPage', 'Display densityPixels: %{public}f', this.dpiScale);
    } catch (e) {
      hilog.warn(DOMAIN, 'FloatPage', 'Failed to get display scale: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    Stack() {
      Column() {
        // Menubar (only on desktop when menu items are available and decorations are enabled)
        if (this.isDesktop && this.decorations) {
          MenuBarComponent({
            windowId: this.windowId,
            acceleratorMatcher: this.acceleratorMatcher,
          })
        }

        Stack({ alignContent: Alignment.TopEnd }) {
          // 1. WebView content area (full screen)
          DefaultXComponent({ windowId: this.windowId })
            .width('100%')
            .height('100%');

          // 2. Top drag control area + right close button
          //    - decorations=true: drag bar + close button (all platforms)
          //    - decorations=false on desktop: transparent drag bar only (no close button)
          if (this.windowClass && (this.decorations || this.isDesktop)) {
            Row() {
              Row() {}
                .layoutWeight(1)
                .height(40);

              if (this.decorations) {
                Button() {
                  Image($r('sys.media.ohos_ic_public_cancel'))
                    .width(20)
                    .height(20)
                    .fillColor('#666666');
                }
                .width(32)
                .height(32)
                .borderRadius(16)
                .backgroundColor('#f0f0f0')
                .margin({ top: 4, right: 8 })
                .onClick(async () => {
                  hilog.info(DOMAIN, 'FloatPage', 'Close button clicked for window %{public}d', this.windowId);
                  if (this.closeNotified) {
                    return;
                  }
                  this.closeNotified = true;
                  try {
                    // Notify Rust event loop before destroying the OHOS window,
                    // so CloseRequested → Destroyed → WindowsStore cleanup can run.
                    const nativeModule: ESObject = AppStorage.get<ESObject>(NATIVE_MODULE_STORAGE_KEY);
                    if (nativeModule && typeof nativeModule.notifyWindowClose === 'function') {
                      nativeModule.notifyWindowClose(this.windowId);
                      hilog.info(DOMAIN, 'FloatPage', 'Window %{public}d close notified via NAPI', this.windowId);
                    } else {
                      hilog.warn(DOMAIN, 'FloatPage', 'NAPI notifyWindowClose not available for window %{public}d', this.windowId);
                    }

                    // removeWindow BEFORE destroyWindow so that aboutToDisappear
                    // sees the window as already handled (consistent with ArkHelper.onCloseWindow)
                    WindowManager.getInstance().removeWindow(this.windowId);
                    if (this.windowClass) {
                      await this.windowClass.destroyWindow();
                      hilog.info(DOMAIN, 'FloatPage', 'Window %{public}d destroyed and cleaned up', this.windowId);
                    }
                  } catch (e) {
                    hilog.error(DOMAIN, 'FloatPage', 'Failed to close window %{public}d: %{public}s', this.windowId, JSON.stringify(e));
                  }
                });
              }
            }
            .width('100%')
            .height(40)
            .align(Alignment.TopEnd)
            .gesture(
              PanGesture({ direction: PanDirection.All })
                .onActionUpdate((event: GestureEvent) => {
                  if (this.windowClass) {
                    this.windowPosition.x = this.windowClass.getGlobalRect().left;
                    this.windowPosition.y = this.windowClass.getGlobalRect().top;
                    this.windowPosition.x += event.offsetX;
                    this.windowPosition.y += event.offsetY;
                  }
                })
            );
          }
        }
        .layoutWeight(1)
        .width('100%');
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent);

      // 3. Resize handles (on desktop, always available regardless of decorations)
      if (this.isDesktop && this.windowClass) {
        // Right edge resize handle
        Row() {}
          .width(10)
          .height('100%')
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
                  this.currentWidth = Math.round(Math.max(200, this.startWidth + event.offsetX * this.dpiScale));
                  this.windowClass.resize(this.currentWidth, this.currentHeight);
                } catch (e) {
                  hilog.error(DOMAIN, 'FloatPage', 'Right resize failed: w=%{public}d, h=%{public}d, err=%{public}s', this.currentWidth, this.currentHeight, JSON.stringify(e));
                }
              })
          );

        // Bottom edge resize handle
        Row() {}
          .width('100%')
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
                  this.currentHeight = Math.round(Math.max(150, this.startHeight + event.offsetY * this.dpiScale));
                  this.windowClass.resize(this.currentWidth, this.currentHeight);
                } catch (e) {
                  hilog.error(DOMAIN, 'FloatPage', 'Bottom resize failed: w=%{public}d, h=%{public}d, err=%{public}s', this.currentWidth, this.currentHeight, JSON.stringify(e));
                }
              })
          );

        // Bottom-right corner resize handle
        Row() {}
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
                  this.currentWidth = Math.round(Math.max(200, this.startWidth + event.offsetX * this.dpiScale));
                  this.currentHeight = Math.round(Math.max(150, this.startHeight + event.offsetY * this.dpiScale));
                  this.windowClass.resize(this.currentWidth, this.currentHeight);
                } catch (e) {
                  hilog.error(DOMAIN, 'FloatPage', 'Corner resize failed: w=%{public}d, h=%{public}d, err=%{public}s', this.currentWidth, this.currentHeight, JSON.stringify(e));
                }
              })
          );
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onKeyPreIme((event: KeyEvent) => {
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
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE && !isMenubarVisible(this.windowId)) {
        const recoverFn = getMenuBarRecoverFn(this.windowId);
        if (recoverFn) {
          recoverFn();
        }
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
          hilog.warn(DOMAIN, 'FloatPage', 'onTouch: WindowManager not ready: %{public}s', String(e));
        }
      }
    })
  }
}
