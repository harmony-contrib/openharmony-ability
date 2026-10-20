/** One owned native pipeline. State callbacks never revive a replaced source. */
export interface AudioSource {
  fd: number;
  close(): void;
}
export interface Playback {
  state(): string;
  observe(state: (value: string) => void, error: (message: string) => void): void;
  source(fd: number): void;
  prepare(): Promise<void>;
  volume(value: number): void;
  rewind(): void;
  play(): Promise<void>;
  release(): Promise<void>;
}
export interface PlaybackFactory {
  create(): Promise<Playback>;
}

export class PlayerSession {
  private player?: Playback;
  private closed: boolean = false;
  private requested: number = 0;
  private applied: number = 0;
  private volume: number = 1;
  private preparing: boolean = false;
  private flushing: boolean = false;
  private startTask?: Promise<void>;
  private closeTask?: Promise<void>;
  private source: AudioSource;
  private factory: PlaybackFactory;
  private report: (message: string) => void;
  constructor(source: AudioSource, factory: PlaybackFactory, report: (message: string) => void) {
    this.source = source;
    this.factory = factory;
    this.report = report;
  }

  update(volume: number, play: boolean): void {
    if (this.closed) {
      return;
    }
    this.volume = volume;
    if (play) {
      this.requested++;
    }
    this.flush();
  }

  begin(previous: Promise<void>): void {
    this.startTask = this.start(previous);
  }

  private async start(previous: Promise<void>): Promise<void> {
    try {
      await previous;
      if (this.closed) {
        return;
      }
      const player = await this.factory.create();
      if (this.closed) {
        await player.release();
        return;
      }
      this.player = player;
      player.observe(
        (state: string): void => {
          if (this.closed) {
            return;
          }
          if (state === "initialized" && !this.preparing) {
            this.preparing = true;
            player.prepare().catch((error: Error): void => {
              this.fail(String(error));
            });
          } else if (state === "prepared") {
            this.flush();
          }
        },
        (message: string): void => {
          this.fail(message);
        },
      );
      player.source(this.source.fd);
    } catch (error) {
      this.fail(String(error));
    }
  }

  private fail(message: string): void {
    if (!this.closed) {
      this.report(message);
    }
  }
  private flush(): void {
    const player = this.player;
    if (this.closed || player === undefined || this.flushing || this.applied === this.requested) {
      return;
    }
    const state = player.state();
    if (
      state !== "prepared" &&
      state !== "playing" &&
      state !== "paused" &&
      state !== "completed"
    ) {
      return;
    }
    this.applied = this.requested;
    this.flushing = true;
    try {
      player.volume(this.volume);
      player.rewind();
      const playing = state === "playing" ? Promise.resolve() : player.play();
      playing
        .catch((error: Error): void => {
          this.fail(String(error));
        })
        .finally((): void => {
          this.flushing = false;
          this.flush();
        });
    } catch (error) {
      this.flushing = false;
      this.fail(String(error));
    }
  }

  close(): Promise<void> {
    if (this.closeTask !== undefined) {
      return this.closeTask;
    }
    this.closed = true;
    this.closeTask = this.dispose();
    return this.closeTask;
  }
  private async dispose(): Promise<void> {
    try {
      // A create still in flight releases its own late result. Waiting for it
      // also guarantees the descriptor remains valid until all native users end.
      await this.startTask;
      if (this.player !== undefined) {
        await this.player.release();
      }
    } catch (error) {
      this.report(`release: ${String(error)}`);
    } finally {
      this.source.close();
      this.player = undefined;
    }
  }
}
