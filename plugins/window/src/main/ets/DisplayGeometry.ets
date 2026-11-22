import window from "@ohos.window";
import display from "@ohos.display";
import { BusinessError, deviceInfo } from "@kit.BasicServicesKit";
import { FrameNode } from "@ohos.arkui.node";

interface GlobalRectWindowApi {
  getGlobalRect?: () => window.Rect;
}

class DisplayRect {
  readonly left: number;
  readonly top: number;
  readonly width: number;
  readonly height: number;

  constructor(left: number, top: number, width: number, height: number) {
    this.left = Math.round(left);
    this.top = Math.round(top);
    this.width = Math.round(width);
    this.height = Math.round(height);
  }
}

export class WindowDisplayGeometry {
  readonly displayId: number;
  readonly bounds: DisplayRect;
  readonly contentBounds: DisplayRect;
  readonly componentBounds?: DisplayRect;

  constructor(win: window.Window, root?: FrameNode) {
    const props = win.getWindowProperties();
    this.displayId = props.displayId ?? display.getDefaultDisplaySync().id;
    let rect = props.windowRect;
    const globalRectApi = win as ESObject as GlobalRectWindowApi;
    if (deviceInfo.sdkApiVersion >= 13 && typeof globalRectApi.getGlobalRect === "function") {
      try {
        rect = globalRectApi.getGlobalRect();
      } catch (error) {
        // Products without scaled/freeform windows still report their physical
        // rectangle through WindowProperties. Do not hide other query failures.
        if ((error as BusinessError).code !== 801) {
          throw error as Error;
        }
      }
    }
    this.bounds = new DisplayRect(rect.left, rect.top, rect.width, rect.height);
    const drawable = props.drawableRect;
    const sx = props.windowRect.width > 0 ? rect.width / props.windowRect.width : 1;
    const sy = props.windowRect.height > 0 ? rect.height / props.windowRect.height : 1;
    this.contentBounds = new DisplayRect(
      rect.left + drawable.left * sx,
      rect.top + drawable.top * sy,
      drawable.width * sx,
      drawable.height * sy,
    );
    if (root !== undefined && root.getUniqueId() > 0) {
      const position = root.getPositionToWindowWithTransform();
      const size = root.getMeasuredSize();
      const context = win.getUIContext();
      this.componentBounds = new DisplayRect(
        rect.left + context.vp2px(position.x) * sx,
        rect.top + context.vp2px(position.y) * sy,
        size.width * sx,
        size.height * sy,
      );
    }
  }
}
