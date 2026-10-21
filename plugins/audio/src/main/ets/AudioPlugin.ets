import media from "@ohos.multimedia.media";
import audio from "@ohos.multimedia.audio";
import fs from "@ohos.file.fs";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeTypedValue,
  expectBridgeRequestType,
} from "@ohos-rs/ability";
import { AudioSource, Playback, PlaybackFactory, PlayerSession } from "./player_session";

interface UpdateRequest {
  player: string;
  sourceFd?: number;
  replace: boolean;
  release: boolean;
  play: boolean;
  volume: number;
  reportErrors: boolean;
  label: string;
}
class UpdateResponse {
  readonly accepted: boolean = true;
}
class OwnedFile implements AudioSource {
  readonly fd: number;
  private closed: boolean = false;
  private file: fs.File;
  constructor(file: fs.File) {
    this.fd = file.fd;
    this.file = file;
  }
  close(): void {
    if (!this.closed) {
      this.closed = true;
      fs.closeSync(this.file);
    }
  }
}
class NativePlayback implements Playback {
  private player: media.AVPlayer;
  constructor(player: media.AVPlayer) {
    this.player = player;
  }
  state(): string {
    return this.player.state;
  }
  observe(state: (value: string) => void, error: (message: string) => void): void {
    this.player.on("stateChange", (value: string): void => {
      try {
        if (value === "initialized") {
          this.player.audioRendererInfo = {
            usage: audio.StreamUsage.STREAM_USAGE_NOTIFICATION,
            rendererFlags: 0,
          };
        }
        state(value);
      } catch (failure) {
        error(String(failure));
      }
    });
    this.player.on("error", (failure: Error): void => {
      error(String(failure));
    });
  }
  source(fd: number): void {
    this.player.fdSrc = { fd };
  }
  prepare(): Promise<void> {
    return this.player.prepare();
  }
  volume(value: number): void {
    this.player.setVolume(value);
  }
  rewind(): void {
    this.player.seek(0);
  }
  play(): Promise<void> {
    return this.player.play();
  }
  release(): Promise<void> {
    return this.player.release();
  }
}
class NativeFactory implements PlaybackFactory {
  async create(): Promise<Playback> {
    const player = await media.createAVPlayer();
    return new NativePlayback(player);
  }
}

export class AudioPlugin extends AsyncPluginBase {
  readonly id: string = "ohos.audio";
  readonly requires: BridgeContextRequirement[] = ["ability"];
  private sessions: Map<string, PlayerSession> = new Map();
  private retiring: Set<Promise<void>> = new Set();

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Audio session is no longer active");
    }
    if (action !== "update") {
      throw new Error(`Unsupported audio action: ${action}`);
    }
    const request = expectBridgeRequestType(
      payload,
      this.id,
      action,
      "ohos.audio.UpdateRequest",
    ) as UpdateRequest;
    if (
      typeof request.player !== "string" ||
      request.player.length === 0 ||
      !Number.isFinite(request.volume) ||
      request.volume < 0 ||
      request.volume > 1 ||
      (request.sourceFd !== undefined &&
        (!Number.isInteger(request.sourceFd) || request.sourceFd < 0 || !request.replace)) ||
      (request.release && (request.sourceFd !== undefined || request.play))
    ) {
      throw new Error("Invalid media-player update");
    }
    let session = this.sessions.get(request.player);
    if (request.replace || request.release) {
      // Duplicate before any await or acknowledgement. Rust retains its source
      // descriptor until this call returns; the pipeline keeps this own handle.
      const source =
        request.sourceFd === undefined ? undefined : new OwnedFile(fs.dup(request.sourceFd));
      this.sessions.delete(request.player);
      const closing = session?.close() ?? Promise.resolve();
      this.retiring.add(closing);
      closing.then(
        (): void => {
          this.retiring.delete(closing);
        },
        (): void => {
          this.retiring.delete(closing);
        },
      );
      session = undefined;
      if (source !== undefined) {
        session = new PlayerSession(source, new NativeFactory(), (message: string): void => {
          if (request.reportErrors) {
            console.warn(
              `[Audio] player=${request.player} source=${request.label} error=${message}`,
            );
          }
        });
        this.sessions.set(request.player, session);
        session.begin(closing);
      }
      // A clear/release acknowledgement is the descriptor-lifetime barrier
      // for the client's next queued source. Do not start a second pipeline
      // while the previous one is still releasing.
      if (source === undefined) {
        await closing;
      }
    }
    session?.update(request.volume, request.play);
    if (!context.isActive()) {
      throw new Error("Audio session is no longer active");
    }
    return { typeName: "ohos.audio.UpdateResponse", value: new UpdateResponse() };
  }

  override async onDispose(): Promise<void> {
    const closing: Promise<void>[] = [];
    this.sessions.forEach((session: PlayerSession): void => {
      closing.push(session.close());
    });
    this.sessions.clear();
    this.retiring.forEach((task: Promise<void>): void => {
      closing.push(task);
    });
    await Promise.all(closing);
  }
}
