import { AbilityConstant, Configuration, UIAbility, Want } from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import display from "@ohos.display";
import webview from "@ohos.web.webview";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { deviceInfo } from "@kit.BasicServicesKit";
import * as Entry from "../components/MainPage";
import {
  setMenuClickHandler,
  setMenuBarRecoverFn,
  getMenuDataCallback,
  windowKeyForId,
} from "../components/MenuBarComponent";
import {
  ApplicationLifecycle,
  Module,
  BridgeBindings,
  BridgePluginFactory,
  BridgeLifecycleEvent,
  BridgeAbilityCreateLifecyclePayload,
  BridgeEmptyLifecyclePayload,
  BridgeMemoryLevelLifecyclePayload,
  BridgeWindowStageEventLifecyclePayload,
  AbilityInitContext,
} from "./type";
import { MenuManager, PredefinedActionExecutor, setPredefinedActionExecutor } from "../helper/menu";
import { AboutMetadataData } from "../helper/menu_types";
import { setCurrentAbilityName } from "../helper/StatusBarUtils";
import { WindowManager, WindowSizeEventWrap, WindowRectEventWrap } from "../window/WindowManager";
import { clearAllTrackedModifiers } from "../helper/accelerator_matcher";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from "../helper/constants";
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
  // D12 join model (openspec multi-uiability-windows): true when this instance's
  // modules were already owned by a live bridge session and prepare() returned
  // that shared session instead of creating a new one. A joined instance skips
  // every session-mutating operation — module.init, configurePlugins,
  // attachEventSink, activateAbility, setWindowStage, beginClosing, dispose —
  // and only fires the shared lifecycle NAPI callbacks with its own windowId.
  private joinedExistingSession: boolean = false;
  // Window identity of this UIAbility instance (design.md D3, openspec
  // multi-uiability-windows): 0 for the process's first instance, or the
  // tauri_window_id pre-allocated by tao and delivered via want.parameters
  // for instances spawned through start-ui-ability. Read in onCreate, used
  // by every Rust-facing registration (stage/menu/window-status/rect events)
  // so they target this instance's window instead of overwriting id 0.
  private abilityWindowId: number = 0;
  // D4b plain-relaunch duplicate flag (design.md D4b, openspec
  // multi-uiability-windows): set in onCreate when this instance resolved to
  // window id 0 while a live primary already owns stage 0 (relaunch via icon /
  // taskbar / a second deep-link click under launchType "standard"). The
  // duplicate forwards its want URI, raises the primary, and terminates in
  // onCreate; terminateSelf is async, so every later system callback
  // (onWindowStageCreate/Destroy, onDestroy, onNewWant) is gated on this flag
  // — the duplicate must never register a stage nor fire the primary's
  // lifecycle callbacks with id 0 (onAbilityDestroy(0) would run the primary
  // exit chain, Event::Destroy → process teardown).
  private isDuplicatePrimary: boolean = false;
  // Transparency delivered alongside tauri_window_id (start-ui-ability sends
  // tauri_transparent as a string); feeds registerUIAbilityStage so
  // applyTransparentBackground in DefaultXComponent works for spawned windows.
  private abilityTransparent: boolean = false;
  // This instance's want URIs (design.md D9): delivered per-instance through
  // the loadWindowStageContent LocalStorage instead of the process-global
  // AppStorage keys, so a spawned instance's deep link never overwrites the
  // primary's (and vice versa).
  private initialWantUri: string = "";
  private latestWantUri: string = "";
  private readonly lifecycleQueue = new SerialTaskQueue((label: string, error: Error): void => {
    hilog.error(
      DOMAIN,
      "NativeAbility",
      "lifecycle op '%{public}s' failed: %{public}s",
      label,
      String(error),
    );
  });

  protected forEachLifecycle(handler: (lifecycle: ApplicationLifecycle) => void): void {
    // A joined instance (D12) never runs module.init, so its moduleRuntimes
    // stays empty; its lifecycle callbacks come from the process-level store
    // the creator instance filled via ProcessInitializer.rememberLifecycle.
    // The bundles are plain NAPI-callback records — every invocation carries
    // this instance's windowId, so sharing them cannot cross-deliver events.
    if (this.moduleRuntimes.length > 0) {
      for (const runtime of this.moduleRuntimes) {
        try {
          handler(runtime.lifecycle);
        } catch (e) {
          hilog.error(DOMAIN, 'NativeAbility', 'Lifecycle callback error: %{public}s', String(e));
        }
      }
      return;
    }
    for (const lifecycle of ProcessInitializer.getLifecycles().values()) {
      try {
        handler(lifecycle);
      } catch (e) {
        hilog.error(DOMAIN, "NativeAbility", "Lifecycle callback error: %{public}s", String(e));
      }
    }
  }

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    setCurrentAbilityName(want.abilityName ?? "");
    // Window identity (design.md D3): tao pre-allocates the id and delivers it
    // as an all-string want parameter; the first (process-launched) instance
    // has no parameter and stays 0. Number("") is 0 and Number(undefined) is
    // NaN, so `|| 0` keeps both degenerate shapes at the primary id.
    this.abilityWindowId = Number(want.parameters?.["tauri_window_id"] ?? 0) || 0;
    this.abilityTransparent = want.parameters?.["tauri_transparent"] === "true";
    hilog.info(DOMAIN, 'NativeAbility', 'onCreate - windowId=%{public}d transparent=%{public}s (from want.parameters)', this.abilityWindowId, String(this.abilityTransparent));

    // D4b plain-relaunch guard (design.md D4b): for a bypassed/missing
    // onAcceptWant route, a relaunch while the app is running — desktop
    // icon / taskbar / a second deep-link click — spawns a duplicate
    // EntryAbility whose want carries no tauri_window_id, so it resolves to
    // the primary id 0. Letting it proceed would overwrite the primary's
    // uiAbilityStages[0] entry (R4: registerUIAbilityStage blind set,
    // device-proven corrosion) and its AppStorage want keys below, and its
    // eventual onDestroy would fire the primary exit chain. Single-instance
    // semantics instead (macOS-native / Windows + single-instance-plugin
    // production behavior): forward this want.uri into the primary's
    // per-window deep-link slot, bring the primary window to front, terminate
    // this instance before it registers a stage or mounts a window.
    // (2026-09-15 specified amendment: bare wants are normally routed to the
    // primary by AbilityStage.onAcceptWant before ever reaching onCreate —
    // this guard is defense-in-depth for a bypassed/missing AbilityStage
    // route. It cannot cover a hideAbility()-hidden primary; that state is
    // foregrounded by the startAbility(self) call sites instead.)
    if (this.abilityWindowId === 0 && WindowManager.isStageRegistered(0)) {
      this.isDuplicatePrimary = true;
      hilog.warn(DOMAIN, 'NativeAbility', 'D4b duplicate-primary guard: relaunch (no tauri_window_id) while primary lives — uri=%{public}s, forwarding + raising + terminating', want.uri ?? '');
      // Forward: seed the primary's INITIAL_WANT_URI[0] slot through the shared
      // lifecycle callback. The Rust side of onAbilityCreateWithWant only
      // writes the per-window URI store (store_initial_want_uri) — no session
      // partition is opened — so the primary's next deep-link getCurrent
      // (get_current_for_window, lazy-take) drains this relaunch URI.
      // Continuation faithfulness: pass the real launchReason so a
      // continuation relaunch at least preserves its payload (NG5 defers
      // multi-instance continuation handling).
      const relaunchIsContinuation = launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION;
      if (want.uri && want.uri.length > 0) {
        this.forEachLifecycle((lifecycle) =>
          lifecycle.windowStageEventCallback.onAbilityCreateWithWant({
            uri: want.uri ?? '',
            isContinuation: relaunchIsContinuation,
            parametersJson: JSON.stringify(want.parameters ?? {}),
          }, 0),
        );
      }
      // Raise the primary window (restore from minimize, or raise to top —
      // WindowManager.showWindowMethod handles both for main windows).
      WindowManager.getInstance().showWindowMethod(0);
      // Terminate this duplicate. Async — later callbacks are gated on
      // isDuplicatePrimary in case the system still delivers them.
      (this.context as common.UIAbilityContext).terminateSelf().catch((e: ESObject) => {
        hilog.error(DOMAIN, 'NativeAbility', 'D4b terminateSelf failed: %{public}s', String(e));
      });
      return;
    }
    // This instance's want URIs (design.md D9): delivered per-instance via the
    // loadWindowStageContent LocalStorage. The AppStorage keys below remain a
    // primary-instance-only back-compat channel for the legacy DeepLinkPlugin
    // bridge path ("initialWantUri"/"wantUri"); a spawned instance must NOT
    // overwrite them, or the primary's deep-link reads would see the spawned
    // instance's launch URI.
    this.initialWantUri = want.uri ?? '';
    this.latestWantUri = want.uri ?? '';
    if (this.abilityWindowId === 0) {
      AppStorage.setOrCreate("initialWantUri", this.initialWantUri);
      AppStorage.setOrCreate("wantUri", this.latestWantUri);
    }

    hilog.info(
      DOMAIN,
      "NativeAbility",
      "onCreate - moduleName: %{public}s",
      JSON.stringify(this.moduleName),
    );
    AppStorage.setOrCreate("moduleName", this.moduleName);
    AppStorage.setOrCreate("loadMode", this.loadMode);

    const context = this.context as common.UIAbilityContext;

    // 1. Process-level initialization (runs only once; subsequent instances skip it).
    //    Loads native modules, probes for custom protocols, initializes the web engine.
    //    No longer calls module.init — session creation is this Ability's responsibility.
    await ProcessInitializer.initialize(context, this.moduleName, this.loadMode, want);

    // 2. Create the bridge session for this Ability instance. Join model (D12):
    //    when every loaded module already belongs to one live session — i.e. this
    //    is a spawned instance reusing the process's modules — prepare() returns
    //    that shared session instead of creating a new one. The joined instance
    //    keeps the session id for its page's LocalStorage (D6) and for teardown
    //    gating, but performs none of the session-mutating setup below.
    const moduleNames = ProcessInitializer.getLoadedModuleNames();
    if (moduleNames.length === 0) {
      hilog.error(
        DOMAIN,
        "NativeAbility",
        "No native modules loaded; cannot create bridge session",
      );
      return;
    }
    const joinedSessionId = BridgeHostRegistry.activeSessionForModules(moduleNames);
    const sessionId = BridgeHostRegistry.prepare(moduleNames, context, this.bridgePlugins);
    this.bridgeSessionId = sessionId;
    // AppStorage readers: the demo pages (Index/SubWindowPage load outside
    // MainPage and feed DefaultXComponent's bridgeSessionId @Prop from here).
    // MainPage itself consumes the per-instance LocalStorage write in
    // onWindowStageCreate instead (design.md D6).
    this.updateAppStorage("bridgeSessionId", sessionId);
    this.joinedExistingSession = joinedSessionId !== undefined && joinedSessionId === sessionId;
    hilog.info(DOMAIN, 'NativeAbility', 'Bridge session created: %{public}s (joined=%{public}s)', sessionId, String(this.joinedExistingSession));

    if (this.joinedExistingSession) {
      // D12 joined instance: the shared session already has every module
      // configured by the primary instance — re-running init /
      // configurePlugins / attachEventSink / activateAbility would
      // double-register plugins and re-deliver ability-create to the ArkTS
      // hosts. Only the NAPI lifecycle callbacks fire, carrying THIS
      // instance's windowId so the Rust-side registry opens the session
      // partition for this window (bridge/mod.rs dispatch_lifecycle →
      // AbilityCreated{window_id}) and deep-link's per-window want-URI map
      // is seeded (onAbilityCreateWithWant → store_initial_want_uri).
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onAbilityCreate("", this.abilityWindowId),
      );
      const isContinuation = launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION;
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onAbilityCreateWithWant({
          uri: want.uri ?? '',
          isContinuation,
          parametersJson: JSON.stringify(want.parameters ?? {}),
        }, this.abilityWindowId),
      );
      this.acceptingLifecycle = true;
      return;
    }

    // 3. Decode per-module restored state (ability recovery scenario).
    const isRestore =
      (want.parameters?.["ohos.ability.params.abilityRecoveryRestart"] as boolean) ?? false;
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
        bridgeInvoke: (
          pluginId: string,
          action: string,
          requestTypeName: string,
          responseTypeName: string,
          value: ESObject,
          timeoutMs: number,
        ): Promise<ESObject> =>
          BridgeHostRegistry.invokeAsync(
            sessionId,
            moduleName,
            pluginId,
            action,
            requestTypeName,
            responseTypeName,
            value,
            timeoutMs,
          ),
        bridgeInvokeSync: (
          pluginId: string,
          action: string,
          requestTypeName: string,
          responseTypeName: string,
          value: ESObject,
        ): ESObject =>
          BridgeHostRegistry.invokeSync(
            sessionId,
            moduleName,
            pluginId,
            action,
            requestTypeName,
            responseTypeName,
            value,
          ),
        bridgeDispatch: (): void => {
          // TSFN no-op trampoline. Rust's MainThreadTask::run() executes inside the
          // build_callback registered during attach_bridge_session; ArkTS just needs a
          // callable here so get_named_property("bridgeDispatch") succeeds.
        },
      };
      const initContext = ProcessInitializer.createInitContext(context, moduleName);
      hilog.debug(
        DOMAIN,
        "NativeAbility",
        "before module.init mod=%{public}s modules=%{public}d",
        moduleName,
        modules.length,
      );
      const lifecycle = module.init(bindings, bridgeOwner, initContext);
      hilog.debug(
        DOMAIN,
        "NativeAbility",
        "after module.init mod=%{public}s bridgePlugins=%{public}d",
        moduleName,
        lifecycle.bridgePlugins?.length ?? -1,
      );
      // Publish the lifecycle bundle to the process-level store (D12) so a
      // later joined instance can fire the shared callbacks with its own
      // windowId once this module is owned by the live session.
      ProcessInitializer.rememberLifecycle(moduleName, lifecycle);

      try {
        BridgeHostRegistry.configurePlugins(sessionId, moduleName, lifecycle.bridgePlugins);
        hilog.debug(DOMAIN, "NativeAbility", "after configurePlugins mod=%{public}s", moduleName);
        BridgeHostRegistry.attachApplicationLifecycle(sessionId, moduleName, lifecycle);
        hilog.debug(
          DOMAIN,
          "NativeAbility",
          "after attachApplicationLifecycle mod=%{public}s",
          moduleName,
        );
        BridgeHostRegistry.attachEventSink(
          sessionId,
          moduleName,
          module.onBridgeSyncEvent
            ? (
                pluginId: string,
                event: string,
                requestTypeName: string,
                responseTypeName: string,
                value: ESObject,
              ): ESObject =>
                module.onBridgeSyncEvent!(pluginId, event, requestTypeName, responseTypeName, value)
            : undefined,
          // windowId threading (design.md D8): only this session-owning instance
          // registers the sink, and its ui-context events describe its own
          // DefaultXComponent attachment — so from_arkts receives the owner
          // instance's window id, never the joined instance's.
          module.onBridgeLifecycle
            ? (kind: string): void => module.onBridgeLifecycle!(kind, this.abilityWindowId)
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
        hilog.debug(
          DOMAIN,
          "NativeAbility",
          "pushed runtime mod=%{public}s total=%{public}d",
          moduleName,
          this.moduleRuntimes.length,
        );

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
          lifecycle.windowStageEventCallback.onAbilityCreate(restoredState, this.abilityWindowId);
        } catch (e) {
          hilog.error(DOMAIN, "NativeAbility", "onAbilityCreate failed: %{public}s", String(e));
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
          const isContinuation =
            launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION;
          lifecycle.windowStageEventCallback.onAbilityCreateWithWant({
            uri: want.uri ?? "",
            isContinuation,
            parametersJson: JSON.stringify(want.parameters ?? {}),
          }, this.abilityWindowId);
        } catch (e) {
          hilog.error(
            DOMAIN,
            "NativeAbility",
            "onAbilityCreateWithWant failed: %{public}s",
            String(e),
          );
        }
        hilog.debug(DOMAIN, "NativeAbility", "before activateAbility mod=%{public}s", moduleName);
        await BridgeHostRegistry.activateAbility(sessionId, moduleName, {
          kind: "ability-create",
          payload: new BridgeAbilityCreateLifecyclePayload(restoredState),
        });
        hilog.debug(DOMAIN, "NativeAbility", "after activateAbility mod=%{public}s", moduleName);
      } catch (e) {
        hilog.error(
          DOMAIN,
          "NativeAbility",
          "module setup THREW mod=%{public}s: %{public}s",
          moduleName,
          String(e),
        );
        hilog.error(
          DOMAIN,
          "NativeAbility",
          "stack: %{public}s",
          (e as Error)?.stack ?? "no-stack",
        );
        // Fail-fast collapse (issue #87 minor-3): continuing with a half-initialized
        // bridge leaves every later call failing with a confusing "not installed".
        // Mirror onDestroy's teardown instead: close the session so pending bridge
        // calls/hooks fail fast with "closing", then feed Event::Destroy to the
        // modules that DID initialize (plus this failing module if its runtime was
        // already pushed) so Rust's run_loop receives Event::Destroy and exits
        // normally. terminate() itself cannot succeed at onCreate time — the
        // main-thread Env is only populated later by render() — so the destroy
        // dispatch, not a terminate call, drives the Rust exit chain.
        if (this.bridgeSessionId) {
          BridgeHostRegistry.beginClosing(this.bridgeSessionId);
        }
        const pushed = this.moduleRuntimes.some((r) => r.moduleName === moduleName);
        if (!pushed) {
          // The throw predates this module's runtime push — forEachLifecycle
          // below would never reach it.
          try {
            lifecycle.windowStageEventCallback.onAbilityDestroy(this.abilityWindowId);
          } catch (e2) {
            hilog.error(
              DOMAIN,
              "NativeAbility",
              "onAbilityDestroy (failed module %{public}s) failed: %{public}s",
              moduleName,
              String(e2),
            );
          }
        }
        this.forEachLifecycle((l) => l.windowStageEventCallback.onAbilityDestroy(this.abilityWindowId));
        // Prevent the real onDestroy from double-dispatching Event::Destroy to the
        // same modules (onDestroy's dispatch is not gated by acceptingLifecycle).
        // onDestroy still runs its own session teardown (dispose) normally.
        this.moduleRuntimes = [];
        return;
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

  private updateAppStorage(key: string, value: string): void {
    AppStorage.setOrCreate(key, value);
  }

  private serializeSavedStateMap(map: Record<string, string>): string {
    return AbilityStateCodec.encode(map);
  }

  protected async loadWindowStageContent(windowStage: window.WindowStage): Promise<void> {
    // Per-instance LocalStorage (design.md D3/D6/D9): MainPage and
    // DefaultXComponent read these via @LocalStorageProp — a spawned instance
    // receives its own window id, the shared bridge session id (D12 join) and
    // its own want URIs, never the process-global AppStorage values the
    // primary instance published. Same pattern as WindowManager.createSubWindow
    // for Float sub-windows.
    const storage = new LocalStorage();
    storage.setOrCreate('windowId', this.abilityWindowId);
    storage.setOrCreate('bridgeSessionId', this.bridgeSessionId);
    storage.setOrCreate('initialWantUri', this.initialWantUri);
    storage.setOrCreate('wantUri', this.latestWantUri);
    await windowStage.loadContentByName(Entry.RouteName, storage);
  }

  private setupMenuPopup(windowStage: window.WindowStage): void {
    const nativeModules = ProcessInitializer.getNativeModules();
    const primaryModule: Module | undefined = nativeModules[0];
    // Probe a live NAPI surface member as the "is this a real openharmony-ability
    // module" guard. This used to probe the onMenuRequest stub — dead code whose
    // registration body never executed (the Rust side discarded the callback);
    // the stub has been deleted (issue #87 major-4), so probe isDesktopDevice
    // instead, which setupMenuPopup itself needs at the line below.
    if (!primaryModule || typeof primaryModule.isDesktopDevice !== "function") {
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
      hilog.info(
        DOMAIN,
        "NativeAbility",
        "emitMenuEventFn ENTER menuId=%{public}s windowId=%{public}s",
        menuId,
        windowId ?? "main",
      );
      try {
        BridgeHostRegistry.invokeNativeSyncProcessWide(
          "ohos.menu",
          "menu-click",
          "ohos.menu.MenuClickEvent",
          "std.bool",
          { menuId, windowId: windowId ?? "main" },
        );
        hilog.info(
          DOMAIN,
          "NativeAbility",
          "emitMenuEventFn forwarded menuId=%{public}s ok",
          menuId,
        );
      } catch (e) {
        hilog.warn(DOMAIN, "NativeAbility", "emitMenuEvent forward failed: %{public}s", String(e));
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
      const appName = metadata.name ?? "";
      const appVersion = metadata.version ?? "";
      const appCopyright = metadata.copyright ?? "";
      const appAuthors = metadata.authors?.join(", ") ?? "";
      const appComments = metadata.comments ?? "";
      const appWebsite = metadata.website ?? "";

      const lines: string[] = [];
      if (appName) lines.push(appName);
      if (appVersion) lines.push(`Version: ${appVersion}`);
      if (appCopyright) lines.push(appCopyright);
      if (appAuthors) lines.push(`Authors: ${appAuthors}`);
      if (appComments) lines.push(appComments);
      if (appWebsite) lines.push(appWebsite);
      const message = lines.join("\n");
      const title = appName || "About";

      try {
        const uiContext = mainWindow.getUIContext();
        uiContext.showAlertDialog({
          title: title,
          message: message,
          autoCancel: true,
          confirm: {
            value: "OK",
            action: () => {},
          },
        });
      } catch (e) {
        hilog.error(DOMAIN, "NativeAbility", "Show about dialog failed: %{public}s", String(e));
      }
    });

    const menuManager = new MenuManager(executor, emitMenuEventFn);

    setMenuClickHandler(this.abilityWindowId, (item) => {
      hilog.info(DOMAIN, 'NativeAbility', 'menuClickHandler invoked id=%{public}s type=%{public}s', item.id, item.type);
      menuManager.handleItemClick(item);
    });

    setMenuBarRecoverFn(this.abilityWindowId, () => {
      // Esc exit from predefined fullscreen: dual-path exit so the title bar /
      // Dock hover hidden on entry (WindowManager.setFullscreen desktop path)
      // are restored too. The internal recover() triggers
      // windowRectChange(RECOVER) → menubar restore (see on("windowRectChange")).
      WindowManager.getInstance().setFullscreen(this.abilityWindowId, false);
    });

    setPrimaryWebviewControllerCallback((controller: ESObject) => {
      executor.setController(controller as webview.WebviewController);
    });

    // NOTE (issue #87 major-4): the legacy `primaryModule.onMenuRequest(...)`
    // registration that used to live here never executed — the Rust-side
    // on_menu_request stub discarded the callback (`let _ = callback`). All three
    // of its branches (menubar visibility / popup / menubar json) are served by
    // the MenuPlugin bridge actions set-menubar / popup / set-menubar-visible.
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    // D4b: a plain-relaunch duplicate (terminated in onCreate) must not
    // register a stage — registerUIAbilityStage(0) would overwrite the live
    // primary's entry — nor mount a window. terminateSelf is async, so the
    // system may still deliver this callback before teardown lands.
    if (this.isDuplicatePrimary) {
      hilog.warn(DOMAIN, 'NativeAbility', 'onWindowStageCreate skipped: duplicate primary (D4b)');
      return;
    }
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageCreate(this.abilityWindowId));

    WindowManager.getInstance().registerUIAbilityStage(this.abilityWindowId, windowStage, this.context, this.abilityTransparent);
    hilog.info(DOMAIN, 'NativeAbility', 'onWindowStageCreate: windowId=%{public}d transparent=%{public}s', this.abilityWindowId, String(this.abilityTransparent));

    // Phase 2 (design.md D3 injection section): WindowManager doesn't hold a lifecycle reference,
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
    // Skipped for a joined instance (D12): the shared session's window-stage
    // context belongs to the primary instance's stage — injecting this
    // instance's stage would re-target every shared plugin at the wrong window
    // (R11 cross-talk). The joined window's webview mounts through the
    // WindowManager multi-root path (OQ3) instead.
    if (this.bridgeSessionId && !this.joinedExistingSession) {
      hilog.debug(DOMAIN, 'NativeAbility', 'setWindowStage loop: runtimes=%{public}d sess=%{public}s', this.moduleRuntimes.length, this.bridgeSessionId);
      for (const runtime of this.moduleRuntimes) {
        try {
          await BridgeHostRegistry.setWindowStage(
            this.bridgeSessionId,
            runtime.moduleName,
            windowStage,
          );
        } catch (e) {
          hilog.error(
            DOMAIN,
            "NativeAbility",
            "setWindowStage failed for %{public}s: %{public}s",
            runtime.moduleName,
            String(e),
          );
        }
      }
      this.windowStageActive = true;
      try {
        await this.notifyBridgeLifecycle({
          kind: "window-stage-create",
          payload: new BridgeEmptyLifecyclePayload(),
        });
      } catch (e) {
        hilog.error(
          DOMAIN,
          "NativeAbility",
          "window-stage-create lifecycle failed: %{public}s",
          String(e),
        );
      }
    }

    try {
      windowStage.on("windowStageEvent", (event: window.WindowStageEventType) => {
        // Clear tracked modifiers on focus loss (issue #111): modifier key
        // releases that happen while the window is INACTIVE (minimized, or
        // focus taken by a subwindow/menu) or HIDDEN are never seen by
        // onKeyPreIme; the stale dirty bits would mis-assemble the first
        // subsequent bare key into a ctrl+ combo (reproduced on a real device).
        if (
          event === window.WindowStageEventType.INACTIVE ||
          event === window.WindowStageEventType.HIDDEN
        ) {
          clearAllTrackedModifiers();
        }
        this.forEachLifecycle((lifecycle) =>
          lifecycle.windowStageEventCallback.onWindowStageEvent(event, this.abilityWindowId),
        );
      });
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
      // Const capture for the closures below: `win` is a narrowed `let` —
      // closure narrowing holds only while it is never reassigned later.
      // A const makes that structural instead of accidental (issue #97 review).
      const mainWindow: window.Window = win;
      try {
        win.on("windowSizeChange", (size: window.Size) => {
          // Phase 3 (design.md D2/D3): wrap with typed interface and route through
          // this instance's per-window throttle (leading+trailing 16ms). The id is
          // abilityWindowId so a second UIAbility instance's resize is keyed (and
          // routed) to its own window, not the primary's.
          // Double-registration dedup: BridgeHost also registers onSizeChange for
          // the same windowId=0 — the throttle merges both sources automatically.
          const wrapped: WindowSizeEventWrap = { windowId: this.abilityWindowId, width: size.width, height: size.height };
          WindowManager.getInstance().throttledRectDispatch(this.abilityWindowId, wrapped, (w: object) => {
            this.forEachLifecycle((lifecycle) =>
              lifecycle.windowStageEventCallback.onWindowSizeChange(w),
            );
          }, 'size');
        });
        mainWindow.on("windowRectChange", (options: window.RectChangeOptions) => {
          // Phase 3 (design.md D3): RECOVER→menubar logic stays synchronous (UI logic,
          // not throttled — must respond immediately on fullscreen exit).
          if (options.reason === window.RectChangeReason.RECOVER) {
            // Per-window menubar key (windowKeyForId(0) === "main"), so a
            // spawned instance's RECOVER notifies its own menubar instead of
            // the primary's.
            const cb = getMenuDataCallback(windowKeyForId(this.abilityWindowId));
            cb?.onMenubarVisible?.(true);
          }
          // Phase 3 (design.md D2/D5): rect dispatch through this instance's
          // per-window throttle. Deep-copy rect fields (not system object ref)
          // per design.md D5.
          // Issue Eulogizethesun/tauri#97: attach the same moment's drawableRect
          // (sync getWindowProperties snapshot) so the Rust inner-rect cache
          // tracks the system-defined inner value — omitted when unreadable.
          const wrapped: WindowRectEventWrap = {
            windowId: this.abilityWindowId,
            reason: options.reason,
            rect: {
              left: options.rect.left,
              top: options.rect.top,
              width: options.rect.width,
              height: options.rect.height,
            },
            drawable: WindowManager.readDrawableRect(mainWindow),
          };
          WindowManager.getInstance().throttledRectDispatch(this.abilityWindowId, wrapped, (w: object) => {
            this.forEachLifecycle((lifecycle) =>
              lifecycle.windowStageEventCallback.onWindowRectChange(w),
            );
          }, 'rect');
        });
        win.on("avoidAreaChange", (options: window.AvoidAreaOptions) => {
          this.forEachLifecycle((lifecycle) =>
            lifecycle.windowStageEventCallback.onAvoidAreaChange(options, this.abilityWindowId),
          );
        });
        win.on("keyboardHeightChange", (height) => {
          this.forEachLifecycle((lifecycle) =>
            lifecycle.keyboardEventCallback.onKeyboardHeightChange(height, this.abilityWindowId),
          );
        });
        // Back-propagate system window state into the tao mirror flags
        // (legacy issue 5.3): maximize/minimize/fullscreen/float state changes
        // are queued through the notifyWindowStatus NAPI entry, and after the
        // runtime-wry drain they are routed to the matching tao Window by its
        // real windowId to update the mirror flags. API 11+; silently degrades
        // when unsupported (no worse than before). See the tauri repository's
        // doc/OHOS窗口遗留问题.md (legacy window issues) for details.
        try {
          win.on("windowStatusChange", (statusType: window.WindowStatusType) => {
            const nativeModule: Module | undefined = AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
            if (nativeModule && typeof nativeModule.notifyWindowStatus === 'function') {
              // Carries abilityWindowId (design.md D3): with multiple
              // UIAbilities the event routes by the instance's real windowId;
              // the first instance is 0, matching the legacy single-instance
              // behavior. runtime-wry routes to the matching tao Window by
              // tao window_id to update its mirror flags.
              nativeModule.notifyWindowStatus(this.abilityWindowId, statusType);
            }
          });
          // Seed the initial state (official updateWindowInfo pattern) so
          // state that predates the subscription is not missed.
          const initialStatus = win.getWindowStatus();
          const nativeModule: Module | undefined = AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
          if (nativeModule && typeof nativeModule.notifyWindowStatus === 'function') {
            nativeModule.notifyWindowStatus(this.abilityWindowId, initialStatus);
          }
        } catch (e) {
          hilog.warn(
            DOMAIN,
            "NativeAbility",
            "windowStatusChange registration failed: %{public}s",
            String(e),
          );
        }

        // Multi-display layout backfill (issue Eulogizethesun/tauri#106): the
        // Rust-side C API OH_NativeDisplayManager_CreateAllDisplays enumerates
        // the display list, but its DisplayInfo struct has no x/y — positions
        // can only come from ArkTS Display.x/y (API 19+; on lower versions
        // undefined → 0, same as before the fix). Push the full layout here
        // and listen for add/remove/change to refresh on hot-plug: hot-plugging
        // an external monitor fires add/remove; change fires on attribute
        // changes (resolution/orientation/fold). getAllDisplays is API 12+.
        this.pushDisplayLayout();
        try {
          this.displayAddListener = (displayId: number): void =>
            this.onDisplayLayoutEvent("add", displayId);
          this.displayRemoveListener = (displayId: number): void =>
            this.onDisplayLayoutEvent("remove", displayId);
          this.displayChangeListener = (displayId: number): void =>
            this.onDisplayLayoutEvent("change", displayId);
          display.on("add", this.displayAddListener);
          display.on("remove", this.displayRemoveListener);
          display.on("change", this.displayChangeListener);
        } catch (e) {
          hilog.warn(
            DOMAIN,
            "NativeAbility",
            "display.on(add/remove/change) registration failed: %{public}s",
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

    if (this.defaultPage) {
      try {
        await this.loadWindowStageContent(windowStage);
      } catch (e) {
        hilog.error(
          DOMAIN,
          "NativeAbility",
          "loadWindowStageContent failed: %{public}s",
          String(e),
        );
      }
    }

    // Review R13 (issue Eulogizethesun/tauri#97 follow-up): seed the Rust rect
    // caches right after content load. The windowRectChange registrations above
    // run BEFORE loadContent, where drawableRect is officially unreadable
    // (在 Stage 模型下需在 loadContent()/setUIContent() 之后获取) — so between
    // stage create and the first system rect event, inner_size()/
    // inner_position() would return the fallback. One synthetic wrap through
    // the SAME throttled dispatch path populates window_rects+inner_rects as a
    // pair (pair-in/pair-out) and also seeds tao's LAST_DISPATCHED_RECTS;
    // reason is UNDEFINED (nothing consumes ContentRect.reason on this path)
    // and readWindowRectSnapshot refuses half pairs, so a failed read simply
    // keeps the existing fallback.
    try {
      const seedWindow = await windowStage.getMainWindow();
      const snapshot = WindowManager.readWindowRectSnapshot(seedWindow);
      if (snapshot) {
        const wrapped: WindowRectEventWrap = {
          windowId: this.abilityWindowId,
          reason: window.RectChangeReason.UNDEFINED,
          rect: snapshot.rect,
          drawable: snapshot.drawable,
        };
        WindowManager.getInstance().throttledRectDispatch(
          this.abilityWindowId,
          wrapped,
          (w: object) => {
            this.forEachLifecycle((lifecycle) =>
              lifecycle.windowStageEventCallback.onWindowRectChange(w),
            );
          },
          "rect",
        );
        // Seed THIS instance's window id (spawned instances seed their own
        // rect, not the primary's window 0).
        hilog.info(DOMAIN, "NativeAbility", "rect cache seeded post-load (windowId=%{public}d)", this.abilityWindowId);
      }
    } catch (e) {
      hilog.warn(DOMAIN, "NativeAbility", "rect cache seed failed: %{public}s", String(e));
    }

    // Transparent window background/container color is applied in
    // DefaultXComponent.aboutToAppear (window fully ready there). The transparent
    // flag is stored in WindowManager.registerUIAbilityStage and applied via
    // WindowManager.applyTransparentBackground(windowId) in aboutToAppear.

    // Menu/tray wiring is skipped for a joined instance (D12): several of the
    // registrations inside are process-global single slots
    // (setPredefinedActionExecutor, primaryModule.onMenuRequest) — a spawned
    // instance taking them would strip the primary's webview controller from
    // tray Copy/Cut/Paste actions and retarget its menubar popups. Per-window
    // menu support for spawned windows lands with the tray/menu phase
    // (design.md Phase 5); the primary's menu behavior must stay intact while
    // a spawned window exists.
    if (!this.joinedExistingSession) {
      try {
        this.setupMenuPopup(windowStage);
      } catch (menuErr) {
        console.error(`[Menu] setupMenuPopup threw: ${menuErr}`);
      }
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

  // issue Eulogizethesun/tauri#106: display is a process-level module and
  // the listeners strongly capture this instance; keep the references and
  // unregister them in onWindowStageDestroy, otherwise repeated stage
  // lifecycles accumulate leaked listeners (unlike the windowStage/window
  // event sources, which die with the stage). add/remove fire on external
  // monitor hot-plug, change on attribute changes.
  private displayAddListener?: (displayId: number) => void;
  private displayRemoveListener?: (displayId: number) => void;
  private displayChangeListener?: (displayId: number) => void;

  // Shared display-event handler: log the event (with the display id the
  // callback reports) and re-push the layout — the positions of every display
  // can change when one is added/removed/resized, so always push the full list.
  private onDisplayLayoutEvent(type: string, displayId: number): void {
    hilog.info(
      DOMAIN,
      "NativeAbility",
      "display on(%s) id=%{public}d — refresh layout",
      type,
      displayId,
    );
    this.pushDisplayLayout();
  }

  // Multi-display layout push (issue Eulogizethesun/tauri#106): push the full
  // id/position list from getAllDisplays to Rust (set_display_layout NAPI).
  // Positions come from Display.x/y (API 19+; on lower versions undefined → 0,
  // no worse than before the fix). The Rust side overlays it onto the C API
  // CreateAllDisplays display list (the C struct has no x/y fields).
  private pushDisplayLayout(): void {
    try {
      display
        .getAllDisplays()
        .then((displays: Array<display.Display>) => {
          const nativeModule: Module | undefined =
            AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
          if (!nativeModule || typeof nativeModule.setDisplayLayout !== "function") {
            return;
          }
          const layout: Array<Array<number>> = [];
          for (const d of displays) {
            layout.push([d.id, d.x ?? 0, d.y ?? 0]);
          }
          nativeModule.setDisplayLayout(JSON.stringify(layout));
        })
        .catch((err: ESObject) => {
          hilog.warn(DOMAIN, "NativeAbility", "getAllDisplays rejected: %{public}s", String(err));
        });
    } catch (e) {
      hilog.warn(DOMAIN, "NativeAbility", "pushDisplayLayout failed: %{public}s", String(e));
    }
  }

  onWindowStageDestroy(): void | Promise<void> {
    // D4b: a duplicate primary never registered a stage — its destroy must not
    // unregister the primary's id-0 entry nor fire its lifecycle callbacks.
    if (this.isDuplicatePrimary) {
      hilog.warn(DOMAIN, 'NativeAbility', 'onWindowStageDestroy skipped: duplicate primary (D4b)');
      return;
    }
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onWindowStageDestroy(this.abilityWindowId));
    if (this.displayAddListener) {
      try {
        display.off("add", this.displayAddListener);
      } catch (e) {
        hilog.warn(DOMAIN, "NativeAbility", "display.off(add) failed: %{public}s", String(e));
      }
      this.displayAddListener = undefined;
    }
    if (this.displayRemoveListener) {
      try {
        display.off("remove", this.displayRemoveListener);
      } catch (e) {
        hilog.warn(DOMAIN, "NativeAbility", "display.off(remove) failed: %{public}s", String(e));
      }
      this.displayRemoveListener = undefined;
    }
    if (this.displayChangeListener) {
      try {
        display.off("change", this.displayChangeListener);
      } catch (e) {
        hilog.warn(DOMAIN, "NativeAbility", "display.off(change) failed: %{public}s", String(e));
      }
      this.displayChangeListener = undefined;
    }
    try {
      // Mirror of registerUIAbilityStage (HC-10): must unregister THIS
      // instance's id — a hardcoded 0 would wipe the primary instance's
      // stage entry when a spawned instance is destroyed.
      WindowManager.getInstance().unregisterUIAbilityStage(this.abilityWindowId);
    } catch (e) {
      hilog.error(
        DOMAIN,
        "NativeAbility",
        "onWindowStageDestroy cleanup failed: %{public}s",
        String(e),
      );
    }
    // Joined instance (D12): the shared session's window-stage context stays
    // with the primary — nothing to clear or notify here.
    if (this.bridgeSessionId && !this.joinedExistingSession) {
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
      this.forEachLifecycle((lifecycle) => lifecycle.environmentCallback.onMemoryLevel(level, this.abilityWindowId));
      await this.notifyBridgeLifecycle({
        kind: "memory-level",
        payload: new BridgeMemoryLevelLifecyclePayload(level),
      });
    });
  }

  /**
   * PC/2in1 pre-close interception (issue Eulogizethesun/tauri#103).
   *
   * Fired BEFORE any teardown when the app is closed via the window close
   * button, taskbar shortcut ("退出"/"关闭所有窗口") or tray exit — the only
   * point where a close is still cancellable (onDestroy returns void and the
   * process dies ~12ms later, so prevent_exit() there is cosmetic by design).
   * Requires ohos.permission.PREPARE_APP_TERMINATE (normal, system_grant)
   * declared in the app's module.json5. API 15+ (HarmonyOS 5.0.3+)
   * interface: on older systems the framework never invokes this callback
   * (silent no-op — the default destroy chain runs un-intercepted). On
   * API 15-18 it only executes on PC/2-in-1 devices (Tablet also from
   * API 19), never on Phone.
   *
   * Asks every Rust lifecycle SYNCHRONOUSLY (same inline dispatch pattern as
   * the onAbilityDestroy call in onDestroy): the tao event loop forwards the
   * probe as an ExitRequested dispatch where tauri's prevent_exit() lands —
   * this is the wiring that makes prevent_exit genuinely stop
   * system-initiated exits instead of firing into an unstoppable teardown.
   *
   * @returns true to CANCEL this termination (app keeps running),
   *          false to allow it (the normal onBackground→onDestroy chain
   *          follows).
   */
  async onPrepareToTerminateAsync(): Promise<boolean> {
    // Only the primary instance's termination ends the app — ask Rust for the
    // app-level ExitRequested/confirm flow here. A spawned instance's close
    // only destroys that window (the app keeps running), so it must NOT reach
    // the app-level probe: tauri-runtime-wry's probe arm marks its process-wide
    // exit_state dedup flag when a probe is allowed through, and a spawned
    // instance's probe would burn that flag and silently neuter every later
    // prevent_exit() (observed 2026-10-08: suite-closed spawned windows
    // consumed the flag, then the primary's ✕ went straight through with
    // Exit Confirm ON).
    if (this.abilityWindowId !== 0) {
      hilog.info(
        DOMAIN,
        "NativeAbility",
        "onPrepareToTerminateAsync: spawned instance (id=%{public}d) — allow, app keeps running",
        this.abilityWindowId,
      );
      return false;
    }
    hilog.info(DOMAIN, "NativeAbility", "onPrepareToTerminateAsync: asking Rust lifecycles");
    let prevent = false;
    this.forEachLifecycle((lifecycle) => {
      try {
        if (lifecycle.windowStageEventCallback.onPrepareToTerminate()) {
          prevent = true;
        }
      } catch (e) {
        // One module's probe failing must not block termination — treat that
        // module as "allow" and keep asking the others.
        hilog.error(
          DOMAIN,
          "NativeAbility",
          "onPrepareToTerminate (module probe) failed: %{public}s",
          String(e),
        );
      }
    });
    hilog.info(
      DOMAIN,
      "NativeAbility",
      "onPrepareToTerminateAsync: prevent=%{public}s",
      String(prevent),
    );
    return prevent;
  }

  onDestroy(): Promise<void> {
    this.acceptingLifecycle = false;
    this.abilityGeneration += 1;
    this.windowStageGeneration += 1;
    this.detachWindowListeners();
    if (this.bridgeSessionId && !this.joinedExistingSession) {
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
    // For a joined instance (D12) the windowId-bearing dispatch is the whole
    // teardown on the ArkTS side: Rust removes only this instance's session
    // partition (bridge/mod.rs AbilityDestroyed{window_id}) while the shared
    // session, its module bridges and the primary's exit chain stay intact —
    // a spawned window closing must NOT terminate the process (OQ4).
    // D4b: a plain-relaunch duplicate resolving to id 0 must not dispatch at
    // all — onAbilityDestroy(0) runs the primary exit chain (Event::Destroy →
    // process teardown) and would kill the live app it was meant to restore.
    if (this.isDuplicatePrimary) {
      hilog.warn(DOMAIN, 'NativeAbility', 'onDestroy: duplicate primary (D4b) — skipping onAbilityDestroy dispatch (id 0 would fire the primary exit chain)');
      return Promise.resolve();
    }
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onAbilityDestroy(this.abilityWindowId));
    if (this.joinedExistingSession) {
      return Promise.resolve();
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
    // D4b: a plain-relaunch duplicate terminated in onCreate; its want was
    // already forwarded there. Under "standard" onNewWant should not fire for
    // it at all — this guard covers a racing delivery before teardown lands.
    if (this.isDuplicatePrimary) {
      hilog.warn(DOMAIN, 'NativeAbility', 'onNewWant skipped: duplicate primary (D4b)');
      return;
    }
    const uri = want.uri ?? '';
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
    // cold-start value. The per-instance field feeds this instance's
    // LocalStorage (D9); the AppStorage key stays a primary-instance-only
    // back-compat channel so a spawned instance's relaunch cannot overwrite
    // the primary's latest URI.
    this.latestWantUri = uri;
    if (this.abilityWindowId === 0) {
      AppStorage.setOrCreate("wantUri", uri);
    }

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
    this.forEachLifecycle((lifecycle) => lifecycle.windowStageEventCallback.onNewWant({ uri, parametersJson, isContinuation }, this.abilityWindowId));
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
        lifecycle.environmentCallback.onConfigurationUpdated(newConfig, this.abilityWindowId),
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
        // Void-returning dispatcher: the Rust callback (lifecycle.rs
        // on_ability_save_state: Function<'a, (), ()>) forwards SaveState to
        // the app and returns nothing — the generated demo bindings agree
        // (Index.d.ts: `onAbilitySaveState: () => void`). Module-level saved
        // state is therefore always empty today; the explicit "" keeps
        // `new String(...)` below from wrapping "undefined".
        runtime.lifecycle.windowStageEventCallback.onAbilitySaveState(this.abilityWindowId);
        stateMap[runtime.moduleName] = "";
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
}
