import pasteboard from '@ohos.pasteboard';
import { image } from "@kit.ImageKit";
import { BusinessError } from "@kit.BasicServicesKit";

export async function writeImageToClipboard(
  rgbaData: Uint8Array, width: number, height: number
): Promise<void> {
  let pm: image.PixelMap | null = null;
  try {
    // Copy napi-provided Uint8Array into a standard JS-managed buffer.
    // napi external buffers may not be properly accessible by ArkTS PixelMap APIs.
    const jsArr = new Uint8Array(rgbaData.length);
    jsArr.set(rgbaData);

    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: width, height: height }
    };
    pm = image.createPixelMapSync(opts);
    pm.writeBufferToPixelsSync(jsArr.buffer);

    const pasteData = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pm);
    const systemPasteboard = pasteboard.getSystemPasteboard();
    await systemPasteboard.setData(pasteData);
  } catch (e) {
    const err = e as BusinessError;
    console.error(`[Clipboard] writeImageToClipboard failed: ${err.code} ${err.message}`);
    throw new Error(`writeImageToClipboard failed: code=${err.code} msg=${err.message}`);
  } finally {
    pm?.release();
  }
}
