import { AbilityConstant, Configuration, UIAbility, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import webview from "@ohos.web.webview";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import * as Entry from "../components/MainPage";
import { setMenuClickHandler, setMenuBarRecoverFn, getMenuDataCallback } from "../components/MenuBarComponent";
import { ApplicationLifecycle, Module, BridgeBindings, BridgePluginFactory, BridgeLifecycleEvent, BridgeAbilityCreateLifecyclePayload, BridgeEmptyLifecyclePayload, BridgeMemoryLevelLifecyclePayload, BridgeWindowStageEventLifecyclePayload, AbilityInitContext } from "./type";
import { MenuManager, PredefinedActionExecutor, setPredefinedActionExecutor } from "../helper/menu";
import { AboutMetadataData } from "../helper/menu_types";
import { setCurrentAbilityName } from "../helper/StatusBarUtils";
import { WindowManager, WindowSizeEventWrap, WindowRectEventWrap } from "../window/WindowManager";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from '../helper/constants';
import { setPrimaryWebviewControllerCallback } from "../components/DefaultXComponent";
import { ProcessInitializer } from "./ProcessInitializer";
import { BridgeHostRegistry } from "../bridge/BridgeHost";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";
import { AbilityStateCodec } from "../runtime/AbilityStateCodec";
import { SerialTaskQueue } from "../runtime/SerialTaskQueue";

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
  private acceptingLifecycle: boolean = false;
  private abilityGeneration: number = 0;
  private windowStageGeneration: number = 0;
  private bridgeSessionId: string = "";
  private moduleRuntimes: NativeModuleRuntime[] = [];
  private windowStageActive: boolean = false;
  private readonly lifecycleQueue = new SerialTaskQueue((label: string, error: Error): void => {
    hilog.error(DOMAIN, 'NativeAbility', "lifecycle op '%{public}s' failed: %{public}s", label, String(error));
  });

  protected forEachLifecycle(handler: (lifecycle: ApplicationLifecycle) => void): void {
    for (const runtime of this.moduleRuntimes) {
      try {
        handler(runtime.lifecycle);
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'Lifecycle callback error: %{public}s', String(e));
      }
    }
  }

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    setCurrentAbilityName(want.abilityName ?? "");
    // Populate AppStorage keys consumed by DeepLinkPlugin.ets (get-initial-uri /
    // get-latest-uri bridge actions, keys INITIAL_WANT_URI_KEY/LATEST_WANT_URI_KEY).
    // Contract documented in DeepLinkPlugin.ets. Was never written before.
    AppStorage.setOrCreate("initialWantUri", want.uri ?? '');
    AppStorage.setOrCreate("wantUri", want.uri ?? '');

    hilog.info(DOMAIN, 'NativeAbility', 'onCreate - moduleName: %{public}s', JSON.stringify(this.moduleName));
    AppStorage.setOrCreate("moduleName", this.moduleName);
    AppStorage.setOrCreate("loadMode", this.loadMode);

    const context = this.context as common.UIAbilityContext;

    // 1. Process-level initialization (runs only once; subsequent instances skip it).
    //    Loads native modules, probes for custom protocols, initializes the web engine.
    //    No longer calls module.init — session creation is this Ability's responsibility.
    await ProcessInitializer.initialize(context, this.moduleName, this.loadMode, want);

    // 2. Create the bridge session for this Ability instance.
    const moduleNames = ProcessInitializer.getLoadedModuleNames();
    if (moduleNames.length === 0) {
      hilog.error(DOMAIN, 'NativeAbility', 'No native modules loaded; cannot create bridge session');
      return;
    }
    const sessionId = BridgeHostRegistry.prepare(moduleNames, context, this.bridgePlugins);
    this.bridgeSessionId = sessionId;
    this.updateAppStorage("bridgeSessionId", sessionId);
    hilog.info(DOMAIN, 'NativeAbility', 'Bridge session created: %{public}s', sessionId);

    // 3. Decode per-module restored state (ability recovery scenario).
    const isRestore = (want.parameters?.["ohos.ability.params.abilityRecoveryRestart"] as boolean) ?? false;
    const restoredStateMap = isRestore
      ? AbilityStateCodec.decode((want.parameters?.[STATE_KEY] as string) ?? "")
      : {};

    // 4. Per module: build BridgeBindings → init → configurePlugins → attachEventSink → activateAbility.
    const modules = ProcessInitializer.getNativeModules();
    for (let i = 0; i < modules.length; i++) {
      const module = modules[i];
      const moduleName = moduleNames[i];
      const bridgeOwner = `${moduleName}#${sessionId}`;
      const bindings: BridgeBindings = {
        bridgeInvoke: (pluginId: string, action: string, requestTypeName: string, responseTypeName: string, value: ESObject, timeoutMs: number): Promise<ESObject> =>
          BridgeHostRegistry.invokeAsync(sessionId, moduleName, pluginId, action, requestTypeName, responseTypeName, value, timeoutMs),
        bridgeInvokeSync: (pluginId: string, action: string, requestTypeName: string, responseTypeName: string, value: ESObject): ESObject =>
          BridgeHostRegistry.invokeSync(sessionId, moduleName, pluginId, action, requestTypeName, responseTypeName, value),
        bridgeDispatch: (): void => {
          // TSFN no-op trampoline. Rust's MainThreadTask::run() executes inside the
          // build_callback registered during attach_bridge_session; ArkTS just needs a
          // callable here so get_named_property("bridgeDispatch") succeeds.
        },
      };
      const initContext = ProcessInitializer.createInitContext(context, moduleName);
      hilog.info(DOMAIN, 'NativeAbility', '[DBG] before module.init mod=%{public}s modules=%{public}d', moduleName, modules.length);
      const lifecycle = module.init(bindings, bridgeOwner, initContext);
      hilog.info(DOMAIN, 'NativeAbility', '[DBG] after module.init mod=%{public}s bridgePlugins=%{public}d', moduleName, lifecycle.bridgePlugins?.length ?? -1);

      try {
      BridgeHostRegistry.configurePlugins(sessionId, moduleName, lifecycle.bridgePlugins);
      hilog.info(DOMAIN, 'NativeAbility', '[DBG] after configurePlugins mod=%{public}s', moduleName);
      BridgeHostRegistry.attachApplicationLifecycle(sessionId, moduleName, lifecycle);
      hilog.info(DOMAIN, 'NativeAbility', '[DBG] after attachApplicationLifecycle mod=%{public}s', moduleName);
      BridgeHostRegistry.attachEventSink(
        sessionId,
        moduleName,
        module.onBridgeSyncEvent
          ? (pluginId: string, event: string, requestTypeName: string, responseTypeName: string, value: ESObject): ESObject =>
              module.onBridgeSyncEvent!(pluginId, event, requestTypeName, responseTypeName, value)
          : undefined,
        module.onBridgeLifecycle
          ? (kind: string): void => module.onBridgeLifecycle!(kind)
          : undefined,
      );

      // Register this module's runtime BEFORE the async ability-create lifecycle below.
      // OHOS does NOT await an async onCreate: it fires onWindowStageCreate as soon as the
      // event loop yields (here, inside `await activateAbility` → deliverLifecycle). If the
      // runtime is pushed only after that await, onWindowStageCreate reads an empty
      // `moduleRuntimes`, the setWindowStage loop runs zero iterations, `windowStageReady`
      // stays false, and the subsequent DefaultXComponent attach fails with "cannot attach
      // without an active WindowStage" — freezing the app before setup runs.
      this.moduleRuntimes.push({ moduleName, module, lifecycle, bridgeOwner });
      hilog.info(DOMAIN, 'NativeAbility', '[DBG] pushed runtime mod=%{public}s total=%{public}d', moduleName, this.moduleRuntimes.length);

      const restoredState = restoredStateMap[moduleName] ?? "";
      // Dispatch AbilityCreated into the Rust bridge registry. This NAPI callback is the ONLY
      // path that flips Rust `BridgePluginRegistryState.session_active` to true
      // (bridge/mod.rs dispatch_lifecycle → AbilityCreated). Without it, every main-thread
      // reverse event the ArkTS webview engine emits during `WebviewClient::create`
      // (seal-engine-schemes / before-engine-init / controller-attached) is rejected with
      // "outside an active Ability session". activateAbility only sets the ArkTS abilityReady
      // flag and delivers to ArkTS plugin.onLifecycle — it does NOT reach Rust
      // dispatch_lifecycle, so it cannot substitute for this call. onWindowStageCreate below
      // uses the same lifecycle.windowStageEventCallback callback pattern; this onAbilityCreate
      // was simply dropped during the NativeAbility refactor (it survived in onWindowStageCreate).
      try {
        lifecycle.windowStageEventCallback.onAbilityCreate(restoredState);
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'onAbilityCreate failed: %{public}s', String(e));
      }
      // Mirror onNewWant: feed the cold-start want.uri into the Rust-side
      // INITIAL_WANT_URI Mutex via the NAPI on_ability_create_with_want closure
      // (lifecycle.rs → store_initial_want_uri). Without this, deep-link
      // getCurrent() lazy-take returns null on cold start. Like onAbilityCreate above,
      // this was dropped during the NativeAbility refactor and never re-added.
      // isContinuation/parametersJson additionally feed the Rust-side continuation
      // storage (app.rs CONTINUATION_RESTORE/CONTINUATION_DATA) for cross-device
      // app-continuation restore; launchReason is compared symbolically here (never
      // sent as a raw number across the bridge).
      try {
        const isContinuation = launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION;
        lifecycle.windowStageEventCallback.onAbilityCreateWithWant({
          uri: want.uri ?? '',
          isContinuation,
          parametersJson: JSON.stringify(want.parameters ?? {}),
        });
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'onAbilityCreateWithWant failed: %{public}s', String(e));
      }
      hilog.info(DOMAIN, 'NativeAbility', '[DBG] before activateAbility mod=%{public}s', moduleName);
      await BridgeHostRegistry.activateAbility(sessionId, moduleName, {
        kind: "ability-create",
        payload: new BridgeAbilityCreateLifecyclePayload(restoredState),
      });
      hilog.info(DOMAIN, 'NativeAbility', '[DBG] after activateAbility mod=%{public}s', moduleName);
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', '[DBG] module setup THREW mod=%{public}s: %{public}s', moduleName, String(e));
        hilog.error(DOMAIN, 'NativeAbility', '[DBG] stack: %{public}s', (e as Error)?.stack ?? 'no-stack');
      }
    }

    this.acceptingLifecycle = true;
  }

  private enqueueLifecycleOperation(label: string, op: () => Promise<void>): Promise<void> {
    return this.lifecycleQueue.enqueue(label, op);
  }

  private async notifyBridgeLifecycle(event: BridgeLifecycleEvent): Promise<void> {
    for (const runtime of this.moduleRuntimes) {
      await BridgeHostRegistry.emitLifecycle(this.bridgeSessionId, runtime.moduleName, event);
    }
  }

  private detachWindowListeners(): void {
    if (!this.bridgeSessionId) {
      return;
    }
    for (const runtime of this.moduleRuntimes) {
      try {
        BridgeHostRegistry.invalidateWindowStage(this.bridgeSessionId, runtime.moduleName);
      } catch (e) {
        hilog.warn(DOMAIN, 'NativeAbility', 'invalidateWindowStage failed for %{public}s: %{public}s', runtime.moduleName, String(e));
      }
    }
  }

  private async destroyWindowStageIfActive(): Promise<void> {
    if (!this.windowStageActive || !this.bridgeSessionId) {
      return;
    }
    for (const runtime of this.moduleRuntimes) {
      await BridgeHostRegistry.clearWindowStage(this.bridgeSessionId, runtime.moduleName);
    }
    this.windowStageActive = false;
  }

  private releaseModuleBridges(runtimes: NativeModuleRuntime[]): void {
    for (const runtime of runtimes) {
      try {
        runtime.module.disposeBridge(runtime.bridgeOwner);
      } catch (e) {
        hilog.warn(DOMAIN, 'NativeAbility', 'disposeBridge failed for %{public}s: %{public}s', runtime.moduleName, String(e));
      }
    }
  }

  private updateAppStorage(key: string, value: string): void {
    AppStorage.setOrCreate(key, value);
  }

  private serializeSavedStateMap(map: Record<string, string>): string {
    return AbilityStateCodec.encode(map);
  }

  protected async loadWindowStageContent(windowStage: window.WindowStage): Promise<void> {
    await windowStage.loadContentByName(Entry.RouteName);
  }

  private setupMenuPopup(windowStage: window.WindowStage): void {
    const nativeModules = ProcessInitializer.getNativeModules();
    const primaryModule: ESObject = nativeModules[0] as ESObject;
    if (!primaryModule || typeof primaryModule.onMenuRequest !== 'function') {
      return;
    }

    AppStorage.setOrCreate("__openharmony_ability_is_desktop__", primaryModule.isDesktopDevice());

    // Forward menubar item clicks / accelerator key presses to the Rust-side
    // plugin-menu bridge `menu-click` main-thread event (process-wide broadcast).
    // plugin-menu decodes MenuClickEvent (typeName "ohos.menu.MenuClickEvent"),
    // forwards over its MENU_EVENT_SENDER (registered by the menu backend) → the menu backend's
    // MENU_EVENT_CHANNEL → MenuEvent::send → frontend onEvent callback.
    // Previously this was `primaryModule.emitMenuEvent` — a legacy NAPI fn that
    // wrote to a dead sink (openharmony-ability's own MENU_EVENT_CHANNEL with no
    // consumer), so menubar clicks and accelerator fires silently dropped.
    // menu plugin is already register_plugin'd (the tray backend's set_ohos_app) + in
    // EntryAbility.bridgePlugins, so the host is active once the menubar is set.
    const emitMenuEventFn: (menuId: string, windowId?: string) => void = (menuId, windowId) => {
      hilog.info(DOMAIN, 'NativeAbility', 'emitMenuEventFn ENTER menuId=%{public}s windowId=%{public}s', menuId, windowId ?? 'main');
      try {
        BridgeHostRegistry.invokeNativeSyncProcessWide(
          'ohos.menu',
          'menu-click',
          'ohos.menu.MenuClickEvent',
          'std.bool',
          { menuId, windowId: windowId ?? 'main' },
        );
        hilog.info(DOMAIN, 'NativeAbility', 'emitMenuEventFn forwarded menuId=%{public}s ok', menuId);
      } catch (e) {
        hilog.warn(DOMAIN, 'NativeAbility', 'emitMenuEvent forward failed: %{public}s', String(e));
      }
    };

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

    setMenuClickHandler(0, (item) => {
      hilog.info(DOMAIN, 'NativeAbility', 'menuClickHandler invoked id=%{public}s type=%{public}s', item.id, item.type);
      menuManager.handleItemClick(item);
    });

    setMenuBarRecoverFn(0, () => {
      // Esc exit from predefined fullscreen: dual-path exit so the title bar /
      // Dock hover hidden on entry (WindowManager.setFullscreen desktop path)
      // are restored too. The internal recover() triggers
      // windowRectChange(RECOVER) → menubar restore (see on("windowRectChange")).
      WindowManager.getInstance().setFullscreen(0, false);
    });

    setPrimaryWebviewControllerCallback((controller: ESObject) => {
      executor.setController(controller as webview.WebviewController);
    });

    primaryModule.onMenuRequest((data: { jsonData: string; x?: number; y?: number; visible?: boolean; windowId?: string }) => {
      const windowId = data.windowId ?? "main";

      if (data.visible !== undefined && data.visible !== null) {
        const cb = getMenuDataCallback(windowId);
        cb?.onMenubarVisible?.(data.visible);
        primaryModule.notifyMenubarVisibility(windowId, data.visible);
        return;
      }

      if (data.x !== undefined && data.y !== undefined) {
        try {
          menuManager.popupFromJson(data.jsonData, data.x ?? 0, data.y ?? 0, windowId);
        } catch (e) {
          console.error(`[Menu] Popup failed: ${e}`);
        }
        return;
      }

      const cb = getMenuDataCallback(windowId);
      cb?.onMenubarJson?.(data.jsonData);
    });
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageCreate());

    WindowManager.getInstance().registerUIAbilityStage(0, windowStage, this.context, false);
    hilog.info(DOMAIN, 'NativeAbility', 'onWindowStageCreate: windowId=0 transparent=false');

    // Phase 2 (design.md D3 注入小节): WindowManager doesn't hold a lifecycle reference,
    // so it exposes a single rectChangeCallback that createSubWindow's per-window
    // windowRectChange handler invokes. Here we wire it to fan out to every lifecycle
    // (same forEachLifecycle pattern as the main-window registrations above). The
    // wrapped options already carry the windowId.
    WindowManager.getInstance().registerRectChangeCallback((wrapped: WindowRectEventWrap) => {
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onWindowRectChange(wrapped),
      );
    });

    // Inject the WindowStage into the bridge session so plugins requiring a
    // window-stage context (e.g. window/webview) can install before the page renders.
    if (this.bridgeSessionId) {
      hilog.info(DOMAIN, 'NativeAbility', '[DBG] setWindowStage loop: runtimes=%{public}d sess=%{public}s', this.moduleRuntimes.length, this.bridgeSessionId);
      for (const runtime of this.moduleRuntimes) {
        try {
          await BridgeHostRegistry.setWindowStage(this.bridgeSessionId, runtime.moduleName, windowStage);
        } catch (e) {
          hilog.error(DOMAIN, 'NativeAbility', 'setWindowStage failed for %{public}s: %{public}s', runtime.moduleName, String(e));
        }
      }
      this.windowStageActive = true;
      try {
        await this.notifyBridgeLifecycle({
          kind: "window-stage-create",
          payload: new BridgeEmptyLifecyclePayload(),
        });
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'window-stage-create lifecycle failed: %{public}s', String(e));
      }
    }

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
          // Phase 3 (design.md D2/D3): wrap with typed interface and route through
          // per-window(0) throttle (leading+trailing 16ms). windowId=0 = main window.
          // Double-registration dedup: BridgeHost also registers onSizeChange for the
          // same windowId=0 — the throttle merges both sources automatically.
          const wrapped: WindowSizeEventWrap = { windowId: 0, width: size.width, height: size.height };
          WindowManager.getInstance().throttledRectDispatch(0, wrapped, (w: object) => {
            this.forEachLifecycle((lifecycle) =>
              lifecycle.windowStageEventCallback.onWindowSizeChange(w),
            );
          }, 'size');
        });
        win.on("windowRectChange", (options: window.RectChangeOptions) => {
          // Phase 3 (design.md D3): RECOVER→menubar logic stays synchronous (UI logic,
          // not throttled — must respond immediately on fullscreen exit).
          if (options.reason === window.RectChangeReason.RECOVER) {
            const cb = getMenuDataCallback("main");
            cb?.onMenubarVisible?.(true);
          }
          // Phase 3 (design.md D2/D5): rect dispatch through per-window(0) throttle.
          // Deep-copy rect fields (not system object ref) per design.md D5.
          const wrapped: WindowRectEventWrap = {
            windowId: 0,
            reason: options.reason,
            rect: { left: options.rect.left, top: options.rect.top, width: options.rect.width, height: options.rect.height }
          };
          WindowManager.getInstance().throttledRectDispatch(0, wrapped, (w: object) => {
            this.forEachLifecycle((lifecycle) =>
              lifecycle.windowStageEventCallback.onWindowRectChange(w),
            );
          }, 'rect');
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
        // 回灌系统窗口状态到 tao 镜像位(问题五 5.3):
        // 最大化/最小化/全屏/悬浮等系统状态变化经 notifyWindowStatus NAPI 入队,
        // runtime-wry drain 后用真实 windowId 路由到对应 tao Window 更新镜像位。
        // API 11+;不支持则静默降级(不比现状差)。详见 doc/OHOS窗口遗留问题.md。
        try {
          win.on("windowStatusChange", (statusType: window.WindowStatusType) => {
            const nativeModule: ESObject = AppStorage.get<ESObject>(NATIVE_MODULE_STORAGE_KEY);
            if (nativeModule && typeof nativeModule.notifyWindowStatus === 'function') {
              // 本地单 UIAbility 架构:主窗口恒为 tao windowId=0(upstream 的
              // readWindowId() 首实例也返回 0);runtime-wry 按 tao window_id 路由。
              nativeModule.notifyWindowStatus(0, statusType);
            }
          });
          // seed 初始态(官方 updateWindowInfo 模式),避免漏掉注册前状态。
          const initialStatus = win.getWindowStatus();
          const nativeModule: ESObject = AppStorage.get<ESObject>(NATIVE_MODULE_STORAGE_KEY);
          if (nativeModule && typeof nativeModule.notifyWindowStatus === 'function') {
            nativeModule.notifyWindowStatus(0, initialStatus);
          }
        } catch (e) {
          hilog.warn(DOMAIN, 'NativeAbility', 'windowStatusChange registration failed: %{public}s', String(e));
        }
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'Window event registration failed: %{public}s', String(e));
      }
    }

    if (this.defaultPage) {
      try {
        await this.loadWindowStageContent(windowStage);
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'loadWindowStageContent failed: %{public}s', String(e));
      }
    }

    // Transparent window background/container color is applied in
    // DefaultXComponent.aboutToAppear (window fully ready there). The transparent
    // flag is stored in WindowManager.registerUIAbilityStage and applied via
    // WindowManager.applyTransparentBackground(windowId) in aboutToAppear.

    try {
      this.setupMenuPopup(windowStage);
    } catch (menuErr) {
      console.error(`[Menu] setupMenuPopup threw: ${menuErr}`);
    }
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
      hilog.info(DOMAIN, 'NativeAbility', 'onWindowStageRestore: stage already active (warm continuation), skipping full setup');
      return;
    }
    hilog.info(DOMAIN, 'NativeAbility', 'onWindowStageRestore: cold continuation, delegating to window-stage setup');
    void this.onWindowStageCreate(windowStage);
  }

  onWindowStageDestroy(): void | Promise<void> {
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageDestroy());
    try {
      WindowManager.getInstance().unregisterUIAbilityStage(0);
    } catch (e) {
      hilog.error(DOMAIN, 'NativeAbility', 'onWindowStageDestroy cleanup failed: %{public}s', String(e));
    }
    if (this.bridgeSessionId) {
      return this.enqueueLifecycleOperation("window-stage-destroy", async (): Promise<void> => {
        await this.destroyWindowStageIfActive();
        await this.notifyBridgeLifecycle({
          kind: "window-stage-destroy",
          payload: new BridgeEmptyLifecyclePayload(),
        });
      });
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
    const uri = want.uri ?? '';
    const parametersJson = JSON.stringify(want.parameters ?? {});
    hilog.info(DOMAIN, 'NativeAbility', 'onNewWant - uri: %{public}s, parametersJson.length: %{public}d', uri, parametersJson.length);

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
        hilog.info(DOMAIN, 'NativeAbility', 'onNewWant detected pending action, cancelling cleanup timer');
        wm.cancelCleanupTimer();
      }
    } catch (e) {
      // WindowManager might not be initialized yet, ignore
    }

    // isContinuation marks a warm-start app-continuation restore; consumed by the
    // Rust-side continuation storage (lifecycle.rs → store_continuation).
    const isContinuation = launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION;
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onNewWant({ uri, parametersJson, isContinuation }));
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
      const primaryModule: ESObject = nativeModules[0] as ESObject;
      if (primaryModule && typeof primaryModule.readContinueSnapshot === "function") {
        snapshot = primaryModule.readContinueSnapshot() as string;
      }
    } catch (e) {
      hilog.error(DOMAIN, 'NativeAbility', 'onContinue - snapshot read failed: %{public}s', String(e));
      return AbilityConstant.OnContinueResult.MISMATCH;
    }

    if (snapshot.length === 0) {
      hilog.info(DOMAIN, 'NativeAbility', 'onContinue - empty snapshot, refusing (MISMATCH)');
      return AbilityConstant.OnContinueResult.MISMATCH;
    }

    // Reserved key round-trip: the target side reads it from getContinuationData()
    // → JSON.parse(...).continuationData. Passed through verbatim — the payload
    // schema is an application-level contract.
    wantParam["continuationData"] = snapshot;
    hilog.info(DOMAIN, 'NativeAbility', 'onContinue - AGREE, snapshot length: %{public}d', snapshot.length);
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
        stateMap[runtime.moduleName] = runtime.lifecycle.windowStageEventCallback.onAbilitySaveState() ?? "";
      } catch (e) {
        hilog.error(DOMAIN, 'NativeAbility', 'onAbilitySaveState failed: %{public}s', String(e));
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
}
