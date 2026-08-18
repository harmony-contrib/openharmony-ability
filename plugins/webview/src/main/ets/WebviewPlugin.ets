import { WebHeader } from "@kit.ArkUI";
import { BuilderNode } from "@ohos.arkui.node";
import webview from "@ohos.web.webview";
import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgePluginContext,
  BridgePluginHookContext,
  AsyncPluginBase,
  BridgeContextRequirement,
  BridgeLifecycleEvent,
} from "@ohos-rs/ability";

const CREATE_REQUEST_TYPE = "ohos.webview.CreateRequest";
const CREATE_RESPONSE_TYPE = "ohos.webview.CreateResponse";
const CONTROLLER_REQUEST_TYPE = "ohos.webview.ControllerRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.webview.Acknowledgement";
const SCRIPT_REQUEST_TYPE = "ohos.webview.ScriptRequest";
const SCRIPT_RESPONSE_TYPE = "ohos.webview.ScriptResponse";
const STRING_RESPONSE_TYPE = "ohos.webview.StringResponse";
const NAVIGATION_REQUEST_TYPE = "ohos.webview.NavigationRequest";
const NAVIGATION_RESPONSE_TYPE = "ohos.webview.NavigationResponse";
const DOWNLOAD_START_REQUEST_TYPE = "ohos.webview.DownloadStartRequest";
const DOWNLOAD_START_RESPONSE_TYPE = "ohos.webview.DownloadStartResponse";
const DOWNLOAD_END_EVENT_TYPE = "ohos.webview.DownloadEndEvent";
const TITLE_CHANGE_EVENT_TYPE = "ohos.webview.TitleChangeEvent";
const ENGINE_LIFECYCLE_EVENT_TYPE = "ohos.webview.EngineLifecycleEvent";
const ENGINE_LIFECYCLE_RESPONSE_TYPE = "ohos.webview.EngineLifecycleResponse";
const CONTROLLER_EVENT_TYPE = "ohos.webview.ControllerEvent";
const EVENT_ACKNOWLEDGEMENT_TYPE = "ohos.webview.EventAcknowledgement";

/** Optional static ArkWeb API resolved dynamically to preserve the API-12 package baseline. */
interface WebviewDebuggingApi {
  setWebDebuggingAccess?: (enabled: boolean) => void;
}

function enableWebDebuggingIfAvailable(): void {
  const debuggingApi = webview.WebviewController as ESObject as WebviewDebuggingApi;
  if (typeof debuggingApi.setWebDebuggingAccess !== "function") {
    console.warn("WebView debugging is unavailable on this ArkWeb API level");
    return;
  }
  debuggingApi.setWebDebuggingAccess(true);
}

interface WebviewStyle {
  x?: number | string | null;
  y?: number | string | null;
  /** Optional width override; defaults to the full container. Numbers are vp, strings are ArkUI lengths. */
  width?: number | string | null;
  /** Optional height override; defaults to the full container. Numbers are vp, strings are ArkUI lengths. */
  height?: number | string | null;
  visible?: boolean | null;
  backgroundColor?: string | null;
}

interface WebviewInitializationScript {
  script: string;
  scriptRules: string[];
}

interface WebviewEventOptions {
  navigationIntercept?: boolean | null;
  downloadStart?: boolean | null;
  downloadEnd?: boolean | null;
  titleChange?: boolean | null;
}

interface WebviewCreatePayload {
  id: string;
  /**
   * Optional opaque container handle issued by the built-in ohos.node plugin. When provided the
   * WebView FrameNode is appended under that container instead of this module's component root,
   * so an RS-layer node tree can adopt WebViews as children.
   */
  parentHandle?: number | null;
  url?: string | null;
  html?: string | null;
  style?: WebviewStyle | null;
  javascriptEnabled?: boolean | null;
  devtools?: boolean | null;
  userAgent?: string | null;
  autoplay?: boolean | null;
  initializationScripts?: WebviewInitializationScript[] | null;
  headers?: Record<string, string> | null;
  transparent?: boolean | null;
  eventOptions?: WebviewEventOptions | null;
}

interface ControllerPayload {
  id: string;
  visible?: boolean | null;
  color?: string | null;
  url?: string | null;
  html?: string | null;
  headers?: Record<string, string> | null;
  zoom?: number | null;
}

interface ScriptPayload {
  id: string;
  script: string;
}

interface ManagedWebview extends WebviewCreatePayload {
  controller: WebviewController;
  /** Process-unique ArkWeb controller tag; distinct from the module-local public ID. */
  nativeTag: string;
  style: WebviewStyle;
  eventOptions: WebviewEventOptions;
  didInitialLoad: boolean;
  beginControllerAttach: () => boolean;
  notifyNativeControllerAttached: () => void;
  markControllerReady: () => void;
  failControllerAttach: (reason: string) => void;
  onNavigationRequest: (url: string) => boolean;
  onTitleChange: (title: string) => void;
  onDownloadStart: (url: string, tempPath: string | null) => WebviewDownloadStartResponse;
  onDownloadEnd: (url: string, tempPath: string | null, success: boolean) => void;
  /** How this WebView was mounted: a parent-handle container or the component root. */
  mountParentHandle: number | null;
  /** Host-internal cleanup key; WebView IDs remain opaque business identifiers. */
  mountKey: string;
}

