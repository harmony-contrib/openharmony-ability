import {
  BridgeContextRequirement,
  AsyncPluginBase,
  BridgeCallContext,
  BridgeTypedValue,
} from "@ohos-rs/ability";

interface DemoProfile {
  userId: string;
  visitCount: number;
}

class DemoProfileValue {
  readonly userId: string;
  readonly visitCount: number;

  constructor(userId: string, visitCount: number) {
    this.userId = userId;
    this.visitCount = visitCount;
  }
}

/** Demonstrates built-in and application-defined named N-API types without a JSON envelope. */
export class DemoTypedPlugin extends AsyncPluginBase {
  readonly id = "demo.raw";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (action === "echo-string") {
      if (payload.typeName !== "std.string" || typeof payload.value !== "string") {
        throw new Error("demo.raw.echo-string requires bridge type std.string");
      }
      return { typeName: "std.string", value: `ArkTS received: ${payload.value}` as ESObject };
    }

    if (action === "reverse-bytes") {
      if (payload.typeName !== "std.bytes" || !(payload.value instanceof Uint8Array)) {
        throw new Error("demo.raw.reverse-bytes requires bridge type std.bytes");
      }
      const bytes = payload.value as Uint8Array;
      const reversed = new Uint8Array(bytes.length);
      for (let index = 0; index < bytes.length; index++) {
        reversed[index] = bytes[bytes.length - index - 1];
      }
      return { typeName: "std.bytes", value: reversed as ESObject };
    }

    if (action === "bump-profile") {
      if (payload.typeName !== "demo.Profile" || typeof payload.value !== "object") {
        throw new Error("demo.raw.bump-profile requires bridge type demo.Profile");
      }
      const profile = payload.value as DemoProfile;
      if (!profile.userId?.trim() || !Number.isInteger(profile.visitCount)) {
        throw new Error("demo.Profile must contain userId and integer visitCount");
      }
      return {
        typeName: "demo.Profile",
        value: new DemoProfileValue(profile.userId, profile.visitCount + 1),
      };
    }

    throw new Error(`Unsupported demo.raw action '${action}'`);
  }
}
