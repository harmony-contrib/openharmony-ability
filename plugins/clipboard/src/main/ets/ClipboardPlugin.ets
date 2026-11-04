import pasteboard from "@ohos.pasteboard";
import abilityAccessCtrl, { Permissions } from "@ohos.abilityAccessCtrl";
import { image } from "@kit.ImageKit";
import { buffer } from "@kit.ArkTS";
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
const READ_IMAGE_REQUEST_TYPE = "ohos.clipboard.ReadImageRequest";
const READ_IMAGE_RESPONSE_TYPE = "ohos.clipboard.ReadImageResponse";
const WRITE_HTML_REQUEST_TYPE = "ohos.clipboard.WriteHtmlRequest";
const WRITE_HTML_RESPONSE_TYPE = "ohos.clipboard.WriteHtmlResponse";
const CLEAR_REQUEST_TYPE = "ohos.clipboard.ClearRequest";
const CLEAR_RESPONSE_TYPE = "ohos.clipboard.ClearResponse";

// Upper bound on the pixel count read-image will pack and decode, mirrored
// from MAX_DECODE_PIXELS in crates/plugin-clipboard/src/lib.rs. Rejecting
// here avoids PNG-packing, base64-encoding (~4/3x), and bridging a huge
// PixelMap that the Rust side would refuse after the fact.
const MAX_DECODE_PIXELS = 1 << 26;

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
  // Optional plain-text alternate (Rust Option<String>): absent when None —
  // the Option-wire-omit convention (never a JS null on the wire).
  altText?: string;
}

interface ClearRequest {}

class ReadTextResponse {
  readonly text: string;

  constructor(text: string) {
    this.text = text;
  }
}

class ReadImageResponse {
  readonly pngBase64: string;
  readonly width: number;
  readonly height: number;

