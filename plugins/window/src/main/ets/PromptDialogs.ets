import type { UIContext, window } from "@kit.ArkUI";
import type { BridgeCallContext } from "@ohos-rs/ability";

export interface WindowPromptRequest {
  windowId: number;
  message: string;
  detail?: string;
  buttons: string[];
  cancelIndex?: number;
  cancelOnTouchOutside: boolean;
}

/** ArkUI owns the content and its lifetime; this session owns only the pending reply. */
class PromptSession {
  private readonly request: WindowPromptRequest;
  private context?: BridgeCallContext;
  private selected?: number;
  private completed: boolean = false;
  private resolve?: (index: number) => void;
  private reject?: (error: Error) => void;
  private unsubscribe?: () => void;

  constructor(request: WindowPromptRequest, context: BridgeCallContext) {
    this.request = request;
    this.context = context;
  }

  async run(uiContext: UIContext): Promise<number> {
    const result = new Promise<number>((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
    try {
      // onCancel may run synchronously for an already retired bridge call.
      this.unsubscribe = this.context?.onCancel((): void => this.cancel());
      if (!this.active()) {
        this.cancel();
      } else if (this.request.buttons.length <= 3) {
        uiContext.showAlertDialog({
          title: this.request.message,
          message: this.request.detail ?? "",
          autoCancel: this.request.cancelOnTouchOutside,
          buttons: this.request.buttons.map(
            (value: string, index: number): AlertDialogButtonOptions => ({
              value,
              action: (): void => this.choose(index),
            }),
          ),
          onWillDismiss: (action: DismissDialogAction): void => this.dismiss(action),
          onDidDisappear: (): void => this.disappeared(),
        });
      } else {
        const sheets: SheetInfo[] = [];
        this.request.buttons.forEach((title: string, index: number): void => {
          if (index !== this.request.cancelIndex) {
            sheets.push({ title, action: (): void => this.choose(index) });
          }
        });
        const cancelIndex = this.request.cancelIndex;
        uiContext.showActionSheet({
          title: this.request.message,
          message: this.request.detail ?? "",
          autoCancel: this.request.cancelOnTouchOutside,
          sheets,
          confirm:
            cancelIndex !== undefined && cancelIndex !== null
              ? {
                  value: this.request.buttons[cancelIndex],
                  action: (): void => this.choose(cancelIndex),
                }
              : undefined,
          onWillDismiss: (action: DismissDialogAction): void => this.dismiss(action),
          onDidDisappear: (): void => this.disappeared(),
        });
      }
    } catch (error) {
      this.fail(new Error(`Opening system prompt failed: ${String(error)}`));
    }
    try {
      return await result;
    } finally {
      this.unsubscribe?.();
      this.unsubscribe = undefined;
      this.context = undefined;
      this.resolve = undefined;
      this.reject = undefined;
    }
  }

  private active(): boolean {
    return !this.completed && this.context?.isActive() === true;
  }

  private choose(index: number): void {
    if (this.active() && this.selected === undefined) {
      this.selected = index;
    }
  }

  private dismiss(action: DismissDialogAction): void {
    // There is no programmatic close API for system alerts. After bridge teardown,
    // their callbacks are inert and the remaining window-owned dialog is dismissible.
    if (!this.active()) {
      this.cancel();
      action.dismiss();
      return;
    }
    if (this.selected !== undefined) {
      action.dismiss();
      return;
    }
    if (action.reason === DismissReason.TOUCH_OUTSIDE && !this.request.cancelOnTouchOutside) {
      return;
    }
    const cancelIndex = this.request.cancelIndex;
    if (cancelIndex !== undefined && cancelIndex !== null) {
      this.choose(cancelIndex);
      action.dismiss();
    }
  }

  private disappeared(): void {
    if (!this.active() || this.selected === undefined) {
      this.cancel();
      return;
    }
    this.completed = true;
    // Resolving only after exit keeps the next prompt out of the old focus scope.
    this.resolve?.(this.selected);
  }

  private fail(error: Error): void {
    if (!this.completed) {
      this.completed = true;
      this.reject?.(error);
    }
  }

  cancel(): void {
    this.fail(new Error("System prompt was cancelled by window/session teardown"));
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
      typeof request.message !== "string" ||
      (request.detail !== undefined &&
        request.detail !== null &&
        typeof request.detail !== "string") ||
      typeof request.cancelOnTouchOutside !== "boolean" ||
      (request.cancelOnTouchOutside &&
        (request.cancelIndex === undefined || request.cancelIndex === null)) ||
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
    const session = new PromptSession(request, context);
    this.sessions.add(session);
    try {
      return await session.run(targetWindow.getUIContext());
    } finally {
      this.sessions.delete(session);
    }
  }

  async dispose(): Promise<void> {
    const sessions = Array.from(this.sessions);
    this.sessions.clear();
    for (const session of sessions) {
      session.cancel();
    }
  }
}
