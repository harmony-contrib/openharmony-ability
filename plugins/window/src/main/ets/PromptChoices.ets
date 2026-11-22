import { ComponentContent, UIContext, window } from "@kit.ArkUI";
import type { BridgeCallContext } from "@ohos-rs/ability";
import type { WindowPromptRequest } from "./PromptDialogs";

export interface WindowPromptChoiceRequest extends WindowPromptRequest {
  checkboxLabel: string;
  checkboxChecked: boolean;
}

export class WindowPromptChoiceResponse {
  index: number;
  checked: boolean;

  constructor(index: number, checked: boolean) {
    this.index = index;
    this.checked = checked;
  }
}

class ChoiceModel {
  readonly request: WindowPromptChoiceRequest;
  readonly select: (index: number) => void;
  checked: boolean;

  constructor(request: WindowPromptChoiceRequest, select: (index: number) => void) {
    this.request = request;
    this.select = select;
    this.checked = request.checkboxChecked;
  }
}

function primaryButtonIndex(request: WindowPromptChoiceRequest): number {
  for (let i = 0; i < request.buttons.length; i++) {
    if (i !== request.cancelIndex) {
      return i;
    }
  }
  return 0;
}

const EMPTY_CHOICE_REQUEST: WindowPromptChoiceRequest = {
  windowId: 0,
  message: "",
  detail: "",
  buttons: [],
  cancelIndex: 0,
  checkboxLabel: "",
  checkboxChecked: false,
  cancelOnTouchOutside: false,
};

@Component
struct ChoiceDialogView {
  model: ChoiceModel = new ChoiceModel(EMPTY_CHOICE_REQUEST, (): void => {});
  @State private checked: boolean = false;

  aboutToAppear(): void {
    this.checked = this.model.checked;
  }

  private setChecked(next: boolean): void {
    this.checked = next;
    this.model.checked = next;
  }

  build() {
    Column({ space: 16 }) {
      Text(this.model.request.message)
        .width("100%")
        .fontSize($r("sys.float.Title_S"))
        .fontWeight(FontWeight.Bold)
        .fontColor($r("sys.color.font_primary"))
        .textAlign(TextAlign.Start)

      if (this.model.request.detail) {
        Scroll() {
          Text(this.model.request.detail)
            .width("100%")
            .fontSize($r("sys.float.Body_M"))
            .fontColor($r("sys.color.font_secondary"))
            .textAlign(TextAlign.Start)
        }
        .width("100%")
        .constraintSize({ maxHeight: 220 })
        .scrollBar(BarState.Auto);
      }
      Row({ space: 8 }) {
        Checkbox()
          .select(this.checked)
          .shape(CheckBoxShape.ROUNDED_SQUARE)
          .onChange((value: boolean): void => this.setChecked(value))
          .accessibilityText(this.model.request.checkboxLabel)
        Text(this.model.request.checkboxLabel)
          .layoutWeight(1)
          .fontSize($r("sys.float.Body_M"))
          .fontColor($r("sys.color.font_primary"))
          .textAlign(TextAlign.Start)
      }
      .width("100%")
      .alignItems(VerticalAlign.Center)
      .onClick((): void => this.setChecked(!this.checked))

      if (this.model.request.buttons.length <= 3) {
        Row({ space: 12 }) {
          ForEach(
            this.model.request.buttons,
            (label: string, index: number) => {
              Button(label, {
                type: ButtonType.Capsule,
                buttonStyle:
                  index === primaryButtonIndex(this.model.request) &&
                  index !== this.model.request.cancelIndex
                    ? ButtonStyleMode.EMPHASIZED
                    : ButtonStyleMode.NORMAL,
              })
                .layoutWeight(1)
                .fontSize($r("sys.float.Body_M"))
                .onClick((): void => this.model.select(index));
            },
            (label: string, index: number): string => `${index}:${label}`,
          )
        }.width("100%");
      } else {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(
              this.model.request.buttons,
              (label: string, index: number) => {
                if (index !== this.model.request.cancelIndex) {
                  Button(label, {
                    type: ButtonType.Normal,
                    buttonStyle: ButtonStyleMode.NORMAL,
                  })
                    .width("100%")
                    .borderRadius($r("sys.float.corner_radius_level4"))
                    .fontSize($r("sys.float.Body_M"))
                    .onClick((): void => this.model.select(index));
                }
              },
              (label: string, index: number): string => `${index}:${label}`,
            )
          }.width("100%")
        }
        .width("100%")
        .constraintSize({ maxHeight: 260 })
        .scrollBar(BarState.Auto);

        if (
          this.model.request.cancelIndex !== undefined &&
          this.model.request.cancelIndex !== null
        ) {
          Button(this.model.request.buttons[this.model.request.cancelIndex], {
            type: ButtonType.Capsule,
            buttonStyle: ButtonStyleMode.TEXTUAL,
          })
            .width("100%")
            .fontSize($r("sys.float.Body_M"))
            .onClick((): void => this.model.select(this.model.request.cancelIndex!));
        }
      }
    }
    .width("90%")
    .constraintSize({ minWidth: 300, maxWidth: 400 })
    .padding(24)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r("sys.color.comp_background_primary"))
    .borderRadius($r("sys.float.corner_radius_level10"))
    .border({ width: "1px", color: $r("sys.color.comp_divider") })
    .shadow(ShadowStyle.OUTER_FLOATING_MD);
  }
}

