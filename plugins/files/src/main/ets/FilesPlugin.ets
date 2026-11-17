import application from "@ohos.app.ability.application";
import common from "@ohos.app.ability.common";
import { BusinessError } from "@ohos.base";
import deviceInfo from "@ohos.deviceInfo";
import picker from "@ohos.file.picker";
import { BuilderNode } from "@ohos.arkui.node";
import { DrawableDescriptor } from "@ohos.arkui.drawableDescriptor";
import { UIContext } from "@ohos.arkui.UIContext";
import { fileIo, fileUri } from "@kit.CoreFileKit";
import { uniformTypeDescriptor } from "@kit.ArkData";
import { image } from "@kit.ImageKit";
import resourceManager from "@ohos.resourceManager";
import { util } from "@kit.ArkTS";
import { fileManagerService } from "@kit.FileManagerServiceKit";
import {
  BridgeCallContext,
  BridgeTypedValue,
  AsyncPluginBase,
  BridgeContextRequirement,
  WindowManager,
} from "@ohos-rs/ability";

const DIALOG_OPTIONS_TYPE = "ohos.files.DialogOptions";
const DIALOG_RESPONSE_TYPE = "ohos.files.DialogResponse";
const TRASH_ITEM_REQUEST_TYPE = "ohos.files.TrashItemRequest";
const TRASH_ITEM_RESPONSE_TYPE = "ohos.files.TrashItemResponse";
const FILE_ICON_REQUEST_TYPE = "ohos.files.FileIconRequest";
const FILE_ICON_RESPONSE_TYPE = "ohos.files.FileIconResponse";
const FILE_MANAGER_SERVICE_SYSCAP = "SystemCapability.FileManagement.FileManagerService.Core";

// This SysCap guards getSelectedIndex(), not opening the folder picker.
const SELECTED_FILTER_INDEX_SYSCAP =
  "SystemCapability.FileManagement.UserFileService.FolderSelection";

interface FileDialogFilter {
  name?: string | null;
  pattern?: string | null;
}

interface FileDialogOptions {
  dialogType: string;
  allowMany: boolean;
  defaultLocation?: string | null;
  suggestedName?: string | null;
  filters: FileDialogFilter[];
  parentWindowId?: number | null;
}

interface DocumentSelectOptionsWithMultipleFolders {
  allowsMulFolderSelection?: boolean;
}

interface DocumentViewPickerWithSelectedIndex {
  getSelectedIndex(): number;
}

class FileDialogResponse {
  readonly files: string[];
  readonly filter: number;

  constructor(files: string[], filter: number) {
    this.files = files;
    this.filter = filter;
  }
}

interface TrashItemRequest {
  path: string;
}

class TrashItemResponse {
  readonly trashedUri: string;

  constructor(trashedUri: string) {
    this.trashedUri = trashedUri;
  }
}

interface FileIconRequest {
  path?: string | null;
  extension?: string | null;
  sizePx: number;
}

class FileIconResponse {
  readonly pngBase64: string;

  constructor(pngBase64: string) {
    this.pngBase64 = pngBase64;
  }
}

function resolveUtdForIcon(req: FileIconRequest): string {
  const rawPath = req.path?.trim() ?? "";
  if (rawPath.length > 0) {
    try {
      if (fileIo.statSync(rawPath).isDirectory()) {
        return uniformTypeDescriptor.UniformDataType.FOLDER;
      }
    } catch {
      // Fall back to filename extension if stat fails.
    }
    const base = rawPath.slice(rawPath.lastIndexOf("/") + 1);
    const dot = base.lastIndexOf(".");
    if (dot > 0 && dot < base.length - 1) {
      const ext = base.slice(dot).toLowerCase();
      try {
        const utd = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(ext);
        if (utd) {
          return utd;
        }
      } catch {
        // Ignore unknown extension lookup error and use general file type.
      }
    }
    return uniformTypeDescriptor.UniformDataType.FILE;
  }
  const rawExt = (req.extension ?? "").trim().toLowerCase();
  if (rawExt.length > 0) {
    const ext = rawExt.startsWith(".") ? rawExt : `.${rawExt}`;
    try {
      const utd = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(ext);
      if (utd) {
        return utd;
      }
    } catch {
      // Ignore unknown extension lookup error and use general file type.
    }
  }
  return uniformTypeDescriptor.UniformDataType.FILE;
}

