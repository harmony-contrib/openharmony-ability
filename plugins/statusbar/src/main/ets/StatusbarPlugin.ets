import { statusBarManager } from "@kit.DeskTopExtensionKit";
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  type AboutMetadataData,
  AsyncPluginBase,
  BridgeAcknowledgement,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  createPixelMapFromRgba,
  DOMAIN,
  expectBridgeRequestType,
  fillMenuItemAbilityName,
  getPredefinedActionExecutor,
  processMenuItemIcons,
  reRegisterStatusBarClickHandlers,
  setAbilityContext,
  setCurrentAbilityName,
  type PredefinedType,
  type StatusBarIconRgba,
} from "@ohos-rs/ability";

const ADD_REQUEST_TYPE = "ohos.statusbar.AddRequest";
const REMOVE_REQUEST_TYPE = "ohos.statusbar.RemoveRequest";
const UPDATE_ICON_REQUEST_TYPE = "ohos.statusbar.UpdateIconRequest";
const UPDATE_MENU_REQUEST_TYPE = "ohos.statusbar.UpdateMenuRequest";
const UPDATE_TIPS_REQUEST_TYPE = "ohos.statusbar.UpdateTipsRequest";
const PREDEFINED_REQUEST_TYPE = "ohos.statusbar.PredefinedRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.statusbar.Acknowledgement";

interface AddRequest {
  /** RGBA pixel data for the white variant of the icon. */
  whiteIcon?: Uint8Array;
  /** RGBA pixel data for the black variant of the icon. */
  blackIcon?: Uint8Array;
  /** Square icon edge length in pixels. */
  iconSize: number;
  /** Quick operation: ability launched on click. Flattened by Rust from StatusBarQuickOperation. */
  abilityName: string;
  title: string;
  height: number;
  moduleName?: string;
  loadingStatus?: boolean;
  /** Serialized `Vec<Vec<StatusBarMenuItem>>` JSON string for the right-click context menu. */
  menuJson?: string;
  /** Hover tooltip text (max 128 chars). */
  hoverTips?: string;
}

interface UpdateIconRequest {
  whiteIcon?: Uint8Array;
  blackIcon?: Uint8Array;
  iconSize: number;
}

interface UpdateMenuRequest {
  /** Serialized `Vec<Vec<StatusBarMenuItem>>` JSON string. */
  menuJson: string;
}

interface UpdateTipsRequest {
  tips: string;
}

interface PredefinedRequest {
  action: string;
  /** About-panel metadata; only read by the `about` action. */
  aboutMetadata?: AboutMetadataData;
}

/**
 * Status bar (system tray) bridge plugin for ArkTS.
 *
 * Routes status bar icon management from Rust consumers to the OHOS
 * `statusBarManager` API. Extracts the 5 statusbar methods from the legacy
 * `ArkHelper` object into a dedicated bridge plugin.
 *
 * Plugin ID: `ohos.statusbar`
 * Required contexts: ability (needs UIAbilityContext for statusBarManager calls)
 */
