import { AbilityConstant, Configuration, UIAbility, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import * as Entry from "../components/MainPage";
import { BridgeHostRegistry } from "../bridge/BridgeHost";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";
import { AbilityStateCodec } from "../runtime/AbilityStateCodec";
import { SerialTaskQueue } from "../runtime/SerialTaskQueue";
import {
  AbilityInitContext,
  ApplicationLifecycle,
  BridgeAbilityCreateLifecyclePayload,
  BridgeEmptyLifecyclePayload,
  BridgeLifecycleEvent,
  BridgeMemoryLevelLifecyclePayload,
  BridgePluginFactory,
  BridgeWindowStageEventLifecyclePayload,
  Module,
} from "./type";

export const STATE_KEY = "ohos.rs.ability.application.state";

interface LoadedNativeModule {
  moduleName: string;
  module: Module;
}

interface NativeModuleRuntime extends LoadedNativeModule {
  lifecycle: ApplicationLifecycle;
}

export class NativeAbility extends UIAbility {
  public moduleName: string | string[] = "";
  public defaultPage: boolean = true;
  public loadMode: "async" | "sync" = "async";
  /** Application-provided capability plugins. NativeAbility itself has no concrete plugin imports. */
  public bridgePlugins: BridgePluginFactory[] = [];

  private moduleRuntimes: NativeModuleRuntime[] = [];
  private bridgeSessionId: string = "";
  private readonly lifecycleQueue = new SerialTaskQueue((label: string, error: Error): void => {
    console.error(`[NativeAbility] lifecycle operation '${label}' failed: ${String(error)}`);
  });
  private acceptingLifecycle: boolean = false;
  private abilityGeneration: number = 0;
  private windowStageGeneration: number = 0;
  private windowStageActive: boolean = false;
  private observedWindowStage?: window.WindowStage;
  private observedMainWindow?: window.Window;

  private readonly onWindowStageEvent = (event: window.WindowStageEventType): void => {
    if (!this.acceptingLifecycle || this.observedWindowStage === undefined) {
      return;
    }
    void this.enqueueLifecycleOperation("window-stage-event", async (): Promise<void> => {
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onWindowStageEvent(event),
      );
      await this.notifyBridgeLifecycle({
        kind: "window-stage-event",
        payload: new BridgeWindowStageEventLifecyclePayload(event),
      });
    });
  };

  private readonly onWindowSizeChange = (size: window.Size): void => {
    if (this.acceptingLifecycle && this.observedMainWindow !== undefined) {
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onWindowSizeChange(size),
      );
    }
  };

  private readonly onWindowRectChange = (options: window.RectChangeOptions): void => {
    if (this.acceptingLifecycle && this.observedMainWindow !== undefined) {
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onWindowRectChange(options),
      );
    }
  };

  private readonly onAvoidAreaChange = (options: window.AvoidAreaOptions): void => {
    if (this.acceptingLifecycle && this.observedMainWindow !== undefined) {
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onAvoidAreaChange(options),
      );
    }
  };

  private readonly onKeyboardHeightChange = (height: number): void => {
    if (this.acceptingLifecycle && this.observedMainWindow !== undefined) {
      this.forEachLifecycle((lifecycle) =>
        lifecycle.keyboardEventCallback.onKeyboardHeightChange(height),
      );
    }
  };

  protected resolveModuleNames(): string[] {
    const moduleNames = NativeModuleLoader.resolveModuleNames(this.moduleName);
    if (moduleNames.length === 0) {
      throw new Error("moduleName must contain at least one module");
    }
    return moduleNames;
  }

  protected forEachLifecycle(handler: (lifecycle: ApplicationLifecycle) => void): void {
    for (const runtime of this.moduleRuntimes) {
      try {
        handler(runtime.lifecycle);
      } catch {}
    }
  }

  /**
   * Adds framework or subclass work to the one Ability-scoped lifecycle queue. OpenHarmony does
   * not await onCreate/onWindowStageCreate/onWindowStageDestroy, so those callbacks only capture
   * their arguments synchronously; this queue is the actual ordering barrier.
   */
  protected enqueueLifecycleOperation(
    label: string,
    operation: () => Promise<void>,
  ): Promise<void> {
    void this.lifecycleQueue.enqueue(label, operation);
    return this.lifecycleQueue.settled();
  }

  protected parseSavedStateMap(rawState: string): Record<string, string> {
    return AbilityStateCodec.decode(rawState);
  }

  protected serializeSavedStateMap(stateMap: Record<string, string>): string {
    return AbilityStateCodec.encode(stateMap);
  }

  protected createInitContext(moduleName: string): AbilityInitContext {
    const context = this.context as common.UIAbilityContext;
    return {
      basePath: context?.filesDir ?? "",
      prefPath: context?.filesDir ?? "",
      preferredLocales: context?.config?.language ?? "",
      moduleName,
      resourceManager: context?.resourceManager,
    };
  }

  /**
   * Loads application content inside the framework's WindowStage lifecycle transaction. Override
   * this instead of starting detached Promise work from the platform callback.
   */
  protected async loadWindowStageContent(windowStage: window.WindowStage): Promise<void> {
    if (this.defaultPage) {
      try {
        await windowStage.loadContentByName(Entry.RouteName);
      } catch (error) {
        throw new Error(`Unable to load default WindowStage content: ${String(error)}`);
      }
    }
  }

  private updateAppStorage<T>(key: string, value: T): void {
    AppStorage.setOrCreate(key, value);
    AppStorage.set(key, value);
  }

  /**
   * Wires both scoped ArkTS -> Rust ports immediately after module.init. The lifecycle sink lets
   * BridgeHost serialize UI readiness with ArkTS plugin installation instead of relying on
   * Promise microtask timing in DefaultXComponent.
   */
  private attachBridgeSinks(sessionId: string, moduleName: string, module: Module): void {
    const mainThreadSink =
      typeof module.onBridgeSyncEvent === "function"
        ? (
            pluginId: string,
            event: string,
            requestTypeName: string,
            responseTypeName: string,
            value: ESObject,
          ): ESObject =>
            module.onBridgeSyncEvent!(pluginId, event, requestTypeName, responseTypeName, value)
        : undefined;
    const lifecycleSink =
      typeof module.onBridgeLifecycle === "function"
        ? (kind: string): void => module.onBridgeLifecycle!(kind)
        : undefined;
    BridgeHostRegistry.attachEventSink(sessionId, moduleName, mainThreadSink, lifecycleSink);
  }

  protected async notifyBridgeLifecycle(event: BridgeLifecycleEvent): Promise<void> {
    const sessionId = this.bridgeSessionId;
    if (!sessionId) {
      return;
    }
    const deliveries: Promise<void>[] = [];
    for (const runtime of this.moduleRuntimes) {
      deliveries.push(this.notifyModuleBridgeLifecycle(sessionId, runtime.moduleName, event));
    }
    await Promise.all(deliveries);
  }

  private async notifyModuleBridgeLifecycle(
    sessionId: string,
    moduleName: string,
    event: BridgeLifecycleEvent,
  ): Promise<void> {
    try {
      await BridgeHostRegistry.emitLifecycle(sessionId, moduleName, event);
    } catch (error) {
      console.error(
        `[NativeAbility] bridge lifecycle '${event.kind}' failed for ${moduleName}: ${String(error)}`,
      );
    }
  }

  private async initializeSession(
    requestedModules: string[],
    restoredStateMap: Record<string, string>,
    fallbackState: string,
    generation: number,
  ): Promise<void> {
    const previousSessionId = this.bridgeSessionId;
    if (previousSessionId) {
      BridgeHostRegistry.beginClosing(previousSessionId);
      await BridgeHostRegistry.dispose(previousSessionId);
    }
    this.assertInitializationActive(generation);
    this.bridgeSessionId = "";
    this.moduleRuntimes = [];
    this.windowStageActive = false;
    this.updateAppStorage("bridgeSessionId", "");

    // Prepare hosts without activating `ability` plugins. Their onInstall hooks are allowed to
    // call Rust synchronously, so module.init and both sinks must exist first.
    const sessionId = BridgeHostRegistry.prepare(
      requestedModules,
      this.context as common.UIAbilityContext,
      this.bridgePlugins,
    );
    this.bridgeSessionId = sessionId;
    this.updateAppStorage("bridgeSessionId", sessionId);

    const loadedModules: LoadedNativeModule[] = [];
    const initializedRuntimes: NativeModuleRuntime[] = [];
    try {
      // Loading is transactional. Parallel arrays and partial "continue after error" states made
      // a module name point at the wrong lifecycle object after one dynamic import failed.
      for (const moduleName of requestedModules) {
        const module = await NativeModuleLoader.load(moduleName, this.loadMode);
        this.assertInitializationActive(generation);
        loadedModules.push({ moduleName, module });
      }

      for (const loaded of loadedModules) {
        const lifecycle = loaded.module.init(this.createInitContext(loaded.moduleName));
        const runtime: NativeModuleRuntime = {
          moduleName: loaded.moduleName,
          module: loaded.module,
          lifecycle,
        };
        initializedRuntimes.push(runtime);
        this.attachBridgeSinks(sessionId, loaded.moduleName, loaded.module);

        const restoredState = restoredStateMap[loaded.moduleName] ?? fallbackState;
        try {
          lifecycle.windowStageEventCallback.onAbilityCreate(restoredState);
        } catch (error) {
          console.error(
            `[NativeAbility] Rust ability-create failed for ${loaded.moduleName}: ${String(error)}`,
          );
        }
      }

      this.moduleRuntimes = initializedRuntimes;
      const abilityActivations: Promise<void>[] = [];
      for (const runtime of initializedRuntimes) {
        abilityActivations.push(
          BridgeHostRegistry.activateAbility(sessionId, runtime.moduleName, {
            kind: "ability-create",
            payload: new BridgeAbilityCreateLifecyclePayload(
              restoredStateMap[runtime.moduleName] ?? fallbackState,
            ),
          }),
        );
      }
      await Promise.all(abilityActivations);
      this.assertInitializationActive(generation);
    } catch (error) {
      for (const runtime of initializedRuntimes.slice().reverse()) {
        try {
          runtime.lifecycle.windowStageEventCallback.onAbilityDestroy();
        } catch {}
      }
      BridgeHostRegistry.beginClosing(sessionId);
      await BridgeHostRegistry.dispose(sessionId);
      if (this.bridgeSessionId === sessionId) {
        this.bridgeSessionId = "";
        this.moduleRuntimes = [];
        this.updateAppStorage("bridgeSessionId", "");
      }
      throw new Error(`Unable to initialize native Ability session: ${String(error)}`);
    }
  }

  private assertInitializationActive(generation: number): void {
    if (!this.acceptingLifecycle || generation !== this.abilityGeneration) {
      throw new Error("Native Ability session initialization was cancelled by lifecycle teardown");
    }
  }

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    const isRestore: boolean =
      (want.parameters?.["ohos.ability.params.abilityRecoveryRestart"] as boolean) ?? false;
    const savedState = want.parameters?.[STATE_KEY];
    const state = isRestore && savedState !== undefined ? savedState.toString() : "";
    const requestedModules = this.resolveModuleNames();
    // A single module owns its state string verbatim, even if business data happens to begin with
    // the framework's multi-module prefix. Only multi-module sessions interpret the state map.
    let restoredStateMap: Record<string, string> = {};
    if (requestedModules.length > 1) {
      restoredStateMap = this.parseSavedStateMap(state);
    }

    this.acceptingLifecycle = true;
    const generation = ++this.abilityGeneration;
    this.updateAppStorage("moduleName", this.moduleName);
    this.updateAppStorage("loadMode", this.loadMode);
    void this.enqueueLifecycleOperation("ability-create", async (): Promise<void> => {
      await this.initializeSession(requestedModules, restoredStateMap, state, generation);
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    if (!this.acceptingLifecycle) {
      return;
    }
    const generation = ++this.windowStageGeneration;
    void this.enqueueLifecycleOperation("window-stage-create", async (): Promise<void> => {
      this.assertWindowStageActive(generation);
      const sessionId = this.bridgeSessionId;
      if (!sessionId) {
        throw new Error("Bridge session is unavailable during window-stage-create");
      }

      // First inject the ArkTS WindowStage object. Rust readiness is then advanced before ArkTS
      // plugin installation/lifecycle delivery can emit a synchronous event back into Rust.
      const stageAssignments: Promise<void>[] = [];
      for (const runtime of this.moduleRuntimes) {
        stageAssignments.push(
          BridgeHostRegistry.setWindowStage(sessionId, runtime.moduleName, windowStage),
        );
      }
      await Promise.all(stageAssignments);
      this.assertWindowStageActive(generation);
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onWindowStageCreate(),
      );
      this.windowStageActive = true;
      await this.notifyBridgeLifecycle({
        kind: "window-stage-create",
        payload: new BridgeEmptyLifecyclePayload(),
      });
      this.assertWindowStageActive(generation);

      try {
        this.observedWindowStage = windowStage;
        windowStage.on("windowStageEvent", this.onWindowStageEvent);
      } catch {}

      let win: window.Window | null = null;
      try {
        win = await windowStage.getMainWindow();
      } catch {
        win = null;
      }
      this.assertWindowStageActive(generation);

      if (win) {
        try {
          this.observedMainWindow = win;
          win.on("windowSizeChange", this.onWindowSizeChange);
          win.on("windowRectChange", this.onWindowRectChange);
          win.on("avoidAreaChange", this.onAvoidAreaChange);
          win.on("keyboardHeightChange", this.onKeyboardHeightChange);
        } catch {}
      }

      await this.loadWindowStageContent(windowStage);
      this.assertWindowStageActive(generation);
    });
  }

  private assertWindowStageActive(generation: number): void {
    if (!this.acceptingLifecycle || generation !== this.windowStageGeneration) {
      throw new Error("WindowStage creation was cancelled by lifecycle teardown");
    }
  }

  onWindowStageDestroy(): void {
    if (!this.acceptingLifecycle) {
      return;
    }
    this.windowStageGeneration += 1;
    this.detachWindowListeners();
    const sessionId = this.bridgeSessionId;
    if (sessionId) {
      for (const runtime of this.moduleRuntimes) {
        BridgeHostRegistry.invalidateWindowStage(sessionId, runtime.moduleName);
      }
    }
    void this.enqueueLifecycleOperation("window-stage-destroy", async (): Promise<void> => {
      await this.destroyWindowStageIfActive();
    });
  }

  private async destroyWindowStageIfActive(): Promise<void> {
    if (!this.windowStageActive) {
      return;
    }
    this.windowStageActive = false;
    this.detachWindowListeners();
    const sessionId = this.bridgeSessionId;
    if (sessionId) {
      const stageClears: Promise<void>[] = [];
      for (const runtime of this.moduleRuntimes) {
        stageClears.push(BridgeHostRegistry.clearWindowStage(sessionId, runtime.moduleName));
      }
      await Promise.all(stageClears);
    }
    for (const runtime of this.moduleRuntimes) {
      try {
        runtime.module.disposeAllRenders?.();
      } catch {}
    }
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageDestroy());
  }

  private detachWindowListeners(): void {
    const windowStage = this.observedWindowStage;
    this.observedWindowStage = undefined;
    if (windowStage !== undefined) {
      try {
        windowStage.off("windowStageEvent", this.onWindowStageEvent);
      } catch {}
    }

    const win = this.observedMainWindow;
    this.observedMainWindow = undefined;
    if (win !== undefined) {
      try {
        win.off("windowSizeChange", this.onWindowSizeChange);
      } catch {}
      try {
        win.off("windowRectChange", this.onWindowRectChange);
      } catch {}
      try {
        win.off("avoidAreaChange", this.onAvoidAreaChange);
      } catch {}
      try {
        win.off("keyboardHeightChange", this.onKeyboardHeightChange);
      } catch {}
    }
  }

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    if (!this.acceptingLifecycle) {
      return;
    }
    void this.enqueueLifecycleOperation("memory-level", async (): Promise<void> => {
      this.forEachLifecycle((lifecycle) => lifecycle.environmentCallback.onMemoryLevel(level));
      await this.notifyBridgeLifecycle({
        kind: "memory-level",
        payload: new BridgeMemoryLevelLifecyclePayload(level),
      });
    });
  }

  onDestroy(): Promise<void> {
    this.acceptingLifecycle = false;
    this.abilityGeneration += 1;
    this.windowStageGeneration += 1;
    this.detachWindowListeners();
    if (this.bridgeSessionId) {
      // Reject new calls and cancel an active plugin hook immediately; the queued teardown below
      // still preserves lifecycle ordering for state mutation and platform callbacks.
      BridgeHostRegistry.beginClosing(this.bridgeSessionId);
    }
    return this.enqueueLifecycleOperation("ability-destroy", async (): Promise<void> => {
      const sessionId = this.bridgeSessionId;
      if (!sessionId) {
        return;
      }
      BridgeHostRegistry.beginClosing(sessionId);
      try {
        await this.destroyWindowStageIfActive();
        await this.notifyBridgeLifecycle({
          kind: "ability-destroy",
          payload: new BridgeEmptyLifecyclePayload(),
        });
        this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onAbilityDestroy());
      } finally {
        this.bridgeSessionId = "";
        this.moduleRuntimes = [];
        this.windowStageActive = false;
        this.updateAppStorage("bridgeSessionId", "");
        await BridgeHostRegistry.dispose(sessionId);
      }
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    if (!this.acceptingLifecycle) {
      return;
    }
    void this.enqueueLifecycleOperation("configuration-updated", async (): Promise<void> => {
      this.forEachLifecycle((lifecycle) =>
        lifecycle.environmentCallback.onConfigurationUpdated(newConfig),
      );
      await this.notifyBridgeLifecycle({
        kind: "configuration-updated",
        payload: new BridgeEmptyLifecyclePayload(),
      });
    });
  }

  onSaveState(
    reason: AbilityConstant.StateType,
    wantParam: Record<string, object>,
  ): AbilityConstant.OnSaveResult {
    const stateMap: Record<string, string> = {};

    for (const runtime of this.moduleRuntimes) {
      try {
        stateMap[runtime.moduleName] =
          runtime.lifecycle.windowStageEventCallback.onAbilitySaveState() ?? "";
      } catch {}
    }

    const stateValues = Object.values(stateMap);
    let stateToSave: string = "";
    if (stateValues.length === 1) {
      stateToSave = stateValues[0];
    } else if (stateValues.length > 1) {
      stateToSave = this.serializeSavedStateMap(stateMap);
    }
    wantParam[STATE_KEY] = new String(stateToSave);

    return AbilityConstant.OnSaveResult.RECOVERY_AGREE;
  }
}
