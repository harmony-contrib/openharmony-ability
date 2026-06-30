import { AbilityConstant, Configuration, UIAbility, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import webview from "@ohos.web.webview";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { RouteName } from "../components/MainPage";
import { setMenuClickHandler, setMenuBarRecoverFn, getMenuDataCallback } from "../components/MenuBarComponent";
import { AbilityInitContext, ApplicationLifecycle, Module } from "./type";
import { Loadable } from "../helper/loadable";
import { MenuManager, PredefinedActionExecutor, setPredefinedActionExecutor } from "../helper/menu";
import { AboutMetadataData } from "../helper/menu_types";
import { setCurrentAbilityName } from "../helper/StatusBarUtils";
import { WindowManager } from "../window/WindowManager";
import { DOMAIN } from '../helper/constants';
import { setPrimaryWebviewControllerCallback } from "../components/DefaultXComponent";

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
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'Lifecycle callback error: %{public}s', String(e));
      }
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
    } catch (e) {
      hilog.warn(DOMAIN, 'NativeAbility', 'State map parse failed: %{public}s', String(e));
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
      sdkApiVersion: deviceInfo.sdkApiVersion,
      distributionOSApiVersion: deviceInfo.distributionOSApiVersion,
    };
  }

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    setCurrentAbilityName(want.abilityName ?? "");

    const isRestore: boolean =
      (want.parameters?.["ohos.ability.params.abilityRecoveryRestart"] as boolean) ?? false;
    const state = isRestore ? ((want.parameters?.[STATE_KEY] as string) ?? "") : "";

    hilog.info(DOMAIN, 'NativeAbility', 'onCreate - moduleName: %{public}s', JSON.stringify(this.moduleName));
    AppStorage.setOrCreate("moduleName", this.moduleName);
    AppStorage.setOrCreate("loadMode", this.loadMode);

    // Initialize WindowManager for multi-window support
    const context = this.context as common.UIAbilityContext;
    WindowManager.init(context);

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
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'onAbilityCreate failed: %{public}s', String(e));
      }
    }
  }

  private setupMenuPopup(windowStage: window.WindowStage): void {
    const primaryModule: ESObject = this.nativeModules[0] as ESObject;
    if (!primaryModule || typeof primaryModule.onMenuRequest !== 'function') {
      return;
    }

    AppStorage.setOrCreate("__openharmony_ability_is_desktop__", primaryModule.isDesktopDevice());

    const emitMenuEventFn: (menuId: string, windowId?: string) => void = primaryModule.emitMenuEvent as (menuId: string, windowId?: string) => void;

    const executor = new PredefinedActionExecutor((code: number) => {
      this.context?.terminateSelf();
    });
    const mainWindow = windowStage.getMainWindowSync();
    executor.setWindow(mainWindow);
    executor.setContext(this.context as common.UIAbilityContext);
    setPredefinedActionExecutor(executor);
    executor.setShowAboutFn((metadata: AboutMetadataData) => {
      const appName = metadata.name ?? '';
      const appVersion = metadata.version ?? '';
      const appCopyright = metadata.copyright ?? '';
      const appAuthors = metadata.authors?.join(', ') ?? '';
      const appComments = metadata.comments ?? '';
      const appWebsite = metadata.website ?? '';

      const lines: string[] = [];
      if (appName) lines.push(appName);
      if (appVersion) lines.push(`Version: ${appVersion}`);
      if (appCopyright) lines.push(appCopyright);
      if (appAuthors) lines.push(`Authors: ${appAuthors}`);
      if (appComments) lines.push(appComments);
      if (appWebsite) lines.push(appWebsite);
      const message = lines.join('\n');
      const title = appName || 'About';

      try {
        const uiContext = mainWindow.getUIContext();
        uiContext.showAlertDialog({
          title: title,
          message: message,
          autoCancel: true,
          confirm: {
            value: 'OK',
            action: () => {},
          },
        });
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'Show about dialog failed: %{public}s', String(e));
      }
    });

    const menuManager = new MenuManager(executor, emitMenuEventFn);

    // Wire up per-window menu click handler (MW-1): routes through MenuManager for predefined/custom actions
    setMenuClickHandler(0, (item) => {
      menuManager.handleItemClick(item);
    });

    // Wire up per-window recover function (MW-1)
    setMenuBarRecoverFn(0, () => {
      mainWindow.recover();
    });

    setPrimaryWebviewControllerCallback((controller: webview.WebviewController) => {
      executor.setController(controller);
    });

    // Route menu requests via callback (MW-5) instead of AppStorage
    primaryModule.onMenuRequest((data: { jsonData: string; x?: number; y?: number; visible?: boolean; windowId?: string }) => {
      const windowId = data.windowId ?? "main";

      // Handle menubar visibility changes via callback
      if (data.visible !== undefined && data.visible !== null) {
        const cb = getMenuDataCallback(windowId);
        cb?.onMenubarVisible?.(data.visible);
        primaryModule.notifyMenubarVisibility(windowId, data.visible);
        return;
      }

      // Handle popup menu requests via callback
      if (data.x !== undefined && data.y !== undefined) {
        try {
          menuManager.popupFromJson(data.jsonData, data.x ?? 0, data.y ?? 0, windowId);
        } catch (e) {
          console.error(`[Menu] Popup failed: ${e}`);
        }
        return;
      }

      // Handle menubar JSON updates via callback
      const cb = getMenuDataCallback(windowId);
      cb?.onMenubarJson?.(data.jsonData);
    });
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageCreate());

    // Pass windowStage to WindowManager for createSubWindow support
    WindowManager.getInstance().setWindowStage(windowStage);

    try {
      windowStage.on("windowStageEvent", (event: window.WindowStageEventType) => {
        this.forEachLifecycle((lifecycle) =>
          lifecycle.windowStageEventCallback.onWindowStageEvent(event),
        );
      });
    } catch (e) {
      hilog.error(DOMAIN, 'NativeAbility', 'windowStage.on failed: %{public}s', String(e));
    }

    let win: window.Window | null = null;
    try {
      win = await windowStage.getMainWindow();
    } catch (e) {
      hilog.error(DOMAIN, 'NativeAbility', 'getMainWindow failed: %{public}s', String(e));
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
          if (options.reason === window.RectChangeReason.RECOVER) {
            const cb = getMenuDataCallback("main");
            cb?.onMenubarVisible?.(true);
          }
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
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'Window event registration failed: %{public}s', String(e));
      }
    }

    if (this.defaultPage) {
      try {
        await windowStage.loadContentByName(RouteName);
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'loadContentByName failed: %{public}s', String(e));
      }
    }

    try {
      this.setupMenuPopup(windowStage);
    } catch (menuErr) {
      console.error(`[Menu] setupMenuPopup threw: ${menuErr}`);
    }
  }

  onWindowStageDestroy(): void | Promise<void> {
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageDestroy());
    try {
      WindowManager.getInstance().removeWindow(0);
    } catch (e) {
      hilog.error(DOMAIN, 'NativeAbility', 'onWindowStageDestroy cleanup failed: %{public}s', String(e));
    }
  }

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    this.forEachLifecycle((lifecycle) => lifecycle.environmentCallback.onMemoryLevel(level));
  }

  onDestroy(): void | Promise<void> {
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onAbilityDestroy());
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const uri = want.uri ?? '';
    const parametersJson = JSON.stringify(want.parameters ?? {});
    hilog.info(DOMAIN, 'NativeAbility', 'onNewWant - uri: %{public}s, parametersJson.length: %{public}d', uri, parametersJson.length);

    // Cancel cleanup timer when system triggers onNewWant
    // This indicates the system's foreground transition has started,
    // so we don't need the safety net timer anymore.
    try {
      const wm = WindowManager.getInstance();
      if (wm.hasPendingAction()) {
        hilog.info(DOMAIN, 'NativeAbility', 'onNewWant detected pending action, cancelling cleanup timer');
        wm.cancelCleanupTimer();
      }
    } catch (e) {
      // WindowManager might not be initialized yet, ignore
    }

    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onNewWant({ uri, parametersJson }));
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
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'onAbilitySaveState failed: %{public}s', String(e));
      }
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
