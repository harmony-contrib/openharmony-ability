import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from "@ohos/hypium";
import { SerialTaskQueue } from "../main/ets/runtime/SerialTaskQueue";
import { AbilityStateCodec } from "../main/ets/runtime/AbilityStateCodec";
import { CancellableTaskScope } from "../main/ets/runtime/CancellableTaskScope";
import { NativeModuleLoader } from "../main/ets/runtime/NativeModuleLoader";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import { FrameNode } from "@ohos.arkui.node";
import { UIContext } from "@ohos.arkui.UIContext";
import {
  AsyncPluginBase,
  BridgeAbilityCreateLifecyclePayload,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeEmptyLifecyclePayload,
  BridgeLifecycleEvent,
  BridgePluginContext,
  BridgePluginDeclaration,
  BridgePluginHookContext,
  BridgeTypedValue,
  LazyPlugin,
} from "../main/ets/ability/type";
import { BridgeHostRegistry } from "../main/ets/bridge/BridgeHost";

let installProbeCount: number = 0;
let installProbeSinkCount: number = 0;
let stageInstallProbeCount: number = 0;
let lifecycleOrderProbe: string[] = [];
let broadcastProbeContext: BridgePluginContext | undefined;

function asyncPluginDeclaration(
  id: string,
  requires: BridgeContextRequirement[],
): BridgePluginDeclaration {
  return { id, execution: "async", requires };
}

class InstallProbeRequest {
  readonly accepted: boolean = true;
}

class InstallProbeResponse {
  readonly accepted: boolean = true;
}

class InstallProbePlugin extends AsyncPluginBase {
  readonly id = "test.install-probe";
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

class AbilityEchoPlugin extends AsyncPluginBase {
  readonly id = "test.ability-echo";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    _action: string,
    request: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    return request;
  }
}

class OrderedRequirementsPlugin extends AsyncPluginBase {
  readonly id = "test.ordered-requirements";
  readonly requires: BridgeContextRequirement[] = ["ui-context", "ability"];

  async invokeAsync(
    _action: string,
    request: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    return request;
  }
}

class ReservedNodePlugin extends AsyncPluginBase {
  readonly id = "ohos.node";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];

  async invokeAsync(
    _action: string,
    request: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    return request;
  }
}

class LifecycleOrderProbePlugin extends AsyncPluginBase {
  readonly id = "test.lifecycle-order-probe";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];

  override onLifecycle(event: BridgeLifecycleEvent, _context: BridgePluginHookContext): void {
    lifecycleOrderProbe.push(event.kind);
  }

  async invokeAsync(
    _action: string,
    request: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    return request;
  }
}