  constructor(pngBase64: string, width: number, height: number) {
    this.pngBase64 = pngBase64;
    this.width = width;
    this.height = height;
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
      // READ_PASTEBOARD gate (Eulogizethesun/tauri#102): since API 12 reading
      // the pasteboard is governed by this restricted user_grant permission —
      // without it getData() silently returns an empty PasteData. Request it
      // before reading; see ensureReadPermission for the preconditions and the
      // degradation contract.
      await this.ensureReadPermission(context);
      if (!context.isActive()) {
        throw new Error("Ability was destroyed while clipboard permission request was pending");
      }
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = await systemPasteboard.getData();
      let text: string = "";
      try {
        const primaryText = data.getPrimaryText();
        // getPrimaryText is typed string|null but returns `undefined` on an empty board
        // (e.g. when READ_PASTEBOARD permission is missing — getData silently returns an
        // empty PasteData). Guard all three: null, undefined, and non-string.
        if (
          primaryText !== null &&
          primaryText !== undefined &&
          typeof primaryText === "string" &&
          primaryText.length > 0
        ) {
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

    if (action === "read-image") {
      expectBridgeRequestType(payload, "ohos.clipboard", action, READ_IMAGE_REQUEST_TYPE);
      // Same READ_PASTEBOARD gate as read-text (API 12+ read restriction).
      await this.ensureReadPermission(context);
      if (!context.isActive()) {
        throw new Error("Ability was destroyed while clipboard permission request was pending");
      }
      const result = await this.readImageFromClipboard();
      return {
        typeName: READ_IMAGE_RESPONSE_TYPE,
        value: new ReadImageResponse(result.pngBase64, result.width, result.height),
      };
    }

    if (action === "write-text") {
      const request = expectBridgeRequestType(
        payload,
        "ohos.clipboard",
        action,
        WRITE_TEXT_REQUEST_TYPE,
      ) as WriteTextRequest;
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
      const request = expectBridgeRequestType(
        payload,
        "ohos.clipboard",
        action,
        WRITE_IMAGE_REQUEST_TYPE,
      ) as WriteImageRequest;
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
      const request = expectBridgeRequestType(
        payload,
        "ohos.clipboard",
        action,
        WRITE_HTML_REQUEST_TYPE,
      ) as WriteHtmlRequest;
      if (typeof request.html !== "string") {
        throw new Error("write-html.html must be a string");
      }
      // Optional plain-text alternate: absent when the Rust side passed None
      // (Option-wire omit) — validate only when present.
      if (request.altText !== undefined && typeof request.altText !== "string") {
        throw new Error("write-html.altText must be a string when present");
      }
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_HTML, request.html);
      // Coexisting plain-text record for the alt text — the official addRecord
      // (mimeType, value) doc names exactly this "plain text and HTML
      // coexisting" case and requires non-empty inputs ("all inputs must be
      // non-empty, otherwise the add fails"), so an empty
      // altText is treated as absent (zero-diff with today's behavior).
      // HTML stays the primary (first) record; mirrors arboard's
      // set_html(html, alt). (plugins-workspace#214)
      if (request.altText !== undefined && request.altText.length > 0) {
        pasteData.addRecord(pasteboard.MIMETYPE_TEXT_PLAIN, request.altText);
      }
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
   * Ensures ohos.permission.READ_PASTEBOARD is granted before a pasteboard read.
   *
   * Preconditions for the request to succeed (official
   * get-pastedata-permission-guidelines):
   * 1. The app's module.json5 declares the permission (with reason/usedScene).
   * 2. The signing profile's ACL contains it — restricted permission, but
   *    "PC/2in1设备上的应用均可申请" (auto-approved on AGC).
   *
   * When either precondition is missing the request rejects or is denied.
   * Both cases degrade to the historical behavior — getData() silently
   * returning an empty PasteData → read-text resolves with "" — so this
   * helper never turns a working (if empty) read into a hard failure.
   * Requesting an already-granted permission resolves without a dialog.
   */
  private async ensureReadPermission(context: BridgeCallContext): Promise<void> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(context.abilityContext, [
        "ohos.permission.READ_PASTEBOARD",
      ] as Permissions[]);
      const granted = (result.authResults ?? [])[0] === 0;
      if (!granted) {
        console.warn(
          "[Clipboard] READ_PASTEBOARD denied — read-text will observe an empty pasteboard",
        );
      }
    } catch (e) {
      // Undeclared permission, missing ACL entry, or a non-interactive call
      // context — degrade instead of failing the read.
      console.warn("[Clipboard] READ_PASTEBOARD request failed: " + String(e));
    }
  }

  /**
   * Reads the primary image from the system clipboard and packs it as a
   * base64 PNG plus its pixel dimensions.
   *
   * base64 (not raw bytes) — a Vec<u8> in a napi object would cross the
   * bridge as Array<number>, inflating a multi-hundred-KB PNG ~8x in memory
   * (same contract as WebviewPlugin's capture-webview).
   *
   * Images above MAX_DECODE_PIXELS total pixels are rejected before packing;
   * the Rust decoder enforces the same cap, so rejecting here skips the
   * pack/base64/bridge round-trip for oversized inputs.
   *
   * Throws when the clipboard holds no PixelMap record (the caller surfaces
   * the error — matches arboard's behavior on the desktop path).
   */
  private async readImageFromClipboard(): Promise<{
    pngBase64: string;
    width: number;
    height: number;
  }> {
    let pm: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = await systemPasteboard.getData();
      // getPrimaryPixelMap throws when the primary record is not a PixelMap;
      // an empty board (e.g. READ_PASTEBOARD denied) yields null/undefined.
      pm = (data.getPrimaryPixelMap() ?? null) as image.PixelMap | null;
      if (pm == null) {
        throw new Error("clipboard does not contain an image");
      }
      const info = pm.getImageInfoSync();
      const pixels = info.size.width * info.size.height;
      if (pixels > MAX_DECODE_PIXELS) {
        throw new Error(
          `clipboard image too large: ${info.size.width}x${info.size.height} (${pixels} px) exceeds the ${MAX_DECODE_PIXELS} px limit`,
        );
      }
      packer = image.createImagePacker();
      // quality is REQUIRED by PackingOption in the API 12 typings even for PNG.
      const packOptions: image.PackingOption = { format: "image/png", quality: 100 };
      const arrayBuffer = await packer.packing(pm, packOptions);
      if (!arrayBuffer || arrayBuffer.byteLength === 0) {
        throw new Error("ImagePacker produced empty PNG buffer");
      }
      const pngBase64 = buffer.from(arrayBuffer).toString("base64");
      return { pngBase64: pngBase64, width: info.size.width, height: info.size.height };
    } catch (e) {
      // BusinessError (pasteboard/packer) or the plain Errors thrown above.
      const message = e instanceof Error ? e.message : String(e);
      console.error(`[Clipboard] readImageFromClipboard failed: ${message}`);
      throw new Error(`readImageFromClipboard failed: ${message}`);
    } finally {
      try {
        packer?.release();
      } catch (_packerErr) {
        // best-effort release
      }
      try {
        pm?.release();
      } catch (_pmErr) {
        // best-effort release
      }
    }
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
        // The rgba buffer is straight (unpremultiplied) alpha. Without this
        // the PixelMap label defaults to PREMUL (pixel_map.cpp), and any PNG
        // re-encode — readImageFromClipboard's ImagePacker, or a paste
        // target — unpremultiplies the straight bytes: alpha=0 pixels lose
        // their rgb entirely and partial-alpha rgb clamps up (200@128→255).
        // Source-attributed via OHOS system source + run-1 hexdump (issue
        // #113 V5, 2026-09-20); evidence in
        // faultlogs/v5-readimage-run1-20260920-report.md.
        alphaType: image.AlphaType.UNPREMUL,
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