export class StatusbarPlugin extends AsyncPluginBase {
  readonly id = "ohos.statusbar";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Statusbar bridge session is no longer active");
    }

    if (action === "add") {
      const request = expectBridgeRequestType(payload, "ohos.statusbar", action, ADD_REQUEST_TYPE) as AddRequest;
      if (!Number.isInteger(request.iconSize) || request.iconSize <= 0) {
        throw new Error("add.iconSize must be a positive integer");
      }
      const abilityContext = context.abilityContext;

      // Inject the live UIAbilityContext into StatusBarUtils' module-level
      // globals. iconClickHandler (registered via reRegisterStatusBarClickHandlers
      // below) has no BridgeCallContext, so it reads these globals at event-firing
      // time to startAbility() and restore the app from background on tray click.
      // currentAbilityName is also set at NativeAbility.onCreate, but re-setting
      // here keeps the injection self-contained against ability re-creation
      // (set_title/set_visible/etc. all re-run `add`). See spec §7.2.
      setAbilityContext(abilityContext);
      setCurrentAbilityName(abilityContext.abilityInfo.name);

      // Build icons object from RGBA data
      const icons: ESObject = {};
      if (request.whiteIcon && request.whiteIcon.length > 0) {
        const pm = createPixelMapFromRgba(request.whiteIcon, request.iconSize);
        if (pm) icons.white = pm;
        hilog.info(DOMAIN, "StatusbarPlugin", "add: white PixelMap %{public}s", pm ? "OK" : "NULL");
      }
      if (request.blackIcon && request.blackIcon.length > 0) {
        const pm = createPixelMapFromRgba(request.blackIcon, request.iconSize);
        if (pm) icons.black = pm;
        hilog.info(DOMAIN, "StatusbarPlugin", "add: black PixelMap %{public}s", pm ? "OK" : "NULL");
      }
      if (Object.keys(icons).length === 0) {
        throw new Error("add: no valid icon data provided");
      }

      // Rust flattens StatusBarQuickOperation into top-level AddRequest fields
      // (abilityName/title/height/moduleName/loadingStatus) and serializes the
      // right-click context menu to menuJson (a JSON string). Rebuild the nested
      // shapes the OHOS statusBarManager.addToStatusBar API expects.
      //
      // IMPORTANT: use `??` (not `||`). An empty-string abilityName is the legacy
      // contract (ArkHelper.ets addToStatusBarWithRgba) meaning "no QuickOperation
      // panel — fire statusBarIconClick instead". `||` would treat "" as falsy
      // and substitute the main UIAbility name (e.g. "EntryAbility"), a singleton
      // already running; statusBarManager's getCurrentInstanceKey then throws
      // 16000078 "Multi-instance is not supported" → generic 401 "check param
      // error". `request.abilityName` arrives as a JS string from a Rust String
      // field (never null/undefined), so `??` only fills when it is genuinely
      // absent. See spec §7.5.
      const quickOperation: ESObject = {
        abilityName: request.abilityName ?? abilityContext.abilityInfo.name,
        title: request.title,
        height: request.height,
        moduleName: request.moduleName,
        loadingStatus: request.loadingStatus,
      };
      let statusBarGroupMenu: ESObject[][] = [];
      if (request.menuJson) {
        try {
          statusBarGroupMenu = JSON.parse(request.menuJson) as ESObject[][];
        } catch (e) {
          hilog.warn(DOMAIN, "StatusbarPlugin", "add: failed to parse menuJson: %{public}s", String(e));
        }
      }

      const opts: ESObject = {
        icons: icons,
        quickOperation: quickOperation,
        statusBarGroupMenu: statusBarGroupMenu,
      };

      if (statusBarGroupMenu.length > 0) {
        fillMenuItemAbilityName(statusBarGroupMenu, abilityContext.abilityInfo.name);
        processMenuItemIcons(statusBarGroupMenu);
      }

      if (request.hoverTips && request.hoverTips.length > 0 && request.hoverTips.length <= 128) {
        opts.hoverTips = request.hoverTips;
      }

      // Diagnostic: log the exact quickOperation scalars sent to statusBarManager.
      // 401 "parameter check failed" (SDK @hms.pcService.statusBarManager.d.ts:248)
      // fires on type/value validation of required QuickOperation fields
      // (title:string, height:number, abilityName:string, moduleName?:string).
      hilog.info(DOMAIN, "StatusbarPlugin", `add: quickOperation abilityName="${quickOperation.abilityName}" title="${quickOperation.title}" height=${quickOperation.height} moduleName=${quickOperation.moduleName} loadingStatus=${quickOperation.loadingStatus} menuLen=${statusBarGroupMenu.length}`);

      try {
        // Use the AsyncCallback overload (API 14+) AND await it before
        // acknowledging the bridge call. The tray backend (tray-icon
        // platform_impl/ohos) issues remove+add back-to-back on its worker and
        // treats this handler's return as "the call finished". Returning on the
        // sync path (before SCB processes the request) let the add's SCB
        // processing overlap the previous remove's async teardown and corrupt
        // status bar rendering.
        //
        // JsStatusbarManager also builds its ScbServerMessageReceiver
        // ASYNCHRONOUSLY ~14ms after the sync addToStatusBar() call returns;
        // registering click handlers on the sync return binds them to the
        // previous receiver, which the new receiver then replaces —
        // rightMenuClick/statusBarIconClick listeners are silently dropped.
        // Registering in the completion callback runs strictly after the new
        // receiver exists.
        await new Promise<void>((resolve, reject) => {
          statusBarManager.addToStatusBar(abilityContext, opts, (err: BusinessError) => {
            if (err) {
              hilog.error(DOMAIN, "StatusbarPlugin", "addToStatusBar callback err: %{public}d %{public}s", err.code, err.message);
              reject(err);
              return;
            }
            reRegisterStatusBarClickHandlers();
            resolve();
          });
        });
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, "StatusbarPlugin", "add failed: %{public}d %{public}s", err.code, err.message);
        throw new Error(`addToStatusBar failed: code=${err.code} msg=${err.message}`);
      }
    }

    if (action === "remove") {
      const abilityContext = context.abilityContext;
      try {
        // Await the AsyncCallback overload (API 14+): the tray backend issues
        // remove+add back-to-back and treats this handler's return as
        // "removal finished". The sync overload returns before SCB processes
        // the removal, so a following add lands while the old registration is
        // still live — and addToStatusBar documents duplicate registration as
        // a silent no-op ("同一个应用仅支持添加一个图标，重复添加无效"),
        // leaving the old icon rendered.
        await new Promise<void>((resolve, reject) => {
          statusBarManager.removeFromStatusBar(abilityContext, (err: BusinessError) => {
            if (err) {
              hilog.error(DOMAIN, "StatusbarPlugin", "remove callback err: %{public}d %{public}s", err.code, err.message);
              reject(err);
              return;
            }
            resolve();
          });
        });
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, "StatusbarPlugin", "remove failed: %{public}d %{public}s", err.code, err.message);
        throw new Error(`removeFromStatusBar failed: code=${err.code} msg=${err.message}`);
      }
    }

    if (action === "update-icon") {
      const request = expectBridgeRequestType(payload, "ohos.statusbar", action, UPDATE_ICON_REQUEST_TYPE) as UpdateIconRequest;
      if (!Number.isInteger(request.iconSize) || request.iconSize <= 0) {
        throw new Error("update-icon.iconSize must be a positive integer");
      }
      const abilityContext = context.abilityContext;
      const icons: ESObject = {};
      if (request.whiteIcon && request.whiteIcon.length > 0) {
        const pm = createPixelMapFromRgba(request.whiteIcon, request.iconSize);
        if (pm) icons.white = pm;
      }
      if (request.blackIcon && request.blackIcon.length > 0) {
        const pm = createPixelMapFromRgba(request.blackIcon, request.iconSize);
        if (pm) icons.black = pm;
      }
      if (Object.keys(icons).length === 0) {
        throw new Error("update-icon: no valid icon data provided");
      }
      try {
        statusBarManager.updateStatusBarIcon(abilityContext, icons);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, "StatusbarPlugin", "update-icon failed: %{public}d %{public}s", err.code, err.message);
        throw new Error(`updateStatusBarIcon failed: code=${err.code} msg=${err.message}`);
      }
    }

    if (action === "update-menu") {
      const request = expectBridgeRequestType(payload, "ohos.statusbar", action, UPDATE_MENU_REQUEST_TYPE) as UpdateMenuRequest;
      if (typeof request.menuJson !== "string" || request.menuJson.length === 0) {
        throw new Error("update-menu.menuJson must be a non-empty string");
      }
      const abilityContext = context.abilityContext;
      let statusBarGroupMenu: ESObject[][] = [];
      try {
        statusBarGroupMenu = JSON.parse(request.menuJson) as ESObject[][];
      } catch (e) {
        throw new Error(`update-menu: failed to parse menuJson: ${String(e)}`);
      }
      try {
        fillMenuItemAbilityName(statusBarGroupMenu, abilityContext.abilityInfo.name);
        processMenuItemIcons(statusBarGroupMenu);
        statusBarManager.updateStatusBarMenu(abilityContext, statusBarGroupMenu);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, "StatusbarPlugin", "update-menu failed: %{public}d %{public}s", err.code, err.message);
        throw new Error(`updateStatusBarMenu failed: code=${err.code} msg=${err.message}`);
      }
    }

    if (action === "update-tips") {
      const request = expectBridgeRequestType(payload, "ohos.statusbar", action, UPDATE_TIPS_REQUEST_TYPE) as UpdateTipsRequest;
      if (typeof request.tips !== "string") {
        throw new Error("update-tips.tips must be a string");
      }
      const abilityContext = context.abilityContext;
      try {
        statusBarManager.updateStatusBarHoverTips(abilityContext, request.tips);
        return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, "StatusbarPlugin", "update-tips failed: %{public}d %{public}s", err.code, err.message);
        throw new Error(`updateStatusBarHoverTips failed: code=${err.code} msg=${err.message}`);
      }
    }

    // The tray backend's execute_predefined_action (tray-icon/src/platform_impl/ohos/event.rs)
    // calls the ohos.statusbar facade's execute_predefined → this action. Previously this
    // threw "Unsupported ohos.statusbar action 'execute-predefined'" so copy/Minimize/etc.
    // silently dropped (Rust side map_err→warn swallowed it). MenuPlugin.ets has the same
    // handler for ohos.menu; mirror it here so tray predefined items run the same executor.
    if (action === "execute-predefined") {
      const request = expectBridgeRequestType(payload, "ohos.statusbar", action, PREDEFINED_REQUEST_TYPE) as PredefinedRequest;
      if (typeof request.action !== "string" || !request.action) {
        throw new Error("execute-predefined.action must be a non-empty string");
      }
      const executor = getPredefinedActionExecutor();
      if (!executor) {
        hilog.warn(DOMAIN, "StatusbarPlugin", "execute-predefined: PredefinedActionExecutor not initialized, action: %{public}s", request.action);
        throw new Error("PredefinedActionExecutor not initialized");
      }
      const actionType = request.action as PredefinedType;
      // Tray menu items fire notify_only:true → rightMenuClick, not startAbility, so
      // WINDOW_ACTIVE may never arrive here. Executing the predefined action directly
      // (fire-and-forget on the bridge worker thread) avoids the 2s setPendingAction
      // timeout that previously dropped minimize/hide/close; minimize is safe because
      // WindowManager.minimizeWindow internally applies minimizeWithRestoreGuard
      // (WINDOW_ACTIVE settle + 50ms fallback) for the tray-menu-close focus-restore
      // race. The MenuPlugin.ets menubar path still uses setPendingAction (see T4).
      hilog.info(DOMAIN, "StatusbarPlugin", "execute-predefined '%{public}s'", request.action);
      executor.execute(actionType, request.aboutMetadata);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new BridgeAcknowledgement(true) };
    }

    throw new Error(`Unsupported ohos.statusbar action '${action}'`);
  }
}