interface FileIconSnapshotSpec {
  icon: Resource;
  componentId: string;
  sizePx: number;
}

@Builder
function BuildFileIconSnapshot(spec: FileIconSnapshotSpec) {
  Stack() {
    Image(spec.icon)
      .id(spec.componentId)
      .width(`${spec.sizePx}px`)
      .height(`${spec.sizePx}px`)
      .objectFit(ImageFit.Contain)
      .syncLoad(true)
  }
  .width(`${spec.sizePx}px`)
  .height(`${spec.sizePx}px`)
  .position({ x: -4096, y: -4096 })
  .hitTestBehavior(HitTestMode.None);
}

const fileIconSnapshotBuilder = wrapBuilder<[FileIconSnapshotSpec]>(BuildFileIconSnapshot);
let nextFileIconSnapshotSeq = 0;

async function packPixelMapToPngBase64(
  pixelMap: image.PixelMap,
  sizePx: number,
  base64: util.Base64Helper,
): Promise<string> {
  const info = await pixelMap.getImageInfo();
  if (
    info.size.width > 0 &&
    info.size.height > 0 &&
    (info.size.width !== sizePx || info.size.height !== sizePx)
  ) {
    await pixelMap.scale(sizePx / info.size.width, sizePx / info.size.height);
  }
  let packer: image.ImagePacker | null = null;
  try {
    packer = image.createImagePacker();
    const pngBuffer = await packer.packToData(pixelMap, { format: "image/png", quality: 100 });
    return base64.encodeToStringSync(new Uint8Array(pngBuffer));
  } finally {
    try {
      await packer?.release();
    } catch {}
  }
}

async function decodeBytesToPngBase64(
  rawBytes: Uint8Array,
  sizePx: number,
  base64: util.Base64Helper,
): Promise<string> {
  const exactBuffer = rawBytes.buffer.slice(
    rawBytes.byteOffset,
    rawBytes.byteOffset + rawBytes.byteLength,
  );
  const source = image.createImageSource(exactBuffer);
  let pixelMap: image.PixelMap | null = null;
  try {
    pixelMap = await source.createPixelMap({
      desiredSize: { width: sizePx, height: sizePx },
    });
    return await packPixelMapToPngBase64(pixelMap, sizePx, base64);
  } finally {
    try {
      await pixelMap?.release();
    } catch {}
    try {
      await source.release();
    } catch {}
  }
}

function extractResourceNames(icon: Resource): string[] {
  const names: string[] = [];
  const dynamicIcon: ESObject = icon as ESObject;
  const params: ESObject = dynamicIcon.params;
  if (!Array.isArray(params) || params.length === 0) {
    return names;
  }
  const first: ESObject = params[0];
  if (typeof first !== "string" || first.length === 0) {
    return names;
  }
  names.push(first);
  const lastDot = first.lastIndexOf(".");
  if (lastDot >= 0 && lastDot + 1 < first.length) {
    names.push(first.slice(lastDot + 1));
  }
  return names;
}

async function collectIconResourceManagers(
  context: BridgeCallContext,
  icon: Resource,
  errors: string[],
): Promise<resourceManager.ResourceManager[]> {
  const managers: resourceManager.ResourceManager[] = [context.abilityContext.resourceManager];
  try {
    const sysRm =
      deviceInfo.sdkApiVersion >= 20
        ? resourceManager.getSysResourceManager()
        : resourceManager.getSystemResourceManager();
    managers.push(sysRm);
  } catch (error) {
    errors.push(`sysRm: ${String(error)}`);
  }
  if (icon.bundleName && icon.moduleName && deviceInfo.sdkApiVersion >= 19) {
    try {
      const pluginCtx = await application.createPluginModuleContext(
        context.abilityContext,
        icon.bundleName,
        icon.moduleName,
      );
      managers.push(pluginCtx.resourceManager);
    } catch (error) {
      errors.push(`pluginModuleCtx: ${String(error)}`);
    }
  }
  if (icon.moduleName) {
    try {
      const modCtx = await application.createModuleContext(context.abilityContext, icon.moduleName);
      managers.push(modCtx.resourceManager);
    } catch (error) {
      errors.push(`moduleCtx: ${String(error)}`);
    }
  }
  return managers;
}

