import { AbilityConstant, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import webview from "@ohos.web.webview";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Module, AbilityInitContext } from "./type";
import { Loadable } from "../helper/loadable";
import { WindowManager } from "../window/WindowManager";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from '../helper/constants';

/**
 * ProcessInitializer — process-level initialization, executed only once.
 *
 * Extracts process-level initialization code from NativeAbility.onCreate that is
 * independent of any single UIAbility instance:
 * - WindowManager singleton initialization
 * - native module (.so dynamic library) loading
 * - custom scheme registration
 * - Web engine initialization
 *
 * Per-session bridge session creation (module.init → BridgeHostRegistry) now lives
 * in NativeAbility.onCreate, which owns the per-Ability lifecycle. This class only
 * loads the modules and probes for custom protocols; it no longer calls module.init.
 *
 * Subsequent UIAbility instances skip these initializations (initialized=true) to
 * avoid panicking from duplicate global-singleton initialization.
 * WebViews of subsequent instances are driven by the WebviewPlugin controller-attach path.
 */
export class ProcessInitializer {
  private static initialized: boolean = false;
  private static nativeModules: Module[] = [];
  private static loadedModuleNames: string[] = [];

  static isInitialized(): boolean {
    return this.initialized;
  }

  static getNativeModules(): Module[] {
    return this.nativeModules;
  }

  static getLoadedModuleNames(): string[] {
    return this.loadedModuleNames;
  }

  static createInitContext(context: common.UIAbilityContext, moduleName: string): AbilityInitContext {
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

  /**
   * Process-level initialization. The first instance runs the full flow; later
   * instances return immediately.
   */
  static async initialize(
    context: common.UIAbilityContext,
    moduleName: string | string[],
    loadMode: "async" | "sync",
    want: Want,
  ): Promise<void> {
    if (this.initialized) {
      hilog.info(DOMAIN, 'ProcessInitializer', 'Already initialized, skipping');
      return;
    }

    // 1. WindowManager singleton initialization
    WindowManager.init(context);

    // 2. Load native module (.so dynamic library, process-level)
    const requestedModules = Loadable.resolveModuleNames(moduleName);
    if (requestedModules.length === 0) {
      throw new Error("moduleName must contain at least one module");
    }

    let webEngineRequired = false;
    for (const name of requestedModules) {
      const module: Module = await Loadable.load(name, loadMode);
      this.nativeModules.push(module);
      this.loadedModuleNames.push(name);

      if (typeof module.registerCustomProtocol === "function") {
        module.registerCustomProtocol();
        webEngineRequired = true;
      }
    }

    // 3. Web engine initialization
    if (webEngineRequired) {
      webview.WebviewController.initializeWebEngine();
    }

    // 4. Register WindowManager.createSubWindow as TSFN for legacy create_os_window path.
    // The windowing backend's Window::new() calls create_os_window() synchronously, which needs a TSFN
    // (not the async bridge plugin path) to fire-and-forget sub-window creation on ArkTS.
    const wm = WindowManager.getInstance();
    for (const module of this.nativeModules) {
      if (typeof module.registerCreateSubWindowTsfn === "function") {
        module.registerCreateSubWindowTsfn(
          (config: ESObject): Promise<number> => wm.createSubWindow(config)
        );
        hilog.info(DOMAIN, 'ProcessInitializer', 'Registered createSubWindow TSFN');
        break;
      }
    }

    // module.init → bridge session creation is now performed by NativeAbility.onCreate,
    // which owns the per-Ability lifecycle and constructs BridgeHostRegistry sessions.

    // Publish the primary native module to AppStorage so ArkUI components (FloatPage ×
    // button / aboutToDisappear, menu.ets closeWindow, NativeAbility windowStatusChange)
    // can call NAPI fns (notifyWindowClose / notifyWindowStatus). Without this, every
    // AppStorage.get(NATIVE_MODULE_STORAGE_KEY) returns undefined → notifyWindowClose is
    // never invoked → ArkTS destroys the Float window but the Rust tauri manager keeps a
    // zombie entry → getByLabel returns a dead handle → same-label windows can't rebuild
    // (manual_tests §二十八 close lifecycle defect).
    if (this.nativeModules.length > 0) {
      AppStorage.setOrCreate<Module>(NATIVE_MODULE_STORAGE_KEY, this.nativeModules[0]);
    }

    this.initialized = true;
    hilog.info(DOMAIN, 'ProcessInitializer', 'Process initialization complete');
  }
}
