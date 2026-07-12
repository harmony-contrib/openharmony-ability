import common from "@ohos.app.ability.common";
import deviceInfo from "@ohos.deviceInfo";
import picker from "@ohos.file.picker";
import { FileDialogFilter, FileDialogOptions, FileDialogResult } from "../ability/type";

const FOLDER_SELECTION_SYSCAP = "SystemCapability.FileManagement.UserFileService.FolderSelection";

export function pickerSuffixFilters(filters: FileDialogFilter[]): string[] | undefined {
  const choices: string[] = [];
  filters.forEach((filter: FileDialogFilter) => {
    const pattern = filter.pattern || "*";
    const name = (filter.name || "Files").split("|").join(" ");
    if (pattern === "*") {
      choices.push(`${name}|.*`);
      return;
    }

    const suffixes: string[] = [];
    pattern.split(";").forEach((suffix: string) => {
      const trimmed = suffix.trim();
      if (trimmed.length > 0) {
        suffixes.push(trimmed.startsWith(".") ? trimmed : `.${trimmed}`);
      }
    });
    if (suffixes.length > 0) {
      choices.push(`${name}|${suffixes.join(",")}`);
    }
  });
  return choices.length > 0 ? choices : undefined;
}

export function pickerLocation(location: string | undefined): string | undefined {
  return location && location.indexOf("://") > 0 ? location : undefined;
}

function supportsFolderSelection(): boolean {
  return deviceInfo.deviceType === "2in1" && canIUse(FOLDER_SELECTION_SYSCAP);
}

export async function showFileDialog(
  context: common.UIAbilityContext,
  options: FileDialogOptions,
): Promise<FileDialogResult> {
  const documentPicker = new picker.DocumentViewPicker(context);
  const location = pickerLocation(options.defaultLocation);
  const suffixFilters = pickerSuffixFilters(options.filters || []);

  if (options.type === "saveFile") {
    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.defaultFilePathUri = location;
    saveOptions.fileSuffixChoices = suffixFilters;
    const files = await documentPicker.save(saveOptions);
    let filter = -1;
    if (deviceInfo.sdkApiVersion >= 14 && supportsFolderSelection()) {
      filter = documentPicker.getSelectedIndex();
    }
    return { files, filter } as FileDialogResult;
  }

  const selectOptions = new picker.DocumentSelectOptions();
  selectOptions.defaultFilePathUri = location;
  selectOptions.maxSelectNumber = options.allowMany ? 500 : 1;
  selectOptions.fileSuffixFilters = suffixFilters;
  if (options.type === "openFolder") {
    if (!supportsFolderSelection()) {
      throw new Error(
        "OpenHarmony folder selection requires a 2-in-1 device with FolderSelection capability",
      );
    }
    selectOptions.selectMode = picker.DocumentSelectMode.FOLDER;
    selectOptions.maxSelectNumber = 1;
    selectOptions.fileSuffixFilters = undefined;
  }
  return {
    files: await documentPicker.select(selectOptions),
    filter: -1,
  } as FileDialogResult;
}
