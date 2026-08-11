import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from "@ohos/hypium";
import { SerialTaskQueue } from "../main/ets/runtime/SerialTaskQueue";
import { AbilityStateCodec } from "../main/ets/runtime/AbilityStateCodec";
import { CancellableTaskScope } from "../main/ets/runtime/CancellableTaskScope";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import {
  AsyncPluginBase,
  BridgeAbilityCreateLifecyclePayload,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeEmptyLifecyclePayload,
  BridgePluginHookContext,
  BridgeTypedValue,
  LazyPlugin,
} from "../main/ets/ability/type";
import { BridgeHostRegistry } from "../main/ets/bridge/BridgeHost";

let installProbeCount: number = 0;
let installProbeSinkCount: number = 0;
let stageInstallProbeCount: number = 0;

class InstallProbeRequest {
  readonly accepted: boolean = true;
}

class InstallProbeResponse {
  readonly accepted: boolean = true;
}

class InstallProbePlugin extends AsyncPluginBase {
  readonly id = "test.install-probe";
  readonly version = 1;
  readonly requires: BridgeContextRequirement[] = ["ability"];

  override onInstall(context: BridgePluginHookContext): void {
    installProbeCount += 1;
    context.invokeNativeSync(
      "install-ready",
      "test.InstallRequest",
      "test.InstallResponse",
      new InstallProbeRequest(),
    );
  }

  async invokeAsync(
    _action: string,
    request: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    return request;
  }
}

class StageInstallProbePlugin extends AsyncPluginBase {
  readonly id = "test.stage-install-probe";
  readonly version = 1;
  readonly requires: BridgeContextRequirement[] = ["window-stage"];

  override onInstall(): void {
    stageInstallProbeCount += 1;
  }

  async invokeAsync(
    _action: string,
    request: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    return request;
  }
}

export default function localUnitTest() {
  describe("localUnitTest", () => {
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {
      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    });
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    });
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    });
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    });
    it("assertContain", 0, () => {
      // Defines a test case. This API supports three parameters: test case name, filter parameter, and test case function.
      let a = "abc";
      let b = "b";
      // Defines a variety of assertion methods, which are used to declare expected boolean conditions.
      expect(a).assertContain(b);
      expect(a).assertEqual(a);
    });
    it("serialTaskQueuePreservesLifecycleOrder", 0, async () => {
      const events: string[] = [];
      let release: () => void = (): void => {};
      const gate = new Promise<void>((resolve) => {
        release = resolve;
      });
      const queue = new SerialTaskQueue((): void => {});

      void queue.enqueue("create", async (): Promise<void> => {
        events.push("create-start");
        await gate;
        events.push("create-end");
      });
      void queue.enqueue("window", async (): Promise<void> => {
        events.push("window");
      });

      await Promise.resolve();
      expect(events.join(",")).assertEqual("create-start");
      release();
      await queue.settled();
      expect(events.join(",")).assertEqual("create-start,create-end,window");
    });
    it("serialTaskQueueContinuesAfterFailure", 0, async () => {
      const errors: string[] = [];
      const events: string[] = [];
      const queue = new SerialTaskQueue((label: string): void => {
        errors.push(label);
      });

      void queue.enqueue("broken", async (): Promise<void> => {
        throw new Error("expected failure");
      });
      void queue.enqueue("destroy", async (): Promise<void> => {
        events.push("destroy");
      });
      await queue.settled();

      expect(errors.join(",")).assertEqual("broken");
      expect(events.join(",")).assertEqual("destroy");
    });
    it("abilityStateCodecRoundTripsDeterministically", 0, () => {
      const stateMap: Record<string, string> = {};
      stateMap.beta = "state&with=delimiters";
      stateMap.alpha = "中文/space value";
      const encoded = AbilityStateCodec.encode(stateMap);
      const decoded = AbilityStateCodec.decode(encoded);

      expect(encoded.indexOf("alpha=") < encoded.indexOf("beta=")).assertTrue();
      expect(decoded.alpha).assertEqual("中文/space value");
      expect(decoded.beta).assertEqual("state&with=delimiters");
      expect(Object.keys(AbilityStateCodec.decode("legacy-state")).length).assertEqual(0);
    });
    it("cancellableTaskScopeCancelsAStuckHook", 0, async () => {
      const scope = new CancellableTaskScope("test hook", 1_000);
      let cancellationObserved = false;
      const task = scope.run(
        async (signal): Promise<void> =>
          await new Promise<void>((resolve) => {
            signal.onCancel((): void => {
              cancellationObserved = true;
              resolve();
            });
          }),
      );
      await Promise.resolve();
      scope.cancel(new Error("session closing"));

      let rejected = false;
      try {
        await task;
      } catch {
        rejected = true;
      }
      expect(cancellationObserved).assertTrue();
      expect(rejected).assertTrue();
    });
    it("cancellableTaskScopeTimesOutAStuckHook", 0, async () => {
      const scope = new CancellableTaskScope("timeout hook", 5);
      let errorText = "";
      try {
        await scope.run(async (): Promise<void> => await new Promise<void>(() => {}));
      } catch (error) {
        errorText = String(error);
      }
      expect(errorText.indexOf("timed out") >= 0).assertTrue();
    });
    it("abilityPluginActivatesOnlyAfterRustSinkIsAttached", 0, async () => {
      installProbeCount = 0;
      installProbeSinkCount = 0;
      const sessionId = BridgeHostRegistry.prepare(["test_native"], {} as common.UIAbilityContext, [
        new LazyPlugin(() => new InstallProbePlugin()),
      ]);
      expect(installProbeCount).assertEqual(0);

      BridgeHostRegistry.attachEventSink(sessionId, "test_native", (): InstallProbeResponse => {
        installProbeSinkCount += 1;
        return new InstallProbeResponse();
      });
      await BridgeHostRegistry.activateAbility(sessionId, "test_native", {
        kind: "ability-create",
        payload: new BridgeAbilityCreateLifecyclePayload(""),
      });

      expect(installProbeCount).assertEqual(1);
      expect(installProbeSinkCount).assertEqual(1);
      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
    });
    it("invalidatedWindowStageCannotBecomeReadyFromAQueuedCreate", 0, async () => {
      stageInstallProbeCount = 0;
      const sessionId = BridgeHostRegistry.prepare(["test_native"], {} as common.UIAbilityContext, [
        new LazyPlugin(() => new StageInstallProbePlugin()),
      ]);
      await BridgeHostRegistry.activateAbility(sessionId, "test_native", {
        kind: "ability-create",
        payload: new BridgeAbilityCreateLifecyclePayload(""),
      });

      const pendingCreate = BridgeHostRegistry.setWindowStage(
        sessionId,
        "test_native",
        {} as window.WindowStage,
      );
      BridgeHostRegistry.invalidateWindowStage(sessionId, "test_native");
      await pendingCreate;
      await BridgeHostRegistry.emitLifecycle(sessionId, "test_native", {
        kind: "configuration-updated",
        payload: new BridgeEmptyLifecyclePayload(),
      });

      expect(stageInstallProbeCount).assertEqual(0);
      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
    });
  });
}
