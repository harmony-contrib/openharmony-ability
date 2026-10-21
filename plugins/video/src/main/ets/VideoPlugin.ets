import { VideoOperations } from "./VideoOperations";
import media from "@ohos.multimedia.media";
import fs from "@ohos.file.fs";
import { util } from "@kit.ArkTS";
import { BuilderNode, FrameNode } from "@kit.ArkUI";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  BridgePluginContext,
  BridgeLifecycleEvent,
  BridgePluginHookContext,
  BridgeAcknowledgement,
} from "@ohos-rs/ability";

interface Settings {
  id: string;
  paused: boolean;
  muted: boolean;
  volume: number;
  rate: number;
  repeat: boolean;
  resizeMode: string;
  controls: boolean;
  progressIntervalMs: number;
}
interface CreateRequest {
  targetId: number;
  settings: Settings;
}
interface CommandRequest {
  id: string;
  source?: string | null;
  value?: number | null;
}
interface BytesRequest {
  id: string;
  bytes: Uint8Array;
}
class Acknowledgement {
  readonly accepted: boolean = true;
}
class Ready {
  targetId: number;
  content: FrameNode;
  constructor(targetId: number, content: FrameNode) {
    this.targetId = targetId;
    this.content = content;
  }
}
class Retiring {
  targetId: number;
  constructor(targetId: number) {
    this.targetId = targetId;
  }
}
class PlaybackEvent {
  readonly id: string;
  readonly targetId: number;
  readonly phase: string;
  readonly currentTime: number;
  readonly duration: number;
  readonly width: number;
  readonly height: number;
  readonly buffering: boolean;
  readonly message?: string;
  constructor(entry: VideoEntry, phase: string, message?: string) {
    this.id = entry.settings.id;
    this.targetId = entry.targetId;
    this.phase = phase;
    this.currentTime = Math.max(0, entry.player?.currentTime ?? 0) / 1000;
    this.duration = Math.max(0, entry.player?.duration ?? 0) / 1000;
    this.width = entry.player?.width ?? 0;
    this.height = entry.player?.height ?? 0;
    this.buffering = entry.buffering;
    this.message = message;
  }
}
function parseSettings(value: Settings): Settings {
  if (
    !value ||
    typeof value.id !== "string" ||
    !value.id.trim() ||
    typeof value.paused !== "boolean" ||
    typeof value.muted !== "boolean" ||
    typeof value.repeat !== "boolean" ||
    typeof value.controls !== "boolean" ||
    !Number.isFinite(value.volume) ||
    value.volume < 0 ||
    value.volume > 1 ||
    ![0, 0.125, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].includes(value.rate) ||
    !["contain", "cover", "stretch", "center"].includes(value.resizeMode) ||
    !Number.isFinite(value.progressIntervalMs) ||
    value.progressIntervalMs < 0
  ) {
    throw new Error("Invalid API-12 video settings");
  }
  return value;
}
function playbackSpeed(rate: number): media.PlaybackSpeed {
  switch (rate) {
    case 0.125:
      return media.PlaybackSpeed.SPEED_FORWARD_0_125_X;
    case 0.25:
      return media.PlaybackSpeed.SPEED_FORWARD_0_25_X;
    case 0.5:
      return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    case 0.75:
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    case 1.25:
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    case 1.5:
      return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    case 1.75:
      return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    case 2:
      return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    default:
      return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
  }
}

@Builder
function VideoContent(entry: VideoEntry) {
  Stack({ alignContent: Alignment.Center }) {
    XComponent({
      id: `ability-video-${entry.targetId}`,
      type: XComponentType.SURFACE,
      controller: entry.surface,
    })
      .width(entry.pictureWidth > 0 ? entry.pictureWidth : "100%")
      .height(entry.pictureHeight > 0 ? entry.pictureHeight : "100%")
      .onLoad(() => entry.surfaceLoaded())
    if (entry.settings.controls) {
      Row({ space: 8 }) {
        Button(entry.player?.state === "playing" ? "Pause" : "Play")
          .onClick(() => {
            entry.togglePlayback();
          })
        Slider({
          value: entry.player?.currentTime ?? 0,
          min: 0,
          max: Math.max(1, entry.player?.duration ?? 1),
        })
          .layoutWeight(1)
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              entry.seek(value / 1000).catch((error: Error): void => entry.reportError(error));
            }
          })
      }
      .padding(8)
      .width("100%")
      .backgroundColor("#99000000")
      .align(Alignment.Bottom);
    }
  }
  .width("100%")
  .height("100%")
  .clip(true)
  .backgroundColor(Color.Black)
  .onAreaChange((_old: Area, area: Area) => entry.resize(Number(area.width), Number(area.height)));
}

