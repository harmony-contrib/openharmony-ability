import { authentication } from "@kit.AccountKit";
import { util } from "@kit.ArkTS";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { common } from "@kit.AbilityKit";
import { BusinessError } from "@kit.BasicServicesKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  DOMAIN,
} from "@ohos-rs/ability";

const TAG = "AccountPlugin.ets";

const LOGIN_REQUEST_TYPE = "ohos.account.LoginRequest";
const LOGIN_RESPONSE_TYPE = "ohos.account.LoginResponse";
const LOGOUT_REQUEST_TYPE = "ohos.account.LogoutRequest";
const LOGOUT_RESPONSE_TYPE = "ohos.account.LogoutResponse";

// Pseudo error code for the CSRF state mismatch check (not covered by Account
// Kit's BusinessError). Embedded in the thrown Error's message as "<code>:<message>"
// so Rust can propagate it (the bridge surfaces the message via napi Error::reason).
const CODE_STATE_MISMATCH = 1001502002;

/** Response carrying the Account Kit credential fields (camelCase keys). */
class AccountLoginResponse {
  readonly uid: string;
  readonly openId: string;
  readonly unionId: string;
  readonly displayName: string;
  readonly avatarUri: string;
  readonly authorizationCode: string;
  // Optional property: when absent, napi-ohos's Object::get returns None → Rust
  // Option<String> = None. A `null` value is NOT decodable — the derive codegen
  // decodes the field as String (not Option<String>), so null fails with
  // `StringExpected on AccountLoginResponse.accessToken` (device-verified 2026-08-31).
  readonly accessToken?: string;

  constructor(
    uid: string,
    openId: string,
    unionId: string,
    displayName: string,
    avatarUri: string,
    authorizationCode: string,
    accessToken: string | null,
  ) {
    this.uid = uid;
    this.openId = openId;
    this.unionId = unionId;
    this.displayName = displayName;
    this.avatarUri = avatarUri;
    this.authorizationCode = authorizationCode;
    if (accessToken !== null) {
      this.accessToken = accessToken;
    }
  }
}

class AccountLogoutResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

/**
 * Safe error logging.
 *
 * `invokeAsync` runs in an async Promise context (not a reentrant NAPI path), so
 * `hilog` is generally usable — but it is wrapped in try/catch with a `console`
 * fallback so the catch itself never throws and masks the original error (same
 * pattern as the former `account.ets` `logError` / `ArkHelper.safeLogError`).
 */
function logError(op: string, err: ESObject): void {
  const e = err as BusinessError;
  const msg =
    e && e.code !== undefined && e.message !== undefined
      ? `${e.code}:${e.message}`
      : String(err);
  try {
    hilog.error(DOMAIN, TAG, "%{public}s failed: %{public}s", op, msg);
  } catch (_e) {
    console.error(`[${TAG}] ${op} failed: ${msg}`);
  }
}

/** Build the "<code>:<message>" message string embedded in thrown Errors. */
function accountError(code: number, message: string): string {
  return `${code}:${message}`;
}

/**
 * Normalize any caught value into an Error whose message is "<code>:<message>".
 * - Account Kit `BusinessError` → `new Error("${code}:${message}")`
 * - Error already thrown by the state check (message is already "<code>:<message>")
 *   → rethrown as-is
 */
function normalizeError(err: ESObject): Error {
  const e = err as BusinessError;
  if (e && e.code !== undefined && e.message !== undefined) {
    return new Error(`${e.code}:${e.message}`);
  }
  if (err instanceof Error) {
    return err as Error;
  }
  return new Error(String(err));
}

/**
 * Shared login flow. `forceLogin=true` → interactive UI; `false` → silent.
 *
 * A `UIAbilityContext` is required: `AuthenticationController(context)` needs it
 * to host the one-tap login UI when forceLogin=true and the user is not already
 * logged in/authorized. When the account is already logged in & authorized,
 * Account Kit returns the credential directly without showing the UI.
 */
