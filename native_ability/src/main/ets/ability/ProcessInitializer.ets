import { AbilityConstant, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import webview from "@ohos.web.webview";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Module, AbilityInitContext, ApplicationLifecycle, WindowConfig } from "./type";
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
  /**
   * Process-level store of each module's init-returned lifecycle callback bundle
   * (design.md D12 join model). The creator instance stores them right after
   * module.init; a joined instance — whose own moduleRuntimes stays empty because
   * module.init is never re-run — reads them via getLifecycles() so
   * NativeAbility.forEachLifecycle can still fire the shared lifecycle callbacks
   * with the joined instance's windowId (NAPI callbacks are process-level fns;
   * each call carries its own windowId, so sharing the bundle is safe).
   */
  private static lifecycleByModule: Map<string, ApplicationLifecycle> = new Map();

  static isInitialized(): boolean {
    return this.initialized;
  }

  static getNativeModules(): Module[] {
    return this.nativeModules;
  }

  static getLoadedModuleNames(): string[] {
    return this.loadedModuleNames;
  }

  /** Stores one module's lifecycle bundle (creator side of the D12 join model). */
  static rememberLifecycle(moduleName: string, lifecycle: ApplicationLifecycle): void {
    this.lifecycleByModule.set(moduleName, lifecycle);
  }

  /**
   * Shared lifecycle bundles, read by a joined UIAbility instance whose own
   * moduleRuntimes is empty (D12). Returns the process-level Map; callers must
   * not mutate it.
   */
  static getLifecycles(): Map<string, ApplicationLifecycle> {
    return this.lifecycleByModule;
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
        // Float creation-race fix (doc/OHOS窗口遗留问题.md issue-7 addendum).
        // Capability handshake (review V1) — arm the Rust-side pending registry
        // BEFORE any create_os_window can run. A stale HAR lacks these members
        // entirely, so the Rust side never gates Float ops and behavior stays
        // exactly the pre-fix fire-and-forget semantics; a fresh HAR on an old
        // .so is covered by the typeof probes in notifySettled below.
        if (typeof module.enableFloatPendingTracking === "function") {
          module.enableFloatPendingTracking();
        }
        const notifySettled = (windowId: number, registered: boolean): void => {
          if (typeof module.notifyFloatWindowRegistered === "function") {
            module.notifyFloatWindowRegistered(windowId, registered);
          }
        };
        module.registerCreateSubWindowTsfn(
          (config: ESObject): Promise<number> => {
            const windowId: number = (config as WindowConfig).windowId;
            return wm.createSubWindow(config)
              .then((id: number): number => {
                // Settle signal: the creation chain finished (window registered
                // in WindowManager.windows, FloatPage UI loaded). Rust drains
                // the ops queued against the pre-registration window. Attached
                // at promise END on purpose — an earlier notify would let
                // replayed ops race the chain's trailing
                // resize/moveWindowTo/showWindow (review V10).
                notifySettled(windowId, true);
                return id;
              })
              .catch((err: ESObject) => {
                // Failure settles identically: Rust drains the queue; the
                // replayed ops then fail loudly at the ArkTS registry
                // (today's "Unknown OS sub-window" warn) instead of being
                // held forever.
                notifySettled(windowId, false);
                throw err;
              });
          }
        );
        hilog.info(DOMAIN, 'ProcessInitializer', 'Registered createSubWindow TSFN');
        break;
      }
    }

    // UIAbility spawn pending-registry handshake (multi-uiability D7): arm the
    // Rust-side gate before any start_ui_ability can be dispatched. A stale HAR
    // lacks this member entirely, so the Rust side never opens pending entries
    // and spawned-window ops keep fire-and-forget dispatch (no queue wedge —
    // same degrade contract as enableFloatPendingTracking above).
    for (const module of this.nativeModules) {
      if (typeof module.enableUiAbilityPendingTracking === "function") {
        module.enableUiAbilityPendingTracking();
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
