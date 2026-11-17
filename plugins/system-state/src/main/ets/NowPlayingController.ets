import avSession from "@ohos.multimedia.avsession";
import { image } from "@kit.ImageKit";
import { common } from "@kit.AbilityKit";
import { BridgePluginHookContext } from "@ohos-rs/ability";

const MEDIA_COMMAND_EVENT_TYPE = "ohos.system-state.MediaCommandEvent";

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

  private serialize<T>(work: () => Promise<T>): Promise<T> {
    const next = this.queue.then(work, work);
    this.queue = next.then(
      () => {},
      () => {},
    );
    return next;
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
      if (!request.active) {
        await this.releaseSession();
        return true;
      }
      const session = await this.ensureSession(abilityContext, hookContext);
      if (this.disposed) {
        await this.releaseSession();
        return false;
      }
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
        duration: request.durationMs > 0 ? request.durationMs : undefined,
        mediaImage: pixelMap,
      };
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
    return this.serialize((): Promise<void> => this.releaseSession());
  }

  private async ensureSession(
    abilityContext: common.UIAbilityContext,
    hookContext: BridgePluginHookContext | null,
  ): Promise<avSession.AVSession> {
    if (this.session !== null) {
      return this.session;
    }
    const created = await avSession.createAVSession(abilityContext, "ability-now-playing", "audio");
    const emit = (command: string, positionMs: number = 0): void => {
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
    };
    created.on("play", () => emit("play"));
    created.on("pause", () => emit("pause"));
    created.on("stop", () => emit("stop"));
    created.on("playNext", () => emit("next"));
    created.on("playPrevious", () => emit("previous"));
    created.on("seek", (time: number) => emit("seek", Math.max(0, Math.round(time))));
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
