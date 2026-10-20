import { ColorMetrics, ComponentContent, LengthMetrics, UIContext, window } from "@kit.ArkUI";
import { BridgeCallContext } from "@ohos-rs/ability";
import { PromptPlacement, PromptOffset } from "./PromptPlacement";

export interface WindowPromptRequest {
  windowId: number;
  message: string;
  detail?: string;
  level: number;
  buttons: string[];
  cancelIndex?: number;
  anchor?: WindowPromptAnchor;
}
export interface WindowPromptAnchor {
  /** Window content-local logical coordinates in vp, not screen coordinates or px. */
  x: number;
  y: number;
}

class PromptModel {
  readonly request: WindowPromptRequest;
  readonly choose: (index: number) => void;
  readonly placement: PromptPlacement;
  readonly measure: (width: number, height: number) => void;
  readonly focusId: string;
  readonly stackButtons: boolean;
  readonly buttonIndices: number[];
  constructor(
    request: WindowPromptRequest,
    choose: (index: number) => void,
    placement: PromptPlacement,
    measure: (width: number, height: number) => void,
    focusId: string,
  ) {
    this.request = request;
    this.choose = choose;
    this.placement = placement;
    this.measure = measure;
    this.focusId = focusId;
    this.stackButtons = placement.width < 360;
    this.buttonIndices = request.buttons.map((_label: string, index: number): number => index);
    if (!this.stackButtons) {
      // Visual ordering must not change the result indices owned by the caller.
      this.buttonIndices = this.buttonIndices.filter(
        (index: number): boolean => index !== 0 && index !== request.cancelIndex,
      );
      if (
        request.cancelIndex !== undefined &&
        request.cancelIndex !== null &&
        request.cancelIndex !== 0
      ) {
        this.buttonIndices.unshift(request.cancelIndex);
      }
      this.buttonIndices.push(0);
    }
  }
}

@Builder
function promptBuilder(model: PromptModel) {
  Scroll() {
    Column({ space: 16 }) {
      Column({ space: 8 }) {
        Text(model.request.message)
          .fontSize(18)
          .fontWeight(600)
          .fontColor($r("sys.color.font_primary"))
          .width("100%")
        if (model.request.detail) {
          Text(model.request.detail)
            .fontSize(14)
            .lineHeight(20)
            .fontColor($r("sys.color.font_secondary"))
            .width("100%");
        }
      }
      .width("100%")
      .alignItems(HorizontalAlign.Start)
      .accessibilityGroup(true)
      Flex({
        direction: model.stackButtons ? FlexDirection.Column : FlexDirection.Row,
        wrap: FlexWrap.Wrap,
        justifyContent: FlexAlign.End,
        space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) },
      }) {
        ForEach(model.buttonIndices, (index: number) => {
          Button({ type: ButtonType.Normal }) {
            Text(model.request.buttons[index])
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(
                index === 0 && index !== model.request.cancelIndex
                  ? $r("sys.color.comp_background_primary")
                  : $r("sys.color.font_primary"),
              )
          }
          .id(`${model.focusId}-${index}`)
          .width(model.stackButtons ? "100%" : undefined)
          .constraintSize({ minHeight: 36, minWidth: 80, maxWidth: model.placement.width - 48 })
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(6)
          .backgroundColor(
            index === 0 && index !== model.request.cancelIndex
              ? $r("sys.color.font_primary")
              : $r("sys.color.comp_background_primary"),
          )
          .border({ width: 1, color: $r("sys.color.ohos_id_color_list_separator") })
          .focusBox({
            strokeColor: ColorMetrics.resourceColor($r("sys.color.font_secondary")),
            strokeWidth: LengthMetrics.vp(2),
            margin: LengthMetrics.vp(3),
          })
          .defaultFocus(index === 0)
          .onClick(() => model.choose(index));
        })
      }
      .width("100%")
      .margin({ top: 8 })
    }
    .padding(24)
    .width("100%")
  }
  .width(model.placement.width)
  .constraintSize({ maxHeight: model.placement.maxHeight })
  .backgroundColor($r("sys.color.comp_background_primary"))
  .borderRadius(8)
  .border({ width: 1, color: $r("sys.color.ohos_id_color_list_separator") })
  .shadow({ radius: 16, color: "#1A000000", offsetY: 4 })
  .onAreaChange((_oldArea: Area, newArea: Area): void => {
    model.measure(Number(newArea.width), Number(newArea.height));
  });
}

