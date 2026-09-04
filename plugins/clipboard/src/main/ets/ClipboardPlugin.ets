import pasteboard from "@ohos.pasteboard";
import { image } from "@kit.ImageKit";
import { BusinessError } from "@kit.BasicServicesKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

const READ_TEXT_REQUEST_TYPE = "ohos.clipboard.ReadTextRequest";
const READ_TEXT_RESPONSE_TYPE = "ohos.clipboard.ReadTextResponse";
const WRITE_TEXT_REQUEST_TYPE = "ohos.clipboard.WriteTextRequest";
const WRITE_TEXT_RESPONSE_TYPE = "ohos.clipboard.WriteTextResponse";
const WRITE_IMAGE_REQUEST_TYPE = "ohos.clipboard.WriteImageRequest";
const WRITE_IMAGE_RESPONSE_TYPE = "ohos.clipboard.WriteImageResponse";
const WRITE_HTML_REQUEST_TYPE = "ohos.clipboard.WriteHtmlRequest";
const WRITE_HTML_RESPONSE_TYPE = "ohos.clipboard.WriteHtmlResponse";
const CLEAR_REQUEST_TYPE = "ohos.clipboard.ClearRequest";
const CLEAR_RESPONSE_TYPE = "ohos.clipboard.ClearResponse";

interface WriteTextRequest {
  text: string;
}

interface WriteImageRequest {
  rgba: Uint8Array;
  width: number;
  height: number;
}

interface WriteHtmlRequest {
  html: string;
}

interface ClearRequest {}

class ReadTextResponse {
  readonly text: string;

  constructor(text: string) {
    this.text = text;
  }
}

class WriteTextResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class WriteImageResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class WriteHtmlResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class ClearResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

export class ClipboardPlugin extends AsyncPluginBase {
  readonly id = "ohos.clipboard";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }

    if (action === "read-text") {
      expectBridgeRequestType(payload, "ohos.clipboard", action, READ_TEXT_REQUEST_TYPE);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = await systemPasteboard.getData();
      let text: string = "";
      try {
        const primaryText = data.getPrimaryText();
        // getPrimaryText is typed string|null but returns `undefined` on an empty board
        // (e.g. when READ_PASTEBOARD permission is missing — getData silently returns an
        // empty PasteData). Guard all three: null, undefined, and non-string.
        if (primaryText !== null && primaryText !== undefined && typeof primaryText === "string" && primaryText.length > 0) {
          text = primaryText;
        }
      } catch {
        text = "";
      }
      return {
        typeName: READ_TEXT_RESPONSE_TYPE,
        value: new ReadTextResponse(text),
      };
    }

    if (action === "write-text") {
      const request = expectBridgeRequestType(payload, "ohos.clipboard", action, WRITE_TEXT_REQUEST_TYPE) as WriteTextRequest;
      if (typeof request.text !== "string") {
        throw new Error("write-text.text must be a string");
      }
      // NOTE: read-back of the clipboard requires ohos.permission.READ_PASTEBOARD (a
      // user_grant restricted permission not in the current signing profile's ACL).
      // Without it, getData() silently returns an empty PasteData (recordCount=0) —
      // hasData() still returns true, so write-text itself succeeds. See memory
      // ohos-clipboard-readpasteboard-permission for the full diagnosis.
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, request.text);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      await systemPasteboard.setData(pasteData);
      return {
        typeName: WRITE_TEXT_RESPONSE_TYPE,
        value: new WriteTextResponse(true),
      };
    }

    if (action === "write-image") {
      const request = expectBridgeRequestType(payload, "ohos.clipboard", action, WRITE_IMAGE_REQUEST_TYPE) as WriteImageRequest;
      // NAPI Vec<u8> inside #[napi(object)] arrives as Array<number>, not Uint8Array — convert
      let rgbaData: Uint8Array;
      if (request.rgba instanceof Uint8Array) {
        rgbaData = request.rgba;
      } else if (Array.isArray(request.rgba)) {
        rgbaData = new Uint8Array(request.rgba as number[]);
      } else {
        throw new Error("write-image.rgba must be a Uint8Array or number array");
      }
      if (!Number.isInteger(request.width) || !Number.isInteger(request.height)) {
        throw new Error("write-image.width and height must be integers");
      }
      const expected = request.width * request.height * 4;
      if (rgbaData.length !== expected) {
        throw new Error(
          `write-image.rgba length ${rgbaData.length} != expected ${expected} (${request.width}x${request.height}x4)`,
        );
      }
      await this.writeImageToClipboard(rgbaData, request.width, request.height);
      return {
        typeName: WRITE_IMAGE_RESPONSE_TYPE,
        value: new WriteImageResponse(true),
      };
    }

    if (action === "write-html") {
      const request = expectBridgeRequestType(payload, "ohos.clipboard", action, WRITE_HTML_REQUEST_TYPE) as WriteHtmlRequest;
      if (typeof request.html !== "string") {
        throw new Error("write-html.html must be a string");
      }
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_HTML, request.html);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      await systemPasteboard.setData(pasteData);
      return {
        typeName: WRITE_HTML_RESPONSE_TYPE,
        value: new WriteHtmlResponse(true),
      };
    }

    if (action === "clear") {
      expectBridgeRequestType(payload, "ohos.clipboard", action, CLEAR_REQUEST_TYPE);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      await systemPasteboard.clearData();
      return {
        typeName: CLEAR_RESPONSE_TYPE,
        value: new ClearResponse(true),
      };
    }

    throw new Error(`Unsupported ohos.clipboard action '${action}'`);
  }

  /**
   * Creates a PixelMap from RGBA data and writes it to the system clipboard.
   * Reuses the same logic as ClipboardHelper.ets writeImageToClipboard.
   */
  private async writeImageToClipboard(
    rgbaData: Uint8Array,
    width: number,
    height: number,
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
        size: { width: width, height: height },
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
}