interface ControllerWaiter {
  resolve: () => void;
  reject: (reason: Error) => void;
}

class WebviewEntry {
  readonly data: ManagedWebview;
  readonly node: BuilderNode<[ManagedWebview]>;
  private attaching = false;
  private attached = false;
  private controllerFailure: Error | null = null;
  private readonly controllerWaiters: ControllerWaiter[] = [];

  constructor(data: ManagedWebview, node: BuilderNode<[ManagedWebview]>) {
    this.data = data;
    this.node = node;
  }

  beginControllerAttach(): boolean {
    if (this.attaching || this.attached || this.controllerFailure !== null) {
      return false;
    }
    this.attaching = true;
    return true;
  }

  markControllerReady(): void {
    if (this.attached || this.controllerFailure !== null) {
      return;
    }
    this.attached = true;
    const waiters = this.controllerWaiters.splice(0, this.controllerWaiters.length);
    for (const waiter of waiters) {
      waiter.resolve();
    }
  }

  async waitForController(onCancel: (listener: () => void) => () => void): Promise<void> {
    if (this.attached) {
      return;
    }
    if (this.controllerFailure !== null) {
      throw this.controllerFailure;
    }
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      let unsubscribe: () => void = (): void => {};
      const waiter: ControllerWaiter = {
        resolve: (): void => {
          if (settled) {
            return;
          }
          settled = true;
          unsubscribe();
          resolve();
        },
        reject: (reason: Error): void => {
          if (settled) {
            return;
          }
          settled = true;
          unsubscribe();
          reject(reason);
        },
      };
      this.controllerWaiters.push(waiter);
      // The waiter is registered before subscription because an already-cancelled bridge call
      // invokes its listener synchronously.
      unsubscribe = onCancel((): void => {
        this.removeControllerWaiter(waiter);
        waiter.reject(new Error(`WebView '${this.data.id}' controller wait was cancelled`));
      });
    });
  }

  failController(reason: string): void {
    if (this.attached || this.controllerFailure !== null) {
      return;
    }
    const error = new Error(reason);
    this.controllerFailure = error;
    const waiters = this.controllerWaiters.splice(0, this.controllerWaiters.length);
    for (const waiter of waiters) {
      waiter.reject(error);
    }
  }

  private removeControllerWaiter(waiter: ControllerWaiter): void {
    const index = this.controllerWaiters.indexOf(waiter);
    if (index >= 0) {
      this.controllerWaiters.splice(index, 1);
    }
  }
}

class WebviewCreatedResponse {
  readonly id: string;

  constructor(id: string) {
    this.id = id;
  }
}

class WebviewAcceptedResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class WebviewScriptResponse {
  readonly result: string | null;

  constructor(result: string | null) {
    this.result = result;
  }
}

class WebviewStringResponse {
  readonly value: string | null;

  constructor(value: string | null) {
    this.value = value;
  }
}

class WebviewNavigationRequest {
  readonly id: string;
  readonly nativeTag: string;
  readonly url: string;

  constructor(id: string, nativeTag: string, url: string) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.url = url;
  }
}

interface WebviewNavigationResponse {
  intercept: boolean;
}

class WebviewDownloadStartRequest {
  readonly id: string;
  readonly nativeTag: string;
  readonly url: string;
  readonly tempPath: string | null;

  constructor(id: string, nativeTag: string, url: string, tempPath: string | null) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.url = url;
    this.tempPath = tempPath;
  }
}

interface WebviewDownloadStartResponse {
  allow: boolean;
  tempPath: string | null;
}

class WebviewDownloadEndEvent {
  readonly id: string;
  readonly nativeTag: string;
  readonly url: string;
  readonly tempPath: string | null;
  readonly success: boolean;

  constructor(
    id: string,
    nativeTag: string,
    url: string,
    tempPath: string | null,
    success: boolean,
  ) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.url = url;
    this.tempPath = tempPath;
    this.success = success;
  }
}

class WebviewTitleChangeEvent {
  readonly id: string;
  readonly nativeTag: string;
  readonly title: string;

  constructor(id: string, nativeTag: string, title: string) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.title = title;
  }
}

class WebviewEngineLifecycleEvent {
  readonly phase: string;
  readonly schemes: WebviewSchemeDeclaration[];

  constructor(phase: string, schemes: WebviewSchemeDeclaration[]) {
    this.phase = phase;
    this.schemes = schemes;
  }
}

class WebviewControllerEvent {
  readonly id: string;
  readonly nativeTag: string;

