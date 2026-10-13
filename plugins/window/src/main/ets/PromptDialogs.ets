import { ComponentContent, UIContext, window } from "@kit.ArkUI";
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
  constructor(
    request: WindowPromptRequest,
    choose: (index: number) => void,
    placement: PromptPlacement,
    measure: (width: number, height: number) => void,
  ) {
    this.request = request;
    this.choose = choose;
    this.placement = placement;
    this.measure = measure;
  }
}

@Builder
function promptBuilder(model: PromptModel) {
  Scroll() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(model.request.level === 0 ? "ℹ" : model.request.level === 1 ? "⚠" : "⛔")
          .fontSize(24)
          .fontColor(
            model.request.level === 0
              ? Color.Blue
              : model.request.level === 1
                ? Color.Orange
                : Color.Red,
          )
        Text(model.request.message)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r("sys.color.font_primary"))
          .layoutWeight(1)
      }.width("100%")
      if (model.request.detail) {
        Text(model.request.detail)
          .fontSize(14)
          .fontColor($r("sys.color.font_secondary"))
          .width("100%");
      }
      Column({ space: 8 }) {
        ForEach(model.request.buttons, (label: string, index: number) => {
          Button(label)
            .width("100%")
            .onClick(() => model.choose(index));
        })
      }.width("100%")
    }
    .padding(24)
    .width("100%")
  }
  .width(model.placement.width)
  .constraintSize({ maxHeight: model.placement.maxHeight })
  .backgroundColor($r("sys.color.comp_background_primary"))
  .borderRadius(16)
  .onAreaChange((_oldArea: Area, newArea: Area): void => {
    model.measure(Number(newArea.width), Number(newArea.height));
  });
}

/** One dialog lifetime; only ArkTS owns the ComponentContent and UIContext. */
class PromptSession {
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
          autoCancel: this.request.cancelIndex !== undefined && this.request.cancelIndex !== null,
          alignment: this.request.anchor ? DialogAlignment.TopStart : DialogAlignment.Center,
          offset: this.offset(),
          onDidDisappear: (): void => {
            void this.cancel();
          },
          onWillDismiss: (action: DismissDialogAction): void => {
            if (this.completed) {
              action.dismiss();
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
    try {
      await this.uiContext.getPromptAction().closeCustomDialog(content);
    } catch {}
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