async function tryLoadBytesOrDrawable(
  rm: resourceManager.ResourceManager,
  icon: Resource,
  names: string[],
  sizePx: number,
  base64: util.Base64Helper,
  errors: string[],
): Promise<string | null> {
  const byteCandidates: Uint8Array[] = [];
  try {
    byteCandidates.push(rm.getMediaContentSync(icon));
  } catch (error) {
    errors.push(`media(res): ${String(error)}`);
  }
  if (Number.isInteger(icon.id) && icon.id > 0) {
    try {
      byteCandidates.push(rm.getMediaContentSync(icon.id));
    } catch (error) {
      errors.push(`media(id): ${String(error)}`);
    }
  }
  for (const name of names) {
    try {
      byteCandidates.push(rm.getMediaByNameSync(name));
    } catch (error) {
      errors.push(`media(name=${name}): ${String(error)}`);
    }
  }
  for (const raw of byteCandidates) {
    if (raw.byteLength === 0) {
      continue;
    }
    try {
      return await decodeBytesToPngBase64(raw, sizePx, base64);
    } catch (error) {
      errors.push(`decodeBytes: ${String(error)}`);
    }
  }

  const drawables: DrawableDescriptor[] = [];
  try {
    drawables.push(rm.getDrawableDescriptor(icon));
  } catch (error) {
    errors.push(`drawable(res): ${String(error)}`);
  }
  if (Number.isInteger(icon.id) && icon.id > 0) {
    try {
      drawables.push(rm.getDrawableDescriptor(icon.id));
    } catch (error) {
      errors.push(`drawable(id): ${String(error)}`);
    }
  }
  for (const name of names) {
    try {
      drawables.push(rm.getDrawableDescriptorByName(name));
    } catch (error) {
      errors.push(`drawable(name=${name}): ${String(error)}`);
    }
  }
  for (const dd of drawables) {
    let pixelMap: image.PixelMap | null = null;
    try {
      pixelMap = dd.getPixelMap();
      if (pixelMap) {
        return await packPixelMapToPngBase64(pixelMap, sizePx, base64);
      }
    } catch (error) {
      errors.push(`drawablePixelMap: ${String(error)}`);
    } finally {
      try {
        await pixelMap?.release();
      } catch {}
    }
  }
  return null;
}

async function loadIconViaSnapshot(
  context: BridgeCallContext,
  icon: Resource,
  sizePx: number,
  base64: util.Base64Helper,
  errors: string[],
): Promise<string | null> {
  nextFileIconSnapshotSeq += 1;
  const seq = nextFileIconSnapshotSeq;
  const componentId = `__ability_file_icon_${seq}`;
  const mountKey = `ohos.files.icon-snapshot.${seq}`;
  let uiCtx: UIContext;
  try {
    uiCtx = context.getUIContext();
  } catch {
    uiCtx = (await context.getWindowStage().getMainWindow()).getUIContext();
  }
  const node = new BuilderNode<[FileIconSnapshotSpec]>(uiCtx);
  let mounted = false;
  try {
    node.build(fileIconSnapshotBuilder, { icon, componentId, sizePx });
    const frameNode = node.getFrameNode();
    if (frameNode === null) {
      errors.push("snapshot: missing FrameNode");
      return null;
    }
    context.appendChild(mountKey, frameNode, (): void => {
      try {
        frameNode.dispose();
      } catch {}
    });
    mounted = true;
    const delays = [16, 50, 100];
    for (const delayMs of delays) {
      await new Promise<void>((resolve) => {
        setTimeout((): void => resolve(), delayMs);
      });
      if (!context.isActive() || context.isCancelled()) {
        return null;
      }
      let snap: image.PixelMap | null = null;
      try {
        snap = await uiCtx.getComponentSnapshot().get(componentId, {
          waitUntilRenderFinished: true,
        });
        return await packPixelMapToPngBase64(snap, sizePx, base64);
      } catch (error) {
        errors.push(`snapshot(${delayMs}ms): ${String(error)}`);
      } finally {
        try {
          await snap?.release();
        } catch {}
      }
    }
  } catch (error) {
    errors.push(`snapshotMount: ${String(error)}`);
  } finally {
    if (mounted) {
      try {
        context.removeChild(mountKey);
      } catch {}
    }
    try {
      node.dispose();
    } catch {}
  }
  return null;
}