// A failed native detach must keep the external node owner alive even after
// its plugin is disposed. Quarantined nodes live until process exit.
const failedNativeRetirements: Set<VideoEntry> = new Set();

class VideoEntry {
  readonly surface: XComponentController = new XComponentController();
  readonly node: BuilderNode<[VideoEntry]>;
  player?: media.AVPlayer;
  buffering: boolean = false;
  pictureWidth: number = 0;
  pictureHeight: number = 0;
  private width: number = 0;
  private height: number = 0;
  private closed: boolean = false;
  private operations: VideoOperations = new VideoOperations();
  private disposal?: Promise<void>;
  private retirementError?: Error;
  private mounted: boolean = false;
  private generation: number = 0;
  private lastProgress: number = 0;
  private file?: fs.File;
  private temporaryPath?: string;
  private surfaceResolve?: () => void;
  private surfaceReject?: (error: Error) => void;
  private surfaceReady: Promise<void>;
  private awaitingSurface: boolean = false;
  private pendingSeek?: number;
  readonly targetId: number;
  settings: Settings;
  private readonly context: BridgePluginContext;
  constructor(targetId: number, settings: Settings, context: BridgePluginContext) {
    this.targetId = targetId;
    this.settings = settings;
    this.context = context;
    this.node = new BuilderNode<[VideoEntry]>(context.getUIContext());
    this.surfaceReady = new Promise<void>((resolve, reject) => {
      this.surfaceResolve = resolve;
      this.surfaceReject = reject;
    });
  }
  create(call: BridgeCallContext): Promise<void> {
    return this.operations.run((): Promise<void> => this.build(call));
  }
  private async build(call: BridgeCallContext): Promise<void> {
    this.node.build(wrapBuilder(VideoContent), this);
    const frame = this.node.getFrameNode();
    if (frame === null) {
      throw new Error("Video BuilderNode has no FrameNode");
    }
    this.mounted = true;
    const ready = this.context.invokeNativeSync(
      "native-node-ready",
      "ohos.node.NativeNodeReady",
      "ohos.node.Acknowledgement",
      new Ready(this.targetId, frame),
    ) as BridgeAcknowledgement;
    if (ready?.accepted !== true) {
      throw new Error("Native video attachment target was disposed");
    }
    if (this.closed || !call.isActive()) {
      throw new Error("Video creation was cancelled");
    }
    this.awaitingSurface = true;
    const unregister = call.onCancel(() => {
      this.surfaceReject?.(new Error("Video creation was cancelled"));
    });
    try {
      await this.surfaceReady;
    } finally {
      this.awaitingSurface = false;
      unregister();
    }
    if (this.closed || !call.isActive()) {
      throw new Error("Video creation was cancelled");
    }
    const player = await media.createAVPlayer();
    // Adopt before cancellation can start release. Failure keeps this complete
    // owner reachable through disposal/quarantine rather than losing the player.
    this.player = player;
    if (this.closed || !call.isActive()) {
      throw new Error("Video creation was cancelled");
    }
    player.on("stateChange", (state: media.AVPlayerState) => {
      const generation = this.generation;
      this.operations
        .run(async (): Promise<void> => {
          if (generation === this.generation) {
            await this.stateChanged(state);
          }
        })
        .catch((e: Error) => this.fail(e));
    });
    player.on("error", (error: Error) => this.fail(error));
    player.on("timeUpdate", () => {
      const now = Date.now();
      if (now - this.lastProgress >= this.settings.progressIntervalMs) {
        this.lastProgress = now;
        this.notify("progress");
        this.update();
      }
    });
    player.on("seekDone", () => this.notify("seek"));
    player.on("endOfStream", () => this.notify("end"));
    player.on("videoSizeChange", () => {
      this.resize(this.width, this.height);
    });
    player.on("bufferingUpdate", (info: media.BufferingInfoType) => {
      if (
        info === media.BufferingInfoType.BUFFERING_START ||
        info === media.BufferingInfoType.BUFFERING_END
      ) {
        this.buffering = info === media.BufferingInfoType.BUFFERING_START;
        this.notify("buffer");
      }
    });
  }
  surfaceLoaded(): void {
    this.surfaceResolve?.();
    this.surfaceResolve = undefined;
  }
  configure(settings: Settings): Promise<void> {
    return this.operations.run(async (): Promise<void> => {
      this.settings = settings;
      this.resize(this.width, this.height);
      await this.apply();
      this.update();
    });
  }
  private async stateChanged(state: media.AVPlayerState): Promise<void> {
    if (this.closed || !this.player || this.player.state !== state) {
      return;
    }
    const player = this.player;
    if (state === "initialized") {
      player.surfaceId = this.surface.getXComponentSurfaceId();
      await player.prepare();
    } else if (state === "prepared") {
      this.resize(this.width, this.height);
      this.notify("load");
      if (this.pendingSeek !== undefined) {
        const seconds = this.pendingSeek;
        this.pendingSeek = undefined;
        this.seekNow(seconds);
      }
      await this.apply();
    }
    this.update();
  }
  private usable(): boolean {
    return (
      this.player !== undefined &&
      ["prepared", "playing", "paused", "completed"].includes(this.player.state)
    );
  }
  private async apply(): Promise<void> {
    if (!this.usable() || !this.player || this.closed) {
      return;
    }
    const p = this.player;
    p.loop = this.settings.repeat;
    p.setVolume(this.settings.muted ? 0 : this.settings.volume);
    p.setSpeed(playbackSpeed(this.settings.rate));
    p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
    if (this.settings.paused || this.settings.rate === 0) {
      if (p.state === "playing") {
        await p.pause();
      }
    } else if (p.state !== "playing") {
      await p.play();
    }
  }
  source(url?: string | null, bytes?: Uint8Array): Promise<void> {
    return this.operations.run((): Promise<void> => this.setSource(url, bytes));
  }
  private async setSource(url?: string | null, bytes?: Uint8Array): Promise<void> {
    const player = this.player;
    if (!player || this.closed) {
      throw new Error("Video is disposed");
    }
    const generation = ++this.generation;
    await player.reset();
    if (this.closed || generation !== this.generation) {
      return;
    }
    this.closeFile();
    this.buffering = false;
    this.lastProgress = 0;
    if (bytes !== undefined) {
      const path = `${this.context.abilityContext.cacheDir}/ability-video-${util.generateRandomUUID(true)}`;
      const file = await fs.open(
        path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC,
      );
      this.file = file;
      this.temporaryPath = path;
      let adopted = false;
      try {
        // Bound copy cost per partial write rather than repeatedly copying the
        // entire remaining resource. The original bytes remain callback-owned.
        let written = 0;
        while (written < bytes.byteLength) {
          if (this.closed) {
            return;
          }
          const chunk = bytes.slice(written, Math.min(bytes.byteLength, written + 65536));
          const count = await fs.write(file.fd, chunk.buffer);
          if (count <= 0 || count > chunk.byteLength) {
            throw new Error("Incomplete temporary video resource write");
          }
          written += count;
        }
        if (this.closed || generation !== this.generation) {
          return;
        }
        player.fdSrc = { fd: file.fd, offset: 0, length: bytes.byteLength };
        adopted = true;
      } finally {
        if (!adopted) {
          this.closeFile();
        }
      }
    } else if (url) {
      player.url = url;
    }
  }
  seek(seconds: number): Promise<void> {
    return this.operations.run(async (): Promise<void> => {
      this.seekNow(seconds);
    });
  }
  private seekNow(seconds: number): void {
    if (this.closed) {
      return;
    }
    if (!this.usable() || !this.player) {
      this.pendingSeek = seconds;
      return;
    }
    this.player.seek(Math.round(seconds * 1000), media.SeekMode.SEEK_CLOSEST);
  }
  togglePlayback(): void {
    this.operations
      .run(async (): Promise<void> => {
        if (!this.usable() || !this.player || this.closed) {
          return;
        }
        if (this.player.state === "playing") {
          await this.player.pause();
        } else {
          await this.player.play();
        }
      })
      .catch((error: Error) => this.fail(error));
  }
  resize(width: number, height: number): void {
    if (this.closed || !Number.isFinite(width) || !Number.isFinite(height)) {
      return;
    }
    this.width = width;
    this.height = height;
    const vw = this.player?.width ?? 0,
      vh = this.player?.height ?? 0;
    let w = width,
      h = height;
    if (vw > 0 && vh > 0 && this.settings.resizeMode !== "stretch") {
      let scale =
        this.settings.resizeMode === "cover"
          ? Math.max(width / vw, height / vh)
          : Math.min(width / vw, height / vh);
      if (this.settings.resizeMode === "center") {
        scale = Math.min(scale, 1 / this.context.getUIContext().vp2px(1));
      }
      w = vw * scale;
      h = vh * scale;
    }
    if (w !== this.pictureWidth || h !== this.pictureHeight) {
      this.pictureWidth = w;
      this.pictureHeight = h;
      this.update();
    }
  }
  private update(): void {
    if (!this.closed) {
      this.node.update(this);
    }
  }
  private notify(phase: string, message?: string): void {
    if (this.closed) {
      return;
    }
    try {
      this.context.invokeNativeSync(
        "playback-event",
        "ohos.video.Event",
        "ohos.video.Acknowledgement",
        new PlaybackEvent(this, phase, message),
      );
    } catch (error) {
      console.error("Video event: " + String(error));
    }
  }
  reportError(error: Error): void {
    this.fail(error);
  }
  private fail(error: Error): void {
    this.notify("error", error.message ?? String(error));
  }
  close(cleanup: BridgePluginContext): void {
    if (this.closed) {
      if (this.retirementError) {
        throw this.retirementError;
      }
      return;
    }
    this.closed = true;
    this.generation++;
    if (this.awaitingSurface) {
      this.surfaceReject?.(new Error("Video was disposed"));
    }
    this.surfaceReject = undefined;
    try {
      if (this.mounted) {
        const retired = cleanup.invokeNativeSync(
          "native-node-retiring",
          "ohos.node.NativeNodeRetiring",
          "ohos.node.Acknowledgement",
          new Retiring(this.targetId),
        ) as BridgeAcknowledgement;
        if (retired?.accepted !== true) {
          throw new Error("Native video retirement was rejected");
        }
        this.mounted = false;
      }
    } catch (error) {
      this.retirementError = new Error(String(error));
      failedNativeRetirements.add(this);
    }
    this.disposal = this.operations.close(async (): Promise<void> => {
      try {
        // A failed release can still own the fd/surface. Retain the whole owner.
        if (this.player) {
          await this.player.release();
          this.player = undefined;
        }
        this.closeFile();
        if (!this.mounted) {
          this.node.dispose();
        }
      } catch (error) {
        failedNativeRetirements.add(this);
        throw new Error(`Video resource release failed: ${String(error)}`);
      }
      if (this.retirementError) {
        throw this.retirementError;
      }
    });
    // onClosing cannot await; onDispose observes this same completion barrier.
    this.disposal.catch((): void => {});
    if (this.retirementError) {
      throw this.retirementError;
    }
  }
  async dispose(cleanup: BridgePluginContext): Promise<void> {
    try {
      this.close(cleanup);
    } finally {
      await this.disposal;
    }
  }
  private closeFile(): void {
    if (this.file) {
      fs.closeSync(this.file);
      this.file = undefined;
    }
    if (this.temporaryPath) {
      fs.unlinkSync(this.temporaryPath);
      this.temporaryPath = undefined;
    }
  }
}

