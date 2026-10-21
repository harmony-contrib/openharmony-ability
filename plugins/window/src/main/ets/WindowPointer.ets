import pointer from "@ohos.multimodalInput.pointer";
import window from "@ohos.window";
import { image } from "@kit.ImageKit";
import { CustomCursorRequest } from "./CustomCursor";

/** Native completion and errors are part of the bridge acknowledgement. */
export class WindowPointer {
  static setStyle(win: window.Window, style: number): void {
    pointer.setPointerStyleSync(win.getWindowProperties().id, style as pointer.PointerStyle);
  }

  static async setCustom(
    win: window.Window,
    request: CustomCursorRequest,
    beforeRun: () => void,
  ): Promise<void> {
    const bytes = new Uint8Array(request.rgba);
    const pixelMap = await image.createPixelMap(bytes.buffer, {
      size: { width: request.width, height: request.height },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.UNPREMUL,
      editable: false,
    });
    try {
      beforeRun();
      const nativeId = win.getWindowProperties().id;
      await pointer.setCustomCursor(nativeId, pixelMap, request.hotspotX, request.hotspotY);
      beforeRun();
    } catch (error) {
      try {
        await pixelMap.release();
      } catch (releaseError) {
        console.warn(`Cursor release failed: ${String(releaseError)}`);
      }
      throw error as Error;
    }
    await pixelMap.release();
    beforeRun();
  }
}