async function loadFileIconPngBase64(
  context: BridgeCallContext,
  req: FileIconRequest,
  sizePx: number,
): Promise<string> {
  const utd = resolveUtdForIcon(req);
  const icon = await fileManagerService.getFileIcon(utd);
  const base64 = new util.Base64Helper();
  if (typeof icon === "string") {
    const comma = icon.indexOf(",");
    const payload = icon.startsWith("data:") && comma >= 0 ? icon.slice(comma + 1) : icon;
    const rawBytes = base64.decodeSync(payload);
    return await decodeBytesToPngBase64(rawBytes, sizePx, base64);
  }
  const errors: string[] = [];
  const names = extractResourceNames(icon);
  const managers = await collectIconResourceManagers(context, icon, errors);
  for (const rm of managers) {
    const resolved = await tryLoadBytesOrDrawable(rm, icon, names, sizePx, base64, errors);
    if (resolved !== null) {
      return resolved;
    }
  }
  const snapped = await loadIconViaSnapshot(context, icon, sizePx, base64, errors);
  if (snapped !== null) {
    return snapped;
  }
  throw new Error(
    `Unable to decode file icon for utd=${utd} resource(id=${icon.id}, bundle=${icon.bundleName}, module=${icon.moduleName}, type=${icon.type ?? -1}): ${errors.slice(0, 6).join("; ")}`,
  );
}

