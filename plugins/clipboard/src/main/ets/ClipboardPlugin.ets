import pasteboard from "@ohos.pasteboard";
import { image } from "@kit.ImageKit";
import { BusinessError } from "@kit.BasicServicesKit";
import {
  BridgeCallContext,
  BridgeTypedValue,
  AsyncPluginBase,
  BridgeContextRequirement,
} from "@ohos-rs/ability";

const IMAGE_REQUEST_TYPE = "ohos.clipboard.ImageRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.clipboard.Acknowledgement";

interface ClipboardImageRequest {
  rgba: Uint8Array;
  width: number;
  height: number;
}

class ClipboardAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function parseImageRequest(payload: BridgeTypedValue): ClipboardImageRequest {
  if (payload.typeName !== IMAGE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.clipboard.write-image requires bridge type ${IMAGE_REQUEST_TYPE}`);
  }
  const request = payload.value as ClipboardImageRequest;
  if (!(request.rgba instanceof Uint8Array)) {
    throw new Error("write-image.rgba must be a Uint8Array");
  }
  if (
    !Number.isInteger(request.width) ||
    !Number.isInteger(request.height) ||
    request.width <= 0 ||
    request.height <= 0
  ) {
    throw new Error("write-image.width and height must be positive integers");
  }
  const expected = request.width * request.height * 4;
  if (request.rgba.length !== expected) {
    throw new Error(
      `write-image rgba len ${request.rgba.length} != expected ${expected} (${request.width}x${request.height}x4)`,
    );
  }
  return request;
}

async function writeImageToClipboard(
  rgba: Uint8Array,
  width: number,
  height: number,
): Promise<void> {
  let pixelMap: image.PixelMap | null = null;
  try {
    // napi external buffers may not be accessible by ArkTS PixelMap APIs; copy into a JS-managed buffer.
    const jsArr = new Uint8Array(rgba.length);
    jsArr.set(rgba);

    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: width, height: height },
    };
    pixelMap = image.createPixelMapSync(opts);
    pixelMap.writeBufferToPixelsSync(jsArr.buffer);

    const pasteData = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap);
    const systemPasteboard = pasteboard.getSystemPasteboard();
    await systemPasteboard.setData(pasteData);
  } catch (error) {
    const err = error as BusinessError;
    throw new Error(`writeImageToClipboard failed: code=${err.code} msg=${err.message}`);
  } finally {
    pixelMap?.release();
  }
}

export class ClipboardPlugin extends AsyncPluginBase {
  readonly id = "ohos.clipboard";
  readonly version = 1;
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (action !== "write-image") {
      throw new Error(`Unsupported ohos.clipboard action '${action}'`);
    }
    const request = parseImageRequest(payload);
    await writeImageToClipboard(request.rgba, request.width, request.height);
    if (!context.isActive()) {
      throw new Error("Ability was destroyed while clipboard write was pending");
    }
    return { typeName: ACKNOWLEDGEMENT_TYPE, value: new ClipboardAcknowledgement(true) };
  }
}
