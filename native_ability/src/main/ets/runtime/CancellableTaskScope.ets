export interface TaskCancellationSignal {
  isCancelled: () => boolean;
  onCancel: (listener: () => void) => () => void;
}

/** One-shot bounded task scope used to keep teardown independent from a stuck plugin Promise. */
export class CancellableTaskScope {
  private cancelled: boolean = false;
  private completed: boolean = false;
  private running: boolean = false;
  private timedOut: boolean = false;
  private cancellationReason?: Error;
  private rejectCancellation?: (reason: Error) => void;
  private readonly cancelListeners: Array<() => void> = [];
  private readonly label: string;
  private readonly timeoutMs: number;

  constructor(label: string, timeoutMs: number) {
    this.label = label;
    this.timeoutMs = Math.max(1, Math.floor(timeoutMs));
  }

  async run(operation: (signal: TaskCancellationSignal) => Promise<void>): Promise<void> {
    if (this.running) {
      throw new Error(`Cancellable task '${this.label}' can only run once`);
    }
    this.running = true;
    const cancellation = new Promise<void>((_resolve, reject) => {
      this.rejectCancellation = reject;
      if (this.cancelled) {
        reject(
          this.cancellationReason ?? new Error(`Cancellable task '${this.label}' was cancelled`),
        );
      }
    });
    const timer = setTimeout(() => {
      this.timedOut = true;
      this.cancel(
        new Error(`Cancellable task '${this.label}' timed out after ${this.timeoutMs}ms`),
      );
    }, this.timeoutMs);
    try {
      const task = Promise.resolve().then(async (): Promise<void> => {
        await operation({
          isCancelled: (): boolean => this.cancelled,
          onCancel: (listener: () => void): (() => void) => this.subscribe(listener),
        });
      });
      await Promise.race([task, cancellation]);
    } finally {
      clearTimeout(timer);
      this.rejectCancellation = undefined;
      this.completed = true;
    }
  }

  cancel(reason: Error): void {
    if (this.cancelled || this.completed) {
      return;
    }
    this.cancelled = true;
    this.cancellationReason = reason;
    const rejectCancellation = this.rejectCancellation;
    this.rejectCancellation = undefined;
    rejectCancellation?.(reason);
    const listeners = this.cancelListeners.splice(0, this.cancelListeners.length);
    for (const listener of listeners) {
      try {
        listener();
      } catch {
        // Cancellation is best-effort; every listener still gets a chance to release its wait.
      }
    }
  }

  didTimeOut(): boolean {
    return this.timedOut;
  }

  private subscribe(listener: () => void): () => void {
    if (this.cancelled || this.completed) {
      listener();
      return (): void => {};
    }
    this.cancelListeners.push(listener);
    return (): void => {
      const index = this.cancelListeners.indexOf(listener);
      if (index >= 0) {
        this.cancelListeners.splice(index, 1);
      }
    };
  }
}
