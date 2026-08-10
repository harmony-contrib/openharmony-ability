import { AbilityConstant, Configuration, UIAbility, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import * as Entry from "../components/MainPage";
import { BridgeHostRegistry } from "../bridge/BridgeHost";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";
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
  private windowStageActive: boolean = false;

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
    if (!rawState) {
      return {};
    }

    try {
      const parsed = JSON.parse(rawState) as Record<string, object>;
      const mapped: Record<string, string> = {};
      for (const key of Object.keys(parsed)) {
        const value = parsed[key];
        mapped[key] = typeof value === "string" ? value : String(value);
      }
      return mapped;
    } catch {
      return {};
    }
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
    for (const runtime of this.moduleRuntimes) {
      try {
        await BridgeHostRegistry.emitLifecycle(sessionId, runtime.moduleName, event);
      } catch (error) {
        console.error(
          `[NativeAbility] bridge lifecycle '${event.kind}' failed for ${runtime.moduleName}: ${String(error)}`,
        );
      }
    }
  }

  private async initializeSession(
    requestedModules: string[],
    restoredStateMap: Record<string, string>,
    fallbackState: string,
  ): Promise<void> {
    const previousSessionId = this.bridgeSessionId;
    if (previousSessionId) {
      BridgeHostRegistry.beginClosing(previousSessionId);
      await BridgeHostRegistry.dispose(previousSessionId);
    }
    this.bridgeSessionId = "";
    this.moduleRuntimes = [];
    this.windowStageActive = false;
    this.updateAppStorage("bridgeSessionId", "");

    const sessionId = await BridgeHostRegistry.open(
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
      for (const runtime of initializedRuntimes) {
        await BridgeHostRegistry.emitLifecycle(sessionId, runtime.moduleName, {
          kind: "ability-create",
          payload: new BridgeAbilityCreateLifecyclePayload(
            restoredStateMap[runtime.moduleName] ?? fallbackState,
          ),
        });
      }
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

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    const isRestore: boolean =
      (want.parameters?.["ohos.ability.params.abilityRecoveryRestart"] as boolean) ?? false;
    const savedState = want.parameters?.[STATE_KEY];
    const state = isRestore && savedState !== undefined ? savedState.toString() : "";
    const requestedModules = this.resolveModuleNames();
    const restoredStateMap = this.parseSavedStateMap(state);

    this.acceptingLifecycle = true;
    this.updateAppStorage("moduleName", this.moduleName);
    this.updateAppStorage("loadMode", this.loadMode);
    void this.enqueueLifecycleOperation("ability-create", async (): Promise<void> => {
      await this.initializeSession(requestedModules, restoredStateMap, state);
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    if (!this.acceptingLifecycle) {
      return;
    }
    void this.enqueueLifecycleOperation("window-stage-create", async (): Promise<void> => {
      const sessionId = this.bridgeSessionId;
      if (!sessionId) {
        throw new Error("Bridge session is unavailable during window-stage-create");
      }

      // First inject the ArkTS WindowStage object. Rust readiness is then advanced before ArkTS
      // plugin installation/lifecycle delivery can emit a synchronous event back into Rust.
      for (const runtime of this.moduleRuntimes) {
        await BridgeHostRegistry.setWindowStage(sessionId, runtime.moduleName, windowStage);
      }
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onWindowStageCreate(),
      );
      this.windowStageActive = true;
      await this.notifyBridgeLifecycle({
        kind: "window-stage-create",
        payload: new BridgeEmptyLifecyclePayload(),
      });

      try {
        windowStage.on("windowStageEvent", (event: window.WindowStageEventType) => {
          if (!this.acceptingLifecycle) {
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
        });
      } catch {}

      let win: window.Window | null = null;
      try {
        win = await windowStage.getMainWindow();
      } catch {
        win = null;
      }

      if (win) {
        try {
          win.on("windowSizeChange", (size: window.Size) => {
            this.forEachLifecycle((lifecycle) =>
              lifecycle.windowStageEventCallback.onWindowSizeChange(size),
            );
          });
          win.on("windowRectChange", (options: window.RectChangeOptions) => {
            this.forEachLifecycle((lifecycle) =>
              lifecycle.windowStageEventCallback.onWindowRectChange(options),
            );
          });
          win.on("avoidAreaChange", (options: window.AvoidAreaOptions) => {
            this.forEachLifecycle((lifecycle) =>
              lifecycle.windowStageEventCallback.onAvoidAreaChange(options),
            );
          });
          win.on("keyboardHeightChange", (height) => {
            this.forEachLifecycle((lifecycle) =>
              lifecycle.keyboardEventCallback.onKeyboardHeightChange(height),
            );
          });
        } catch {}
      }

      if (this.defaultPage) {
        await windowStage.loadContentByName(Entry.RouteName);
      }
    });
  }

  onWindowStageDestroy(): void {
    if (!this.acceptingLifecycle) {
      return;
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
    const sessionId = this.bridgeSessionId;
    if (sessionId) {
      for (const runtime of this.moduleRuntimes) {
        await BridgeHostRegistry.clearWindowStage(sessionId, runtime.moduleName);
      }
    }
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageDestroy());
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
      stateToSave = JSON.stringify(stateMap);
    }
    wantParam[STATE_KEY] = new String(stateToSave);

    return AbilityConstant.OnSaveResult.RECOVERY_AGREE;
  }
}
