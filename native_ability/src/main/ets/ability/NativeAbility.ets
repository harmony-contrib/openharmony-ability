import {
  AbilityConstant,
  Configuration,
  ConfigurationConstant,
  UIAbility,
  Want,
} from "@kit.AbilityKit";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import display from "@ohos.display";
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
  NormalizedConfiguration,
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
  initialConfiguration: NormalizedConfiguration;
}

export class NativeAbility extends UIAbility {
  public moduleName: string | string[] = "";
  public defaultPage: boolean = true;
  public loadMode: "async" | "sync" = "async";
  public independentWindowAbility?: string;
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
  private observedWindowStage?: window.WindowStage;

  // Kept as an arrow-function field so detachWindowListeners can pass the exact same
  // reference to windowStage.off("windowStageEvent", ...).
  private readonly onWindowStageEvent = (event: window.WindowStageEventType): void => {
    if (!this.acceptingLifecycle || this.observedWindowStage === undefined) {
      return;
    }
    void this.enqueueLifecycleOperation("window-stage-event", async (): Promise<void> => {
      // windowId threading (design.md D3): the stage event carries THIS
      // instance's window id so the Rust registry routes the mirror update to
      // this window's partition. (Modifier clearing on INACTIVE/HIDDEN — the
      // old core-side #111 clearAllTrackedModifiers — moved with the
      // accelerator state into the menu plugin: WindowManager's per-window
      // focus tracking now fires onWindowFocusLost → resetAcceleratorModifiers,
      // which covers the same INACTIVE/HIDDEN window cases per window.)
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onWindowStageEvent(event, this.abilityWindowId),
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
          const error = e as Error;
          hilog.error(
            DOMAIN,
            "NativeAbility",
            "Lifecycle callback error: %{public}s",
            `${String(e)}\n${error.stack ?? ""}`,
          );
        }
      }
      return;
    }
    for (const lifecycle of ProcessInitializer.getLifecycles().values()) {
      try {
        handler(lifecycle);
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
    // Window identity (design.md D3): tao pre-allocates the id and delivers it
    // as an all-string want parameter; the first (process-launched) instance
    // has no parameter and stays 0. Number("") is 0 and Number(undefined) is
    // NaN, so `|| 0` keeps both degenerate shapes at the primary id.
    this.abilityWindowId = Number(want.parameters?.["tauri_window_id"] ?? 0) || 0;
    this.abilityTransparent = want.parameters?.["tauri_transparent"] === "true";
    hilog.info(
      DOMAIN,
      "NativeAbility",
      "onCreate - windowId=%{public}d transparent=%{public}s (from want.parameters)",
      this.abilityWindowId,
      String(this.abilityTransparent),
    );

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
      hilog.warn(
        DOMAIN,
        "NativeAbility",
        "D4b duplicate-primary guard: relaunch (no tauri_window_id) while primary lives — uri=%{public}s, forwarding + raising + terminating",
        want.uri ?? "",
      );
      // Forward: seed the primary's INITIAL_WANT_URI[0] slot through the shared
      // lifecycle callback. The Rust side of onAbilityCreateWithWant only
      // writes the per-window URI store (store_initial_want_uri) — no session
      // partition is opened — so the primary's next deep-link getCurrent
      // (get_current_for_window, lazy-take) drains this relaunch URI.
      // Continuation faithfulness: pass the real launchReason so a
      // continuation relaunch at least preserves its payload (NG5 defers
      // multi-instance continuation handling).
      const relaunchIsContinuation =
        launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION;
      if (want.uri && want.uri.length > 0) {
        this.forEachLifecycle((lifecycle) =>
          lifecycle.windowStageEventCallback.onAbilityCreateWithWant(
            {
              uri: want.uri ?? "",
              isContinuation: relaunchIsContinuation,
              parametersJson: JSON.stringify(want.parameters ?? {}),
            },
            0,
          ),
        );
      }
      // Raise the primary window (restore from minimize, or raise to top —
      // WindowManager.showWindowMethod handles both for main windows).
      // #219: showWindowMethod is async now -- this duplicate-termination
      // caller is fire-and-forget; keep the rejection handled so onNewWant
      // continues into terminateSelf even if the raise fails.
      WindowManager.getInstance()
        .showWindowMethod(0)
        .catch((err: ESObject) => {
          hilog.warn(
            DOMAIN,
            "NativeAbility",
            "duplicate-primary raise failed: %{public}s",
            String(err),
          );
        });
      // Terminate this duplicate. Async — later callbacks are gated on
      // isDuplicatePrimary in case the system still delivers them.
      (this.context as common.UIAbilityContext).terminateSelf().catch((e: ESObject) => {
        hilog.error(DOMAIN, "NativeAbility", "D4b terminateSelf failed: %{public}s", String(e));
      });
      return;
    }
    // This instance's want URIs (design.md D9): delivered per-instance via the
    // loadWindowStageContent LocalStorage. The AppStorage keys below remain a
    // primary-instance-only back-compat channel for the legacy DeepLinkPlugin
    // bridge path ("initialWantUri"/"wantUri"); a spawned instance must NOT
    // overwrite them, or the primary's deep-link reads would see the spawned
    // instance's launch URI.
    this.initialWantUri = want.uri ?? "";
    this.latestWantUri = want.uri ?? "";
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
    // and the primary-module AppStorage publish consumed by SubWindowPage / the
    // windowStatusChange fan-in below. Idempotent for subsequent Ability instances;
    // module loading itself is re-done transactionally below via NativeModuleLoader.
    await ProcessInitializer.initialize(context, this.moduleName, this.loadMode, want);
    this.assertInitializationActive(generation);
    WindowManager.getInstance().setIndependentWindowAbility(this.independentWindowAbility);

    // Transactional duplicate-create re-init (queue skeleton): if this
    // instance already owns a live session — a duplicated platform create
    // (recovery restart / repeated ability-create op) — replace it wholesale
    // before any new state is built: window stage, lifecycle notify, renders,
    // bridges, then the session itself. Gated on `!this.joinedExistingSession`:
    // a D12 joined instance holds the SHARED primary session id in
    // bridgeSessionId and must never tear that session down here — its
    // re-initialization just re-joins below.
    const previousSessionId = this.bridgeSessionId;
    if (previousSessionId && !this.joinedExistingSession) {
      BridgeHostRegistry.beginClosing(previousSessionId);
      try {
        await this.destroyWindowStageIfActive();
        await this.notifyBridgeLifecycle({
          kind: "ability-destroy",
          payload: new BridgeEmptyLifecyclePayload(),
        });
        this.forEachLifecycle((lifecycle) =>
          lifecycle.windowStageEventCallback.onAbilityDestroy(this.abilityWindowId),
        );
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

    // 2. Create the bridge session for this Ability instance. Join model (D12):
    //    when every requested module already belongs to one live session — i.e.
    //    this is a spawned instance reusing the process's modules — prepare()
    //    returns that shared session instead of creating a new one. The joined
    //    instance keeps the session id for its page's LocalStorage (D6) and for
    //    teardown gating, but performs none of the session-mutating setup below.
    //    Prepare hosts without activating `ability` plugins. Their onInstall
    //    hooks are allowed to call Rust synchronously, so module.init and both
    //    sinks must exist first.
    const joinedSessionId = BridgeHostRegistry.activeSessionForModules(requestedModules);
    const sessionId = BridgeHostRegistry.prepare(requestedModules, context, this.bridgePlugins);
    this.bridgeSessionId = sessionId;
    this.joinedExistingSession = joinedSessionId !== undefined && joinedSessionId === sessionId;
    // AppStorage readers: the demo pages (Index/SubWindowPage load outside
    // MainPage and feed DefaultXComponent's bridgeSessionId @Prop from here).
    // MainPage itself consumes the per-instance LocalStorage write in
    // loadWindowStageContent instead (design.md D6).
    hilog.info(
      DOMAIN,
      "NativeAbility",
      "Bridge session created: %{public}s (joined=%{public}s)",
      sessionId,
      String(this.joinedExistingSession),
    );

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
        lifecycle.windowStageEventCallback.onAbilityCreateWithWant(
          {
            uri: want.uri ?? "",
            isContinuation,
            parametersJson: JSON.stringify(want.parameters ?? {}),
          },
          this.abilityWindowId,
        ),
      );
      // The joined session is the primary's, already fully initialized — safe
      // to publish immediately (unlike the create path below, which publishes
      // only after every module attached).
      this.updateAppStorage("bridgeSessionId", sessionId);
      return;
    }

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
        const initContext = this.createInitContext(loaded.moduleName);
        const initialConfiguration =
          initContext.configuration ?? ProcessInitializer.normalizeConfiguration(context?.config);
        const lifecycle = loaded.module.init(
          this.createBridgeBindings(sessionId, loaded.moduleName),
          bridgeOwner,
          initContext,
        );
        // Publish the lifecycle bundle to the process-level store (D12) so a
        // later joined instance can fire the shared callbacks with its own
        // windowId once this module is owned by the live session.
        ProcessInitializer.rememberLifecycle(loaded.moduleName, lifecycle);
        const runtime: NativeModuleRuntime = {
          moduleName: loaded.moduleName,
          module: loaded.module,
          lifecycle,
          bridgeOwner,
          initialConfiguration,
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
      // activateAbility loop below. Every call threads this instance's windowId
      // (design.md D3/D8) so the Rust registry opens the session partition for
      // THIS window — the single-instance form omits the argument and would
      // key every spawned instance onto the primary's window 0.
      for (const runtime of initializedRuntimes) {
        const restoredState = restoredStateMap[runtime.moduleName] ?? fallbackState;
        try {
          runtime.lifecycle.windowStageEventCallback.onAbilityCreate(
            restoredState,
            this.abilityWindowId,
          );
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
          runtime.lifecycle.windowStageEventCallback.onAbilityCreateWithWant(
            {
              uri: want.uri ?? "",
              isContinuation,
              parametersJson: JSON.stringify(want.parameters ?? {}),
            },
            this.abilityWindowId,
          );
        } catch (e) {
          hilog.error(
            DOMAIN,
            "NativeAbility",
            "onAbilityCreateWithWant failed for %{public}s: %{public}s",
            runtime.moduleName,
            String(e),
          );
        }
        try {
          runtime.lifecycle.environmentCallback.onConfigurationUpdated(
            runtime.initialConfiguration,
          );
        } catch (e) {
          hilog.error(
            DOMAIN,
            "NativeAbility",
            "initial onConfigurationUpdated failed for %{public}s: %{public}s",
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
      // Fail-fast collapse (issue #87 minor-3): continuing with a half-initialized
      // bridge leaves every later call failing with a confusing "not installed";
      // the full teardown — destroy dispatch, bridge release, session dispose —
      // feeds Event::Destroy to the modules that DID initialize so Rust's
      // run_loop exits normally instead of dangling half-initialized.
      BridgeHostRegistry.beginClosing(sessionId);
      for (const runtime of initializedRuntimes.slice().reverse()) {
        try {
          runtime.lifecycle.windowStageEventCallback.onAbilityDestroy(this.abilityWindowId);
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

    // #181: cold-start configuration/theme injection (committer issue #181).
    // The system only fires onConfigurationUpdate on CHANGE, so on a cold
    // start in dark mode the Rust-side app.configuration (and therefore tao's
    // theme()) kept its default Light value until the first real change.
    // acceptingLifecycle is true (set in onCreate before the queue op), so
    // the guard at the top of onConfigurationUpdate passes: synthesize a
    // Configuration from the resource manager and feed it through the SAME
    // entry point the system callback uses -- the Rust on_configuration_updated
    // closure writes app.configuration and dispatches Event::ConfigChanged
    // before any window queries the theme. Joined-instance early-return path
    // above does NOT inject (bridge closure registration is equally restricted
    // there -- known limitation, same boundary as the pre-existing
    // event-forwarding face). Nested try/catch: a failure here must never fail
    // the session op -- the app simply keeps the pre-injection default, as
    // before this change.
    try {
      const abilityContext = this.context as common.UIAbilityContext;
      const resCfg = abilityContext.resourceManager.getConfigurationSync();
      const injectedConfig: Configuration = {
        // resmgr direct reads (6 keys): locale -> language, colorMode,
        // direction, screenDensity, mcc, mnc. resmgr types mcc/mnc as number
        // while the app Configuration and the Rust closure read strings --
        // String() them to prevent a type mismatch on the bridge.
        // resmgr and ConfigurationConstant declare distinct-but-value-equal
        // numeric enums for colorMode (DARK=0/LIGHT=1) and screenDensity
        // (SDPI=120...XXXLDPI=640), and direction (VERTICAL=0/HORIZONTAL=1):
        // hop through number to re-key the value into the app-side enum type
        // the app Configuration declares.
        language: resCfg.locale,
        colorMode: resCfg.colorMode as number as ConfigurationConstant.ColorMode,
        direction: resCfg.direction as number as ConfigurationConstant.Direction,
        screenDensity: resCfg.screenDensity as number as ConfigurationConstant.ScreenDensity,
        // mcc/mnc are absent when the host does not report them -- String()
        // would inject the literal "undefined" into the app Configuration.
        // Guard to the empty string (the neutral "unknown" form).
        mcc: typeof resCfg.mcc === "number" ? String(resCfg.mcc) : "",
        mnc: typeof resCfg.mnc === "number" ? String(resCfg.mnc) : "",
        // SDK 20 resmgr exposes no such fields -- neutral defaults (sources:
        // app-side defaults the system would report for a fresh UIAbility).
        fontSizeScale: 1.0,
        fontWeightScale: 1.0,
        hasPointerDevice: true,
        displayId: 0,
      };
      this.onConfigurationUpdate(injectedConfig);
      hilog.debug(
        DOMAIN,
        "NativeAbility",
        "#181 config injected: colorMode=%{public}d language=%{public}s direction=%{public}d",
        injectedConfig.colorMode,
        injectedConfig.language,
        injectedConfig.direction,
      );
    } catch (e) {
      hilog.warn(
        DOMAIN,
        "NativeAbility",
        "#181 config injection failed (theme stays default): %{public}s",
        String(e),
      );
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

  // Delegates to ProcessInitializer so the base main-line context (basePath/prefPath/
  // locales/resourceManager/configuration) has a single construction site.
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
        ? // windowId threading (design.md D8): only this session-owning instance
          // registers the sink, and its ui-context events describe its own
          // DefaultXComponent attachment — so from_arkts receives the owner
          // instance's window id, never the joined instance's.
          (kind: string): void => module.onBridgeLifecycle!(kind, this.abilityWindowId)
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

  /**
   * Loads application content inside the framework's WindowStage lifecycle
   * transaction. Override this instead of starting detached Promise work from
   * the platform callback.
   */
  protected async loadWindowStageContent(windowStage: window.WindowStage): Promise<void> {
    // Per-instance LocalStorage (design.md D3/D6/D9): MainPage and
    // DefaultXComponent read these via @LocalStorageProp — a spawned instance
    // receives its own window id, the shared bridge session id (D12 join) and
    // its own want URIs, never the process-global AppStorage values the
    // primary instance published. Same pattern as WindowManager.createSubWindow
    // for sub-windows. HIS's defaultPage gate is folded in: an Ability that
    // opts out (defaultPage=false) manages its own window content.
    if (this.defaultPage) {
      const storage = new LocalStorage();
      storage.setOrCreate("windowId", this.abilityWindowId);
      storage.setOrCreate("bridgeSessionId", this.bridgeSessionId);
      storage.setOrCreate("initialWantUri", this.initialWantUri);
      storage.setOrCreate("wantUri", this.latestWantUri);
      await windowStage.loadContentByName(Entry.RouteName, storage);
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
    // D4b: a plain-relaunch duplicate (terminated in onCreate) must not
    // register a stage — registerUIAbilityStage(0) would overwrite the live
    // primary's entry — nor mount a window. terminateSelf is async, so the
    // system may still deliver this callback before teardown lands. The
    // acceptingLifecycle gate below also blocks it (onCreate returned before
    // the flag was set); this guard is the explicit, logged defense.
    if (this.isDuplicatePrimary) {
      hilog.warn(DOMAIN, "NativeAbility", "onWindowStageCreate skipped: duplicate primary (D4b)");
      return;
    }
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
      // D12 note: a joined instance has an empty moduleRuntimes — the loop is a
      // no-op, which is exactly the contract: the shared session's stage
      // belongs to the primary instance, and re-injecting this instance's
      // stage would re-target every shared plugin at the wrong window (R11
      // cross-talk).
      const stageAssignments: Promise<void>[] = [];
      for (const runtime of this.moduleRuntimes) {
        stageAssignments.push(
          BridgeHostRegistry.setWindowStage(sessionId, runtime.moduleName, windowStage),
        );
      }
      await Promise.all(stageAssignments);
      this.assertWindowStageActive(generation);
      // windowId threading (design.md D3): every callback carries THIS
      // instance's window id so the Rust-side registry opens the session
      // partition for this window (bridge/mod.rs dispatch_lifecycle →
      // WindowStageCreated). For a joined instance forEachLifecycle falls
      // through to ProcessInitializer.getLifecycles() (dual source) and fires
      // the shared modules' NAPI callbacks with this window id.
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onWindowStageCreate(this.abilityWindowId),
      );
      this.windowStageActive = true;
      // ArkTS-host delivery: notifyBridgeLifecycle iterates this.moduleRuntimes,
      // so a joined instance (empty runtimes) delivers nothing — only the NAPI
      // fan above fires, which is the D12 contract.
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
      // component attaches. windowId/transparent are re-threaded from this instance
      // (design.md D3): the hardcoded 0/false form would key a spawned instance's
      // stage onto the primary's window.
      WindowManager.getInstance().registerUIAbilityStage(
        this.abilityWindowId,
        windowStage,
        this.context,
        this.abilityTransparent,
      );
      hilog.info(
        DOMAIN,
        "NativeAbility",
        "onWindowStageCreate: windowId=%{public}d transparent=%{public}s",
        this.abilityWindowId,
        String(this.abilityTransparent),
      );

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
      // Focus fan-in (HIS #93): WindowManager.registerFocusTracking emits the
      // wrapped {windowId, focused} per window — single-arg object form, matching
      // the Rust closure contract (on_window_focus_change reads the object).
      WindowManager.getInstance().registerFocusChangeCallback((wrapped: WindowFocusEventWrap) => {
        this.forEachLifecycle((lifecycle) =>
          lifecycle.windowStageEventCallback.onWindowFocusChange(wrapped),
        );
      });
      // Sub-window avoid-area fan-in (HIS #93): WindowManager's sub-window path
      // wraps {windowId, type, area}. Re-shaped to the Rust callback contract
      // (make_on_avoid_area_change in crates/ability/src/lifecycle.rs): the raw
      // {type, area} object as arg 1 and the windowId as arg 2 — the single-arg
      // wrap form degrades windowId to 0 and would cross-write the primary's
      // avoid_areas cache. Per-window avoid areas remain primary-window-scoped
      // in Rust (known limitation): a sub-window (windowId>0) delivery reaches
      // this fan but the Rust closure drops it at its window_id==0 gate.
      WindowManager.getInstance().registerAvoidAreaChangeCallback(
        (wrapped: WindowAvoidAreaEventWrap) => {
          this.forEachLifecycle((lifecycle) =>
            lifecycle.windowStageEventCallback.onAvoidAreaChange(
              { type: wrapped.type, area: wrapped.area },
              wrapped.windowId,
            ),
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
            const wrapped: WindowSizeEventWrap = {
              windowId: this.abilityWindowId,
              width: size.width,
              height: size.height,
            };
            WindowManager.getInstance().throttledRectDispatch(
              this.abilityWindowId,
              wrapped,
              (w: object) => {
                this.forEachLifecycle((lifecycle) =>
                  lifecycle.windowStageEventCallback.onWindowSizeChange(w),
                );
              },
              "size",
            );
          });
          mainWindow.on("windowRectChange", (options: window.RectChangeOptions) => {
            // Phase 3 (design.md D3): RECOVER→menubar logic stays synchronous (UI logic,
            // not throttled — must respond immediately on fullscreen exit). Delivery
            // goes through the menu plugin's registered port (MenuBarSlot seam):
            // core must not reach into the menu package's callback registry.
            if (options.reason === window.RectChangeReason.RECOVER) {
              // Per-instance window id (design.md D3): a spawned instance's
              // RECOVER notifies its own menubar, not the primary's.
              getMenuBarPort(mainWindow)?.onMenubarVisibility(this.abilityWindowId, true);
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
          });
          win.on("avoidAreaChange", (options: window.AvoidAreaOptions) => {
            // Rust callback contract (make_on_avoid_area_change,
            // crates/ability/src/lifecycle.rs): the raw system options object
            // as arg 1 + the windowId as arg 2. The wrap-based single-arg form
            // degrades the windowId to 0 (known limitation: avoid_areas stays
            // primary-window-scoped in Rust).
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
              const nativeModule: Module | undefined =
                AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
              if (nativeModule && typeof nativeModule.notifyWindowStatus === "function") {
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
            const nativeModule: Module | undefined =
              AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
            if (nativeModule && typeof nativeModule.notifyWindowStatus === "function") {
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

      // Transparent window background/container color is applied in
      // DefaultXComponent.aboutToAppear (window fully ready there). The transparent
      // flag is stored in WindowManager.registerUIAbilityStage and applied via
      // WindowManager.applyTransparentBackground(windowId) in aboutToAppear.
      try {
        this.setupDesktopFlag();
      } catch (menuErr) {
        hilog.error(DOMAIN, "NativeAbility", "setupDesktopFlag threw: %{public}s", String(menuErr));
      }

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
      this.assertWindowStageActive(generation);

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
          hilog.info(
            DOMAIN,
            "NativeAbility",
            "rect cache seeded post-load (windowId=%{public}d)",
            this.abilityWindowId,
          );
        }
      } catch (e) {
        hilog.warn(DOMAIN, "NativeAbility", "rect cache seed failed: %{public}s", String(e));
      }
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

  onWindowStageDestroy(): void {
    // D4b: a duplicate primary never registered a stage — its destroy must not
    // unregister the primary's id-0 entry nor fire its lifecycle callbacks.
    // (The acceptingLifecycle gate below also blocks it — onCreate returned
    // before the flag was set — this guard is the explicit, logged defense.)
    if (this.isDuplicatePrimary) {
      hilog.warn(DOMAIN, "NativeAbility", "onWindowStageDestroy skipped: duplicate primary (D4b)");
      return;
    }
    if (!this.acceptingLifecycle) {
      return;
    }
    this.windowStageGeneration += 1;
    this.detachWindowListeners();
    // Display listeners are process-global but instance-owned (issue
    // Eulogizethesun/tauri#106): unregister THIS instance's references so
    // repeated stage lifecycles don't accumulate leaks.
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
    // Dual-source fan (D12): a joined instance has empty moduleRuntimes, so
    // this falls through to ProcessInitializer.getLifecycles() and fires the
    // shared modules' NAPI callbacks with THIS instance's window id — Rust
    // closes this window's session partition. The windowId arg is required by
    // the merged callback contract (design.md D3).
    this.forEachLifecycle((lifecycle) =>
      lifecycle.windowStageEventCallback.onWindowStageDestroy(this.abilityWindowId),
    );
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
    // instead, which is what SubWindowPage's __openharmony_ability_is_desktop__
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

  onPrepareToTerminate(): boolean {
    if (!this.acceptingLifecycle || !this.windowStageActive) {
      return false;
    }
    // System shortcuts and dock close requests bypass windowWillClose. Defer
    // termination to the same native close handler so the app can prompt first.
    return WindowManager.getInstance().requestWindowClose(MAIN_WINDOW_ID);
  }

  onDestroy(): Promise<void> {
    this.acceptingLifecycle = false;
    this.abilityGeneration += 1;
    this.windowStageGeneration += 1;
    this.detachWindowListeners();
    // D12: a joined instance shares the primary's session — closing it here
    // would reject the live session's calls while the primary still runs.
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
    // windowId threading (design.md D3): the destroy dispatch carries THIS
    // instance's id so Rust closes this window's partition (a joined instance
    // destroying its window must not run the primary's exit chain).
    // For a joined instance (D12) the windowId-bearing dispatch is the whole
    // teardown on the ArkTS side: Rust removes only this instance's session
    // partition (bridge/mod.rs AbilityDestroyed{window_id}) while the shared
    // session, its module bridges and the primary's exit chain stay intact —
    // a spawned window closing must NOT terminate the process (OQ4).
    // D4b: a plain-relaunch duplicate resolving to id 0 must not dispatch at
    // all — onAbilityDestroy(0) runs the primary exit chain (Event::Destroy →
    // process teardown) and would kill the live app it was meant to restore.
    if (this.isDuplicatePrimary) {
      hilog.warn(
        DOMAIN,
        "NativeAbility",
        "onDestroy: duplicate primary (D4b) — skipping onAbilityDestroy dispatch (id 0 would fire the primary exit chain)",
      );
      return Promise.resolve();
    }
    this.forEachLifecycle((lifecycle) =>
      lifecycle.windowStageEventCallback.onAbilityDestroy(this.abilityWindowId),
    );
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
      // windowId threading (design.md D3): the new-want dispatch carries THIS
      // instance's id so the deep-link update lands in this window's want-URI
      // map (a spawned instance's relaunch must not overwrite the primary's).
      this.forEachLifecycle((lifecycle) =>
        lifecycle.windowStageEventCallback.onNewWant(
          { uri, parametersJson, isContinuation },
          this.abilityWindowId,
        ),
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
    const normalizedConfig = ProcessInitializer.normalizeConfiguration(
      newConfig,
      (this.context as common.UIAbilityContext)?.config,
    );
    void this.enqueueLifecycleOperation("configuration-updated", async (): Promise<void> => {
      this.forEachLifecycle((lifecycle) =>
        lifecycle.environmentCallback.onConfigurationUpdated(normalizedConfig),
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
        // (HIS's string-harvesting form — onAbilitySaveState() ?? "" — is not
        // portable onto this contract: the callback returns void, and its
        // windowId-less call form would compile against the merged type.)
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

  private updateAppStorage<T>(key: string, value: T): void {
    AppStorage.setOrCreate(key, value);
    AppStorage.set(key, value);
  }
}