/** One dialog lifetime; only ArkTS owns the ComponentContent and UIContext. */
class PromptSession {
  private static nextFocusId: number = 0;
  private readonly focusId: string = `native-window-prompt-${PromptSession.nextFocusId++}`;
  private readonly uiContext: UIContext;
  private readonly targetWindow: window.Window;
  private readonly request: WindowPromptRequest;
  private readonly context: BridgeCallContext;
  private content?: ComponentContent<PromptModel>;
  private completed: boolean = false;
  private opened: boolean = false;
  private closing?: Promise<void>;
  private unsubscribe?: () => void;
  private resolve?: (index: number) => void;
  private reject?: (error: Error) => void;
  private placement: PromptPlacement;
  private measuredWidth: number = 0;
  private measuredHeight: number = 0;
  private lastOffset?: PromptOffset;
  private positionUpdates: Promise<void> = Promise.resolve();
  private sizeListener?: (size: window.Size) => void;
  private previousFocusActive?: boolean;
  private disappearing: boolean = false;
  private resolveDisappearance?: () => void;
  private readonly disappearance: Promise<void> = new Promise((resolve) => {
    this.resolveDisappearance = resolve;
  });

  constructor(
    targetWindow: window.Window,
    request: WindowPromptRequest,
    context: BridgeCallContext,
  ) {
    this.targetWindow = targetWindow;
    this.uiContext = targetWindow.getUIContext();
    this.request = request;
    this.context = context;
    this.placement = this.readPlacement();
  }

  private readPlacement(): PromptPlacement {
    const rect = this.targetWindow.getWindowProperties().windowRect;
    const avoid = this.targetWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    // Window geometry is px; dialog sizes and offsets are vp. Use this window's
    // UIContext conversion so secondary displays and custom densities are respected.
    return new PromptPlacement(
      this.uiContext.px2vp(Math.max(1, rect.width - avoid.leftRect.width - avoid.rightRect.width)),
      this.uiContext.px2vp(
        Math.max(1, rect.height - avoid.topRect.height - avoid.bottomRect.height),
      ),
      this.request.anchor !== undefined && this.request.anchor !== null,
    );
  }

