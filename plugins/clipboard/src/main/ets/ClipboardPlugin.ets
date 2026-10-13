import pasteboard from "@ohos.pasteboard";
import { image } from "@kit.ImageKit";
import { util } from "@kit.ArkTS";
import { BusinessError } from "@kit.BasicServicesKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgePluginHookContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

const READ_TEXT_REQUEST_TYPE = "ohos.clipboard.ReadTextRequest";
const READ_TEXT_RESPONSE_TYPE = "ohos.clipboard.ReadTextResponse";
const READ_CONTENT_RESPONSE_TYPE = "ohos.clipboard.ReadContentResponse";
const WRITE_ENCODED_IMAGE_REQUEST_TYPE = "ohos.clipboard.WriteEncodedImageRequest";
const WRITE_URIS_REQUEST_TYPE = "ohos.clipboard.WriteUrisRequest";
const WRITE_TEXT_REQUEST_TYPE = "ohos.clipboard.WriteTextRequest";
const WRITE_TEXT_RESPONSE_TYPE = "ohos.clipboard.WriteTextResponse";
const WRITE_IMAGE_REQUEST_TYPE = "ohos.clipboard.WriteImageRequest";
const WRITE_IMAGE_RESPONSE_TYPE = "ohos.clipboard.WriteImageResponse";
const WRITE_HTML_REQUEST_TYPE = "ohos.clipboard.WriteHtmlRequest";
const WRITE_HTML_RESPONSE_TYPE = "ohos.clipboard.WriteHtmlResponse";
const WRITE_RECORDS_REQUEST_TYPE = "ohos.clipboard.WriteRecordsRequest";
const READ_RECORDS_RESPONSE_TYPE = "ohos.clipboard.ReadRecordsResponse";
const CHANGED_EVENT_TYPE = "ohos.clipboard.ChangedEvent";
// Retain reads of existing clipboard entries during consumer-specific MIME migration.
const LEGACY_METADATA_MIME = "application/x-gpui-ohos-text-metadata";
const LEGACY_METADATA_MIME_V1 = "application/x-gpui-ohos-text-metadata-v1";

export interface ClipboardPluginOptions {
  /** Custom MIME for versioned UTF-8 text metadata; keep writers and readers consistent. */
  metadataMimeType: string;
}

interface ClipboardRecord {
  text?: string;
  metadata?: string;
  encodedImage?: Uint8Array | number[];
  uri?: string;
}
interface WriteRecordsRequest {
  records: ClipboardRecord[];
}
class ReadRecordsResponse {
  readonly records: ClipboardRecord[];
  constructor(records: ClipboardRecord[]) {
    this.records = records;
  }
}

const CLEAR_REQUEST_TYPE = "ohos.clipboard.ClearRequest";
const CLEAR_RESPONSE_TYPE = "ohos.clipboard.ClearResponse";

interface WriteTextRequest {
  text: string;
}

interface WriteEncodedImageRequest {
  bytes: Uint8Array | number[];
}

interface WriteUrisRequest {
  uris: string[];
}

class ReadContentResponse {
  readonly text?: string;
  readonly png?: number[];
  readonly uris: string[];

  constructor(text: string | undefined, png: number[] | undefined, uris: string[]) {
    this.text = text;
    this.png = png;
    this.uris = uris;
  }
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
  private readonly metadataMimeType: string;

  private updateListener?: () => void;

  constructor(options: ClipboardPluginOptions) {
    super();
    const mime = options?.metadataMimeType;
    const reserved = [
      pasteboard.MIMETYPE_TEXT_PLAIN,
      pasteboard.MIMETYPE_TEXT_HTML,
      pasteboard.MIMETYPE_TEXT_URI,
      pasteboard.MIMETYPE_TEXT_WANT,
      pasteboard.MIMETYPE_PIXELMAP,
      LEGACY_METADATA_MIME,
    ];
    if (
      typeof mime !== "string" ||
      mime.length > 1024 ||
      !/^[A-Za-z0-9!#$&^_.+-]+\/[A-Za-z0-9!#$&^_.+-]+$/.test(mime) ||
      reserved.includes(mime.toLowerCase())
    ) {
      throw new Error(
        "ClipboardPlugin options.metadataMimeType must be a non-reserved type/subtype MIME",
      );
    }
    this.metadataMimeType = mime.toLowerCase();
  }

  override onInstall(context: BridgePluginHookContext): void {
    this.updateListener = (): void => {
      if (!context.isActive()) {
        return;
      }
      try {
        context.invokeNativeSync("changed", CHANGED_EVENT_TYPE, "std.bool", {});
      } catch (error) {
        console.warn(`[Clipboard] update notification failed: ${String(error)}`);
      }
    };
    pasteboard.getSystemPasteboard().on("update", this.updateListener);
  }

  override onDispose(): void {
    if (this.updateListener) {
      pasteboard.getSystemPasteboard().off("update", this.updateListener);
      this.updateListener = undefined;
    }
  }

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }

    if (action === "write-records") {
      const request = expectBridgeRequestType(
        payload,
        this.id,
        action,
        WRITE_RECORDS_REQUEST_TYPE,
      ) as WriteRecordsRequest;
      if (
        !Array.isArray(request.records) ||
        request.records.length === 0 ||
        request.records.length > 512
      ) {
        throw new Error("write-records requires 1..512 records");
      }
      const maps: image.PixelMap[] = [];
      let data: pasteboard.PasteData | undefined;
      try {
        // addRecord inserts at the front; reverse construction preserves caller record order.
        for (let index = request.records.length - 1; index >= 0; index--) {
          const entry = request.records[index];
          const hasText = typeof entry.text === "string";
          const hasImage = entry.encodedImage !== undefined && entry.encodedImage !== null;
          const hasUri = typeof entry.uri === "string";
          if (
            Number(hasText) + Number(hasImage) + Number(hasUri) !== 1 ||
            (entry.metadata !== undefined && !hasText)
          ) {
            throw new Error("Each clipboard record must contain one supported value");
          }
          let record: pasteboard.PasteDataRecord;
          if (hasText) {
            record = pasteboard.createRecord(pasteboard.MIMETYPE_TEXT_PLAIN, entry.text!);
            if (entry.metadata !== undefined) {
              // A version byte keeps empty metadata readable: the SDK rejects empty custom data.
              const encoded = new util.TextEncoder().encodeInto(`1${entry.metadata}`);
              record.addEntry(
                this.metadataMimeType,
                encoded.buffer.slice(encoded.byteOffset, encoded.byteOffset + encoded.byteLength),
              );
            }
          } else if (hasUri) {
            if (!entry.uri!.startsWith("file://") || entry.uri!.includes("\0")) {
              throw new Error("clipboard URI must be a file:// URI");
            }
            record = pasteboard.createRecord(pasteboard.MIMETYPE_TEXT_URI, entry.uri!);
          } else {
            const bytes = new Uint8Array(entry.encodedImage!);
            if (bytes.length === 0) {
              throw new Error("clipboard image must not be empty");
            }
            const source = image.createImageSource(bytes.buffer);
            try {
              const pixelMap = await source.createPixelMap();
              maps.push(pixelMap);
              record = pasteboard.createRecord(pasteboard.MIMETYPE_PIXELMAP, pixelMap);
            } finally {
              source.release();
            }
          }
          if (!context.isActive()) {
            throw new Error("Clipboard write was cancelled");
          }
          if (data === undefined) {
            // createData requires a typed value; start with the last record, then replace it.
            data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, "");
            data.replaceRecord(0, record);
          } else {
            data.addRecord(record);
          }
        }
        await pasteboard.getSystemPasteboard().setData(data!);
        if (!context.isActive()) {
          throw new Error("Clipboard write was cancelled");
        }
        return { typeName: WRITE_TEXT_RESPONSE_TYPE, value: new WriteTextResponse(true) };
      } finally {
        for (const pixelMap of maps) {
          pixelMap.release();
        }
      }
    }

    if (action === "read-records") {
      expectBridgeRequestType(payload, this.id, action, READ_TEXT_REQUEST_TYPE);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = await systemPasteboard.getData().catch((error: Error): never => {
        throw new Error(`Clipboard getData failed: ${String(error)}`);
      });
      if (data.getRecordCount() === 0 && (await systemPasteboard.hasData())) {
        throw new Error("Clipboard data is unreadable; check READ_PASTEBOARD signing profile ACL");
      }
      const entries: ClipboardRecord[] = [];
      for (let index = 0; index < data.getRecordCount(); index++) {
        const record = data.getRecordAt(index);
        if (
          record.mimeType === pasteboard.MIMETYPE_TEXT_PLAIN &&
          typeof record.plainText === "string"
        ) {
          let metadata: string | undefined;
          let metadataMime: string | undefined;
          for (const mime of [
            this.metadataMimeType,
            LEGACY_METADATA_MIME_V1,
            LEGACY_METADATA_MIME,
          ]) {
            if (record.getValidTypes([mime]).length > 0) {
              metadataMime = mime;
              break;
            }
          }
          if (metadataMime !== undefined) {
            const versioned = metadataMime !== LEGACY_METADATA_MIME;
            const value = await record.getData(metadataMime).catch((error: Error): never => {
              throw new Error(`Clipboard metadata record ${index} failed: ${String(error)}`);
            });
            if (value instanceof ArrayBuffer) {
              const decoded = new util.TextDecoder("utf-8").decodeToString(new Uint8Array(value));
              if (versioned && !decoded.startsWith("1")) {
                throw new Error("Unsupported clipboard metadata version");
              }
              metadata = versioned ? decoded.slice(1) : decoded;
            }
          }
          entries.push({ text: record.plainText, metadata });
        } else if (
          record.mimeType === pasteboard.MIMETYPE_TEXT_URI &&
          typeof record.uri === "string" &&
          record.uri.startsWith("file://")
        ) {
          entries.push({ uri: record.uri });
        } else if (record.pixelMap) {
          const packer = image.createImagePacker();
          try {
            const encoded = await packer
              .packToData(record.pixelMap, { format: "image/png", quality: 100 })
              .catch((error: Error): never => {
                throw new Error(`Clipboard image record ${index} failed: ${String(error)}`);
              });
            entries.push({ encodedImage: Array.from(new Uint8Array(encoded)) });
          } finally {
            packer.release();
          }
        }
      }
      if (!context.isActive()) {
        throw new Error("Clipboard read was cancelled");
      }
      return { typeName: READ_RECORDS_RESPONSE_TYPE, value: new ReadRecordsResponse(entries) };
    }

    if (action === "read-content") {
      expectBridgeRequestType(payload, "ohos.clipboard", action, READ_TEXT_REQUEST_TYPE);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = await systemPasteboard.getData();
      if (data.getRecordCount() === 0 && (await systemPasteboard.hasData())) {
        throw new Error("Clipboard data is unreadable; check READ_PASTEBOARD signing profile ACL");
      }
      const mimeTypes = data.getMimeTypes();
      let text: string | undefined;
      let png: number[] | undefined;
      const uris: string[] = [];
      if (mimeTypes.includes(pasteboard.MIMETYPE_TEXT_PLAIN)) {
        text = data.getPrimaryText() || undefined;
      }
      if (mimeTypes.includes(pasteboard.MIMETYPE_TEXT_URI)) {
        for (let index = 0; index < data.getRecordCount(); index++) {
          const uri = data.getRecordAt(index).uri;
          if (typeof uri === "string" && uri.length > 0) {
            uris.push(uri);
          }
        }
      }
      if (mimeTypes.includes(pasteboard.MIMETYPE_PIXELMAP)) {
        const pixelMap = data.getPrimaryPixelMap();
        if (pixelMap) {
          const packer = image.createImagePacker();
          try {
            const encoded = await packer.packToData(pixelMap, {
              format: "image/png",
              quality: 100,
            });
            png = Array.from(new Uint8Array(encoded));
          } finally {
            packer.release();
          }
        }
      }
      return {
        typeName: READ_CONTENT_RESPONSE_TYPE,
        value: new ReadContentResponse(text, png, uris),
      };
    }

    if (action === "write-encoded-image") {
      const request = expectBridgeRequestType(
        payload,
        "ohos.clipboard",
        action,
        WRITE_ENCODED_IMAGE_REQUEST_TYPE,
      ) as WriteEncodedImageRequest;
      const bytes =
        request.bytes instanceof Uint8Array ? request.bytes : new Uint8Array(request.bytes);
      if (bytes.length === 0) {
        throw new Error("write-encoded-image.bytes must not be empty");
      }
      const copy = new Uint8Array(bytes.length);
      copy.set(bytes);
      const source = image.createImageSource(copy.buffer);
      try {
        const pixelMap = await source.createPixelMap();
        try {
          await pasteboard
            .getSystemPasteboard()
            .setData(pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap));
        } finally {
          pixelMap.release();
        }
      } finally {
        source.release();
      }
      return {
        typeName: WRITE_IMAGE_RESPONSE_TYPE,
        value: new WriteImageResponse(true),
      };
    }

    if (action === "write-uris") {
      const request = expectBridgeRequestType(
        payload,
        "ohos.clipboard",
        action,
        WRITE_URIS_REQUEST_TYPE,
      ) as WriteUrisRequest;
      if (
        !Array.isArray(request.uris) ||
        request.uris.length === 0 ||
        request.uris.some((uri) => typeof uri !== "string" || !uri.startsWith("file://"))
      ) {
        throw new Error("write-uris.uris must contain file:// URIs");
      }
      // Both addRecord overloads prepend; construct from the end to preserve URI order.
      const data = pasteboard.createData(
        pasteboard.MIMETYPE_TEXT_URI,
        request.uris[request.uris.length - 1],
      );
      for (let index = request.uris.length - 2; index >= 0; index--) {
        data.addRecord(pasteboard.MIMETYPE_TEXT_URI, request.uris[index]);
      }
      await pasteboard.getSystemPasteboard().setData(data);
      return { typeName: WRITE_TEXT_RESPONSE_TYPE, value: new WriteTextResponse(true) };
    }

    if (action === "read-text") {
      expectBridgeRequestType(payload, "ohos.clipboard", action, READ_TEXT_REQUEST_TYPE);
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = await systemPasteboard.getData();
      // On OHOS, a denied READ_PASTEBOARD can return an empty PasteData without
      // rejecting getData(). Distinguish that from a genuinely empty clipboard.
      if (data.getRecordCount() === 0 && (await systemPasteboard.hasData())) {
        throw new Error(
          "Clipboard contains data but cannot be read; check ohos.permission.READ_PASTEBOARD and the signing profile ACL",
        );
      }
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
      throw e as Error;
    } finally {
      pm?.release();
    }
  }
}