  constructor(id: string, nativeTag: string) {
    this.id = id;
    this.nativeTag = nativeTag;
  }
}

interface WebviewEventAcknowledgement {
  accepted: boolean;
}

interface WebviewSchemeDeclaration {
  scheme: string;
  options: number;
}

interface WebviewEngineLifecycleResponse {
  accepted: boolean;
  schemes: WebviewSchemeDeclaration[];
}

let webEngineInitialized = false;
let webEngineSchemes: WebviewSchemeDeclaration[] = [];
let nextWebviewNativeTagId = 1;

/**
 * Custom schemes must be registered by Rust before this call. The two events let the Rust
 * WebView facade flush declarations immediately before the engine is initialized and seal the
 * declaration set afterwards.
 */
function ensureWebEngineInitialized(context: BridgePluginContext): void {
  if (!webEngineInitialized) {
    // Seal and validate every module's declarations before any module mutates ArkWeb's global
    // scheme registry.
    const sealedSchemes = notifyWebEngineProcessWide(
      context,
      "seal-engine-schemes",
      ENGINE_LIFECYCLE_EVENT_TYPE,
      new WebviewEngineLifecycleEvent("seal-engine-schemes", []) as ESObject,
    );
    notifyWebEngineProcessWide(
      context,
      "before-engine-init",
      ENGINE_LIFECYCLE_EVENT_TYPE,
      new WebviewEngineLifecycleEvent("before-engine-init", sealedSchemes) as ESObject,
    );
    webview.WebviewController.initializeWebEngine();
    webEngineSchemes = sealedSchemes;
    webEngineInitialized = true;
  }
  // ArkWeb is process-global, while every native module has independent Rust static state.
  // Notify every active module, including those whose DefaultXComponent has not appeared yet.
  notifyWebEngineProcessWide(
    context,
    "engine-initialized",
    ENGINE_LIFECYCLE_EVENT_TYPE,
    new WebviewEngineLifecycleEvent("engine-initialized", webEngineSchemes) as ESObject,
  );
}

function parseCreatePayload(payload: BridgeTypedValue): WebviewCreatePayload {
  if (
    payload.typeName !== CREATE_REQUEST_TYPE ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`ohos.webview.create requires bridge type ${CREATE_REQUEST_TYPE}`);
  }
  return payload.value as WebviewCreatePayload;
}

function parseControllerPayload(payload: BridgeTypedValue, action: string): ControllerPayload {
  if (
    payload.typeName !== CONTROLLER_REQUEST_TYPE ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`ohos.webview.${action} requires bridge type ${CONTROLLER_REQUEST_TYPE}`);
  }
  return payload.value as ControllerPayload;
}

function parseScriptPayload(payload: BridgeTypedValue): ScriptPayload {
  if (
    payload.typeName !== SCRIPT_REQUEST_TYPE ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`ohos.webview.evaluate-script requires bridge type ${SCRIPT_REQUEST_TYPE}`);
  }
  const request = payload.value as ScriptPayload;
  if (!request?.id?.trim()) {
    throw new Error("WebView script controller id must not be empty");
  }
  if (typeof request.script !== "string") {
    throw new Error("WebView script must be a string");
  }
  return request;
}

function requireControllerString(value: string | null | undefined, description: string): string {
  if (typeof value !== "string") {
    throw new Error(`${description} must be a string`);
  }
  return value;
}

function ensureCreatePayload(payload: WebviewCreatePayload): WebviewCreatePayload {
  if (!payload?.id?.trim()) {
    throw new Error("WebView id must not be empty");
  }
  if (!!payload.url === !!payload.html) {
    throw new Error("WebView requires exactly one source: url or html");
  }
  if (payload.headers !== undefined && payload.headers !== null) {
    for (const key of Object.keys(payload.headers)) {
      const value = payload.headers[key];
      if (!key.trim() || typeof value !== "string") {
        throw new Error("WebView headers must contain non-empty string names and string values");
      }
    }
  }
  if (
    payload.transparent !== undefined &&
    payload.transparent !== null &&
    typeof payload.transparent !== "boolean"
  ) {
    throw new Error("WebView transparent must be a boolean");
  }
  if (
    payload.parentHandle !== undefined &&
    payload.parentHandle !== null &&
    (typeof payload.parentHandle !== "number" ||
      !Number.isInteger(payload.parentHandle) ||
      payload.parentHandle <= 0)
  ) {
    throw new Error("WebView parentHandle must be a positive integer ohos.node handle");
  }
  normalizeEventOptions(payload.eventOptions);
  return payload;
}

function optionalEventFlag(value: boolean | null | undefined, description: string): boolean {
  if (value === undefined || value === null) {
    return false;
  }
  if (typeof value !== "boolean") {
    throw new Error(description + " must be a boolean");
  }
  return value;
}

