import audio from "@ohos.multimedia.audio";
import fs from "@ohos.file.fs";
import media from "@ohos.multimedia.media";

/** One owned native pipeline. State callbacks never revive a replaced source. */
export class PlayerSession {
  private player?: media.AVPlayer;
  private closed: boolean = false;
  private sourceClosed: boolean = false;
  private requested: number = 0;
  private applied: number = 0;
  private volume: number = 1;
  private preparing: boolean = false;
  private flushing: boolean = false;
  private startTask?: Promise<void>;
  private closeTask?: Promise<void>;
  private source: fs.File;
  private report: (message: string) => void;

  constructor(source: fs.File, report: (message: string) => void) {
    this.source = source;
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
      const player = await media.createAVPlayer();
      this.player = player;
      if (this.closed) {
        return;
      }
      player.on("stateChange", (state: string): void => {
        try {
          if (this.closed) {
            return;
          }
          if (state === "initialized") {
            player.audioRendererInfo = {
              usage: audio.StreamUsage.STREAM_USAGE_NOTIFICATION,
              rendererFlags: 0,
            };
            if (!this.preparing) {
              this.preparing = true;
              player.prepare().catch((error: Error): void => {
                this.fail(String(error));
              });
            }
          } else if (state === "prepared") {
            this.flush();
          }
        } catch (failure) {
          this.fail(String(failure));
        }
      });
      player.on("error", (failure: Error): void => {
        this.fail(String(failure));
      });
      player.fdSrc = { fd: this.source.fd };
    } catch (error) {
      this.fail(String(error));
    }
  }

  private fail(message: string): void {
    if (!this.closed) {
      this.report(message);
      this.close().catch((error: Error): void => {
        this.report(`close: ${String(error)}`);
      });
    }
  }

  private flush(): void {
    const player = this.player;
    if (this.closed || player === undefined || this.flushing || this.applied === this.requested) {
      return;
    }
    const state = player.state;
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
      player.setVolume(this.volume);
      player.seek(0);
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
      // Waiting for a pending create also releases its late result and keeps
      // the descriptor valid until all native users end.
      await this.startTask;
      if (this.player !== undefined) {
        await this.player.release();
      }
    } catch (error) {
      this.report(`release: ${String(error)}`);
    } finally {
      if (!this.sourceClosed) {
        this.sourceClosed = true;
        fs.closeSync(this.source);
      }
      this.player = undefined;
    }
  }
}
