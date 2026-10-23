import fs from "@ohos.file.fs";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeTypedValue,
  expectBridgeRequestType,
} from "@ohos-rs/ability";
import { PlayerSession } from "./player_session";

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
      const source = request.sourceFd === undefined ? undefined : fs.dup(request.sourceFd);
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
        session = new PlayerSession(source, (message: string): void => {
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