function normalizeEventOptions(
  options: WebviewEventOptions | null | undefined,
): WebviewEventOptions {
  return {
    navigationIntercept: optionalEventFlag(
      options?.navigationIntercept,
      "WebView eventOptions.navigationIntercept",
    ),
    downloadStart: optionalEventFlag(options?.downloadStart, "WebView eventOptions.downloadStart"),
    downloadEnd: optionalEventFlag(options?.downloadEnd, "WebView eventOptions.downloadEnd"),
    titleChange: optionalEventFlag(options?.titleChange, "WebView eventOptions.titleChange"),
  };
}

function styleLength(
  value: number | string | null | undefined,
  description: string,
): number | string | null {
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== "number" && typeof value !== "string") {
    throw new Error(description + " must be a number or an ArkUI length string");
  }
  if (typeof value === "number" && !Number.isFinite(value)) {
    throw new Error(description + " must be finite");
  }
  return value;
}

function normalizeStyle(
  style: WebviewStyle | null | undefined,
  transparent: boolean | null | undefined,
): WebviewStyle {
  const normalized: WebviewStyle = {};
  if (style === undefined || style === null) {
    if (transparent === true) {
      normalized.backgroundColor = "#00000000";
    }
    return normalized;
  }
  if (style.x !== undefined && style.x !== null) {
    normalized.x = style.x;
  }
  if (style.y !== undefined && style.y !== null) {
    normalized.y = style.y;
  }
  const width = styleLength(style.width, "WebView style.width");
  if (width !== null) {
    normalized.width = width;
  }
  const height = styleLength(style.height, "WebView style.height");
  if (height !== null) {
    normalized.height = height;
  }
  if (style.visible !== undefined && style.visible !== null) {
    normalized.visible = style.visible;
  }
  if (style.backgroundColor !== undefined && style.backgroundColor !== null) {
    normalized.backgroundColor = style.backgroundColor;
  }
  if (transparent === true && !normalized.backgroundColor) {
    normalized.backgroundColor = "#00000000";
  }
  return normalized;
}

function headersOf(headers?: Record<string, string> | null): WebHeader[] {
  const result: WebHeader[] = [];
  if (headers === undefined || headers === null) {
    return result;
  }
  const keys: string[] = Object.keys(headers);
  for (const key of keys) {
    const value = headers[key];
    if (!key.trim() || typeof value !== "string") {
      throw new Error("WebView headers must contain non-empty string names and string values");
    }
    const header: WebHeader = { headerKey: key, headerValue: value };
    result.push(header);
  }
  return result;
}

function navigationDecision(
  context: BridgePluginContext,
  id: string,
  nativeTag: string,
  url: string,
): boolean {
  try {
    const response = context.invokeNativeSync(
      "navigation-request",
      NAVIGATION_REQUEST_TYPE,
      NAVIGATION_RESPONSE_TYPE,
      new WebviewNavigationRequest(id, nativeTag, url) as ESObject,
    ) as WebviewNavigationResponse;
    if (
      response === null ||
      typeof response !== "object" ||
      typeof response.intercept !== "boolean"
    ) {
      throw new Error("Invalid WebView navigation response");
    }
    return response.intercept;
  } catch (error) {
    console.error("WebView navigation decision failed: " + String(error));
    // Navigation interception must fail open so a temporarily unavailable Rust handler cannot
    // strand the user on a page.
    return false;
  }
}

function downloadStartDecision(
  context: BridgePluginContext,
  id: string,
  nativeTag: string,
  url: string,
  tempPath: string | null,
): WebviewDownloadStartResponse {
  try {
    const response = context.invokeNativeSync(
      "download-start",
      DOWNLOAD_START_REQUEST_TYPE,
      DOWNLOAD_START_RESPONSE_TYPE,
      new WebviewDownloadStartRequest(id, nativeTag, url, tempPath) as ESObject,
    ) as WebviewDownloadStartResponse;
    if (
      response === null ||
      typeof response !== "object" ||
      typeof response.allow !== "boolean" ||
      (response.tempPath !== null && typeof response.tempPath !== "string")
    ) {
      throw new Error("Invalid WebView download-start response");
    }
    return response;
  } catch (error) {
    console.error("WebView download decision failed: " + String(error));
    // A download callback explicitly requested a synchronous admission decision. Failing closed
    // avoids writing to an unintended path when native state is no longer available.
    return { allow: false, tempPath: null };
  }
}

function notifyNative(
  context: BridgePluginContext,
  event: string,
  requestTypeName: string,
  value: ESObject,
): void {
  const response = context.invokeNativeSync(
    event,
    requestTypeName,
    EVENT_ACKNOWLEDGEMENT_TYPE,
    value,
  ) as WebviewEventAcknowledgement;
  if (response === null || typeof response !== "object" || response.accepted !== true) {
    throw new Error("WebView native notification was not accepted");
  }
}

