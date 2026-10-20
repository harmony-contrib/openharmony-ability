import pasteboard from "@ohos.pasteboard";
import abilityAccessCtrl from "@ohos.abilityAccessCtrl";
import common from "@ohos.app.ability.common";
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
  WindowManager,
} from "@ohos-rs/ability";

const READ_AUTHORIZED_RECORDS_REQUEST_TYPE = "ohos.clipboard.ReadAuthorizedRecordsRequest";
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
const WRITE_MIME_REQUEST_TYPE = "ohos.clipboard.WriteMimeRequest";
const READ_MIME_REQUEST_TYPE = "ohos.clipboard.ReadMimeRequest";
const READ_MIME_RESPONSE_TYPE = "ohos.clipboard.ReadMimeResponse";
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

interface MimeContent {
  mime: string;
  data: Uint8Array | number[];
}
interface WriteMimeRequest {
  contents: MimeContent[];
}
interface ReadMimeRequest {
  mimes: string[];
  list: boolean;
}
class ReadMimeResponse {
  readonly contents: MimeContent[];
  readonly available: string[];
  constructor(contents: MimeContent[], available: string[]) {
    this.contents = contents;
    this.available = available;
  }
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
  private observedPasteboard?: pasteboard.SystemPasteboard;
  private initialization?: Promise<void>;
  private disposed: boolean = false;
  private readPermissionRequest?: Promise<void>;
  private writeTail: Promise<void> = Promise.resolve();

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
    this.disposed = false;
    const updateListener = (): void => {
      if (!context.isActive() || this.updateListener !== updateListener) {
        return;
      }
      try {
        context.invokeNativeSync("changed", CHANGED_EVENT_TYPE, "std.bool", {});
      } catch (error) {
        console.warn(`[Clipboard] update notification failed: ${String(error)}`);
      }
    };
    this.updateListener = updateListener;
    this.observeUpdates((): boolean => context.isActive());
  }

  private observeUpdates(isActive: () => boolean): Promise<void> {
    if (this.initialization) {
      return this.initialization;
    }
    const updateListener = this.updateListener;
    if (!updateListener || this.disposed) {
      return Promise.resolve();
    }
    const systemPasteboard = pasteboard.getSystemPasteboard();
    // on("update") initializes the native singleton through synchronous Binder IPC.
    // hasData() connects on the SDK's worker first, without reading clipboard contents
    // or holding up Ability startup while the system service is loading.
    const initialization = systemPasteboard.hasData().then((): void => {
      if (!isActive() || this.disposed || this.updateListener !== updateListener) {
        return;
      }
      systemPasteboard.on("update", updateListener);
      this.observedPasteboard = systemPasteboard;
    });
    this.initialization = initialization;
    initialization.catch((error: Error): void => {
      if (this.initialization === initialization) {
        this.initialization = undefined;
      }
      console.warn(`[Clipboard] initialization failed: ${String(error)}`);
    });
    return initialization;
  }

  override onDispose(): void {
    const systemPasteboard = this.observedPasteboard;
    const updateListener = this.updateListener;
    this.disposed = true;
    this.observedPasteboard = undefined;
    this.updateListener = undefined;
    this.initialization = undefined;
    this.readPermissionRequest = undefined;
    if (systemPasteboard && updateListener) {
      try {
        systemPasteboard.off("update", updateListener);
      } catch (error) {
        console.warn(`[Clipboard] removing update listener failed: ${String(error)}`);
      }
    }
  }

  private async requestReadPermission(context: BridgeCallContext): Promise<void> {
    if (this.disposed || !context.isActive()) {
      throw new Error("Clipboard permission request was cancelled");
    }
    let request = this.readPermissionRequest;
    if (!request) {
      const focusedWindow = WindowManager.getInstance().getFocusedWindow();
      // Secondary workspaces have a different Ability; its dialog must own the focus.
      const abilityContext = focusedWindow
        ? (focusedWindow.getUIContext().getHostContext() as common.UIAbilityContext)
        : context.abilityContext;
      request = abilityAccessCtrl
        .createAtManager()
        .requestPermissionsFromUser(abilityContext, ["ohos.permission.READ_PASTEBOARD"])
        .then((result): void => {
          if (result.authResults?.[0] !== 0) {
            throw new Error(
              "Clipboard access was denied. Allow clipboard access for the application in system settings.",
            );
          }
        })
        .finally((): void => {
          if (this.readPermissionRequest === request) {
            this.readPermissionRequest = undefined;
          }
        });
      this.readPermissionRequest = request;
    }
    await request;
    if (this.disposed || !context.isActive()) {
      throw new Error("Clipboard permission request was cancelled");
    }
  }

  private async readRecordsData(
    context: BridgeCallContext,
    authorize: boolean,
  ): Promise<pasteboard.PasteData> {
    const systemPasteboard = pasteboard.getSystemPasteboard();
    try {
      const data = await systemPasteboard.getData();
      if (data.getRecordCount() > 0 || !(await systemPasteboard.hasData())) {
        return data;
      }
    } catch (error) {
      if (!authorize || (error as BusinessError).code !== 201) {
        throw new Error(`Clipboard getData failed: ${String(error)}`);
      }
    }
    if (!authorize) {
      throw new Error(
        "Clipboard data is unreadable; check READ_PASTEBOARD signing profile ACL and runtime authorization",
      );
    }
    // A native PasteButton or shortcut may already grant temporary access.
    // Request persistent access only when that ordinary read could not succeed.
    await this.requestReadPermission(context);
    const data = await systemPasteboard.getData();
    if (data.getRecordCount() === 0 && (await systemPasteboard.hasData())) {
      throw new Error(
        "Clipboard data is unreadable after authorization; check READ_PASTEBOARD signing profile ACL",
      );
    }
    return data;
  }

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    const previous = this.writeTail;
    if (!action.startsWith("write-") && action !== "clear") {
      await previous;
      return this.executeAsync(action, payload, context);
    }
    let finish: () => void = (): void => {};
    this.writeTail = new Promise<void>((resolve): void => {
      finish = resolve;
    });
    await previous;
    try {
      return await this.executeAsync(action, payload, context);
    } finally {
      finish();
    }
  }

  private async executeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    await this.observeUpdates((): boolean => context.isActive());
    if (this.disposed || !context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }

    if (action === "write-mime") {
      const request = expectBridgeRequestType(
        payload,
        this.id,
        action,
        WRITE_MIME_REQUEST_TYPE,
      ) as WriteMimeRequest;
      if (!Array.isArray(request.contents) || request.contents.length > 512) {
        throw new Error("write-mime requires at most 512 representations");
      }
      if (request.contents.length === 0) {
        await pasteboard.getSystemPasteboard().clearData();
      } else {
        let record: pasteboard.PasteDataRecord | undefined;
        const maps: image.PixelMap[] = [];
        try {
          for (const content of request.contents) {
            if (!(content.data instanceof Uint8Array) && !Array.isArray(content.data)) {
              throw new Error("Clipboard MIME representation requires bytes");
            }
            if (
              typeof content.mime !== "string" ||
              content.mime.length === 0 ||
              new util.TextEncoder().encodeInto(content.mime).length > 1024 ||
              content.mime.includes("\0") ||
              content.mime === pasteboard.MIMETYPE_PIXELMAP ||
              content.mime === pasteboard.MIMETYPE_TEXT_WANT
            ) {
              throw new Error("Unsupported clipboard MIME type");
            }
            const bytes = new Uint8Array(content.data);
            let value: pasteboard.ValueType;
            if (
              content.mime === pasteboard.MIMETYPE_TEXT_PLAIN ||
              content.mime === pasteboard.MIMETYPE_TEXT_HTML ||
              content.mime === pasteboard.MIMETYPE_TEXT_URI
            ) {
              value =
                bytes.byteLength === 0
                  ? ""
                  : new util.TextDecoder("utf-8", { fatal: true }).decodeToString(bytes);
            } else {
              value = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
            }
            if (record === undefined) {
              record = pasteboard.createRecord(content.mime, value);
            } else {
              record.addEntry(content.mime, value);
            }
            // Keep original encoded bytes under their MIME and also offer a
            // native image representation to other OHOS applications.
            if (content.mime.startsWith("image/")) {
              let source: image.ImageSource | undefined;
              try {
                source = image.createImageSource(bytes.buffer);
                const map = await source.createPixelMap();
                maps.push(map);
                record.addEntry(pasteboard.MIMETYPE_PIXELMAP, map);
              } catch (error) {
                // Clipboard data is opaque. Unsupported image formats still
                // remain readable under their exact original MIME type.
                console.info(`[Clipboard] no native image projection: ${String(error)}`);
              } finally {
                source?.release();
              }
            }
          }
          if (!context.isActive()) {
            throw new Error("Clipboard write was cancelled");
          }
          const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, "");
          data.replaceRecord(0, record!);
          await pasteboard.getSystemPasteboard().setData(data);
        } finally {
          for (const map of maps) {
            map.release();
          }
        }
      }
      if (!context.isActive()) {
        throw new Error("Clipboard write was cancelled");
      }
      return { typeName: WRITE_TEXT_RESPONSE_TYPE, value: new WriteTextResponse(true) };
    }

    if (action === "read-mime") {
      const request = expectBridgeRequestType(
        payload,
        this.id,
        action,
        READ_MIME_REQUEST_TYPE,
      ) as ReadMimeRequest;
      if (
        !Array.isArray(request.mimes) ||
        request.mimes.length > 512 ||
        typeof request.list !== "boolean"
      ) {
        throw new Error("read-mime requires at most 512 MIME types");
      }
      const board = pasteboard.getSystemPasteboard();
      if (!(await board.hasData())) {
        if (!context.isActive()) {
          throw new Error("Clipboard read was cancelled");
        }
        return { typeName: READ_MIME_RESPONSE_TYPE, value: new ReadMimeResponse([], []) };
      }
      const data = await board.getData();
      if (data.getRecordCount() === 0 && (await board.hasData())) {
        throw new Error("Clipboard data is unreadable");
      }
      const available = data
        .getMimeTypes()
        .filter(
          (mime: string): boolean =>
            mime !== pasteboard.MIMETYPE_PIXELMAP && mime !== pasteboard.MIMETYPE_TEXT_WANT,
        );
      if (
        data.getMimeTypes().includes(pasteboard.MIMETYPE_PIXELMAP) &&
        !available.includes("image/png")
      ) {
        available.push("image/png");
      }
      const contents: MimeContent[] = [];
      for (const mime of request.mimes) {
        if (
          typeof mime !== "string" ||
          mime.length === 0 ||
          mime.includes("\0") ||
          new util.TextEncoder().encodeInto(mime).length > 1024
        ) {
          throw new Error("Invalid requested clipboard MIME type");
        }
        const alias = ["text/plain;charset=utf-8", "UTF8_STRING", "TEXT", "STRING"].includes(mime);
        let found = false;
        for (let index = 0; index < data.getRecordCount() && !found; index++) {
          const record = data.getRecordAt(index);
          const candidates = [mime];
          if (alias) {
            candidates.push(pasteboard.MIMETYPE_TEXT_PLAIN);
          }
          if (mime === "image/png") {
            candidates.push(pasteboard.MIMETYPE_PIXELMAP);
          }
          for (const candidate of candidates) {
            if (record.getValidTypes([candidate]).length === 0) {
              continue;
            }
            const value = await record.getData(candidate);
            let bytes: Uint8Array;
            if (typeof value === "string") {
              // OHOS TextEncoder.encodeInto("") returns undefined, despite its
              // Uint8Array declaration. An empty representation is still data.
              bytes =
                value.length === 0 ? new Uint8Array(0) : new util.TextEncoder().encodeInto(value);
            } else if (value instanceof ArrayBuffer) {
              bytes = new Uint8Array(value);
            } else if (candidate === pasteboard.MIMETYPE_PIXELMAP) {
              const packer = image.createImagePacker();
              try {
                bytes = new Uint8Array(
                  await packer.packToData(value as image.PixelMap, {
                    format: "image/png",
                    quality: 100,
                  }),
                );
              } finally {
                packer.release();
              }
            } else {
              continue;
            }
            contents.push({ mime, data: Array.from(bytes) });
            found = true;
            break;
          }
        }
      }
      if (!context.isActive()) {
        throw new Error("Clipboard read was cancelled");
      }
      return {
        typeName: READ_MIME_RESPONSE_TYPE,
        value: new ReadMimeResponse(contents, request.list ? available : []),
      };
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

    if (action === "read-records" || action === "read-authorized-records") {
      expectBridgeRequestType(
        payload,
        this.id,
        action,
        action === "read-authorized-records"
          ? READ_AUTHORIZED_RECORDS_REQUEST_TYPE
          : READ_TEXT_REQUEST_TYPE,
      );
      const data = await this.readRecordsData(context, action === "read-authorized-records");
      const entries: ClipboardRecord[] = [];
      for (let index = 0; index < data.getRecordCount(); index++) {
        const record = data.getRecordAt(index);
        if (record.getValidTypes([pasteboard.MIMETYPE_TEXT_PLAIN]).length > 0) {
          const text = await record.getData(pasteboard.MIMETYPE_TEXT_PLAIN);
          if (typeof text !== "string") {
            throw new Error("Invalid native text representation");
          }
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
          entries.push({ text, metadata });
        } else if (record.getValidTypes(["image/png"]).length > 0) {
          const encoded = await record.getData("image/png");
          if (encoded instanceof ArrayBuffer) {
            entries.push({ encodedImage: Array.from(new Uint8Array(encoded)) });
          }
        } else if (record.getValidTypes([pasteboard.MIMETYPE_TEXT_URI]).length > 0) {
          const uri = await record.getData(pasteboard.MIMETYPE_TEXT_URI);
          if (typeof uri === "string" && uri.startsWith("file://")) {
            entries.push({ uri });
          }
        } else if (record.getValidTypes([pasteboard.MIMETYPE_PIXELMAP]).length > 0) {
          const pixelMap = (await record.getData(pasteboard.MIMETYPE_PIXELMAP)) as image.PixelMap;
          const packer = image.createImagePacker();
          try {
            const encoded = await packer
              .packToData(pixelMap, { format: "image/png", quality: 100 })
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
