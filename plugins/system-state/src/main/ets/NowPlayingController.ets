import avSession from "@ohos.multimedia.avsession";
import { image } from "@kit.ImageKit";
import { common } from "@kit.AbilityKit";
import { BridgePluginHookContext } from "@ohos-rs/ability";

const MEDIA_COMMAND_EVENT_TYPE = "ohos.system-state.MediaCommandEvent";

export const MEDIA_CMD_PLAY = 1 << 0;
export const MEDIA_CMD_PAUSE = 1 << 1;
export const MEDIA_CMD_STOP = 1 << 2;
export const MEDIA_CMD_NEXT = 1 << 3;
export const MEDIA_CMD_PREVIOUS = 1 << 4;
export const MEDIA_CMD_SEEK = 1 << 5;

export interface SetNowPlayingRequest {
  active: boolean;
  title: string;
  artist: string;
  album: string;
  artwork?: number[] | null;
  state: string;
  durationMs: number;
  positionMs: number;
  rate: number;
  commands: number;
}

class MediaCommandEvent {
  readonly command: string;
  readonly positionMs: number;

  constructor(command: string, positionMs: number) {
    this.command = command;
    this.positionMs = positionMs;
  }
}

export class NowPlayingController {
  private session: avSession.AVSession | null = null;
  private artworkPixelMap: image.PixelMap | null = null;
  private queue: Promise<void> = Promise.resolve();
  private disposed = false;
  private registeredCommands = 0;
  private activeHookContext: BridgePluginHookContext | null = null;

  private readonly onPlay = (): void => this.emit("play");
  private readonly onPause = (): void => this.emit("pause");
  private readonly onStop = (): void => this.emit("stop");
  private readonly onNext = (): void => this.emit("next");
  private readonly onPrevious = (): void => this.emit("previous");
  private readonly onSeek = (time: number): void =>
    this.emit("seek", Math.max(0, Math.round(time)));

  reset(): void {
    this.disposed = false;
  }

  private serialize<T>(work: () => Promise<T>): Promise<T> {
    const next = this.queue.then(work, work);
    this.queue = next.then(
      () => {},
      () => {},
    );
    return next;
  }

  private emit(command: string, positionMs: number = 0): void {
    const hookContext = this.activeHookContext;
    if (this.disposed || hookContext === null || !hookContext.isActive()) {
      return;
    }
    try {
      hookContext.invokeNativeSync(
        "media-command",
        MEDIA_COMMAND_EVENT_TYPE,
        "std.bool",
        new MediaCommandEvent(command, positionMs),
      );
    } catch (error) {
      console.warn(`[SystemState] media command dispatch failed: ${String(error)}`);
    }
  }

  private syncCommandListeners(session: avSession.AVSession, nextMask: number): void {
    const prevMask = this.registeredCommands;
    const toggle = (bit: number, on: () => void, off: () => void): void => {
      const had = (prevMask & bit) !== 0;
      const want = (nextMask & bit) !== 0;
      if (!had && want) {
        on();
      } else if (had && !want) {
        off();
      }
    };
    toggle(
      MEDIA_CMD_PLAY,
      (): void => session.on("play", this.onPlay),
      (): void => session.off("play", this.onPlay),
    );
    toggle(
      MEDIA_CMD_PAUSE,
      (): void => session.on("pause", this.onPause),
      (): void => session.off("pause", this.onPause),
    );
    toggle(
      MEDIA_CMD_STOP,
      (): void => session.on("stop", this.onStop),
      (): void => session.off("stop", this.onStop),
    );
    toggle(
      MEDIA_CMD_NEXT,
      (): void => session.on("playNext", this.onNext),
      (): void => session.off("playNext", this.onNext),
    );
    toggle(
      MEDIA_CMD_PREVIOUS,
      (): void => session.on("playPrevious", this.onPrevious),
      (): void => session.off("playPrevious", this.onPrevious),
    );
    toggle(
      MEDIA_CMD_SEEK,
      (): void => session.on("seek", this.onSeek),
      (): void => session.off("seek", this.onSeek),
    );
    this.registeredCommands = nextMask;
  }

  apply(
    request: SetNowPlayingRequest,
    abilityContext: common.UIAbilityContext,
    hookContext: BridgePluginHookContext | null,
  ): Promise<boolean> {
    return this.serialize(async (): Promise<boolean> => {
      if (this.disposed) {
        return false;
      }
      this.activeHookContext = hookContext;
      if (!request.active) {
        await this.releaseSession();
        return true;
      }
      const session = await this.ensureSession(abilityContext);
      if (this.disposed) {
        await this.releaseSession();
        return false;
      }
      const commandMask = Number.isInteger(request.commands) ? request.commands >>> 0 : 0;
      this.syncCommandListeners(session, commandMask);

      await this.releaseArtwork();
      let pixelMap: image.PixelMap | undefined;
      if (Array.isArray(request.artwork) && request.artwork.length > 0) {
        pixelMap = await this.decodeArtwork(request.artwork);
      }
      const metadata: avSession.AVMetadata = {
        assetId: "now-playing",
        title: request.title,
        artist: request.artist,
        album: request.album,
      };
      if (request.durationMs > 0) {
        metadata.duration = request.durationMs;
      }
      if (pixelMap !== undefined) {
        metadata.mediaImage = pixelMap;
      }
      await session.setAVMetadata(metadata);

      let playbackState = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
      if (request.state === "paused") {
        playbackState = avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
      } else if (request.state === "stopped") {
        playbackState = avSession.PlaybackState.PLAYBACK_STATE_STOP;
      }
      await session.setAVPlaybackState({
        state: playbackState,
        speed: request.rate > 0 ? request.rate : 1.0,
        position: {
          elapsedTime: Math.max(0, request.positionMs),
          updateTime: Date.now(),
        },
      });
      await session.activate();
      return true;
    });
  }

  dispose(): Promise<void> {
    this.disposed = true;
    this.activeHookContext = null;
    return this.serialize((): Promise<void> => this.releaseSession());
  }

  private async ensureSession(
    abilityContext: common.UIAbilityContext,
  ): Promise<avSession.AVSession> {
    if (this.session !== null) {
      return this.session;
    }
    const created = await avSession.createAVSession(abilityContext, "ability-now-playing", "audio");
    this.registeredCommands = 0;
    this.session = created;
    return created;
  }

  private async decodeArtwork(bytes: number[]): Promise<image.PixelMap | undefined> {
    const raw = new Uint8Array(bytes);
    const source = image.createImageSource(raw.buffer);
    try {
      const pixelMap = await source.createPixelMap();
      this.artworkPixelMap = pixelMap;
      return pixelMap;
    } catch (error) {
      console.warn(`[SystemState] artwork decode failed: ${String(error)}`);
      return undefined;
    } finally {
      try {
        await source.release();
      } catch {}
    }
  }

  private async releaseArtwork(): Promise<void> {
    const pm = this.artworkPixelMap;
    this.artworkPixelMap = null;
    if (pm !== null) {
      try {
        await pm.release();
      } catch {}
    }
  }

  private async releaseSession(): Promise<void> {
    const session = this.session;
    this.session = null;
    this.registeredCommands = 0;
    if (session !== null) {
      try {
        await session.deactivate();
      } catch {}
      try {
        await session.destroy();
      } catch {}
    }
    await this.releaseArtwork();
  }
}