function notifyWebEngineProcessWide(
  context: BridgePluginContext,
  event: string,
  requestTypeName: string,
  value: ESObject,
): WebviewSchemeDeclaration[] {
  const responses: ESObject[] = context.invokeNativeSyncProcessWide(
    event,
    requestTypeName,
    ENGINE_LIFECYCLE_RESPONSE_TYPE,
    value,
  ) as ESObject[];
  if (responses.length === 0) {
    throw new Error(`WebView native notification '${event}' had no active plugin receiver`);
  }
  const schemeOptions: Map<string, number> = new Map();
  for (let index: number = 0; index < responses.length; index++) {
    const responseValue: ESObject = responses[index];
    const response = responseValue as WebviewEngineLifecycleResponse;
    if (
      response === null ||
      typeof response !== "object" ||
      response.accepted !== true ||
      !Array.isArray(response.schemes)
    ) {
      throw new Error(
        `WebView native notification '${event}' was not accepted by every active plugin instance`,
      );
    }
    for (const declaration of response.schemes) {
      if (
        declaration === null ||
        typeof declaration !== "object" ||
        !declaration.scheme ||
        !Number.isInteger(declaration.options) ||
        declaration.options < 0
      ) {
        throw new Error(`WebView native notification '${event}' returned an invalid scheme`);
      }
      if (
        schemeOptions.has(declaration.scheme) &&
        schemeOptions.get(declaration.scheme) !== declaration.options
      ) {
        throw new Error(
          `WebView scheme '${declaration.scheme}' has conflicting options across active plugin instances`,
        );
      }
      schemeOptions.set(declaration.scheme, declaration.options);
    }
  }
  const declarations: WebviewSchemeDeclaration[] = [];
  for (const entry of schemeOptions.entries()) {
    declarations.push({ scheme: entry[0], options: entry[1] });
  }
  return declarations;
}

function setupDownloadDelegate(data: ManagedWebview): void {
  if (data.eventOptions.downloadStart !== true && data.eventOptions.downloadEnd !== true) {
    return;
  }
  const download = new webview.WebDownloadDelegate();
  if (data.eventOptions.downloadStart === true) {
    download.onBeforeDownload((event) => {
      const tempPath = event.getFullPath();
      const response = data.onDownloadStart(event.getUrl(), tempPath);
      if (response.allow) {
        event.start(response.tempPath ?? tempPath);
      } else {
        event.cancel();
      }
    });
  }
  if (data.eventOptions.downloadEnd === true) {
    download.onDownloadFinish((event) => {
      data.onDownloadEnd(event.getUrl(), event.getFullPath(), true);
    });
    download.onDownloadFailed((event) => {
      data.onDownloadEnd(event.getUrl(), null, false);
    });
  }
  try {
    data.controller.setDownloadDelegate(download);
  } catch (error) {
    throw new Error("Unable to set WebView download delegate: " + String(error));
  }
}

@Builder
function BuildWebview(data: ManagedWebview) {
  Web({ src: "", controller: data.controller as webview.WebviewController })
    .width(data.style.width ?? "100%")
    .height(data.style.height ?? "100%")
    .position({ x: data.style.x ?? 0, y: data.style.y ?? 0 })
    .backgroundColor(data.style.backgroundColor ?? undefined)
    .visibility(data.style.visible === false ? Visibility.Hidden : Visibility.Visible)
    .javaScriptAccess(data.javascriptEnabled ?? true)
    .mediaPlayGestureAccess(data.autoplay === true ? false : true)
    .javaScriptOnDocumentStart(data.initializationScripts ?? [])
    .onControllerAttached(() => {
      if (!data.beginControllerAttach()) {
        return;
      }
      try {
        if (data.userAgent !== undefined && data.userAgent !== null) {
          data.controller.setCustomUserAgent(data.userAgent);
        }
        // The controller is associated with the Web component at this point. Install delegates,
        // then synchronously flush Rust-owned protocol/proxy declarations before the first load.
        setupDownloadDelegate(data);
        data.notifyNativeControllerAttached();
        data.didInitialLoad = true;
        if (data.url) {
          data.controller.loadUrl(data.url, headersOf(data.headers));
        } else {
          data.controller.loadData(data.html!, "text/html", "UTF-8", " ", " ");
        }
        data.markControllerReady();
      } catch (error) {
        const reason = `WebView '${data.id}' controller initialization failed: ${String(error)}`;
        console.error(reason);
        data.failControllerAttach(reason);
      }
    })
    .onLoadIntercept((event) => data.onNavigationRequest(event.data.getRequestUrl()))
    .onTitleReceive((event) => data.onTitleChange(event.title));
}

const webviewBuilder = wrapBuilder<[ManagedWebview]>(BuildWebview);

/**
 * One surface per WebviewPlugin instance (per session and module). It owns no root node of its
 * own: every WebView is mounted either into this module's component root (full-bleed default) or
 * under a caller-provided container handle from the built-in ohos.node plugin.
 */