class BroadcastProbePlugin extends AsyncPluginBase {
  readonly id = "test.broadcast-probe";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  override attachContext(context: BridgePluginContext): void {
    super.attachContext(context);
    if (broadcastProbeContext === undefined) {
      broadcastProbeContext = context;
    }
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
    it("nativeModuleDeclarationsMustBeDistinct", 0, () => {
      let duplicateError = "";
      try {
        NativeModuleLoader.resolveModuleNames(["module_a", "module_a"]);
      } catch (error) {
        duplicateError = String(error);
      }
      expect(
        duplicateError.indexOf("every DefaultXComponent needs a distinct module") >= 0,
      ).assertTrue();
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
      BridgeHostRegistry.configurePlugins(sessionId, "test_native", [
        asyncPluginDeclaration("test.install-probe", ["ability"]),
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
    it("pluginFactoriesAreSelectedByEachRustRegistryWithoutModuleFilters", 0, async () => {
      installProbeCount = 0;
      const modules = ["factory_match_module_a", "factory_match_module_b"];
      const sessionId = BridgeHostRegistry.prepare(modules, {} as common.UIAbilityContext, [
        new LazyPlugin(() => new InstallProbePlugin()),
        new LazyPlugin(() => new AbilityEchoPlugin()),
      ]);
      BridgeHostRegistry.configurePlugins(sessionId, modules[0], [
        asyncPluginDeclaration("test.install-probe", ["ability"]),
      ]);
      BridgeHostRegistry.configurePlugins(sessionId, modules[1], [
        asyncPluginDeclaration("test.ability-echo", ["ability"]),
      ]);
      BridgeHostRegistry.attachEventSink(
        sessionId,
        modules[0],
        (): InstallProbeResponse => new InstallProbeResponse(),
      );
      for (const moduleName of modules) {
        await BridgeHostRegistry.activateAbility(sessionId, moduleName, {
          kind: "ability-create",
          payload: new BridgeAbilityCreateLifecyclePayload(""),
        });
      }

      expect(installProbeCount).assertEqual(1);
      let undeclaredPluginError = "";
      try {
        await BridgeHostRegistry.invokeAsync(
          sessionId,
          modules[1],
          "test.install-probe",
          "echo",
          "test.InstallRequest",
          "test.InstallRequest",
          new InstallProbeRequest(),
          1_000,
        );
      } catch (error) {
        undeclaredPluginError = String(error);
      }
      expect(undeclaredPluginError.indexOf("is not installed") >= 0).assertTrue();

      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
    });
    it("pluginConfigurationFailsWhenRustPluginHasNoArkTSFactory", 0, async () => {
      const moduleName = "missing_factory_module";
      const sessionId = BridgeHostRegistry.prepare([moduleName], {} as common.UIAbilityContext, []);
      let configurationError = "";
      try {
        BridgeHostRegistry.configurePlugins(sessionId, moduleName, [
          asyncPluginDeclaration("test.ability-echo", ["ability"]),
        ]);
      } catch (error) {
        configurationError = String(error);
      }
      expect(configurationError.indexOf("has no matching ArkTS factory") >= 0).assertTrue();

      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
    });
    it("pluginConfigurationRejectsExecutionAndContextMismatches", 0, async () => {
      const executionModule = "execution_mismatch_module";
      const executionSession = BridgeHostRegistry.prepare(
        [executionModule],
        {} as common.UIAbilityContext,
        [new LazyPlugin(() => new AbilityEchoPlugin())],
      );
      let executionError = "";
      try {
        BridgeHostRegistry.configurePlugins(executionSession, executionModule, [
          {
            id: "test.ability-echo",
            execution: "sync-main-thread",
            requires: ["ability"],
          },
        ]);
      } catch (error) {
        executionError = String(error);
      }
      expect(executionError.indexOf("execution mismatch") >= 0).assertTrue();
      BridgeHostRegistry.beginClosing(executionSession);
      await BridgeHostRegistry.dispose(executionSession);

      const contextModule = "context_mismatch_module";
      const contextSession = BridgeHostRegistry.prepare(
        [contextModule],
        {} as common.UIAbilityContext,
        [new LazyPlugin(() => new AbilityEchoPlugin())],
      );
      let contextError = "";
      try {
        BridgeHostRegistry.configurePlugins(contextSession, contextModule, [
          asyncPluginDeclaration("test.ability-echo", ["window-stage"]),
        ]);
      } catch (error) {
        contextError = String(error);
      }
      expect(contextError.indexOf("context mismatch") >= 0).assertTrue();
      BridgeHostRegistry.beginClosing(contextSession);
      await BridgeHostRegistry.dispose(contextSession);
    });
    it("pluginConfigurationRejectsBuiltInPluginIdConflicts", 0, async () => {
      const moduleName = "reserved_plugin_id_module";
      const sessionId = BridgeHostRegistry.prepare([moduleName], {} as common.UIAbilityContext, [
        new LazyPlugin(() => new ReservedNodePlugin()),
      ]);
      let configurationError = "";
      try {
        BridgeHostRegistry.configurePlugins(sessionId, moduleName, []);
      } catch (error) {
        configurationError = String(error);
      }
      expect(configurationError.indexOf("conflicts with a built-in plugin") >= 0).assertTrue();

      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
    });
    it("pluginContextRequirementsAreComparedAsASet", 0, async () => {
      const moduleName = "requirement_order_module";
      const sessionId = BridgeHostRegistry.prepare([moduleName], {} as common.UIAbilityContext, [
        new LazyPlugin(() => new OrderedRequirementsPlugin()),
      ]);
      BridgeHostRegistry.configurePlugins(sessionId, moduleName, [
        asyncPluginDeclaration("test.ordered-requirements", ["ability", "ui-context"]),
      ]);

      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
    });
    it("abilityPluginDoesNotDependOnDefaultXComponentLifetime", 0, async () => {
      const moduleName = "ability_only_module";
      const sessionId = BridgeHostRegistry.prepare([moduleName], {} as common.UIAbilityContext, [
        new LazyPlugin(() => new AbilityEchoPlugin()),
      ]);
      BridgeHostRegistry.configurePlugins(sessionId, moduleName, [
        asyncPluginDeclaration("test.ability-echo", ["ability"]),
      ]);
      await BridgeHostRegistry.activateAbility(sessionId, moduleName, {
        kind: "ability-create",
        payload: new BridgeAbilityCreateLifecyclePayload(""),
      });

      const invoke = async (): Promise<ESObject> =>
        await BridgeHostRegistry.invokeAsync(
          sessionId,
          moduleName,
          "test.ability-echo",
          "echo",
          "test.InstallRequest",
          "test.InstallRequest",
          new InstallProbeRequest(),
          1_000,
        );
      expect(((await invoke()) as InstallProbeRequest).accepted).assertTrue();

      await BridgeHostRegistry.setWindowStage(sessionId, moduleName, {} as window.WindowStage);
      await BridgeHostRegistry.attachComponent(
        sessionId,
        moduleName,
        "ability-only-owner",
        {} as UIContext,
        {} as FrameNode,
      );
      await BridgeHostRegistry.detachComponent(sessionId, moduleName, "ability-only-owner");

      // Removing this module's UI root gates ui-context plugins only. The Ability-session
      // transport and ability-only plugins remain available until NativeAbility.onDestroy.
      expect(((await invoke()) as InstallProbeRequest).accepted).assertTrue();
      await BridgeHostRegistry.clearWindowStage(sessionId, moduleName);
      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
    });
    it("invalidatedWindowStageCannotBecomeReadyFromAQueuedCreate", 0, async () => {
      stageInstallProbeCount = 0;
      const sessionId = BridgeHostRegistry.prepare(["test_native"], {} as common.UIAbilityContext, [
        new LazyPlugin(() => new StageInstallProbePlugin()),
      ]);
      BridgeHostRegistry.configurePlugins(sessionId, "test_native", [
        asyncPluginDeclaration("test.stage-install-probe", ["window-stage"]),
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
    it("oneNativeModuleCannotBelongToTwoActiveAbilities", 0, async () => {
      const firstSession = BridgeHostRegistry.prepare(
        ["module_owner_test"],
        {} as common.UIAbilityContext,
        [],
      );
      BridgeHostRegistry.configurePlugins(firstSession, "module_owner_test", []);
      let duplicateError = "";
      try {
        BridgeHostRegistry.prepare(["module_owner_test"], {} as common.UIAbilityContext, []);
      } catch (error) {
        duplicateError = String(error);
      }
      expect(duplicateError.indexOf("already belongs to active Ability") >= 0).assertTrue();

      BridgeHostRegistry.beginClosing(firstSession);
      await BridgeHostRegistry.dispose(firstSession);
      const replacementSession = BridgeHostRegistry.prepare(
        ["module_owner_test"],
        {} as common.UIAbilityContext,
        [],
      );
      BridgeHostRegistry.configurePlugins(replacementSession, "module_owner_test", []);
      BridgeHostRegistry.beginClosing(replacementSession);
      await BridgeHostRegistry.dispose(replacementSession);
    });
    it("pluginInstanceCannotBeSharedAcrossNativeModules", 0, async () => {
      const singleton = new InstallProbePlugin();
      let reuseError = "";
      const sessionId = BridgeHostRegistry.prepare(
        ["singleton_module_a", "singleton_module_b"],
        {} as common.UIAbilityContext,
        [new LazyPlugin(() => singleton)],
      );
      try {
        BridgeHostRegistry.configurePlugins(sessionId, "singleton_module_a", [
          asyncPluginDeclaration("test.install-probe", ["ability"]),
        ]);
        BridgeHostRegistry.configurePlugins(sessionId, "singleton_module_b", [
          asyncPluginDeclaration("test.install-probe", ["ability"]),
        ]);
      } catch (error) {
        reuseError = String(error);
      }
      expect(reuseError.indexOf("cannot be reused") >= 0).assertTrue();
      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
    });
    it("oneNativeModuleRejectsASecondDefaultXComponent", 0, async () => {
      const moduleName = "single_component_module";
      const sessionId = BridgeHostRegistry.prepare([moduleName], {} as common.UIAbilityContext, []);
      BridgeHostRegistry.configurePlugins(sessionId, moduleName, []);
      await BridgeHostRegistry.activateAbility(sessionId, moduleName, {
        kind: "ability-create",
        payload: new BridgeAbilityCreateLifecyclePayload(""),
      });
      await BridgeHostRegistry.setWindowStage(sessionId, moduleName, {} as window.WindowStage);
      await BridgeHostRegistry.attachComponent(
        sessionId,
        moduleName,
        "owner-a",
        {} as UIContext,
        {} as FrameNode,
      );

      let duplicateError = "";
      try {
        await BridgeHostRegistry.attachComponent(
          sessionId,
          moduleName,
          "owner-b",
          {} as UIContext,
          {} as FrameNode,
        );
      } catch (error) {
        duplicateError = String(error);
      }
      expect(
        duplicateError.indexOf("every component must use a distinct native module") >= 0,
      ).assertTrue();

      // Cleanup from the rejected component must not detach the valid owner.
      await BridgeHostRegistry.detachComponent(sessionId, moduleName, "owner-b");
      let staleCleanupDetachedOwner = false;
      try {
        await BridgeHostRegistry.attachComponent(
          sessionId,
          moduleName,
          "owner-c",
          {} as UIContext,
          {} as FrameNode,
        );
        staleCleanupDetachedOwner = true;
      } catch {}
      expect(staleCleanupDetachedOwner).assertFalse();
      await BridgeHostRegistry.detachComponent(sessionId, moduleName, "owner-a");
      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
    });
    it("oneAbilityCanAttachComponentsBackedByDifferentModules", 0, async () => {
      const modules = ["component_module_a", "component_module_b"];
      const sessionId = BridgeHostRegistry.prepare(modules, {} as common.UIAbilityContext, []);
      for (const moduleName of modules) {
        BridgeHostRegistry.configurePlugins(sessionId, moduleName, []);
        await BridgeHostRegistry.activateAbility(sessionId, moduleName, {
          kind: "ability-create",
          payload: new BridgeAbilityCreateLifecyclePayload(""),
        });
        await BridgeHostRegistry.setWindowStage(sessionId, moduleName, {} as window.WindowStage);
        await BridgeHostRegistry.attachComponent(
          sessionId,
          moduleName,
          `owner-${moduleName}`,
          {} as UIContext,
          {} as FrameNode,
        );
      }

      for (const moduleName of modules) {
        await BridgeHostRegistry.detachComponent(sessionId, moduleName, `owner-${moduleName}`);
      }
      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
    });
    it("processGlobalPluginEventReachesEveryActiveNativeModule", 0, async () => {
      broadcastProbeContext = undefined;
      const modules = ["broadcast_module_a", "broadcast_module_b"];
      const receivedBy: string[] = [];
      const sessionId = BridgeHostRegistry.prepare(modules, {} as common.UIAbilityContext, [
        new LazyPlugin(() => new BroadcastProbePlugin()),
      ]);
      for (const moduleName of modules) {
        BridgeHostRegistry.configurePlugins(sessionId, moduleName, [
          asyncPluginDeclaration("test.broadcast-probe", ["ability"]),
        ]);
        BridgeHostRegistry.attachEventSink(sessionId, moduleName, (): InstallProbeResponse => {
          receivedBy.push(moduleName);
          return new InstallProbeResponse();
        });
        await BridgeHostRegistry.activateAbility(sessionId, moduleName, {
          kind: "ability-create",
          payload: new BridgeAbilityCreateLifecyclePayload(""),
        });
      }

      const context = broadcastProbeContext;
      if (context === undefined) {
        throw new Error("broadcast probe was not installed");
      }
      const responses = context.invokeNativeSyncProcessWide(
        "engine-event",
        "test.InstallRequest",
        "test.InstallResponse",
        new InstallProbeRequest(),
      );
      expect(responses.length).assertEqual(2);
      expect(receivedBy.join(",")).assertEqual(modules.join(","));

      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
      broadcastProbeContext = undefined;
    });
    it("windowStageCleanupCannotOvertakeComponentCleanup", 0, async () => {
      lifecycleOrderProbe = [];
      const moduleName = "lifecycle_order_module";
      const sessionId = BridgeHostRegistry.prepare([moduleName], {} as common.UIAbilityContext, [
        new LazyPlugin(() => new LifecycleOrderProbePlugin()),
      ]);
      BridgeHostRegistry.configurePlugins(sessionId, moduleName, [
        asyncPluginDeclaration("test.lifecycle-order-probe", ["ui-context"]),
      ]);
      await BridgeHostRegistry.activateAbility(sessionId, moduleName, {
        kind: "ability-create",
        payload: new BridgeAbilityCreateLifecyclePayload(""),
      });
      await BridgeHostRegistry.setWindowStage(sessionId, moduleName, {} as window.WindowStage);
      await BridgeHostRegistry.attachComponent(
        sessionId,
        moduleName,
        "owner-a",
        {} as UIContext,
        {} as FrameNode,
      );
      lifecycleOrderProbe = [];

      // Reproduce platform WindowStage teardown and component disappearance in one turn.
      const clearStage = BridgeHostRegistry.clearWindowStage(sessionId, moduleName);
      const detachComponent = BridgeHostRegistry.detachComponent(sessionId, moduleName, "owner-a");
      await Promise.all([clearStage, detachComponent]);
      expect(lifecycleOrderProbe.join(",")).assertEqual("ui-context-destroy,window-stage-destroy");

      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
    });
  });
}
