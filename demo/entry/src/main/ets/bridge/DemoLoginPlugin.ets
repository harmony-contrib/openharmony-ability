import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgePluginHookContext,
  AsyncPluginBase,
  BridgeContextRequirement,
  SyncPluginBase,
} from "@ohos-rs/ability";

const LOGIN_REQUEST_TYPE = "demo.login.LoginRequest";
const LOGIN_RESPONSE_TYPE = "demo.login.LoginResponse";
const LOGIN_PUBLISH_RESPONSE_TYPE = "demo.login.LoginPublishResponse";
const MAIN_THREAD_INSPECT_REQUEST_TYPE = "demo.main-thread.InspectRequest";
const MAIN_THREAD_INSPECT_RESPONSE_TYPE = "demo.main-thread.InspectResponse";

interface LoginRequest {
  provider: string;
  scopes: string[];
}

interface LoginResponse {
  userId: string;
  displayName: string;
  accessToken: string;
  expiresAtMs: number;
}

interface LoginProvider {
  authorize(request: LoginRequest, context: BridgeCallContext): Promise<LoginResponse>;
}

interface LoginPublishResponse {
  published: boolean;
}

interface MainThreadInspectResponse {
  sessionId: string;
  uiContextReady: boolean;
  execution: string;
}

interface MainThreadInspectRequest {
  requested: boolean;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function requireObject<T>(payload: BridgeTypedValue, typeName: string, description: string): T {
  if (
    payload.typeName !== typeName ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`${description} requires bridge type ${typeName}`);
  }
  return payload.value as T;
}

function parseLoginRequest(payload: BridgeTypedValue): LoginRequest {
  const request = requireObject<LoginRequest>(payload, LOGIN_REQUEST_TYPE, "login request");
  if (
    typeof request.provider !== "string" ||
    !Array.isArray(request.scopes) ||
    request.scopes.some((scope) => typeof scope !== "string")
  ) {
    throw new Error("Invalid login request");
  }
  return request;
}

function parseLoginResponse(payload: BridgeTypedValue): LoginResponse {
  const response = requireObject<LoginResponse>(payload, LOGIN_RESPONSE_TYPE, "login response");
  if (
    typeof response.userId !== "string" ||
    typeof response.displayName !== "string" ||
    typeof response.accessToken !== "string" ||
    typeof response.expiresAtMs !== "number"
  ) {
    throw new Error("Invalid login response");
  }
  return response;
}

/**
 * Replace this provider with an AccountKit/OAuth implementation in a product app. Its Promise
 * may open system UI or wait for a redirect; BridgeHost will resolve/reject the Rust future and
 * discard the result if NativeAbility is destroyed in the meantime.
 */
export class DemoIdentityProvider implements LoginProvider {
  async authorize(request: LoginRequest, context: BridgeCallContext): Promise<LoginResponse> {
    if (!context.isActive()) {
      throw new Error("Ability was destroyed before login started");
    }
    if (request.provider !== "demo" || request.scopes.length === 0) {
      throw new Error("Unsupported login request");
    }

    // Simulates an asynchronous system-account/OAuth authorization operation on ArkTS.
    await delay(80);
    if (!context.isActive()) {
      throw new Error("Ability was destroyed while login was pending");
    }
    return {
      userId: "demo-user-1001",
      displayName: "Bridge Demo User",
      accessToken: "demo-access-token",
      expiresAtMs: Date.now() + 60 * 60 * 1000,
    };
  }
}

export class DemoLoginPlugin extends AsyncPluginBase {
  readonly id: string = "demo.login";
  /** Login can open system UI, so installation waits for DefaultXComponent's UIContext. */
  readonly requires: BridgeContextRequirement[] = ["ui-context"];

  private readonly provider: LoginProvider;

  constructor(provider: LoginProvider) {
    super();
    this.provider = provider;
  }

  override async onInstall(context: BridgePluginHookContext): Promise<void> {
    // This would throw before UIContext readiness; BridgeHost guarantees it is ready here.
    context.getUIContext();
    AppStorage.setOrCreate("bridgeLoginStatus", "ready");
  }

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }

    if (action === "authorize") {
      const request = parseLoginRequest(payload);
      const response = await this.provider.authorize(request, context);
      return { typeName: LOGIN_RESPONSE_TYPE, value: response as ESObject };
    }

    if (action === "publish") {
      const response = parseLoginResponse(payload);
      if (!context.isActive()) {
        throw new Error("Bridge session is no longer active");
      }
      // This is the app-visible UI state update. A production plugin could instead publish an
      // event, persist encrypted credentials, or invoke an application-specific callback.
      AppStorage.setOrCreate("bridgeLoginResult", response.userId);
      const result: LoginPublishResponse = {
        published: true,
      };
      return { typeName: LOGIN_PUBLISH_RESPONSE_TYPE, value: result as ESObject };
    }

    throw new Error(`Unsupported demo.login action '${action}'`);
  }
}

/**
 * Synchronous counterpart for the demo. BridgeHost never accepts this through bridgeInvoke;
 * Rust can reach it only from an Env-scoped N-API main-thread callback.
 */
export class DemoMainThreadPlugin extends SyncPluginBase {
  readonly id: string = "demo.main-thread";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];

  override onInstall(context: BridgePluginHookContext): void {
    context.getUIContext();
  }

  invokeSync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): BridgeTypedValue {
    if (action !== "inspect") {
      throw new Error(`Unsupported demo.main-thread action '${action}'`);
    }
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }
    const request = requireObject<MainThreadInspectRequest>(
      payload,
      MAIN_THREAD_INSPECT_REQUEST_TYPE,
      "demo.main-thread.inspect",
    );
    if (request.requested !== true) {
      throw new Error("Invalid demo.main-thread.inspect request");
    }
    context.getUIContext();
    const response: MainThreadInspectResponse = {
      sessionId: context.sessionId,
      uiContextReady: true,
      execution: "sync-main-thread",
    };
    return { typeName: MAIN_THREAD_INSPECT_RESPONSE_TYPE, value: response as ESObject };
  }
}