class WebviewSurface {
  private readonly entries: Map<string, WebviewEntry> = new Map();
  private disposed = false;
  private nextMountKey = 1;
  private readonly pluginContext: BridgePluginContext;

  constructor(pluginContext: BridgePluginContext) {
    this.pluginContext = pluginContext;
  }

  async create(payload: WebviewCreatePayload, callContext: BridgeCallContext): Promise<void> {
    this.assertActive();
    this.assertCallActive(callContext);
    this.remove(payload.id);
    const style = normalizeStyle(payload.style, payload.transparent);
    const eventOptions = normalizeEventOptions(payload.eventOptions);
    const parentHandle = payload.parentHandle ?? null;
    const instanceId = this.nextMountKey++;
    const nativeTagId = nextWebviewNativeTagId++;
    const nativeTag = `ohos.webview.${this.pluginContext.sessionId}.${nativeTagId}`;
    const data: ManagedWebview = {
      id: payload.id,
      mountParentHandle: parentHandle,
      mountKey: `ohos.webview.${instanceId}`,
      nativeTag,
      url: payload.url,
      html: payload.html,
      javascriptEnabled: payload.javascriptEnabled,
      devtools: payload.devtools,
      userAgent: payload.userAgent,
      autoplay: payload.autoplay,
      initializationScripts: payload.initializationScripts,
      headers: payload.headers,
      transparent: payload.transparent,
      eventOptions,
      controller: new webview.WebviewController(nativeTag) as WebviewController,
      style,
      didInitialLoad: false,
      beginControllerAttach: (): boolean => false,
      notifyNativeControllerAttached: (): void => {},
      markControllerReady: (): void => {},
      failControllerAttach: (_reason: string): void => {},
      onNavigationRequest: (url: string): boolean => {
        if (eventOptions.navigationIntercept !== true) {
          return false;
        }
        return navigationDecision(this.pluginContext, payload.id, nativeTag, url);
      },
      onTitleChange: (title: string): void => {
        if (eventOptions.titleChange !== true) {
          return;
        }
        try {
          notifyNative(
            this.pluginContext,
            "title-change",
            TITLE_CHANGE_EVENT_TYPE,
            new WebviewTitleChangeEvent(payload.id, nativeTag, title) as ESObject,
          );
        } catch (error) {
          console.error("WebView title notification failed: " + String(error));
        }
      },
      onDownloadStart: (url: string, tempPath: string | null): WebviewDownloadStartResponse => {
        return downloadStartDecision(this.pluginContext, payload.id, nativeTag, url, tempPath);
      },
      onDownloadEnd: (url: string, tempPath: string | null, success: boolean): void => {
        if (eventOptions.downloadEnd !== true) {
          return;
        }
        try {
          notifyNative(
            this.pluginContext,
            "download-end",
            DOWNLOAD_END_EVENT_TYPE,
            new WebviewDownloadEndEvent(payload.id, nativeTag, url, tempPath, success) as ESObject,
          );
        } catch (error) {
          console.error("WebView download-end notification failed: " + String(error));
        }
      },
    };
    ensureWebEngineInitialized(callContext);
    if (payload.devtools) {
      enableWebDebuggingIfAvailable();
    }
    const node = new BuilderNode<[ManagedWebview]>(this.pluginContext.getUIContext());
    const entry = new WebviewEntry(data, node);
    data.beginControllerAttach = (): boolean => entry.beginControllerAttach();
    data.notifyNativeControllerAttached = (): void => {
      notifyNative(
        this.pluginContext,
        "controller-attached",
        CONTROLLER_EVENT_TYPE,
        new WebviewControllerEvent(data.id, data.nativeTag) as ESObject,
      );
    };
    data.markControllerReady = (): void => entry.markControllerReady();
    data.failControllerAttach = (reason: string): void => entry.failController(reason);
    let registered = false;
    try {
      node.build(webviewBuilder, data);
      this.entries.set(payload.id, entry);
      registered = true;
      const frameNode = node.getFrameNode();
      if (frameNode === null) {
        throw new Error(`Unable to build WebView '${payload.id}': no FrameNode`);
      }
      if (parentHandle !== null) {
        this.pluginContext.getFrameNode(parentHandle).appendChild(frameNode);
      } else {
        this.pluginContext.appendChild(data.mountKey, frameNode, (): void => {
          try {
            frameNode.dispose();
          } catch {}
        });
      }
    } catch (error) {
      if (registered) {
        this.remove(payload.id, entry);
      }
      throw new Error(`Unable to attach WebView '${payload.id}': ${String(error)}`);
    }
    try {
      await entry.waitForController(callContext.onCancel);
      this.assertCallActive(callContext);
    } catch (error) {
      this.remove(payload.id, entry);
      throw new Error(`Unable to initialize WebView '${payload.id}': ${String(error)}`);
    }
  }

  setVisible(id: string, visible: boolean): boolean {
    const entry = this.entries.get(id);
    if (!entry) {
      return false;
    }
    entry.data.style.visible = visible;
    entry.node.update(entry.data);
    return true;
  }

