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
  appearance?: WindowPromptAppearance;
}
/** ARGB semantic colors; omitted appearance follows the target window's system theme. */
export interface WindowPromptAppearance {
  background: number;
  foreground: number;
  mutedForeground: number;
  primary: number;
  primaryForeground: number;
  border: number;
  focus: number;
}

class PromptPalette implements WindowPromptAppearance {
  readonly background: number;
  readonly foreground: number;
  readonly mutedForeground: number;
  readonly primary: number;
  readonly primaryForeground: number;
  readonly border: number;
  readonly focus: number;

  constructor(appearance?: WindowPromptAppearance) {
    const systemBackground = PromptPalette.resource($r("sys.color.comp_background_primary"));
    const background = PromptPalette.blend(0xffffffff, systemBackground);
    this.background = appearance
      ? PromptPalette.blend(background, appearance.background)
      : background;
    this.foreground = PromptPalette.readable(
      appearance?.foreground ?? PromptPalette.resource($r("sys.color.font_primary")),
      this.background,
      4.5,
    );
    this.mutedForeground = PromptPalette.readable(
      appearance?.mutedForeground ?? PromptPalette.resource($r("sys.color.font_secondary")),
      this.background,
      4.5,
    );
    this.primary = PromptPalette.blend(this.background, appearance?.primary ?? this.foreground);
    this.primaryForeground = PromptPalette.readable(
      appearance?.primaryForeground ?? this.background,
      this.primary,
      4.5,
    );
    this.border = PromptPalette.blend(
      this.background,
      appearance?.border ?? PromptPalette.resource($r("sys.color.ohos_id_color_list_separator")),
    );
    this.focus = PromptPalette.readable(appearance?.focus ?? this.foreground, this.background, 3);
  }

  private static resource(resource: Resource): number {
    const color = ColorMetrics.resourceColor(resource);
    return ((color.alpha << 24) | (color.red << 16) | (color.green << 8) | color.blue) >>> 0;
  }

  private static blend(background: number, foreground: number): number {
    const alpha = (foreground >>> 24) / 255;
    const channel = (shift: number): number =>
      Math.round(
        ((background >>> shift) & 255) * (1 - alpha) + ((foreground >>> shift) & 255) * alpha,
      );
    return (0xff000000 | (channel(16) << 16) | (channel(8) << 8) | channel(0)) >>> 0;
  }

  private static luminance(color: number): number {
    const linear = (shift: number): number => {
      const value = ((color >>> shift) & 255) / 255;
      return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0);
  }

  private static readable(foreground: number, background: number, minimum: number): number {
    const color = PromptPalette.blend(background, foreground);
    const luminance = PromptPalette.luminance(background);
    const other = PromptPalette.luminance(color);
    if ((Math.max(luminance, other) + 0.05) / (Math.min(luminance, other) + 0.05) >= minimum) {
      return color;
    }
    // Custom themes can supply translucent or equal foreground/background colors.
    return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? 0xff000000 : 0xffffffff;
  }
}

export interface WindowPromptAnchor {
  /** Window content-local logical coordinates in vp, not screen coordinates or px. */
  x: number;
  y: number;
}

class PromptModel {
  readonly request: WindowPromptRequest;
  readonly palette: PromptPalette;
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
    palette: PromptPalette,
  ) {
    this.request = request;
    this.palette = palette;
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
          .fontSize($r("sys.float.Subtitle_L"))
          .fontWeight(600)
          .fontColor(model.palette.foreground)
          .width("100%")
        if (model.request.detail) {
          Text(model.request.detail)
            .fontSize($r("sys.float.Body_M"))
            .lineHeight(20)
            .fontColor(model.palette.mutedForeground)
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
              .fontSize($r("sys.float.Body_M"))
              .fontWeight(FontWeight.Medium)
              .fontColor(
                index === 0 && index !== model.request.cancelIndex
                  ? model.palette.primaryForeground
                  : model.palette.foreground,
              )
          }
          .id(`${model.focusId}-${index}`)
          .width(model.stackButtons ? "100%" : undefined)
          .constraintSize({ minHeight: 36, minWidth: 80, maxWidth: model.placement.width - 48 })
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(
            index === 0 && index !== model.request.cancelIndex
              ? model.palette.primary
              : model.palette.background,
          )
          .border({
            width: 1,
            color: model.palette.border,
            radius: $r("sys.float.corner_radius_level3"),
          })
          .focusBox({
            strokeColor: ColorMetrics.numeric(model.palette.focus),
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
  .backgroundColor(model.palette.background)
  .border({ width: 1, color: model.palette.border, radius: $r("sys.float.corner_radius_level4") })
  .shadow(ShadowStyle.OUTER_FLOATING_SM)
  .onAreaChange((_oldArea: Area, newArea: Area): void => {
    model.measure(Number(newArea.width), Number(newArea.height));
  });
}

/** One dialog lifetime; only ArkTS owns the ComponentContent and UIContext. */
const PROMPT_DIALOG_TRANSITION: TransitionEffect = TransitionEffect.asymmetric(
  TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.9, y: 0.9 })).animation({
    duration: 200,
    curve: Curve.Friction,
  }),
  TransitionEffect.IDENTITY.animation({ duration: 0 }),
);

const PROMPT_MASK_TRANSITION: TransitionEffect = TransitionEffect.asymmetric(
  TransitionEffect.OPACITY.animation({
    duration: 200,
    curve: Curve.Friction,
  }),
  TransitionEffect.IDENTITY.animation({ duration: 0 }),
);

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
    let palette: PromptPalette | undefined;
    this.uiContext.runScopedTask((): void => {
      palette = new PromptPalette(this.request.appearance);
    });
    if (!palette) {
      throw new Error("Native prompt theme resolution failed");
    }
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
      palette,
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
          maskColor: $r("sys.color.mask_fourth"),
          transition: PROMPT_DIALOG_TRANSITION,
          dialogTransition: PROMPT_DIALOG_TRANSITION,
          maskTransition: PROMPT_MASK_TRANSITION,
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
              this.disappearing = true;
              action.dismiss();
            } else if (action.reason === DismissReason.TOUCH_OUTSIDE && !this.request.anchor) {
              // Confirmation dialogs require an explicit choice; Escape still cancels.
              return;
            } else if (
              this.request.cancelIndex !== undefined &&
              this.request.cancelIndex !== null
            ) {
              this.disappearing = true;
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
    if (!this.disappearing) {
      try {
        await this.uiContext.getPromptAction().closeCustomDialog(content);
        closeRequested = true;
      } catch (error) {
        // Auto-dismiss removes the dialog from the SDK registry before its animation ends.
        if (!this.disappearing) {
          console.warn(`[WindowPrompt] close failed: ${String(error)}`);
        }
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
    const appearance = request.appearance;
    if (
      appearance &&
      [
        appearance.background,
        appearance.foreground,
        appearance.mutedForeground,
        appearance.primary,
        appearance.primaryForeground,
        appearance.border,
        appearance.focus,
      ].some(
        (color: number): boolean => !Number.isInteger(color) || color < 0 || color > 0xffffffff,
      )
    ) {
      throw new Error("Invalid native prompt appearance: expected ARGB colors");
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
