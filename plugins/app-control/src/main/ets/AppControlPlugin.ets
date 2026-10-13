import common from "@ohos.app.ability.common";
import { ConfigurationConstant } from "@kit.AbilityKit";
import { BusinessError } from "@kit.BasicServicesKit";
import { StartOptions, Want } from "@kit.AbilityKit";
import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  SyncPluginBase,
  NATIVE_MODULE_STORAGE_KEY,
  Module,
} from "@ohos-rs/ability";

const TERMINATE_REQUEST_TYPE = "ohos.app_control.TerminateRequest";
const TERMINATE_RESPONSE_TYPE = "ohos.app_control.TerminateResponse";
const RESTART_REQUEST_TYPE = "ohos.app_control.RestartRequest";
const RESTART_RESPONSE_TYPE = "ohos.app_control.RestartResponse";
const SET_COLOR_MODE_REQUEST_TYPE = "ohos.app_control.SetColorModeRequest";
const SET_COLOR_MODE_RESPONSE_TYPE = "ohos.app_control.SetColorModeResponse";
const HIDE_ABILITY_REQUEST_TYPE = "ohos.app_control.HideAbilityRequest";
const HIDE_ABILITY_RESPONSE_TYPE = "ohos.app_control.HideAbilityResponse";
const SHOW_ABILITY_REQUEST_TYPE = "ohos.app_control.ShowAbilityRequest";
const SHOW_ABILITY_RESPONSE_TYPE = "ohos.app_control.ShowAbilityResponse";
const START_UI_ABILITY_REQUEST_TYPE = "ohos.app_control.StartUiAbilityRequest";
const START_UI_ABILITY_RESPONSE_TYPE = "ohos.app_control.StartUiAbilityResponse";

interface TerminateRequest {
  code: number;
}

interface SetColorModeRequest {
  colorMode: number;
}

interface RestartRequest {
}

interface StartUiAbilityRequest {
  windowId: number;
  label: string;
  url: string;
  transparent: boolean;
  // Creation-time geometry (tao#26 review follow-up F5): physical px,
  // optional per axis — absent (undefined) keeps the OS default.
  width?: number;
  height?: number;
  left?: number;
  top?: number;
}


class TerminateResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class RestartResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class SetColorModeResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class HideAbilityResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class ShowAbilityResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class StartUiAbilityResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

function parseTerminateRequest(payload: BridgeTypedValue): TerminateRequest {
  if (payload.typeName !== TERMINATE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.app-control.terminate requires bridge type ${TERMINATE_REQUEST_TYPE}`);
  }
  const request = payload.value as TerminateRequest;
  if (!Number.isInteger(request?.code)) {
    throw new Error("terminate.code must be an integer");
  }
  return request;
}

function parseSetColorModeRequest(payload: BridgeTypedValue): SetColorModeRequest {
  if (payload.typeName !== SET_COLOR_MODE_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(
      `ohos.app-control.set-color-mode requires bridge type ${SET_COLOR_MODE_REQUEST_TYPE}`,
    );
  }
  const request = payload.value as SetColorModeRequest;
  if (!Number.isInteger(request?.colorMode)) {
    throw new Error("set-color-mode.colorMode must be an integer");
  }
  return request;
}

function parseRestartRequest(payload: BridgeTypedValue): RestartRequest {
  if (payload.typeName !== RESTART_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.app-control.restart requires bridge type ${RESTART_REQUEST_TYPE}`);
  }
  return payload.value as RestartRequest;
}

function parseStartUiAbilityRequest(payload: BridgeTypedValue): StartUiAbilityRequest {
  if (payload.typeName !== START_UI_ABILITY_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`ohos.app-control.start-ui-ability requires bridge type ${START_UI_ABILITY_REQUEST_TYPE}`);
  }
  const request = payload.value as StartUiAbilityRequest;
  // windowId must be a positive integer: 0 is the process's original
  // UIAbility instance, which never goes through start-ui-ability. A 0 here
  // would make the new instance overwrite the primary registry entry (R4).
  if (!Number.isInteger(request?.windowId) || request.windowId <= 0) {
    throw new Error("start-ui-ability.windowId must be a positive integer");
  }
  if (typeof request?.label !== "string" || request.label.length === 0) {
    throw new Error("start-ui-ability.label must be a non-empty string");
  }
  if (typeof request?.url !== "string") {
    throw new Error("start-ui-ability.url must be a string (may be empty)");
  }
  if (typeof request?.transparent !== "boolean") {
    throw new Error("start-ui-ability.transparent must be a boolean");
  }
  // Optional creation-time geometry (F5): physical px integers; width/height
  // must be positive when present, left/top may be negative (multi-display).
  if (request.width !== undefined && (!Number.isInteger(request.width) || request.width <= 0)) {
    throw new Error("start-ui-ability.width must be a positive integer when present");
  }
  if (request.height !== undefined && (!Number.isInteger(request.height) || request.height <= 0)) {
    throw new Error("start-ui-ability.height must be a positive integer when present");
  }
  if (request.left !== undefined && !Number.isInteger(request.left)) {
    throw new Error("start-ui-ability.left must be an integer when present");
  }
  if (request.top !== undefined && !Number.isInteger(request.top)) {
    throw new Error("start-ui-ability.top must be an integer when present");
  }
  return request;
}