@Builder
function choiceDialog(model: ChoiceModel) {
  ChoiceDialogView({ model });
}

/** Window-scoped native ArkUI dialog with checkbox; API 12+ compatible, no bridge UI refs. */
export class PromptChoices {
  private sessions: Set<() => void> = new Set();

  async show(
    target: window.Window,
    request: WindowPromptChoiceRequest,
    context: BridgeCallContext,
  ): Promise<WindowPromptChoiceResponse> {
    if (
      typeof request.message !== "string" ||
      typeof request.checkboxLabel !== "string" ||
      !request.checkboxLabel.trim() ||
      typeof request.checkboxChecked !== "boolean" ||
      typeof request.cancelOnTouchOutside !== "boolean" ||
      (request.detail !== undefined &&
        request.detail !== null &&
        typeof request.detail !== "string") ||
      !Array.isArray(request.buttons) ||
      request.buttons.length === 0 ||
      request.buttons.length > 128 ||
      request.buttons.some((v: string): boolean => typeof v !== "string" || !v.trim()) ||
      (request.cancelIndex !== undefined &&
        request.cancelIndex !== null &&
        (!Number.isInteger(request.cancelIndex) ||
          request.cancelIndex < 0 ||
          request.cancelIndex >= request.buttons.length)) ||
      (request.cancelOnTouchOutside &&
        (request.cancelIndex === undefined || request.cancelIndex === null))
    ) {
      throw new Error("Invalid prompt choice request");
    }
    const ui: UIContext = target.getUIContext();
    const prompt = ui.getPromptAction();
    let opened = false;
    let closing = false;
    let completed = false;
    let cancelled = false;
    let selected: number | undefined;
    let resolveResult: ((result: WindowPromptChoiceResponse) => void) | undefined;
    let rejectResult: ((error: Error) => void) | undefined;
    const result = new Promise<WindowPromptChoiceResponse>((resolve, reject) => {
      resolveResult = resolve;
      rejectResult = reject;
    });
    const finish = (): void => {
      if (completed) {
        return;
      }
      completed = true;
      if (cancelled || !context.isActive() || selected === undefined) {
        rejectResult?.(new Error("Prompt choice cancelled"));
      } else {
        resolveResult?.(new WindowPromptChoiceResponse(selected, model.checked));
      }
    };
    const close = (): void => {
      if (!opened || closing || completed) {
        return;
      }
      closing = true;
      prompt
        .closeCustomDialog(content)
        .then(finish)
        .catch((): void => {
          cancelled = true;
          finish();
        });
    };
    const model = new ChoiceModel(request, (index: number): void => {
      if (completed || cancelled || !context.isActive() || selected !== undefined) {
        return;
      }
      selected = index;
      close();
    });
    const content = new ComponentContent(ui, wrapBuilder(choiceDialog), model);
    const cancel = (): void => {
      cancelled = true;
      close();
    };
    this.sessions.add(cancel);
    const unsubscribe = context.onCancel(cancel);
    try {
      if (!context.isActive()) {
        cancelled = true;
        throw new Error("Prompt choice cancelled before opening");
      }
      await prompt.openCustomDialog(content, {
        alignment: DialogAlignment.Center,
        autoCancel: request.cancelOnTouchOutside,
        onWillDismiss: (action: DismissDialogAction): void => {
          if (cancelled || selected !== undefined) {
            action.dismiss();
            return;
          }
          if (action.reason === DismissReason.TOUCH_OUTSIDE && !request.cancelOnTouchOutside) {
            return;
          }
          if (request.cancelIndex !== undefined && request.cancelIndex !== null) {
            selected = request.cancelIndex;
            action.dismiss();
          }
        },
        onDidDisappear: finish,
      });
      opened = true;
      if (cancelled || selected !== undefined) {
        close();
      }
      return await result;
    } finally {
      completed = true;
      unsubscribe();
      this.sessions.delete(cancel);
      content.dispose();
    }
  }

  dispose(): void {
    for (const cancel of Array.from(this.sessions)) {
      cancel();
    }
    this.sessions.clear();
  }
}