  setBackgroundColor(id: string, color: string): boolean {
    const entry = this.entries.get(id);
    if (!entry) {
      return false;
    }
    entry.data.style.backgroundColor = color;
    entry.node.update(entry.data);
    return true;
  }

  async getUrl(id: string, callContext: BridgeCallContext): Promise<string> {
    const entry = await this.controllerEntry(id, callContext);
    try {
      return entry.data.controller.getUrl();
    } catch (error) {
      throw new Error(`Unable to get WebView URL: ${String(error)}`);
    }
  }

  async loadUrl(
    id: string,
    url: string,
    headers: Record<string, string> | null | undefined,
    callContext: BridgeCallContext,
  ): Promise<void> {
    const entry = await this.controllerEntry(id, callContext);
    try {
      entry.data.controller.loadUrl(url, headersOf(headers));
    } catch (error) {
      throw new Error(`Unable to load WebView URL: ${String(error)}`);
    }
  }

  async loadHtml(id: string, html: string, callContext: BridgeCallContext): Promise<void> {
    const entry = await this.controllerEntry(id, callContext);
    try {
      entry.data.controller.loadData(html, "text/html", "UTF-8", " ", " ");
    } catch (error) {
      throw new Error(`Unable to load WebView HTML: ${String(error)}`);
    }
  }

  async setZoom(id: string, zoom: number, callContext: BridgeCallContext): Promise<void> {
    const entry = await this.controllerEntry(id, callContext);
    try {
      entry.data.controller.zoom(zoom);
    } catch (error) {
      throw new Error(`Unable to set WebView zoom: ${String(error)}`);
    }
  }

  async reload(id: string, callContext: BridgeCallContext): Promise<void> {
    const entry = await this.controllerEntry(id, callContext);
    try {
      entry.data.controller.refresh();
    } catch (error) {
      throw new Error(`Unable to reload WebView: ${String(error)}`);
    }
  }

  async focus(id: string, callContext: BridgeCallContext): Promise<void> {
    const entry = await this.controllerEntry(id, callContext);
    try {
      entry.data.controller.requestFocus();
    } catch (error) {
      throw new Error(`Unable to focus WebView: ${String(error)}`);
    }
  }

  async cookiesWithUrl(id: string, url: string, callContext: BridgeCallContext): Promise<string> {
    await this.controllerEntry(id, callContext);
    try {
      return webview.WebCookieManager.fetchCookieSync(url);
    } catch (error) {
      throw new Error(`Unable to get WebView cookies: ${String(error)}`);
    }
  }

  async clearAllBrowsingData(id: string, callContext: BridgeCallContext): Promise<void> {
    const entry = await this.controllerEntry(id, callContext);
    try {
      webview.WebStorage.deleteAllData(true);
      webview.WebDataBase.deleteHttpAuthCredentials();
      entry.data.controller.removeCache(true);
      entry.data.controller.clearHistory();
    } catch (error) {
      throw new Error(`Unable to clear WebView browsing data: ${String(error)}`);
    }
  }

  remove(id: string, expected?: WebviewEntry, detachNode: boolean = true): boolean {
    const entry = this.entries.get(id);
    if (!entry || (expected !== undefined && entry !== expected)) {
      return false;
    }
    this.entries.delete(id);
    entry.failController(`WebView '${id}' was removed before its controller attached`);
    if (detachNode) {
      const parentHandle = entry.data.mountParentHandle;
      if (parentHandle !== null) {
        const frameNode = entry.node.getFrameNode();
        if (frameNode !== null) {
          try {
            this.pluginContext.getFrameNode(parentHandle).removeChild(frameNode);
          } catch {}
          try {
            frameNode.dispose();
          } catch {}
        }
      } else {
        this.pluginContext.removeChild(entry.data.mountKey);
      }
    }
    try {
      notifyNative(
        this.pluginContext,
        "controller-removed",
        CONTROLLER_EVENT_TYPE,
        new WebviewControllerEvent(id, entry.data.nativeTag) as ESObject,
      );
    } catch (error) {
      console.error("WebView controller-removed notification failed: " + String(error));
    }
    return true;
  }

  async evaluateScript(
    id: string,
    script: string,
    callContext: BridgeCallContext,
  ): Promise<string | null> {
    const entry = await this.controllerEntry(id, callContext);
    try {
      return await entry.data.controller.runJavaScript(script);
    } catch (error) {
      throw new Error(`Unable to evaluate WebView JavaScript: ${String(error)}`);
    }
  }

