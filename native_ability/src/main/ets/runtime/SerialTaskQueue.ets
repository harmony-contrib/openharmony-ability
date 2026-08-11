export type SerialTaskErrorHandler = (label: string, error: Error) => void;

/**
 * A small failure-isolating FIFO for lifecycle work. Callers enqueue from synchronous platform
 * callbacks; Promise work runs in event order, and one rejection is reported without poisoning
 * the rest of the lifecycle chain.
 */
export class SerialTaskQueue {
  private tail: Promise<void> = Promise.resolve();
  private readonly onError: SerialTaskErrorHandler;

  constructor(onError: SerialTaskErrorHandler) {
    this.onError = onError;
  }

  enqueue(label: string, operation: () => Promise<void>): Promise<void> {
    const result = this.tail.then(operation);
    this.tail = result.catch((error: Error): void => {
      this.onError(label, error);
    });
    return result;
  }

  settled(): Promise<void> {
    return this.tail;
  }
}