export class AppControlPlugin extends SyncPluginBase {
  readonly id = "ohos.app-control";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  invokeSync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): BridgeTypedValue {
    if (action === "terminate") {
      const request = parseTerminateRequest(payload);
      // Graceful termination via terminateSelf. The exit code is advisory only
      // (logged): OHOS ability termination has no process exit-code channel.
      // The previous implementation called process.ProcessManager.exit(code),
      // which appspawn intercepts and converts to SIGABRT — every terminate
      // left a cppcrash record (same family as the old tray Quit workaround).
      // Deferred to the next event-loop tick so the bridge response unwinds
      // before ability teardown begins (same pattern as set-color-mode).
      const ctx = context.abilityContext;
      console.info(`[AppControl] terminateSelf requested (exit code ${request.code} is advisory)`);
      setTimeout(() => {
        ctx.terminateSelf().catch((e: BusinessError) => {
          console.error(`[AppControl] terminateSelf failed: ${e.code} ${e.message}`);
        });
      }, 0);
      return { typeName: TERMINATE_RESPONSE_TYPE, value: new TerminateResponse(true) };
    }

    if (action === "restart") {
      parseRestartRequest(payload);
      // Official restart: ApplicationContext.restartApp (API 12+) kills all of
      // the app's processes and relaunches the specified UIAbility. Main-thread
      // only (this is a MainThreadSync plugin action) and the app must be
      // focused; violations throw sync error codes (e.g. 16000053 "not on top
      // of the UI", 16000064 "restart too frequently, retry after 3s") which
      // propagate to Rust as bridge errors. onDestroy is NOT triggered.
      const ctx = context.abilityContext;
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name,
      };
      const applicationContext = ctx.getApplicationContext();
      if (typeof applicationContext.restartApp !== "function") {
        throw new Error("restart requires API level 12+ on OpenHarmony (restartApp is unavailable)");
      }
      applicationContext.restartApp(want);
      return { typeName: RESTART_RESPONSE_TYPE, value: new RestartResponse(true) };
    }

    if (action === "set-color-mode") {
      const request = parseSetColorModeRequest(payload);
      this.setAppColorMode(request.colorMode, context);
      return { typeName: SET_COLOR_MODE_RESPONSE_TYPE, value: new SetColorModeResponse(true) };
    }

    if (action === "hide-ability") {
      const ctx = context.abilityContext;
      // hideAbility() takes no arguments in the current SDK (fire-and-forget).
      ctx.hideAbility();
      return { typeName: HIDE_ABILITY_RESPONSE_TYPE, value: new HideAbilityResponse(true) };
    }

    if (action === "show-ability") {
      // D4 specified amendment (openspec multi-uiability-windows): under
      // launchType "specified" + AbilityStage.onAcceptWant, a bare
      // self-targeting startAbility routes to the live primary instance —
      // AMS pulls it back to the top of the stack. This is the only
      // mechanism that also covers a context.hideAbility()-hidden ability
      // (window-level showWindow cannot — device-proven regression under
      // the interim "standard" + showWindowMethod variant, 2026-09-15).
      // (Multi-window spawn has its own action: "start-ui-ability" below.)
      const ctx = context.abilityContext;
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name,
      };
      // startAbility(want) supports Promise (unlike hideAbility which is callback-only).
      // Fire-and-forget: initiate the call and immediately return accepted=true.
      ctx.startAbility(want).catch((e: BusinessError) => {
        console.error(`[AppControl] showAbility failed: ${e.code} ${e.message}`);
      });
      return { typeName: SHOW_ABILITY_RESPONSE_TYPE, value: new ShowAbilityResponse(true) };
    }

    if (action === "start-ui-ability") {
      const request = parseStartUiAbilityRequest(payload);
      const ctx = context.abilityContext;
      // All parameters must be strings: AMS re-parses scalar values when the
      // Want crosses the binder boundary, and non-string values silently lose
      // their type. Stringifying keeps tauri_window_id intact for the new
      // instance's onCreate (Number(...) read on the other side).
      const params: Record<string, Object> = {
        "tauri_window_id": String(request.windowId),
        "tauri_window_label": request.label,
        "tauri_window_url": request.url,
        "tauri_transparent": String(request.transparent),
      };
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name,
        parameters: params,
      };
      // Creation-time geometry (tao#26 review follow-up F5): forward the
      // builder's size/position through startAbility StartOptions
      // (windowWidth/windowHeight/windowLeft/windowTop, API 11+). Physical
      // px, window rectangle (frame included) — same contract as the Float
      // path's WindowCreateParams. Absent axes stay unset (OS default), so
      // a start without builder geometry keeps today's sizing exactly.
      const options: StartOptions = {};
      if (request.width !== undefined) {
        options.windowWidth = request.width;
      }
      if (request.height !== undefined) {
        options.windowHeight = request.height;
      }
      if (request.left !== undefined) {
        options.windowLeft = request.left;
      }
      if (request.top !== undefined) {
        options.windowTop = request.top;
      }
      console.info(`[AppControl] start-ui-ability: id=${request.windowId} label=${request.label} url='${request.url}' transparent=${request.transparent} geometry=${request.width ?? "*"}x${request.height ?? "*"}@${request.left ?? "*"},${request.top ?? "*"}`);
      // Escape the NAPI re-entrancy context before calling AMS: startAbility
      // invoked synchronously inside a bridge (MainThreadSync) callback drops
      // want.parameters (multi-uiability-windows design D1). Fire-and-forget —
      // the Rust caller already returned with its pre-allocated window id and
      // observes the handshake via register_ui_ability_stage, not this
      // response (accepted = "dispatched", not "instance created").
      setTimeout(() => {
        ctx.startAbility(want, options).catch((e: BusinessError) => {
          console.error(`[AppControl] start-ui-ability id=${request.windowId} failed: ${e.code} ${e.message}`);
          // accepted ≠ created: the Rust caller already returned Ok and tao
          // pre-registered the pending D7 handshake entry plus the label→id
          // pairing, so an AMS rejection here (this want never creates a
          // stage) would strand both registries — the id never becomes ready
          // and every op queued for that window is held silently forever
          // (G15). Roll back the same registries the synchronous Err leg
          // does: unregister_window_label + unregister_pending_ui_ability
          // (tao's queued-op drop is Rust-side and unreachable here — the
          // entry removal makes the id read as ready, so the runtime's next
          // drain pass replays those ops and each fails loudly instead).
          // typeof-probed optional export: a stale .so without it keeps
          // today's fire-and-forget semantics. console.error only (C5: this
          // catch must not hilog — NAPI re-entrancy turns the log itself into
          // a thrown error and swallows the original one).
          try {
            const nativeModule: Module | undefined = AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
            if (nativeModule && typeof nativeModule.notifyUiAbilityStartFailed === "function") {
              nativeModule.notifyUiAbilityStartFailed(request.windowId);
            }
          } catch (notifyErr) {
            console.error(`[AppControl] start-ui-ability rollback notify failed: ${String(notifyErr)}`);
          }
        });
      }, 0);
      return { typeName: START_UI_ABILITY_RESPONSE_TYPE, value: new StartUiAbilityResponse(true) };
    }

    throw new Error(`Unsupported ohos.app-control action '${action}'`);
  }

  private setAppColorMode(code: number, context: BridgeCallContext): void {
    // Map the bridge integer to ConfigurationConstant.ColorMode.
    // 0 → COLOR_MODE_DARK, 1 → COLOR_MODE_LIGHT, default → COLOR_MODE_NOT_SET.
    // Do NOT pass the raw integer to setColorMode — OHOS expects the enum value,
    // and 2 is not a legal ColorMode value (NOT_SET is a distinct constant).
    let colorMode: ConfigurationConstant.ColorMode;
    switch (code) {
      case 0:
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
        break;
      case 1:
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
        break;
      default:
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
        break;
    }

    // Capture only the application context (survives the callback) — the
    // BridgeCallContext itself is only valid during the current N-API callback.
    const applicationContext = context.abilityContext.getApplicationContext();

    // Defer setColorMode to the next event-loop tick to avoid deadlock:
    // setColorMode synchronously triggers onConfigurationUpdate, which calls
    // back into Rust on the main thread. If we are already inside a NAPI
    // callback from Rust (MainThreadSync), this deadlocks the main thread.
    // See ohos-constraints 4.3 and ArkHelper.ets L893-927 for the same pattern.
    setTimeout(() => {
      try {
        applicationContext.setColorMode(colorMode);
      } catch (err) {
        // The ability may have been destroyed between scheduling and execution.
        // Silently swallow — the response was already accepted.
      }
    }, 0);
  }
}