  private model(): PromptModel {
    return new PromptModel(
      this.request,
      (index: number): void => {
        void this.choose(index);
      },
      this.placement,
      (width: number, height: number): void => {
        if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
          return;
        }
        this.measuredWidth = width;
        this.measuredHeight = height;
        this.updatePosition();
      },
      this.focusId,
    );
  }

  private offset(): PromptOffset {
    const anchor = this.request.anchor;
    if (!anchor) {
      return { dx: 0, dy: 0 };
    }
    // Before layout is measured, reserve the maximum height to keep the initial
    // dialog on screen. Actual layout then moves it as close to the anchor as fits.
    return this.placement.offset(
      anchor.x,
      anchor.y,
      this.measuredWidth || this.placement.width,
      this.measuredHeight || this.placement.maxHeight,
    );
  }

  private updatePosition(): void {
    if (!this.request.anchor || !this.opened || this.completed) {
      return;
    }
    this.positionUpdates = this.positionUpdates
      .then(async (): Promise<void> => {
        const content = this.content;
        if (!content || !this.opened || this.completed || !this.context.isActive()) {
          return;
        }
        const offset = this.offset();
        if (this.lastOffset?.dx === offset.dx && this.lastOffset?.dy === offset.dy) {
          return;
        }
        await this.uiContext.getPromptAction().updateCustomDialog(content, {
          alignment: DialogAlignment.TopStart,
          offset,
          autoCancel: this.request.cancelIndex !== undefined && this.request.cancelIndex !== null,
        });
        this.lastOffset = offset;
      })
      .catch((error: Error): void => {
        console.warn(`[WindowPrompt] position update failed: ${String(error)}`);
      });
  }

  async run(): Promise<number> {
    const result = new Promise<number>((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
    // An open failure or cancellation can reject before openCustomDialog completes.
    void result.catch(() => {});
    // Register cancellation before building/opening: a late open must be closed again.
    this.unsubscribe = this.context.onCancel(() => {
      void this.cancel();
    });
    try {
      const model = this.model();
      const content = new ComponentContent(this.uiContext, wrapBuilder(promptBuilder), model);
      this.content = content;
      this.sizeListener = (_size: window.Size): void => {
        if (this.completed || !this.context.isActive()) {
          return;
        }
        try {
          this.placement = this.readPlacement();
          this.measuredWidth = 0;
          this.measuredHeight = 0;
          content.update(this.model());
          this.updatePosition();
        } catch (error) {
          console.warn(`[WindowPrompt] resize update failed: ${String(error)}`);
        }
      };
      this.targetWindow.on("windowSizeChange", this.sizeListener);
      if (this.completed || !this.context.isActive()) {
        await this.cancel();
      } else {
        await this.uiContext.getPromptAction().openCustomDialog(content, {
          isModal: true,
          maskColor: "#80000000",
          autoCancel: this.request.cancelIndex !== undefined && this.request.cancelIndex !== null,
          alignment: this.request.anchor ? DialogAlignment.TopStart : DialogAlignment.Center,
          offset: this.offset(),
          onDidAppear: (): void => {
            if (this.completed || !this.context.isActive()) {
              return;
            }
            // ComponentContent can mount after the dialog's initial focus pass.
            try {
              const controller = this.uiContext.getFocusController();
              this.previousFocusActive = controller.isActive();
              controller.activate(true);
              controller.requestFocus(`${this.focusId}-0`);
            } catch (error) {
              console.warn(`[WindowPrompt] default focus failed: ${String(error)}`);
            }
          },
          onWillDisappear: (): void => {
            this.disappearing = true;
          },
          onDidDisappear: (): void => {
            this.resolveDisappearance?.();
            void this.cancel();
          },
          onWillDismiss: (action: DismissDialogAction): void => {
            if (this.completed) {
              action.dismiss();
            } else if (action.reason === DismissReason.TOUCH_OUTSIDE && !this.request.anchor) {
              // Confirmation dialogs require an explicit choice; Escape still cancels.
              return;
            } else if (
              this.request.cancelIndex !== undefined &&
              this.request.cancelIndex !== null
            ) {
              action.dismiss();
              void this.choose(this.request.cancelIndex);
            }
          },
        });
        this.opened = true;
        if (this.completed || !this.context.isActive()) {
          await this.close();
        } else {
          this.updatePosition();
        }
      }
    } catch (error) {
      if (!this.completed) {
        this.completed = true;
        this.reject?.(new Error(`Native prompt failed: ${String(error)}`));
      }
    }
    try {
      return await result;
    } finally {
      this.unsubscribe?.();
      if (this.sizeListener) {
        try {
          this.targetWindow.off("windowSizeChange", this.sizeListener);
        } catch (error) {
          console.warn(`[WindowPrompt] size listener cleanup failed: ${String(error)}`);
        }
        this.sizeListener = undefined;
      }
      await this.close();
    }
  }

  private async choose(index: number): Promise<void> {
    if (this.completed) {
      return;
    }
    this.completed = true;
    await this.close();
    this.resolve?.(index);
  }

  async cancel(): Promise<void> {
    this.resolveDisappearance?.();
    if (!this.completed) {
      this.completed = true;
      this.reject?.(new Error("Native prompt was cancelled by window/session teardown"));
    }
    await this.close();
  }

  private async close(): Promise<void> {
    if (this.closing) {
      await this.closing;
      return;
    }
    const content = this.content;
    if (this.opened && content) {
      this.opened = false;
      this.closing = this.closeOpened(content);
      await this.closing;
    }
  }

  private async closeOpened(content: ComponentContent<PromptModel>): Promise<void> {
    await this.positionUpdates;
    let closeRequested = false;
    try {
      await this.uiContext.getPromptAction().closeCustomDialog(content);
      closeRequested = true;
    } catch (error) {
      // Auto-dismiss removes the dialog from the SDK registry before its animation ends.
      if (!this.disappearing) {
        console.warn(`[WindowPrompt] close failed: ${String(error)}`);
      }
    }
    // The SDK resolves closeCustomDialog before removing its animated focus scope.
    // Returning a choice sooner can open the next system dialog over that scope.
    if ((closeRequested || this.disappearing) && this.context.isActive()) {
      await this.disappearance;
    }
    if (this.previousFocusActive !== undefined && this.context.isActive()) {
      try {
        this.uiContext.getFocusController().activate(this.previousFocusActive);
      } catch (error) {
        console.warn(`[WindowPrompt] focus activation restore failed: ${String(error)}`);
      }
    }
  }

  disposeContent(): void {
    this.content?.dispose();
    this.content = undefined;
  }
}

export class PromptDialogs {
  private readonly sessions: Set<PromptSession> = new Set();

  async show(
    targetWindow: window.Window,
    request: WindowPromptRequest,
    context: BridgeCallContext,
  ): Promise<number> {
    if (
      (request.anchor &&
        (!Number.isFinite(request.anchor.x) ||
          !Number.isFinite(request.anchor.y) ||
          request.anchor.x < 0 ||
          request.anchor.y < 0)) ||
      typeof request.message !== "string" ||
      !Number.isInteger(request.level) ||
      request.level < 0 ||
      request.level > 2 ||
      !Array.isArray(request.buttons) ||
      request.buttons.length === 0 ||
      request.buttons.length > 128 ||
      request.buttons.some(
        (label: string) => typeof label !== "string" || label.trim().length === 0,
      ) ||
      (request.cancelIndex !== undefined &&
        request.cancelIndex !== null &&
        (!Number.isInteger(request.cancelIndex) ||
          request.cancelIndex < 0 ||
          request.cancelIndex >= request.buttons.length))
    ) {
      throw new Error("Invalid native prompt request");
    }
    const session = new PromptSession(targetWindow, request, context);
    this.sessions.add(session);
    try {
      return await session.run();
    } finally {
      this.sessions.delete(session);
      session.disposeContent();
    }
  }

  async dispose(): Promise<void> {
    const sessions = Array.from(this.sessions);
    this.sessions.clear();
    await Promise.all(sessions.map((session: PromptSession) => session.cancel()));
  }
}
