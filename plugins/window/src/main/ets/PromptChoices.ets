import { ComponentContent, UIContext, window } from "@kit.ArkUI";
import { CustomContentDialogV2, AdvancedDialogV2Button } from "@ohos.arkui.advanced.DialogV2";
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

@ObservedV2
class ChoiceModel {
  readonly request: WindowPromptChoiceRequest;
  readonly select: (index: number) => void;
  @Trace checked: boolean;
  constructor(request: WindowPromptChoiceRequest, select: (index: number) => void) {
    this.request = request;
    this.select = select;
    this.checked = request.checkboxChecked;
  }
  buttons(): AdvancedDialogV2Button[] {
    return this.request.buttons.map((label: string, index: number): AdvancedDialogV2Button => {
      const button = new AdvancedDialogV2Button({ content: label });
      button.action = (): void => this.select(index);
      return button;
    });
  }
}

@Builder
function choiceBody(model: ChoiceModel) {
  Column({ space: 12 }) {
    if (model.request.detail) {
      Text(model.request.detail).fontColor($r("sys.color.font_primary"));
    }
    Row() {
      Checkbox()
        .select(model.checked)
        .onChange((checked: boolean): void => {
          model.checked = checked;
        })
        .accessibilityText(model.request.checkboxLabel)
      Text(model.request.checkboxLabel)
        .layoutWeight(1)
        .fontColor($r("sys.color.font_primary"))
        .onClick((): void => {
          model.checked = !model.checked;
        })
    }.width("100%")
    if (model.request.buttons.length > 3) {
      Scroll() {
        Column({ space: 8 }) {
          ForEach(model.request.buttons, (label: string, index: number) => {
            Button(label)
              .width("100%")
              .onClick((): void => model.select(index));
          })
        }.width("100%")
      }
      .constraintSize({ maxHeight: 320 });
    }
  }.width("100%");
}

@Builder
function choiceDialog(model: ChoiceModel) {
  CustomContentDialogV2({
    primaryTitle: model.request.message,
    contentBuilder: (): void => {
      choiceBody(model);
    },
    buttons: model.request.buttons.length <= 3 ? model.buttons() : [],
  });
}

/** Window-scoped native ArkUI controls; no framework UI or object crosses the bridge. */
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
