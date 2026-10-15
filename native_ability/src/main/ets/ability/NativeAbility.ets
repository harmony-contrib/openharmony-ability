import { AbilityConstant, Configuration, UIAbility, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import { hilog } from "@kit.PerformanceAnalysisKit";
import * as Entry from "../components/MainPage";
import { BridgeHostRegistry } from "../bridge/BridgeHost";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";
import { AbilityStateCodec } from "../runtime/AbilityStateCodec";
import { SerialTaskQueue } from "../runtime/SerialTaskQueue";
import {
  AbilityInitContext,
  ApplicationLifecycle,
  BridgeBindings,
  BridgeAbilityCreateLifecyclePayload,
  BridgeEmptyLifecyclePayload,
  BridgeLifecycleEvent,
  BridgeMemoryLevelLifecyclePayload,
  BridgePluginFactory,
  BridgeWindowStageEventLifecyclePayload,
  Module,
} from "./type";
import { getMenuBarPort } from "../components/MenuBarSlot";
import {
  WindowManager,
  WindowSizeEventWrap,
  WindowRectEventWrap,
  WindowFocusEventWrap,
  WindowAvoidAreaEventWrap,
} from "../window/WindowManager";
import { DOMAIN, MAIN_WINDOW_ID, NATIVE_MODULE_STORAGE_KEY } from "../helper/constants";
import { ProcessInitializer } from "./ProcessInitializer";

export const STATE_KEY = "ohos.rs.ability.application.state";

interface LoadedNativeModule {
  moduleName: string;
  module: Module;
}

interface NativeModuleRuntime extends LoadedNativeModule {
  lifecycle: ApplicationLifecycle;
  bridgeOwner: string;
}

export class NativeAbility extends UIAbility {
  public moduleName: string | string[] = "";
  public defaultPage: boolean = true;
  public loadMode: "async" | "sync" = "async";
  // Subclasses (EntryAbility) override this with the ArkTS BridgePlugin factories
  // matching the Rust-declared plugin ids. BridgeHostRegistry.prepare installs them
  // into every module host for this Ability session.
  public bridgePlugins: BridgePluginFactory[] = [];

  private moduleRuntimes: NativeModuleRuntime[] = [];
  private bridgeSessionId: string = "";
  private readonly lifecycleQueue = new SerialTaskQueue((label: string, error: Error): void => {
    hilog.error(
      DOMAIN,
      "NativeAbility",
      "lifecycle op '%{public}s' failed: %{public}s",
      label,
      String(error),
    );
  });
  private acceptingLifecycle: boolean = false;
  private abilityGeneration: number = 0;
  private windowStageGeneration: number = 0;
  private windowStageActive: boolean = false;
  private observedWindowStage?: window.WindowStage;

  // Kept as an arrow-function field so detachWindowListeners can pass the exact same
  // reference to windowStage.off("windowStageEvent", ...).
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
      } catch (e) {
        const error = e as Error;
        hilog.error(
          DOMAIN,
          "NativeAbility",
          "Lifecycle callback error: %{public}s",
          `${String(e)}\n${error.stack ?? ""}`,
        );
      }
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Current ability name, consumed by the statusbar plugin package's click
    // handlers (startAbility restore Want). AppStorage contract key — see
    // StatusBarUtils.ets (plugins/statusbar); core must not import the package.
    AppStorage.setOrCreate("__openharmony_ability_current_ability_name__", want.abilityName ?? "");
    // Populate AppStorage keys consumed by DeepLinkPlugin.ets (get-initial-uri /
    // get-latest-uri bridge actions, keys INITIAL_WANT_URI_KEY/LATEST_WANT_URI_KEY).
    // Contract documented in DeepLinkPlugin.ets. Was never written before.
    AppStorage.setOrCreate("initialWantUri", want.uri ?? "");
    AppStorage.setOrCreate("wantUri", want.uri ?? "");

    hilog.info(
      DOMAIN,
      "NativeAbility",
      "onCreate - moduleName: %{public}s",
      JSON.stringify(this.moduleName),
    );

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
      await this.initializeSession(
        requestedModules,
        restoredStateMap,
        state,
        generation,
        want,
        launchParam,
      );
    });
  }

  private async initializeSession(
    requestedModules: string[],
    restoredStateMap: Record<string, string>,
    fallbackState: string,
    generation: number,
    want: Want,
    launchParam: AbilityConstant.LaunchParam,
  ): Promise<void> {
    const context = this.context as common.UIAbilityContext;

    // Process-level initialization, once per process (adaptation line): WindowManager
    // singleton, custom-scheme probing + web-engine init, createSubWindow TSFN hookup
    // and the primary-module AppStorage publish consumed by FloatPage / the
    // windowStatusChange fan-in below. Idempotent for subsequent Ability instances;
    // module loading itself is re-done transactionally below via NativeModuleLoader.
    await ProcessInitializer.initialize(context, this.moduleName, this.loadMode, want);
    this.assertInitializationActive(generation);

    const previousSessionId = this.bridgeSessionId;
    if (previousSessionId) {
      BridgeHostRegistry.beginClosing(previousSessionId);
      try {
        await this.destroyWindowStageIfActive();
        await this.notifyBridgeLifecycle({
          kind: "ability-destroy",
          payload: new BridgeEmptyLifecyclePayload(),
        });
        this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onAbilityDestroy());
      } finally {
        // A duplicated platform create is not expected, but treating replacement as a complete
        // teardown prevents an old component root from surviving into the new bridge session.
        for (const runtime of this.moduleRuntimes) {
          try {
            runtime.module.disposeAllRenders();
          } catch {}
        }
        this.releaseModuleBridges(this.moduleRuntimes);
        await BridgeHostRegistry.dispose(previousSessionId);
      }
    }
    this.assertInitializationActive(generation);
    this.bridgeSessionId = "";
    this.moduleRuntimes = [];
    this.windowStageActive = false;
    this.updateAppStorage("bridgeSessionId", "");

    // Prepare hosts without activating `ability` plugins. Their onInstall hooks are allowed to
    // call Rust synchronously, so module.init and both sinks must exist first.
    const sessionId = BridgeHostRegistry.prepare(requestedModules, context, this.bridgePlugins);
    this.bridgeSessionId = sessionId;
    hilog.info(DOMAIN, "NativeAbility", "Bridge session created: %{public}s", sessionId);

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
        const bridgeOwner = `${sessionId}:${loaded.moduleName}`;
        const lifecycle = loaded.module.init(
          this.createBridgeBindings(sessionId, loaded.moduleName),
          bridgeOwner,
          this.createInitContext(loaded.moduleName),
        );
        const runtime: NativeModuleRuntime = {
          moduleName: loaded.moduleName,
          module: loaded.module,
          lifecycle,
          bridgeOwner,
        };
        initializedRuntimes.push(runtime);
        BridgeHostRegistry.configurePlugins(sessionId, loaded.moduleName, lifecycle.bridgePlugins);
        BridgeHostRegistry.attachApplicationLifecycle(sessionId, loaded.moduleName, lifecycle);
        this.attachBridgeSinks(sessionId, loaded.moduleName, loaded.module);
      }

      // Register every runtime BEFORE the ability-create NAPI dispatch below. The dispatch is
      // synchronous, but keeping the batch assignment in one place guarantees forEachLifecycle
      // below reaches all modules of this session (the single-runtime push per iteration of the
      // adaptation line had the same goal, with interleaving hazards the queue now removes).
      this.moduleRuntimes = initializedRuntimes;

      // Dispatch AbilityCreated into the Rust bridge registry. This NAPI callback is the ONLY
      // path that flips Rust `BridgePluginRegistryState.session_active` to true
      // (bridge/mod.rs dispatch_lifecycle → AbilityCreated). Without it, every main-thread
      // reverse event the ArkTS webview engine emits during `WebviewClient::create`
      // (seal-engine-schemes / before-engine-init / controller-attached) is rejected with
      // "outside an active Ability session". activateAbility only sets the ArkTS abilityReady
      // flag and delivers to ArkTS plugin.onLifecycle — it does NOT reach Rust
      // dispatch_lifecycle, so it cannot substitute for this call.
      // Ordering: strictly after the batch assignment above and strictly before the
      // activateAbility loop below.
      for (const runtime of initializedRuntimes) {
        const restoredState = restoredStateMap[runtime.moduleName] ?? fallbackState;
        try {
          runtime.lifecycle.windowStageEventCallback.onAbilityCreate(restoredState);
        } catch (e) {
          hilog.error(
            DOMAIN,
            "NativeAbility",
            "onAbilityCreate failed for %{public}s: %{public}s",
            runtime.moduleName,
            String(e),
          );
        }
        // Mirror onNewWant: feed the cold-start want.uri into the Rust-side
        // INITIAL_WANT_URI Mutex via the NAPI on_ability_create_with_want closure
        // (lifecycle.rs → store_initial_want_uri). Without this, deep-link
        // getCurrent() lazy-take returns null on cold start.
        // isContinuation/parametersJson additionally feed the Rust-side continuation
        // storage (app.rs CONTINUATION_RESTORE/CONTINUATION_DATA) for cross-device
        // app-continuation restore; launchReason is compared symbolically here (never
        // sent as a raw number across the bridge).
        try {
          const isContinuation =
            launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION;
          runtime.lifecycle.windowStageEventCallback.onAbilityCreateWithWant({
            uri: want.uri ?? "",
            isContinuation,
            parametersJson: JSON.stringify(want.parameters ?? {}),
          });
        } catch (e) {
          hilog.error(
            DOMAIN,
            "NativeAbility",
            "onAbilityCreateWithWant failed for %{public}s: %{public}s",
            runtime.moduleName,
            String(e),
          );
        }
      }

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
      // Publish only a fully initialized session. DefaultXComponent must never observe a host
      // whose native module has not attached its bridge endpoints and lifecycle sinks yet.
      this.updateAppStorage("bridgeSessionId", sessionId);
    } catch (error) {
      // Promise.all may reject while another module's install hook is still active. Close every
      // host first so no late hook can enter Rust while its bridge is being released below.
      BridgeHostRegistry.beginClosing(sessionId);
      for (const runtime of initializedRuntimes.slice().reverse()) {
        try {
          runtime.lifecycle.windowStageEventCallback.onAbilityDestroy();
        } catch {}
      }
      this.releaseModuleBridges(initializedRuntimes);
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

  private assertWindowStageActive(generation: number): void {
    if (!this.acceptingLifecycle || generation !== this.windowStageGeneration) {
      throw new Error("WindowStage creation was cancelled by lifecycle teardown");
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

  // Delegates to ProcessInitializer so the sdkApiVersion/distributionOSApiVersion fields
  // survive: the #[ability] derive feeds them into version::init and every API-level
  // gate on the Rust side. The base main-line context (basePath/prefPath/locales/
  // resourceManager) is built there too, so there is exactly one construction site.
  protected createInitContext(moduleName: string): AbilityInitContext {
    return ProcessInitializer.createInitContext(
      this.context as common.UIAbilityContext,
      moduleName,
    );
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

  /**
   * Creates the Ability-session transport for one native module. It deliberately lives here,
   * not in DefaultXComponent: ability-only plugins must work before a render surface appears and
   * must survive a component disappear/reappear cycle within the same Ability.
   */
  private createBridgeBindings(sessionId: string, moduleName: string): BridgeBindings {
    return {
      bridgeInvoke: async (
        pluginId: string,
        action: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
        timeoutMs: number,
      ): Promise<ESObject> => {
        return await BridgeHostRegistry.invokeAsync(
          sessionId,
          moduleName,
          pluginId,
          action,
          requestTypeName,
          responseTypeName,
          value,
          timeoutMs,
        );
      },
      bridgeInvokeSync: (
        pluginId: string,
        action: string,
        requestTypeName: string,
        responseTypeName: string,
        value: ESObject,
      ): ESObject => {
        return BridgeHostRegistry.invokeSync(
          sessionId,
          moduleName,
          pluginId,
          action,
          requestTypeName,
          responseTypeName,
          value,
        );
      },
      // MainThreadScheduler runs the Rust closure inside this TSFN callback before invoking this
      // no-op function. It intentionally carries no component or capability state.
      bridgeDispatch: (): void => {},
    };
  }

  private releaseModuleBridges(runtimes: NativeModuleRuntime[]): void {
    for (const runtime of runtimes.slice().reverse()) {
      try {
        runtime.module.disposeBridge(runtime.bridgeOwner);
      } catch (e) {
        hilog.warn(
          DOMAIN,
          "NativeAbility",
          "disposeBridge failed for %{public}s: %{public}s",
          runtime.moduleName,
          String(e),
        );
      }
    }
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
    } catch (e) {
      hilog.error(
        DOMAIN,
        "NativeAbility",
        "bridge lifecycle '%{public}s' failed for %{public}s: %{public}s",
        event.kind,
        moduleName,
        String(e),
      );
    }
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

      // ── OHOS platform wiring (adaptation line) ──
      // Everything in this block must run after the bridge window-stage assignment +
      // window-stage-create lifecycle above (plugins may resolve windows / emit reverse
      // events into Rust) and before the page content loads at the bottom of this queue
      // operation, so the WindowManager registry and the menubar are ready when the first
      // component attaches.
      WindowManager.getInstance().registerUIAbilityStage(0, windowStage, this.context, false);
      hilog.info(DOMAIN, "NativeAbility", "onWindowStageCreate: windowId=0 transparent=false");

      // WindowManager doesn't hold a lifecycle reference, so it exposes a single
      // rectChangeCallback that createSubWindow's per-window windowRectChange handler
      // invokes. Here we wire it to fan out to every lifecycle (same forEachLifecycle
      // pattern as the main-window registrations below). The wrapped options already
      // carry the windowId.
      WindowManager.getInstance().registerRectChangeCallback((wrapped: WindowRectEventWrap) => {
        this.forEachLifecycle((lifecycle) =>
          lifecycle.windowStageEventCallback.onWindowRectChange(wrapped),
        );
      });
      WindowManager.getInstance().registerFocusChangeCallback((wrapped: WindowFocusEventWrap) => {
        this.forEachLifecycle((lifecycle) =>
          lifecycle.windowStageEventCallback.onWindowFocusChange(wrapped),
        );
      });
      WindowManager.getInstance().registerAvoidAreaChangeCallback(
        (wrapped: WindowAvoidAreaEventWrap) => {
          this.forEachLifecycle((lifecycle) =>
            lifecycle.windowStageEventCallback.onAvoidAreaChange(wrapped),
          );
        },
      );

      try {
        this.observedWindowStage = windowStage;
        windowStage.on("windowStageEvent", this.onWindowStageEvent);
      } catch (e) {
        hilog.error(DOMAIN, "NativeAbility", "windowStage.on failed: %{public}s", String(e));
      }

      let win: window.Window | null = null;
      try {
        win = await windowStage.getMainWindow();
      } catch (e) {
        hilog.error(DOMAIN, "NativeAbility", "getMainWindow failed: %{public}s", String(e));
        win = null;
      }

      if (win) {
        try {
          win.on("windowSizeChange", (size: window.Size) => {
            // Phase 3 (design.md D2/D3): wrap with typed interface and route through
            // per-window(0) throttle (leading+trailing 16ms). windowId=0 = main window.
            // Double-registration dedup: BridgeHost also registers onSizeChange for the
            // same windowId=0 — the throttle merges both sources automatically.
            const wrapped: WindowSizeEventWrap = {
              windowId: 0,
              width: size.width,
              height: size.height,
            };
            WindowManager.getInstance().throttledRectDispatch(
              0,
              wrapped,
              (w: object) => {
                this.forEachLifecycle((lifecycle) =>
                  lifecycle.windowStageEventCallback.onWindowSizeChange(w),
                );
              },
              "size",
            );
          });
          win.on("windowRectChange", (options: window.RectChangeOptions) => {
            // Phase 3 (design.md D3): RECOVER→menubar logic stays synchronous (UI logic,
            // not throttled — must respond immediately on fullscreen exit). Delivery
            // goes through the menu plugin's registered port (MenuBarSlot seam):
            // core must not reach into the menu package's callback registry.
            if (options.reason === window.RectChangeReason.RECOVER) {
              getMenuBarPort()?.onMenubarVisibility(MAIN_WINDOW_ID, true);
            }
            // Phase 3 (design.md D2/D5): rect dispatch through per-window(0) throttle.
            // Deep-copy rect fields (not system object ref) per design.md D5.
            const wrapped: WindowRectEventWrap = {
              windowId: 0,
              reason: options.reason,
              rect: {
                left: options.rect.left,
                top: options.rect.top,
                width: options.rect.width,
                height: options.rect.height,
              },
            };
            WindowManager.getInstance().throttledRectDispatch(
              0,
              wrapped,
              (w: object) => {
                this.forEachLifecycle((lifecycle) =>
                  lifecycle.windowStageEventCallback.onWindowRectChange(w),
                );
              },
              "rect",
            );
          });
          win.on("avoidAreaChange", (options: window.AvoidAreaOptions) => {
            const wrapped: WindowAvoidAreaEventWrap = {
              windowId: 0,
              type: options.type,
              area: options.area,
            };
            this.forEachLifecycle((lifecycle) =>
              lifecycle.windowStageEventCallback.onAvoidAreaChange(wrapped),
            );
          });
          win.on("keyboardHeightChange", (height) => {
            this.forEachLifecycle((lifecycle) =>
              lifecycle.keyboardEventCallback.onKeyboardHeightChange(height),
            );
          });
          // 回灌系统窗口状态到 tao 镜像位(问题五 5.3):
          // 最大化/最小化/全屏/悬浮等系统状态变化经 notifyWindowStatus NAPI 入队,
          // runtime-wry drain 后用真实 windowId 路由到对应 tao Window 更新镜像位。
          // API 11+;不支持则静默降级(不比现状差)。详见 doc/OHOS窗口遗留问题.md。
          try {
            win.on("windowStatusChange", (statusType: window.WindowStatusType) => {
              const nativeModule: Module | undefined =
                AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
              if (nativeModule && typeof nativeModule.notifyWindowStatus === "function") {
                // 本地单 UIAbility 架构:主窗口恒为 tao windowId=0(upstream 的
                // readWindowId() 首实例也返回 0);runtime-wry 按 tao window_id 路由。
                nativeModule.notifyWindowStatus(0, statusType);
              }
            });
            // seed 初始态(官方 updateWindowInfo 模式),避免漏掉注册前状态。
            const initialStatus = win.getWindowStatus();
            const nativeModule: Module | undefined =
              AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
            if (nativeModule && typeof nativeModule.notifyWindowStatus === "function") {
              nativeModule.notifyWindowStatus(0, initialStatus);
            }
          } catch (e) {
            hilog.warn(
              DOMAIN,
              "NativeAbility",
              "windowStatusChange registration failed: %{public}s",
              String(e),
            );
          }
        } catch (e) {
          hilog.error(
            DOMAIN,
            "NativeAbility",
            "Window event registration failed: %{public}s",
            String(e),
          );
        }
      }

      // Transparent window background/container color is applied in
      // DefaultXComponent.aboutToAppear (window fully ready there). The transparent
      // flag is stored in WindowManager.registerUIAbilityStage and applied via
      // WindowManager.applyTransparentBackground(windowId) in aboutToAppear.
      try {
        this.setupDesktopFlag();
      } catch (menuErr) {
        hilog.error(DOMAIN, "NativeAbility", "setupDesktopFlag threw: %{public}s", String(menuErr));
      }

      await this.loadWindowStageContent(windowStage);
      this.assertWindowStageActive(generation);
    });
  }

  // App-continuation target-side restore entry. When the system launches the target
  // Ability for a continuation it calls onWindowStageRestore instead of
  // onWindowStageCreate (verified on MateBook Pro OpenHarmony 6.1.0: cold-start
  // continuation also goes through this callback). Tauri does not use ArkUI
  // page-stack auto-restore — the continuation payload is a custom JSON route
  // (source onContinue → continuationData, target onCreate → onAbilityCreateWithWant
  // stores it in Rust) — so this must do the same loadContentByName + bridge
  // windowStage wiring as onWindowStageCreate, or the window stays empty →
  // SetUIContent timeout → white screen (app icon only).
  // Cold-start continuation: windowStageActive=false (onCreate does not set it) →
  // full setup. Warm continuation: windowStageActive=true (onWindowStageCreate
  // already ran the setup) → skip to avoid a duplicate load.
  // The signature must match the base UIAbility.onWindowStageRestore:
  // (windowStage) => void (no want/launchParam, not async).
  onWindowStageRestore(windowStage: window.WindowStage): void {
    if (this.windowStageActive) {
      hilog.info(
        DOMAIN,
        "NativeAbility",
        "onWindowStageRestore: stage already active (warm continuation), skipping full setup",
      );
      return;
    }
    hilog.info(
      DOMAIN,
      "NativeAbility",
      "onWindowStageRestore: cold continuation, delegating to window-stage setup",
    );
    void this.onWindowStageCreate(windowStage);
  }

  onWindowStageDestroy(): void {
    if (!this.acceptingLifecycle) {
      return;
    }
    this.windowStageGeneration += 1;
    this.detachWindowListeners();
    try {
      WindowManager.getInstance().unregisterUIAbilityStage(0);
    } catch (e) {
      hilog.error(
        DOMAIN,
        "NativeAbility",
        "onWindowStageDestroy cleanup failed: %{public}s",
        String(e),
      );
    }
    const sessionId = this.bridgeSessionId;
    if (sessionId) {
      for (const runtime of this.moduleRuntimes) {
        try {
          BridgeHostRegistry.invalidateWindowStage(sessionId, runtime.moduleName);
        } catch (e) {
          hilog.warn(
            DOMAIN,
            "NativeAbility",
            "invalidateWindowStage failed for %{public}s: %{public}s",
            runtime.moduleName,
            String(e),
          );
        }
      }
    }
    // No explicit notifyBridgeLifecycle("window-stage-destroy") here: the queued
    // destroyWindowStageIfActive → BridgeHost.clearWindowStage already delivers the
    // window-stage-destroy lifecycle to every ArkTS plugin and runs
    // forEachLifecycle(onWindowStageDestroy) (→ Rust) below.
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
        runtime.module.disposeAllRenders();
      } catch {}
    }
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageDestroy());
  }

  private detachWindowListeners(): void {
    WindowManager.getInstance().unregisterFocusChangeCallback();
    WindowManager.getInstance().unregisterAvoidAreaChangeCallback();
    const windowStage = this.observedWindowStage;
    this.observedWindowStage = undefined;
    if (windowStage !== undefined) {
      try {
        windowStage.off("windowStageEvent", this.onWindowStageEvent);
      } catch {}
    }
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

  /**
   * Desktop form-factor probe only. The menu wiring that used to live here
   * (PredefinedActionExecutor, MenuManager, click/recover handlers, about
   * dialog, primary webview controller callback) moved to
   * MenuPlugin.onLifecycle("window-stage-create") in plugins/menu — the plugin
   * lifecycle fires earlier in the same queue operation, before the pages load.
   */
  private setupDesktopFlag(): void {
    const nativeModules = ProcessInitializer.getNativeModules();
    const primaryModule: Module | undefined = nativeModules[0];
    // Probe a live NAPI surface member as the "is this a real openharmony-ability
    // module" guard. This used to probe the onMenuRequest stub — dead code whose
    // registration body never executed (the Rust side discarded the callback);
    // the stub has been deleted (issue #87 major-4), so probe isDesktopDevice
    // instead, which is what FloatPage's __openharmony_ability_is_desktop__
    // AppStorage flag below is derived from.
    if (!primaryModule || typeof primaryModule.isDesktopDevice !== "function") {
      return;
    }

    AppStorage.setOrCreate("__openharmony_ability_is_desktop__", primaryModule.isDesktopDevice());
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
    // Dispatch onAbilityDestroy synchronously, before the async teardown queue.
    // The system kills the process ~12ms after onDestroy (Kill Reason:ClearSession),
    // so the queued version below — which sits behind two awaited bridge round-trips —
    // never completed before the kill, and the Rust exit chain
    // (on_ability_destroy → Event::Destroy → LoopDestroyed → RunEvent::ExitRequested/Exit)
    // never fired. This call is fully synchronous (no await / bridge recv) and completes
    // in microseconds; prevent_exit() is ineffective on this path by design
    // (tauri-runtime-wry discards it on LoopDestroyed).
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onAbilityDestroy());
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
        // No queue-internal onAbilityDestroy here: the synchronous dispatch above already
        // sent Event::Destroy to every module; a second dispatch would double-count the
        // Rust-side destroy path.
      } finally {
        const runtimes = this.moduleRuntimes;
        this.releaseModuleBridges(runtimes);
        this.bridgeSessionId = "";
        this.moduleRuntimes = [];
        this.windowStageActive = false;
        this.updateAppStorage("bridgeSessionId", "");
        await BridgeHostRegistry.dispose(sessionId);
      }
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const uri = want.uri ?? "";
    const parametersJson = JSON.stringify(want.parameters ?? {});
    hilog.info(
      DOMAIN,
      "NativeAbility",
      "onNewWant - uri: %{public}s, parametersJson.length: %{public}d",
      uri,
      parametersJson.length,
    );

    // Update the latest want.uri for deep-link get-latest-uri (warm-start
    // relaunch). initialWantUri is intentionally NOT updated — it stays the
    // cold-start value. (Previously onNewWant only forwarded to lifecycle
    // callbacks, never wrote AppStorage, so get_latest_uri was stale.)
    AppStorage.setOrCreate("wantUri", uri);

    // Cancel cleanup timer when system triggers onNewWant
    // This indicates the system's foreground transition has started,
    // so we don't need the safety net timer anymore.
    try {
      const wm = WindowManager.getInstance();
      if (wm.hasPendingAction()) {
        hilog.info(
          DOMAIN,
          "NativeAbility",
          "onNewWant detected pending action, cancelling cleanup timer",
        );
        wm.cancelCleanupTimer();
      }
    } catch (e) {
      // WindowManager might not be initialized yet, ignore
    }

    // isContinuation marks a warm-start app-continuation restore; consumed by the
    // Rust-side continuation storage (lifecycle.rs → store_continuation).
    const isContinuation = launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION;
    // acceptingLifecycle guard (main-line style): never dispatch lifecycle callbacks
    // outside an active session (e.g. after onDestroy has started teardown).
    if (this.acceptingLifecycle) {
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onNewWant({ uri, parametersJson, isContinuation }),
      );
    } else {
      hilog.warn(
        DOMAIN,
        "NativeAbility",
        "onNewWant skipped lifecycle dispatch: session no longer accepting lifecycle events",
      );
    }
  }

  // Source-side app-continuation save. The snapshot is PRE-REGISTERED by the JS
  // side (`setContinuationData` → Rust `CONTINUATION_SNAPSHOT`); this callback
  // only reads it synchronously via NAPI (`readContinueSnapshot`). onContinue is
  // a synchronous callback — never await a Promise or block here (the snapshot
  // pattern exists precisely so we don't have to). Empty snapshot → MISMATCH
  // (explicit opt-in: an app that never registered data refuses to migrate).
  // NOTE: EntryAbility subclasses must NOT override onContinue — that would
  // shadow this snapshot logic.
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    let snapshot: string = "";
    try {
      const nativeModules = ProcessInitializer.getNativeModules();
      const primaryModule: Module | undefined = nativeModules[0];
      if (primaryModule && typeof primaryModule.readContinueSnapshot === "function") {
        snapshot = primaryModule.readContinueSnapshot();
      }
    } catch (e) {
      hilog.error(
        DOMAIN,
        "NativeAbility",
        "onContinue - snapshot read failed: %{public}s",
        String(e),
      );
      return AbilityConstant.OnContinueResult.MISMATCH;
    }

    if (snapshot.length === 0) {
      hilog.info(DOMAIN, "NativeAbility", "onContinue - empty snapshot, refusing (MISMATCH)");
      return AbilityConstant.OnContinueResult.MISMATCH;
    }

    // Reserved key round-trip: the target side reads it from getContinuationData()
    // → JSON.parse(...).continuationData. Passed through verbatim — the payload
    // schema is an application-level contract.
    wantParam["continuationData"] = snapshot;
    hilog.info(
      DOMAIN,
      "NativeAbility",
      "onContinue - AGREE, snapshot length: %{public}d",
      snapshot.length,
    );
    return AbilityConstant.OnContinueResult.AGREE;
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
      } catch (e) {
        hilog.error(DOMAIN, "NativeAbility", "onAbilitySaveState failed: %{public}s", String(e));
      }
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

  private updateAppStorage<T>(key: string, value: T): void {
    AppStorage.setOrCreate(key, value);
    AppStorage.set(key, value);
  }
}