function parseDialogOptions(payload: BridgeTypedValue): FileDialogOptions {
  if (payload.typeName !== DIALOG_OPTIONS_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.files.file-dialog requires bridge type ${DIALOG_OPTIONS_TYPE}`);
  }
  const request = payload.value as FileDialogOptions;
  if (
    request.parentWindowId != null &&
    (!Number.isSafeInteger(request.parentWindowId) || request.parentWindowId < 0)
  ) {
    throw new Error("file-dialog.parentWindowId must be a non-negative safe integer");
  }
  if (
    request.dialogType !== "open-file" &&
    request.dialogType !== "save-file" &&
    request.dialogType !== "open-folder" &&
    request.dialogType !== "open-mixed"
  ) {
    throw new Error(`file-dialog.dialogType '${request.dialogType}' is unsupported`);
  }
  if (typeof request.filters !== "object") {
    throw new Error("file-dialog.filters must be an array");
  }
  if (request.suggestedName != null) {
    if (
      typeof request.suggestedName !== "string" ||
      request.dialogType !== "save-file" ||
      request.suggestedName.trim().length === 0
    ) {
      throw new Error("file-dialog.suggestedName requires a save-file dialog and a non-empty name");
    }
  }
  return request;
}

/**
 * Picker-specific filter grammar is an internal ArkTS concern: structured `{ name, pattern }`
 * groups arrive through the bridge and are converted to the `name|*.ext` choice strings here.
 * No string-encoded filter grammar crosses the bridge.
 */
function pickerSuffixFilters(filters: FileDialogFilter[]): string[] | undefined {
  const choices: string[] = [];
  for (const filter of filters) {
    const pattern = filter.pattern || "*";
    const name = (filter.name || "Files").split("|").join(" ");
    if (pattern === "*") {
      choices.push(`${name}|.*`);
      continue;
    }
    const suffixes: string[] = [];
    const parts = pattern.split(";");
    for (const part of parts) {
      const trimmed = part.trim();
      if (trimmed.length > 0) {
        suffixes.push(trimmed.startsWith(".") ? trimmed : `.${trimmed}`);
      }
    }
    if (suffixes.length > 0) {
      choices.push(`${name}|${suffixes.join(",")}`);
    }
  }
  return choices.length > 0 ? choices : undefined;
}

function pickerLocation(location: string | undefined | null): string | undefined {
  return location && location.indexOf("://") > 0 ? location : undefined;
}

async function showFileDialog(
  context: BridgeCallContext,
  options: FileDialogOptions,
  autoCreateEmptyFile: boolean,
): Promise<FileDialogResponse> {
  let documentPicker: picker.DocumentViewPicker;
  if (options.parentWindowId != null) {
    if (deviceInfo.sdkApiVersion < 13) {
      throw new Error("Window-owned file dialogs require API 13 or newer");
    }
    const manager = WindowManager.getInstance();
    // Zero is the calling component's window, just as in the window plugin.
    // Ability-only callers without an attached component must omit the parent.
    const hostWindow = options.parentWindowId === 0 ? context.getWindow() : undefined;
    if (hostWindow === undefined) {
      await manager.waitForWindowCreation(options.parentWindowId);
    }
    if (!context.isActive() || context.isCancelled()) {
      throw new Error("File dialog was cancelled before its parent window was ready");
    }
    const parent = hostWindow ?? manager.getWindow(options.parentWindowId);
    if (parent === undefined) {
      throw new Error(`File dialog parent window ${options.parentWindowId} no longer exists`);
    }
    // An Ability can keep running after its original main workspace closes. Using only its
    // context would attach this picker to that hidden window instead of the requesting one.
    const abilityContext = parent.getUIContext().getHostContext() as common.UIAbilityContext;
    if (deviceInfo.deviceType === "phone") {
      documentPicker = new picker.DocumentViewPicker(abilityContext);
    } else {
      documentPicker = new picker.DocumentViewPicker(abilityContext, parent);
    }
  } else {
    documentPicker = new picker.DocumentViewPicker(context.abilityContext);
  }
  const location = pickerLocation(options.defaultLocation);
  const suffixFilters = pickerSuffixFilters(options.filters || []);

  if (options.dialogType === "save-file") {
    const saveOptions = new picker.DocumentSaveOptions();
    if (deviceInfo.sdkApiVersion >= 23 && canIUse(SELECTED_FILTER_INDEX_SYSCAP)) {
      // Atomic writers select a destination without allocating a placeholder file.
      saveOptions.autoCreateEmptyFile = autoCreateEmptyFile;
    }
    saveOptions.defaultFilePathUri = location;
    if (options.suggestedName) {
      saveOptions.newFileNames = [options.suggestedName];
    }
    saveOptions.fileSuffixChoices = suffixFilters;
    const files = await documentPicker.save(saveOptions);
    let filter = -1;
    if (deviceInfo.sdkApiVersion >= 14 && canIUse(SELECTED_FILTER_INDEX_SYSCAP)) {
      // Keep the package compatible with API 12 while using the API 14 method only after the
      // runtime capability check. The narrow adapter prevents the static checker from rejecting
      // an otherwise guarded call solely because compatibleSdkVersion is lower than 14.
      filter = (documentPicker as DocumentViewPickerWithSelectedIndex).getSelectedIndex();
    }
    return new FileDialogResponse(files, filter);
  }

  const selectOptions = new picker.DocumentSelectOptions();
  selectOptions.defaultFilePathUri = location;
  selectOptions.maxSelectNumber = options.allowMany ? 500 : 1;
  selectOptions.fileSuffixFilters = suffixFilters;
  if (options.dialogType === "open-folder") {
    // Let DocumentViewPicker decide whether this device supports folder selection.
    // Product-type allowlists reject capable tablets; the selectMode SysCap also
    // changes from FolderSelection to UserFileService in API 26.
    selectOptions.selectMode = picker.DocumentSelectMode.FOLDER;
    if (deviceInfo.sdkApiVersion < 26) {
      selectOptions.maxSelectNumber = 1;
    }
    selectOptions.fileSuffixFilters = undefined;
  } else if (options.dialogType === "open-mixed") {
    if (!canIUse(SELECTED_FILTER_INDEX_SYSCAP)) {
      throw new Error("This device does not support mixed file and folder selection");
    }
    selectOptions.selectMode = picker.DocumentSelectMode.MIXED;
  }
  if (
    options.dialogType !== "open-file" &&
    deviceInfo.sdkApiVersion >= 26 &&
    canIUse("SystemCapability.FileManagement.UserFileService.FolderSelection")
  ) {
    // Keep the API-26 property behind a runtime guard for the API-12 package baseline.
    (selectOptions as DocumentSelectOptionsWithMultipleFolders).allowsMulFolderSelection =
      options.allowMany;
  }
  return new FileDialogResponse(await documentPicker.select(selectOptions), -1);
}

export class FilesPlugin extends AsyncPluginBase {
  readonly id = "ohos.files";
  readonly requires: BridgeContextRequirement[] = ["ability"];
  private readonly autoCreateEmptyFile: boolean;

  constructor(autoCreateEmptyFile: boolean = true) {
    super();
    this.autoCreateEmptyFile = autoCreateEmptyFile;
  }

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive() || context.isCancelled()) {
      throw new Error("File dialog plugin is not active");
    }
    if (action === "trash-item") {
      if (
        payload.typeName !== TRASH_ITEM_REQUEST_TYPE ||
        !payload.value ||
        typeof payload.value !== "object"
      ) {
        throw new Error(`ohos.files.trash-item requires bridge type ${TRASH_ITEM_REQUEST_TYPE}`);
      }
      const req = payload.value as TrashItemRequest;
      if (typeof req.path !== "string" || !req.path.trim()) {
        throw new Error("trash-item.path must not be empty");
      }
      if (!canIUse(FILE_MANAGER_SERVICE_SYSCAP) || deviceInfo.sdkApiVersion < 17) {
        throw new Error("Unsupported: FileManagerService trash is unavailable on this device");
      }
      const targetUri = req.path.includes("://") ? req.path : fileUri.getUriFromPath(req.path);
      const trashedUri = await fileManagerService.deleteToTrash(targetUri);
      if (!context.isActive() || context.isCancelled()) {
        throw new Error("trash-item was cancelled or its Ability was destroyed");
      }
      return { typeName: TRASH_ITEM_RESPONSE_TYPE, value: new TrashItemResponse(trashedUri) };
    }
    if (action === "get-file-icon") {
      if (
        payload.typeName !== FILE_ICON_REQUEST_TYPE ||
        !payload.value ||
        typeof payload.value !== "object"
      ) {
        throw new Error(`ohos.files.get-file-icon requires bridge type ${FILE_ICON_REQUEST_TYPE}`);
      }
      const req = payload.value as FileIconRequest;
      const sizePx = req.sizePx;
      if (!Number.isInteger(sizePx) || sizePx <= 0 || sizePx > 1024) {
        throw new Error("get-file-icon.sizePx must be 1..1024");
      }
      if (!canIUse(FILE_MANAGER_SERVICE_SYSCAP) || deviceInfo.sdkApiVersion < 17) {
        throw new Error("Unsupported: FileManagerService file icon is unavailable on this device");
      }
      const pngBase64 = await loadFileIconPngBase64(context, req, sizePx);
      if (!context.isActive() || context.isCancelled()) {
        throw new Error("get-file-icon was cancelled or its Ability was destroyed");
      }
      return { typeName: FILE_ICON_RESPONSE_TYPE, value: new FileIconResponse(pngBase64) };
    }
    if (action !== "file-dialog") {
      throw new Error(`Unsupported ohos.files action '${action}'`);
    }
    const options = parseDialogOptions(payload);
    let response: FileDialogResponse;
    try {
      response = await showFileDialog(context, options, this.autoCreateEmptyFile);
    } catch (error) {
      const detail = error as BusinessError;
      throw new Error(
        `file-dialog ${options.dialogType} failed (device=${deviceInfo.deviceType}, ` +
          `api=${deviceInfo.sdkApiVersion}, code=${detail.code ?? "unknown"}): ${detail.message}`,
      );
    }
    if (!context.isActive() || context.isCancelled()) {
      throw new Error("File dialog was cancelled or its Ability was destroyed");
    }
    return { typeName: DIALOG_RESPONSE_TYPE, value: response };
  }
}
