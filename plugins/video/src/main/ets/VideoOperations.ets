/** One player's operations and release share a single ordered completion barrier. */
export class VideoOperations {
  private tail: Promise<void> = Promise.resolve();
  private closing: boolean = false;
  private release?: Promise<void>;
  run(operation: () => Promise<void>): Promise<void> {
    if (this.closing) {
      return Promise.reject(new Error("Video is disposed"));
    }
    const result = this.tail.then(async (): Promise<void> => {
      if (this.closing) {
        throw new Error("Video is disposed");
      }
      await operation();
    });
    this.tail = result.catch((): void => {});
    return result;
  }
  close(release: () => Promise<void>): Promise<void> {
    if (!this.release) {
      this.closing = true;
      this.release = this.tail.then(release);
    }
    return this.release;
  }
}