  dispose(detachNodes: boolean = true): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    for (const id of Array.from(this.entries.keys())) {
      this.remove(id, undefined, detachNodes);
    }
  }

  private assertActive(): void {
    if (this.disposed) {
      throw new Error("WebView surface is already disposed");
    }
  }

  private async controllerEntry(id: string, callContext: BridgeCallContext): Promise<WebviewEntry> {
    this.assertCallActive(callContext);
    const entry = this.entries.get(id);
    if (!entry) {
      throw new Error(`Unknown WebView controller '${id}'`);
    }
    await entry.waitForController(callContext.onCancel);
    this.assertCallActive(callContext);
    return entry;
  }

  private assertCallActive(callContext: BridgeCallContext): void {
    if (!callContext.isActive()) {
      throw new Error("Bridge call is no longer active");
    }
  }
}

export class WebviewPlugin extends AsyncPluginBase {
  readonly id = "ohos.webview";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];
  private surface?: WebviewSurface;

  override onInstall(_context: BridgePluginHookContext): void {
    this.surface = new WebviewSurface(this.getContext());
  }

  override onLifecycle(event: BridgeLifecycleEvent, _context: BridgePluginHookContext): void {
    if (event.kind === "ui-context-destroy") {
      // BridgeHost already detached this module's component and owns its node-tree cleanup.
      this.surface?.dispose(false);
      this.surface = undefined;
      return;
    }
    if (event.kind === "ui-context-ready" && this.surface === undefined) {
      this.surface = new WebviewSurface(this.getContext());
    }
  }

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }
    const surface = this.requireSurface();
    if (action === "create") {
      const createPayload = ensureCreatePayload(parseCreatePayload(payload));
      await surface.create(createPayload, context);
      if (!context.isActive()) {
        throw new Error(
          "Bridge session is no longer active after WebView controller initialization",
        );
      }
      return {
        typeName: CREATE_RESPONSE_TYPE,
        value: new WebviewCreatedResponse(createPayload.id),
      };
    }

    if (action === "evaluate-script") {
      const scriptPayload = parseScriptPayload(payload);
      const result = await surface.evaluateScript(scriptPayload.id, scriptPayload.script, context);
      return {
        typeName: SCRIPT_RESPONSE_TYPE,
        value: new WebviewScriptResponse(result),
      };
    }

    const controllerPayload = parseControllerPayload(payload, action);
    if (!controllerPayload?.id?.trim()) {
      throw new Error("WebView controller id must not be empty");
    }
    let accepted = false;
    if (action === "get-url") {
      return {
        typeName: STRING_RESPONSE_TYPE,
        value: new WebviewStringResponse(await surface.getUrl(controllerPayload.id, context)),
      };
    } else if (action === "load-url") {
      await surface.loadUrl(
        controllerPayload.id,
        requireControllerString(controllerPayload.url, "load-url.url"),
        controllerPayload.headers,
        context,
      );
      accepted = true;
    } else if (action === "load-html") {
      await surface.loadHtml(
        controllerPayload.id,
        requireControllerString(controllerPayload.html, "load-html.html"),
        context,
      );
      accepted = true;
    } else if (action === "set-zoom") {
      if (typeof controllerPayload.zoom !== "number" || !Number.isFinite(controllerPayload.zoom)) {
        throw new Error("set-zoom.zoom must be a finite number");
      }
      await surface.setZoom(controllerPayload.id, controllerPayload.zoom, context);
      accepted = true;
    } else if (action === "reload") {
      await surface.reload(controllerPayload.id, context);
      accepted = true;
    } else if (action === "focus") {
      await surface.focus(controllerPayload.id, context);
      accepted = true;
    } else if (action === "cookies-with-url") {
      return {
        typeName: STRING_RESPONSE_TYPE,
        value: new WebviewStringResponse(
          await surface.cookiesWithUrl(
            controllerPayload.id,
            requireControllerString(controllerPayload.url, "cookies-with-url.url"),
            context,
          ),
        ),
      };
    } else if (action === "clear-all-browsing-data") {
      await surface.clearAllBrowsingData(controllerPayload.id, context);
      accepted = true;
    } else if (action === "set-visible") {
      if (typeof controllerPayload.visible !== "boolean") {
        throw new Error("set-visible.visible must be a boolean");
      }
      accepted = surface.setVisible(controllerPayload.id, controllerPayload.visible);
    } else if (action === "set-background-color") {
      if (!controllerPayload.color) {
        throw new Error("set-background-color.color must not be empty");
      }
      accepted = surface.setBackgroundColor(controllerPayload.id, controllerPayload.color);
    } else if (action === "remove") {
      accepted = surface.remove(controllerPayload.id);
    } else {
      throw new Error(`Unsupported ohos.webview action '${action}'`);
    }
    return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WebviewAcceptedResponse(accepted) };
  }

  override onDispose(_context: BridgePluginHookContext): void {
    const surface = this.surface;
    this.surface = undefined;
    surface?.dispose();
  }

  private requireSurface(): WebviewSurface {
    const surface = this.surface;
    if (surface === undefined) {
      throw new Error(
        "WebView surface is not installed; the ohos.webview plugin requires ui-context readiness",
      );
    }
    return surface;
  }
}

declare class WebviewController extends webview.WebviewController {}