export class VideoPlugin extends AsyncPluginBase {
  readonly id = "ohos.video";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];
  private entries: Map<string, VideoEntry> = new Map();
  override async onLifecycle(
    event: BridgeLifecycleEvent,
    context: BridgePluginHookContext,
  ): Promise<void> {
    if (event.kind === "ui-context-destroy") {
      await this.onDispose(context);
    }
  }
  override onClosing(context: BridgePluginHookContext): void {
    let failure: Error | undefined;
    for (const entry of Array.from(this.entries.values())) {
      try {
        entry.close(context);
      } catch (error) {
        failure ??= new Error(String(error));
      }
    }
    if (failure) {
      throw failure;
    }
  }
  override async onDispose(context: BridgePluginHookContext): Promise<void> {
    let failure: Error | undefined;
    try {
      this.onClosing(context);
    } catch (error) {
      failure = new Error(String(error));
    }
    const entries = Array.from(this.entries.values());
    const results = await Promise.allSettled(
      entries.map((entry: VideoEntry): Promise<void> => entry.dispose(context)),
    );
    for (const result of results) {
      if (result.status === "rejected") {
        failure ??= new Error(String(result.reason));
      }
    }
    this.entries.clear();
    if (failure) {
      throw failure;
    }
  }
  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    call: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!call.isActive()) {
      throw new Error("Video bridge session is inactive");
    }
    if (payload.value === null || typeof payload.value !== "object") {
      throw new Error("Video requires a named object");
    }
    if (action === "create") {
      if (payload.typeName !== "ohos.video.CreateRequest") {
        throw new Error("Video create requires ohos.video.CreateRequest");
      }
      const request = payload.value as CreateRequest;
      if (
        !Number.isInteger(request.targetId) ||
        request.targetId <= 0 ||
        request.targetId > 0xffffffff
      ) {
        throw new Error("Invalid native video target");
      }
      const settings = parseSettings(request.settings);
      if (this.entries.has(settings.id)) {
        throw new Error("Video ID already exists");
      }
      const entry = new VideoEntry(request.targetId, settings, this.getContext());
      this.entries.set(settings.id, entry);
      try {
        await entry.create(call);
      } catch (error) {
        // A cancelled call cannot admit cleanup callbacks. The installed plugin
        // context stays active until lifecycle teardown supplies its scoped hook.
        await entry.dispose(this.getContext());
        if (this.entries.get(settings.id) === entry) {
          this.entries.delete(settings.id);
        }
        throw new Error(String(error));
      }
    } else if (action === "configure") {
      if (payload.typeName !== "ohos.video.Settings") {
        throw new Error("Video configure requires ohos.video.Settings");
      }
      const settings = parseSettings(payload.value as Settings);
      await this.entry(settings.id).configure(settings);
    } else if (action === "set-bytes") {
      if (payload.typeName !== "ohos.video.BytesRequest") {
        throw new Error("Video set-bytes requires ohos.video.BytesRequest");
      }
      const request = payload.value as BytesRequest;
      if (!(request.bytes instanceof Uint8Array) || request.bytes.byteLength === 0) {
        throw new Error("Video bytes must not be empty");
      }
      await this.entry(request.id).source(undefined, request.bytes);
    } else {
      if (payload.typeName !== "ohos.video.CommandRequest") {
        throw new Error("Video command requires ohos.video.CommandRequest");
      }
      const request = payload.value as CommandRequest;
      const entry = this.entry(request.id);
      if (action === "set-source") {
        if (
          request.source !== null &&
          request.source !== undefined &&
          typeof request.source !== "string"
        ) {
          throw new Error("Invalid video source");
        }
        if (
          request.value != null ||
          (typeof request.source === "string" && !request.source.trim())
        ) {
          throw new Error("Invalid video source");
        }
        await entry.source(request.source);
      } else if (action === "seek") {
        if (
          typeof request.value !== "number" ||
          !Number.isFinite(request.value) ||
          request.value < 0 ||
          request.value * 1000 > 0x7fffffff ||
          request.source != null
        ) {
          throw new Error("Invalid seek time");
        }
        await entry.seek(request.value);
      } else if (action === "dispose") {
        if (request.source != null || request.value != null) {
          throw new Error("Invalid video dispose");
        }
        await entry.dispose(call);
        this.entries.delete(request.id);
      } else {
        throw new Error(`Unsupported ohos.video action '${action}'`);
      }
    }
    if (!call.isActive()) {
      throw new Error("Video bridge session closed during operation");
    }
    return { typeName: "ohos.video.Acknowledgement", value: new Acknowledgement() };
  }
  private entry(id: string): VideoEntry {
    if (typeof id !== "string" || !id.trim()) {
      throw new Error("Video ID must not be empty");
    }
    const entry = this.entries.get(id);
    if (!entry) {
      throw new Error(`Unknown video '${id}'`);
    }
    return entry;
  }
}
