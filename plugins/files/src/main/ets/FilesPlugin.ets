import common from "@ohos.app.ability.common";
import { BusinessError } from "@ohos.base";
import deviceInfo from "@ohos.deviceInfo";
import picker from "@ohos.file.picker";
import {
  BridgeCallContext,
  BridgeTypedValue,
  AsyncPluginBase,
  BridgeContextRequirement,
} from "@ohos-rs/ability";

const DIALOG_OPTIONS_TYPE = "ohos.files.DialogOptions";
const DIALOG_RESPONSE_TYPE = "ohos.files.DialogResponse";

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

function parseDialogOptions(payload: BridgeTypedValue): FileDialogOptions {
  if (payload.typeName !== DIALOG_OPTIONS_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.files.file-dialog requires bridge type ${DIALOG_OPTIONS_TYPE}`);
  }
  const request = payload.value as FileDialogOptions;
  if (
    request.dialogType !== "open-file" &&
    request.dialogType !== "save-file" &&
    request.dialogType !== "open-folder"
  ) {
    throw new Error(`file-dialog.dialogType '${request.dialogType}' is unsupported`);
  }
  if (request.dialogType === "open-folder" && request.allowMany === true) {
    throw new Error("open-folder dialog does not support allowMany");
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
  context: common.UIAbilityContext,
  options: FileDialogOptions,
): Promise<FileDialogResponse> {
  const documentPicker = new picker.DocumentViewPicker(context);
  const location = pickerLocation(options.defaultLocation);
  const suffixFilters = pickerSuffixFilters(options.filters || []);

  if (options.dialogType === "save-file") {
    const saveOptions = new picker.DocumentSaveOptions();
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
    selectOptions.maxSelectNumber = 1;
    selectOptions.fileSuffixFilters = undefined;
  }
  return new FileDialogResponse(await documentPicker.select(selectOptions), -1);
}

export class FilesPlugin extends AsyncPluginBase {
  readonly id = "ohos.files";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("File dialog plugin is not active");
    }
    if (action !== "file-dialog") {
      throw new Error(`Unsupported ohos.files action '${action}'`);
    }
    const options = parseDialogOptions(payload);
    let response: FileDialogResponse;
    try {
      response = await showFileDialog(context.abilityContext, options);
    } catch (error) {
      const detail = error as BusinessError;
      throw new Error(
        `file-dialog ${options.dialogType} failed (device=${deviceInfo.deviceType}, ` +
          `api=${deviceInfo.sdkApiVersion}, code=${detail.code ?? "unknown"}): ${detail.message}`,
      );
    }
    if (!context.isActive()) {
      throw new Error("Ability was destroyed while the file dialog was pending");
    }
    return { typeName: DIALOG_RESPONSE_TYPE, value: response };
  }
}
