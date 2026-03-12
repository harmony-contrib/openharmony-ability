import { AbilityConstant, Configuration, UIAbility, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import webview from "@ohos.web.webview";
import * as Entry from "../components/MainPage";
import { AbilityInitContext, ApplicationLifecycle, Module } from "./type";
import { Loadable } from "../helper/loadable";

export const STATE_KEY = "ohos.rs.ability.application.state";

export class NativeAbility extends UIAbility {
  public moduleName: string | string[] = "";
  public defaultPage: boolean = true;
  public mode: "xcomponent" | "webview" = "xcomponent";
  public loadMode: "async" | "sync" = "async";
  private nativeModules: Module[] = [];
  private lifecycles: ApplicationLifecycle[] = [];
  private loadedModuleNames: string[] = [];

  protected resolveModuleNames(): string[] {
    const moduleNames = Loadable.resolveModuleNames(this.moduleName);
    if (moduleNames.length === 0) {
      throw new Error("moduleName must contain at least one module");
    }
    return moduleNames;
  }

  protected forEachLifecycle(handler: (lifecycle: ApplicationLifecycle) => void): void {
    for (const lifecycle of this.lifecycles) {
      try {
        handler(lifecycle);
      } catch (_) {}
    }
  }

  protected parseSavedStateMap(rawState: string): Record<string, string> {
    if (!rawState) {
      return {};
    }

    try {
      const parsed = JSON.parse(rawState) as Record<string, Object>;
      const mapped: Record<string, string> = {};
      const keys = Object.keys(parsed);
      for (const key of keys) {
        const value = parsed[key];
        mapped[key] = typeof value === "string" ? value : String(value);
      }
      return mapped;
    } catch (_) {
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

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    const isRestore: boolean =
      (want.parameters?.["ohos.ability.params.abilityRecoveryRestart"] as boolean) ?? false;
    const state = isRestore ? ((want.parameters?.[STATE_KEY] as string) ?? "") : "";

    AppStorage.setOrCreate("moduleName", this.moduleName);
    AppStorage.setOrCreate("loadMode", this.loadMode);

    const requestedModules: string[] = this.resolveModuleNames();
    const restoredStateMap: Record<string, string> = this.parseSavedStateMap(state);
    let webEngineRequired = false;

    this.nativeModules = [];
    this.lifecycles = [];
    this.loadedModuleNames = [];

    for (const moduleName of requestedModules) {
      const module: Module = await Loadable.load(moduleName, this.loadMode);
      this.nativeModules.push(module);
      this.loadedModuleNames.push(moduleName);

      if (typeof module.registerCustomProtocol === "function") {
        module.registerCustomProtocol();
        webEngineRequired = true;
      }
    }

    if (webEngineRequired) {
      webview.WebviewController.initializeWebEngine();
    }

    for (let i = 0; i < this.nativeModules.length; i++) {
      const module: Module = this.nativeModules[i];
      const moduleName: string = this.loadedModuleNames[i];
      const lifecycle: ApplicationLifecycle = module.init(this.createInitContext(moduleName));

      this.lifecycles.push(lifecycle);

      const restoredState = restoredStateMap[moduleName] ?? state;
      try {
        lifecycle.windowStageEventCallback.onAbilityCreate(restoredState);
      } catch (_) {}
    }
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageCreate());

    try {
      windowStage.on("windowStageEvent", (event: window.WindowStageEventType) => {
        this.forEachLifecycle((lifecycle) =>
          lifecycle.windowStageEventCallback.onWindowStageEvent(event),
        );
      });
    } catch (_) {}

    let win: window.Window | null = null;
    try {
      win = await windowStage.getMainWindow();
    } catch (_) {
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
      } catch (_) {}
    }

    if (this.defaultPage) {
      try {
        await windowStage.loadContentByName(Entry.RouteName);
      } catch (_) {}
    }
  }

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    this.forEachLifecycle((lifecycle) => lifecycle.environmentCallback.onMemoryLevel(level));
  }

  onDestroy(): void | Promise<void> {
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onAbilityDestroy());
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.forEachLifecycle((lifecycle) =>
      lifecycle.environmentCallback.onConfigurationUpdated(newConfig),
    );
  }

  onSaveState(
    reason: AbilityConstant.StateType,
    wantParam: Record<string, Object>,
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
      } catch (_) {}
    }

    const stateValues = Object.values(stateMap);
    if (stateValues.length === 1) {
      wantParam[STATE_KEY] = stateValues[0];
    } else if (stateValues.length > 1) {
      wantParam[STATE_KEY] = JSON.stringify(stateMap);
    } else {
      wantParam[STATE_KEY] = "";
    }

    return AbilityConstant.OnSaveResult.RECOVERY_AGREE;
  }
}