async function loginWithHuaweiID(
  forceLogin: boolean,
  context: common.UIAbilityContext,
): Promise<AccountLoginResponse> {
  try {
    const request = new authentication.HuaweiIDProvider().createLoginWithHuaweiIDRequest();
    request.forceLogin = forceLogin;
    request.state = util.generateRandomUUID();

    const controller = new authentication.AuthenticationController(context);
    const response = await controller.executeRequest(request) as authentication.LoginWithHuaweiIDResponse;

    // CSRF state check (best-effort).
    if (response.state && request.state !== response.state) {
      throw new Error(accountError(CODE_STATE_MISMATCH, "state mismatch (possible CSRF)"));
    }

    // Map LoginWithHuaweiIDCredential to the canonical response. Field casing
    // verified by hvigor compile: the credential only carries openID / unionID /
    // authorizationCode (+ idToken). Profile fields (displayName / avatarUri),
    // uid, and accessToken are NOT returned by the login flow.
    const credential = response.data;
    return new AccountLoginResponse(
      "",
      credential?.openID ?? "",
      credential?.unionID ?? "",
      "",
      "",
      credential?.authorizationCode ?? "",
      null,
    );
  } catch (err) {
    logError("loginWithHuaweiID", err);
    throw normalizeError(err);
  }
}

/**
 * Huawei Account one-tap login bridge plugin (`ohos.account`).
 *
 * Actions:
 * - `login`      → interactive one-tap login (forceLogin=true)
 * - `silentLogin`→ silent login, no UI (forceLogin=false); succeeds only when
 *                  the device is already logged in & the app is authorized
 * - `logout`     → cancels the app's Huawei account authorization
 *                  (Account Kit's `createCancelAuthorizationRequest`; there is
 *                  no `signOut` — see design D8)
 *
 * Replaces the former TSFN transport (`helper/account.ets` + `get_helper()`),
 * whose `set_helper` was never called after the `#[ability]` derive refactor,
 * so login/logout silently failed at runtime. Routes through the bridge
 * `bridgeInvoke` which is wired up per Ability session.
 *
 * ArkTS strictness notes:
 * - `throw` only accepts Error objects (arkts-limited-throw); errors are thrown
 *   as `new Error("<code>:<message>")` rather than bare strings.
 * - `any`/`unknown` are forbidden (arkts-no-any-unknown); credential fields are
 *   accessed via the typed `LoginWithHuaweiIDCredential` (casing verified by
 *   hvigor compile: openID / unionID with capital "ID").
 */
export class AccountPlugin extends AsyncPluginBase {
  readonly id = "ohos.account";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }

    if (action === "login") {
      if (payload.typeName !== LOGIN_REQUEST_TYPE) {
        throw new Error(`ohos.account.login requires bridge type ${LOGIN_REQUEST_TYPE}`);
      }
      const info = await loginWithHuaweiID(true, context.abilityContext);
      return { typeName: LOGIN_RESPONSE_TYPE, value: info };
    }

    if (action === "silentLogin") {
      if (payload.typeName !== LOGIN_REQUEST_TYPE) {
        throw new Error(`ohos.account.silentLogin requires bridge type ${LOGIN_REQUEST_TYPE}`);
      }
      const info = await loginWithHuaweiID(false, context.abilityContext);
      return { typeName: LOGIN_RESPONSE_TYPE, value: info };
    }

    if (action === "logout") {
      if (payload.typeName !== LOGOUT_REQUEST_TYPE) {
        throw new Error(`ohos.account.logout requires bridge type ${LOGOUT_REQUEST_TYPE}`);
      }
      await this.performLogout();
      return { typeName: LOGOUT_RESPONSE_TYPE, value: new AccountLogoutResponse(true) };
    }

    throw new Error(`Unsupported ohos.account action '${action}'`);
  }

  /** Cancels the app's Huawei account authorization on this device. */
  private async performLogout(): Promise<void> {
    try {
      const request = new authentication.HuaweiIDProvider().createCancelAuthorizationRequest();
      const controller = new authentication.AuthenticationController();
      await controller.executeRequest(request);
    } catch (err) {
      logError("logout", err);
      throw normalizeError(err);
    }
  }
}
