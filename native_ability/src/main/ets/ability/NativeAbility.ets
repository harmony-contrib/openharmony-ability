import { AbilityConstant, Configuration, UIAbility, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import * as Entry from "../components/MainPage";
import { BridgeHostRegistry } from "../bridge/BridgeHost";
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
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";

export const STATE_KEY = "ohos.rs.ability.application.state";

export class NativeAbility extends UIAbility {
  public moduleName: string | string[] = "";
  public defaultPage: boolean = true;
  public loadMode: "async" | "sync" = "async";
  /** Application-provided capability plugins. NativeAbility itself has no concrete plugin imports. */
  public bridgePlugins: BridgePluginFactory[] = [];
  private nativeModules: Module[] = [];
  private lifecycles: ApplicationLifecycle[] = [];
  private loadedModuleNames: string[] = [];
  private bridgeSessionId: string = "";

  protected resolveModuleNames(): string[] {
    const moduleNames = NativeModuleLoader.resolveModuleNames(this.moduleName);
    if (moduleNames.length === 0) {
      throw new Error("moduleName must contain at least one module");
    }
    return moduleNames;
  }

  protected forEachLifecycle(handler: (lifecycle: ApplicationLifecycle) => void): void {
    for (const lifecycle of this.lifecycles) {
      try {
        handler(lifecycle);
      } catch {}
    }
  }

  protected parseSavedStateMap(rawState: string): Record<string, string> {
    if (!rawState) {
      return {};
    }

    try {
      const parsed = JSON.parse(rawState) as Record<string, object>;
      const mapped: Record<string, string> = {};
      const keys = Object.keys(parsed);
      for (const key of keys) {
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

  /**
   * Wires the ArkTS -> Rust main-thread event sink for one native module. Called right after
   * `module.init` in onCreate so plugins that only require `ability` can emit inbound events on
   * `ability-create`; the render-time attach in DefaultXComponent overrides it with the same
   * module object (idempotent, NativeModuleLoader caches instances).
   */
  private attachBridgeEventSink(moduleName: string, module: Module): void {
    if (this.bridgeSessionId === undefined) {
      return;
    }
    if (typeof module.onBridgeSyncEvent !== "function") {
      return;
    }
    BridgeHostRegistry.attachEventSink(
      this.bridgeSessionId,
      moduleName,
      (
        pluginId: string,
        event: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject => {
        return module.onBridgeSyncEvent!(pluginId, event, requestTypeName, responseTypeName, value);
      },
    );
  }

  protected async notifyBridgeLifecycle(event: BridgeLifecycleEvent): Promise<void> {
    if (!this.bridgeSessionId) {
      return;
    }
    for (const moduleName of this.loadedModuleNames) {
      await BridgeHostRegistry.emitLifecycle(this.bridgeSessionId, moduleName, event);
    }
  }

  protected async setBridgeWindowStage(windowStage: window.WindowStage): Promise<void> {
    if (!this.bridgeSessionId) {
      return;
    }
    for (const moduleName of this.loadedModuleNames) {
      await BridgeHostRegistry.setWindowStage(this.bridgeSessionId, moduleName, windowStage);
    }
  }

  protected async clearBridgeWindowStage(): Promise<void> {
    if (!this.bridgeSessionId) {
      return;
    }
    for (const moduleName of this.loadedModuleNames) {
      await BridgeHostRegistry.clearWindowStage(this.bridgeSessionId, moduleName);
    }
  }

  async onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): Promise<void> {
    const isRestore: boolean =
      (want.parameters?.["ohos.ability.params.abilityRecoveryRestart"] as boolean) ?? false;
    const savedState = want.parameters?.[STATE_KEY];
    const state = isRestore && savedState !== undefined ? savedState.toString() : "";

    AppStorage.setOrCreate("moduleName", this.moduleName);
    AppStorage.setOrCreate("loadMode", this.loadMode);

    const requestedModules: string[] = this.resolveModuleNames();
    const restoredStateMap: Record<string, string> = this.parseSavedStateMap(state);
    if (this.bridgeSessionId) {
      await BridgeHostRegistry.dispose(this.bridgeSessionId);
    }
    try {
      this.bridgeSessionId = await BridgeHostRegistry.open(
        requestedModules,
        this.context as common.UIAbilityContext,
        this.bridgePlugins,
      );
    } catch (error) {
      // A plugin factory/install failure here aborts onCreate before module.init runs,
      // which later surfaces as "OpenHarmony app not initialized" from every napi call.
      console.error(`[NativeAbility] BridgeHostRegistry.open failed: ${String(error)}`);
    }
    AppStorage.setOrCreate("bridgeSessionId", this.bridgeSessionId);

    this.nativeModules = [];
    this.lifecycles = [];
    this.loadedModuleNames = [];

    for (const moduleName of requestedModules) {
      try {
        const module: Module = await NativeModuleLoader.load(moduleName, this.loadMode);
        this.nativeModules.push(module);
        this.loadedModuleNames.push(moduleName);
      } catch (error) {
        // A dynamic import failure aborts onCreate before module.init runs; the Rust-side
        // INNER_APP is then never set and every napi call reports "OpenHarmony app not
        // initialized". A stale/incompatible .so is the usual cause.
        console.error(
          `[NativeAbility] failed to load native module ${moduleName}: ${String(error)}`,
        );
      }
    }

    for (let i = 0; i < this.nativeModules.length; i++) {
      const module: Module = this.nativeModules[i];
      const moduleName: string = this.loadedModuleNames[i];
      try {
        const lifecycle: ApplicationLifecycle = module.init(this.createInitContext(moduleName));
        this.lifecycles.push(lifecycle);

        // Attach the inbound event sink right after init, not at UI render time: the native
        // module is loaded and the Rust app (plus its registered plugins) exists from here on.
        // Plugins that only require `ability` can therefore push ArkTS -> Rust main-thread
        // events on `ability-create` instead of waiting for `ui-context-ready`. The render-time
        // attach in DefaultXComponent remains as an idempotent fallback for the same module.
        this.attachBridgeEventSink(moduleName, module);

        const restoredState = restoredStateMap[moduleName] ?? state;
        try {
          lifecycle.windowStageEventCallback.onAbilityCreate(restoredState);
        } catch {}
      } catch (error) {
        // `#[ability] init` sets the Rust-side INNER_APP; when it fails, every later
        // napi call reports "OpenHarmony app not initialized". Log the exact failure
        // so the root cause (stale .so, context mismatch, bridge open failure) is visible.
        console.error(`[NativeAbility] module.init failed for ${moduleName}: ${String(error)}`);
      }
    }

    for (const moduleName of requestedModules) {
      await BridgeHostRegistry.emitLifecycle(this.bridgeSessionId, moduleName, {
        kind: "ability-create",
        payload: new BridgeAbilityCreateLifecyclePayload(restoredStateMap[moduleName] ?? state),
      });
    }
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    await this.setBridgeWindowStage(windowStage);
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageCreate());

    try {
      windowStage.on("windowStageEvent", (event: window.WindowStageEventType) => {
        this.forEachLifecycle((lifecycle) =>
          lifecycle.windowStageEventCallback.onWindowStageEvent(event),
        );
        this.notifyBridgeLifecycle({
          kind: "window-stage-event",
          payload: new BridgeWindowStageEventLifecyclePayload(event),
        }).catch(() => {});
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
      try {
        await windowStage.loadContentByName(Entry.RouteName);
      } catch {}
    }
  }

  async onWindowStageDestroy(): Promise<void> {
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageDestroy());
    await this.clearBridgeWindowStage();
  }

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    this.forEachLifecycle((lifecycle) => lifecycle.environmentCallback.onMemoryLevel(level));
    this.notifyBridgeLifecycle({
      kind: "memory-level",
      payload: new BridgeMemoryLevelLifecyclePayload(level),
    }).catch(() => {});
  }

  async onDestroy(): Promise<void> {
    await this.notifyBridgeLifecycle({
      kind: "ability-destroy",
      payload: new BridgeEmptyLifecyclePayload(),
    });
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onAbilityDestroy());
    const bridgeSessionId = this.bridgeSessionId;
    this.bridgeSessionId = "";
    await BridgeHostRegistry.dispose(bridgeSessionId);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.forEachLifecycle((lifecycle) =>
      lifecycle.environmentCallback.onConfigurationUpdated(newConfig),
    );
    this.notifyBridgeLifecycle({
      kind: "configuration-updated",
      payload: new BridgeEmptyLifecyclePayload(),
    }).catch(() => {});
  }

  onSaveState(
    reason: AbilityConstant.StateType,
    wantParam: Record<string, object>,
  ): AbilityConstant.OnSaveResult {
    const stateMap: Record<string, string> = {};

    for (let i = 0; i < this.lifecycles.length; i++) {
      const lifecycle = this.lifecycles[i];
      const moduleName = this.loadedModuleNames[i];
      if (!moduleName) {
        continue;
      }

      try {
        stateMap[moduleName] = lifecycle.windowStageEventCallback.onAbilitySaveState() ?? "";
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
