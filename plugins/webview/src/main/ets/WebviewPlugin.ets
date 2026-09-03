import { WebHeader } from "@kit.ArkUI";
import { BuilderNode } from "@ohos.arkui.node";
import webview from "@ohos.web.webview";
import { image } from "@kit.ImageKit";
import { buffer } from "@kit.ArkTS";
import { fileIo, fileUri } from "@kit.CoreFileKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, print } from "@kit.BasicServicesKit";
import { abilityAccessCtrl, common } from "@kit.AbilityKit";
import { unifiedDataChannel, uniformTypeDescriptor, uniformDataStruct } from "@kit.ArkData";
import { openNewWindowDialog } from "./NewWindowDialog";
import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgePluginContext,
  BridgePluginHookContext,
  AsyncPluginBase,
  BridgeContextRequirement,
  BridgeLifecycleEvent,
  WindowManager,
  notifyPrimaryWebviewController,
  notifyKeySynthesisController,
  KEY_SYNTHESIS_SHIM,
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
const PRINT_REQUEST_TYPE = "ohos.webview.PrintRequest";
const PRINT_RESPONSE_TYPE = "ohos.webview.PrintResponse";
const PRINT_STATE_EVENT_TYPE = "ohos.webview.PrintStateEvent";

const PRINT_LOG_DOMAIN = 0x9801;
const PRINT_LOG_TAG = "WebviewPrint";
// Mirrors native_ability helper/constants.ets NATIVE_MODULE_STORAGE_KEY; not re-exported
// through the @ohos-rs/ability barrel, so defined locally for the close-window path.
const NATIVE_MODULE_STORAGE_KEY = '__native_module__';
const SNAPSHOT_REQUEST_TYPE = "ohos.webview.SnapshotRequest";
const SNAPSHOT_RESPONSE_TYPE = "ohos.webview.SnapshotResponse";
const CAPTURE_RESPONSE_TYPE = "ohos.webview.CaptureResponse";
const PICK_COLOR_RESPONSE_TYPE = "ohos.webview.PickColorResponse";
const USER_AGENT_REQUEST_TYPE = "ohos.webview.UserAgentRequest";
const DRAG_EVENT_TYPE = "ohos.webview.DragEvent";
const DROP_EVENT_TYPE = "ohos.webview.DropEvent";
const NEW_WINDOW_REQUEST_TYPE = "ohos.webview.NewWindowRequest";
const NEW_WINDOW_RESPONSE_TYPE = "ohos.webview.NewWindowResponse";

const PAGE_EVENT_TYPE = "ohos.webview.PageEvent";
const HTTPS_INTERCEPT_REQUEST_TYPE = "ohos.webview.HttpsInterceptRequest";
const HTTPS_INTERCEPT_RESPONSE_TYPE = "ohos.webview.HttpsInterceptResponse";
const REGISTER_HTTPS_INTERCEPT_REQUEST_TYPE = "ohos.webview.RegisterHttpsInterceptRequest";
const SET_COOKIE_REQUEST_TYPE = "ohos.webview.SetCookieRequest";

/** Shape of the Web component onInterceptRequest callback event. */
interface WebInterceptRequestEvent {
  request: WebResourceRequest;
}

/** Optional static ArkWeb API resolved dynamically to preserve the API-12 package baseline. */
interface WebviewDebuggingApi {
  setWebDebuggingAccess?: (enabled: boolean) => void;
}

function setWebDebuggingAccessIfAvailable(enabled: boolean): void {
  const debuggingApi = webview.WebviewController as ESObject as WebviewDebuggingApi;
  if (typeof debuggingApi.setWebDebuggingAccess !== "function") {
    console.warn("WebView debugging is unavailable on this ArkWeb API level");
    return;
  }
  debuggingApi.setWebDebuggingAccess(enabled);
}

function enableWebDebuggingIfAvailable(): void {
  setWebDebuggingAccessIfAvailable(true);
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
  /** Blur radius for vibrancy/frosted glass effect. Applied via backdropBlur on the Web component. */
  blurRadius?: number | null;
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
  dragDrop?: boolean | null;
  newWindow?: boolean | null;
  pageBegin?: boolean | null;
  pageEnd?: boolean | null;
}

interface WebviewCreatePayload {
  id: string;
  /**
   * Optional opaque container handle issued by the built-in ohos.node plugin. When provided the
   * WebView FrameNode is appended under that container instead of this module's component root,
   * so an RS-layer node tree can adopt WebViews as children.
   */
  parentHandle?: number | null;
  /** OHOS window ID for sub-window mounting. When set, the WebView mounts into
   *  the specified window's component root instead of this module's root. */
  windowId?: number | null;
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
  /** Enable ArkWeb native clipboard (Ctrl+C/V/X/A/Z/Y). Defaults to true. */
  clipboard?: boolean | null;
  /** Enable zoom hotkeys (Ctrl+/-/0). Defaults to false. */
  zoomHotkeys?: boolean | null;
  /** Use a transparent Stack overlay to receive drag events. Defaults to false. */
  dragDropOverlay?: boolean | null;
  /** https-scheme protocols to intercept at create time (seeds httpsInterceptProtocols
   *  before first loadUrl, fixing the create-vs-register race that left the set empty).
   *  Wire payload uses an array (napi object); ManagedWebview stores it as a Set. */
  httpsInterceptProtocolList?: string[] | null;
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
  x?: number | null;
  y?: number | null;
  width?: number | null;
  height?: number | null;
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
  onCloseWindow?: () => void;
  onTitleChange: (title: string) => void;
  onDownloadStart: (url: string, tempPath: string | null) => WebviewDownloadStartResponse;
  onDownloadEnd: (url: string, tempPath: string | null, success: boolean) => void;
  onDragEnter: (x: number, y: number) => void;
  onDragMove: (x: number, y: number) => void;
  onDrop: (x: number, y: number, paths: string[]) => void;
  onDragLeave: (x: number, y: number) => void;
  onPageBegin: (url: string) => void;
  onPageEnd: (url: string) => void;
  onNewWindow: (targetUrl: string, isAlert: boolean, isUserTrigger: boolean) => boolean;
  /**
   * In-page popup shown by the `.onWindowNew` Allow branch. ArkWeb's own popup is
   * cancelled (`setWebController(null)`) to avoid deadlocking the UI thread on an
   * unhosted controller (#85); this dialog's `Web` loads the target URL directly
   * (NewWindowDialog builder `src=params.url`), giving the OHOS equivalent of
   * "open in a new in-page window" (Allow). Defined in `create()` where
   * `this.pluginContext.getUIContext()` is in scope (the `@Builder` hosting the
   * `onWindowNew` closure is a free function with no `this`).
   */
  onShowNewWindow?: (controller: webview.WebviewController, url: string) => void;
  /** How this WebView was mounted: a parent-handle container or the component root. */
  mountParentHandle: number | null;
  /** Host-internal cleanup key; WebView IDs remain opaque business identifiers. */
  mountKey: string;
  /**
   * Live set of custom-protocol names registered for https interception. Populated by the
   * `register-https-intercept` action. `onInterceptRequest` checks this set before dispatching
   * through the bridge, so unregistered protocols fall through to ArkWeb's default network stack.
   */
  httpsInterceptProtocols: Set<string>;
  /**
   * Synchronous https intercept handler. Receives the full request URL, dispatches through the
   * `https-intercept` bridge event, and constructs a `WebResourceResponse` (or returns null to
   * let ArkWeb continue with its default network stack).
   */
  onHttpsInterceptRequest: (url: string) => WebResourceResponse | null;
  /** Trailing debounce timer for onAreaChange → resize dispatch. Prevents flooding
   *  ArkWeb with rapid JS dispatches during drag-resize. */
  resizeDebounceTimer: number;
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

class WebviewPrintStateEvent {
  readonly id: string;
  readonly state: string;
  // Optional: absent when there is no error. The NAPI bridge cannot decode a
  // JS `null` into Rust `Option<String>` (treated as `String` → conversion
  // error), so the field must be left unset rather than set to null.
  readonly error?: string;

  constructor(id: string, state: string, error?: string) {
    this.id = id;
    this.state = state;
    if (error !== undefined && error !== null) {
      this.error = error;
    }
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

class WebviewDragEventPayload {
  readonly id: string;
  readonly nativeTag: string;
  readonly x: number;
  readonly y: number;

  constructor(id: string, nativeTag: string, x: number, y: number) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.x = x;
    this.y = y;
  }
}

class WebviewDropEventPayload {
  readonly id: string;
  readonly nativeTag: string;
  readonly x: number;
  readonly y: number;
  readonly paths: string[];

  constructor(id: string, nativeTag: string, x: number, y: number, paths: string[]) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.x = x;
    this.y = y;
    this.paths = paths;
  }
}

class WebviewNewWindowRequestPayload {
  readonly id: string;
  readonly nativeTag: string;
  readonly targetUrl: string;
  readonly isAlert: boolean;
  readonly isUserTrigger: boolean;

  constructor(
    id: string,
    nativeTag: string,
    targetUrl: string,
    isAlert: boolean,
    isUserTrigger: boolean,
  ) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.targetUrl = targetUrl;
    this.isAlert = isAlert;
    this.isUserTrigger = isUserTrigger;
  }
}

interface WebviewNewWindowResponse {
  allow: boolean;
}

class WebviewPageEventPayload {
  readonly id: string;
  readonly nativeTag: string;
  readonly url: string;

  constructor(id: string, nativeTag: string, url: string) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.url = url;
  }
}

class WebviewHttpsInterceptRequestPayload {
  readonly id: string;
  readonly nativeTag: string;
  readonly url: string;

  constructor(id: string, nativeTag: string, url: string) {
    this.id = id;
    this.nativeTag = nativeTag;
    this.url = url;
  }
}

interface WebviewHttpsInterceptResponse {
  handled: boolean;
  status: number;
  mimeType: string;
  body: Uint8Array;
}

interface WebviewRegisterHttpsInterceptPayload {
  id: string;
  protocols: string[];
}

interface WebviewPdfConfig {
  width?: number;
  height?: number;
  marginTop?: number;
  marginBottom?: number;
  marginLeft?: number;
  marginRight?: number;
  scale?: number;
  shouldPrintBackground?: boolean;
}

interface WebviewPrintRequest {
  id: string;
  path: string;
  pdfConfig?: WebviewPdfConfig | null;
}

class WebviewPrintResponse {
  readonly success: boolean;

  constructor(success: boolean) {
    this.success = success;
  }
}

interface WebviewSnapshotRequest {
  id: string;
}

class WebviewSnapshotResponse {
  readonly success: boolean;
  readonly width: number;
  readonly height: number;
  readonly rgbaLen: number;

  constructor(success: boolean, width: number, height: number, rgbaLen: number) {
    this.success = success;
    this.width = width;
    this.height = height;
    this.rgbaLen = rgbaLen;
  }
}

class WebviewCaptureResponse {
  readonly pngBase64: string;
  readonly width: number;
  readonly height: number;

  constructor(pngBase64: string, width: number, height: number) {
    this.pngBase64 = pngBase64;
    this.width = width;
    this.height = height;
  }
}

class WebviewPickColorResponse {
  readonly r: number;
  readonly g: number;
  readonly b: number;
  readonly a: number;

  constructor(r: number, g: number, b: number, a: number) {
    this.r = r;
    this.g = g;
    this.b = b;
    this.a = a;
  }
}

interface WebviewUserAgentRequest {
  id: string;
  userAgent: string;
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

function parsePrintRequest(payload: BridgeTypedValue): WebviewPrintRequest {
  if (
    payload.typeName !== PRINT_REQUEST_TYPE ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`ohos.webview.create-pdf requires bridge type ${PRINT_REQUEST_TYPE}`);
  }
  const request = payload.value as WebviewPrintRequest;
  if (!request?.id?.trim()) {
    throw new Error("WebView print controller id must not be empty");
  }
  if (typeof request.path !== "string" || !request.path.trim()) {
    throw new Error("WebView print path must be a non-empty string");
  }
  return request;
}

function parseSnapshotRequest(payload: BridgeTypedValue): WebviewSnapshotRequest {
  if (
    payload.typeName !== SNAPSHOT_REQUEST_TYPE ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`ohos.webview.web-page-snapshot requires bridge type ${SNAPSHOT_REQUEST_TYPE}`);
  }
  const request = payload.value as WebviewSnapshotRequest;
  if (!request?.id?.trim()) {
    throw new Error("WebView snapshot controller id must not be empty");
  }
  return request;
}

function parseUserAgentRequest(payload: BridgeTypedValue): WebviewUserAgentRequest {
  if (
    payload.typeName !== USER_AGENT_REQUEST_TYPE ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`ohos.webview.set-user-agent requires bridge type ${USER_AGENT_REQUEST_TYPE}`);
  }
  const request = payload.value as WebviewUserAgentRequest;
  if (!request?.id?.trim()) {
    throw new Error("WebView user-agent controller id must not be empty");
  }
  if (typeof request.userAgent !== "string") {
    throw new Error("WebView user-agent must be a string");
  }
  return request;
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
    dragDrop: optionalEventFlag(options?.dragDrop, "WebView eventOptions.dragDrop"),
    newWindow: optionalEventFlag(options?.newWindow, "WebView eventOptions.newWindow"),
    pageBegin: optionalEventFlag(options?.pageBegin, "WebView eventOptions.pageBegin"),
    pageEnd: optionalEventFlag(options?.pageEnd, "WebView eventOptions.pageEnd"),
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
  if (style.blurRadius !== undefined && style.blurRadius !== null) {
    normalized.blurRadius = style.blurRadius;
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

/** Best-effort print-job terminal-state notification to Rust (fire-and-forget). */
function notifyPrintState(
  context: BridgePluginContext,
  id: string,
  state: string,
  error?: string,
): void {
  try {
    notifyNative(
      context,
      "print-state",
      PRINT_STATE_EVENT_TYPE,
      new WebviewPrintStateEvent(id, state, error) as ESObject,
    );
  } catch (e) {
    // Best-effort: the bridge session may be disposed before the print dialog
    // closes (webview navigated/destroyed). Drop silently — the terminal state
    // is informational, not part of the printPdf call contract.
    console.error("WebView print-state notification failed: " + String(e));
  }
}

// Strong references to live PrintTask objects, keyed by webview id. The task
// returned by print.print() must outlive printPdf() — it is a local proxy
// holding the framework's event callback; once GC'd the framework unregisters
// the task callback ("UnregisterPrintTaskCallback: The job is not completed")
// and no terminal event (succeed/fail/cancel) is ever delivered to the app.
// Entries are cleared on the first terminal state.
const activePrintTasks = new Map<string, ESObject>();

/**
 * Synchronous https intercept handler for ArkWeb's `onInterceptRequest`.
 *
 * Matches `https://<protocol>.localhost/<path>` against the WebView's live protocol set. On match:
 * dispatches through the `https-intercept` bridge event synchronously, constructs a
 * `WebResourceResponse` from the returned body bytes, and returns it. On no match, handler
 * decline, or bridge dispatch failure: returns null so ArkWeb uses its default network stack.
 */
function handleHttpsIntercept(
  data: ManagedWebview,
  url: string,
): WebResourceResponse | null {
  if (!url || !url.startsWith("https://")) {
    if (url) {
      hilog.info(0x1999, 'WebviewSurface',
        '[https-intercept] handleHttpsIntercept skip (not https): id=%{public}s url=%{public}s',
        String(data.id), url);
    }
    return null;
  }
  const protocols = data.httpsInterceptProtocols;
  if (!protocols || protocols.size === 0) {
    hilog.info(0x1999, 'WebviewSurface',
      '[https-intercept] handleHttpsIntercept skip (no protocols): id=%{public}s url=%{public}s',
      String(data.id), url);
    return null;
  }
  const rest = url.substring("https://".length);
  const dotIdx = rest.indexOf(".");
  if (dotIdx <= 0) return null;
  const protocol = rest.substring(0, dotIdx);
  if (!protocols.has(protocol)) {
    hilog.info(0x1999, 'WebviewSurface',
      '[https-intercept] handleHttpsIntercept skip (protocol not in set): id=%{public}s url=%{public}s protocol=%{public}s',
      String(data.id), url, protocol);
    return null;
  }
  hilog.info(0x1999, 'WebviewSurface',
    '[https-intercept] handleHttpsIntercept match: id=%{public}s url=%{public}s protocol=%{public}s — dispatching to bridge',
    String(data.id), url, protocol);
  try {
    const response = data.onHttpsInterceptRequest(url);
    hilog.info(0x1999, 'WebviewSurface',
      '[https-intercept] handleHttpsIntercept result: id=%{public}s handled=%{public}s response_is_null=%{public}s',
      String(data.id), response !== null ? 'true' : 'false', response === null ? 'true' : 'false');
    return response;
  } catch (error) {
    hilog.error(0x1999, 'WebviewSurface',
      '[https-intercept] handleHttpsIntercept exception: id=%{public}s url=%{public}s error=%{public}s',
      String(data.id), url, String(error));
    return null;
  }
}

/**
 * Invokes a reverse event that returns a boolean response (e.g. new-window-request).
 */
function invokeNativeBool(
  context: BridgePluginContext,
  event: string,
  requestTypeName: string,
  responseTypeName: string,
  value: ESObject,
  fallback: boolean,
): boolean {
  try {
    const response = context.invokeNativeSync(
      event,
      requestTypeName,
      responseTypeName,
      value,
    ) as WebviewNewWindowResponse;
    if (
      response === null ||
      typeof response !== "object" ||
      typeof response.allow !== "boolean"
    ) {
      return fallback;
    }
    return response.allow;
  } catch (error) {
    console.error("WebView " + event + " decision failed: " + String(error));
    return fallback;
  }
}

/**
 * Drag event helpers ported from _legacy/DefaultWebview.ets.
 * Extracts UDMF record URIs from ArkUI DragEvent.getData() (only valid in onDrop).
 */

function extractDragPaths(dragEvent: DragEvent): string[] {
  try {
    const ud: unifiedDataChannel.UnifiedData = dragEvent.getData();
    if (!ud) {
      return [];
    }
    const records: Array<unifiedDataChannel.UnifiedRecord> = ud.getRecords();
    if (!records || records.length === 0) {
      return [];
    }
    const uris: Array<string> = [];
    for (let i = 0; i < records.length; i++) {
      const uri = extractRecordUri(records[i]);
      if (uri.length > 0) {
        uris.push(uri);
      }
    }
    return uris;
  } catch (e) {
    return [];
  }
}

function extractRecordUri(record: unifiedDataChannel.UnifiedRecord): string {
  try {
    const types = record.getTypes();
    if (types.includes(uniformTypeDescriptor.UniformDataType.FILE_URI)) {
      const fileUriUds = record.getEntry(
        uniformTypeDescriptor.UniformDataType.FILE_URI,
      ) as uniformDataStruct.FileUri;
      if (fileUriUds && fileUriUds.oriUri) {
        return stripDragScheme(fileUriUds.oriUri);
      }
    }
    const img = record as unifiedDataChannel.Image;
    if (img && img.imageUri) {
      return stripDragScheme(img.imageUri);
    }
  } catch (e) {
    // record type not extractable
  }
  return "";
}

function readDragX(dragEvent: DragEvent): number {
  try {
    return dragEvent.getX();
  } catch (e) {
    return 0;
  }
}

function readDragY(dragEvent: DragEvent): number {
  try {
    return dragEvent.getY();
  } catch (e) {
    return 0;
  }
}

function stripDragScheme(raw: string): string {
  if (raw.startsWith("file://")) {
    return raw.substring("file://".length);
  }
  if (raw.startsWith("datashare://")) {
    return raw.substring("datashare://".length);
  }
  return raw;
}

/**
 * Extracts a file path from a file:// URL intercepted by onLoadIntercept.
 * ArkWeb consumes OS file drops by navigating to file://<dropped file>, which preempts onDrop.
 * The reliable interception point is onLoadIntercept blocking file:// navigation.
 */
function pathFromFileUrl(url: string): string {
  let raw = url;
  if (raw.startsWith("file://")) {
    raw = raw.substring("file://".length);
  }
  try {
    return stripDragScheme(decodeURIComponent(raw));
  } catch (e) {
    return stripDragScheme(raw);
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
  if (data.eventOptions.dragDrop === true && data.dragDropOverlay === true) {
    // Overlay mode: Web does not receive drag events; transparent Stack above it does.
    Stack() {
      Web({ src: "", controller: data.controller as webview.WebviewController, renderMode: data.transparent === true ? RenderMode.SYNC_RENDER : RenderMode.ASYNC_RENDER })
        .width("100%")
        .height("100%")
        .position({ x: data.style.x ?? 0, y: data.style.y ?? 0 })
        .backgroundColor(data.transparent === true ? Color.Transparent : (data.style.backgroundColor ?? undefined))
        .visibility(data.style.visible === false ? Visibility.Hidden : Visibility.Visible)
        // Vibrancy: backdropBlur for opaque sub-windows (see Direct mode comment)
        .backdropBlur(data.style.blurRadius ?? 0)
        // Debounce resize JS dispatch to avoid flooding ArkWeb during drag-resize.
        // Mirrors the proven legacy DefaultWebview.ets pattern (ASYNC_RENDER + dispatchEvent).
        .onAreaChange((oldArea: Area, newArea: Area) => {
          hilog.info(0x1999, 'WebviewSurface',
            'onAreaChange: oldW=%{public}s oldH=%{public}s newW=%{public}s newH=%{public}s',
            String(oldArea.width), String(oldArea.height), String(newArea.width), String(newArea.height));
          if (data.resizeDebounceTimer) {
            clearTimeout(data.resizeDebounceTimer);
          }
          data.resizeDebounceTimer = setTimeout(() => {
            data.resizeDebounceTimer = 0;
            try {
              data.controller.runJavaScript('window.dispatchEvent(new Event("resize"));')
                .catch(() => { /* fire-and-forget */ });
            } catch (_e) { /* synchronous throw guard */ }
          }, 50);
        })
        .javaScriptAccess(data.javascriptEnabled ?? true)
        .domStorageAccess(true)
        .mediaPlayGestureAccess(data.autoplay === true ? false : true)
        .javaScriptOnDocumentStart(keySynthesisScripts(data))
        .multiWindowAccess(data.eventOptions.newWindow === true)
        .allowWindowOpenMethod(data.eventOptions.newWindow === true)
        .onControllerAttached(() => {
          handleControllerAttached(data);
        })
        .onLoadIntercept((event) => handleLoadIntercept(data, event.data.getRequestUrl()))
        .onInterceptRequest((event) => {
          const interceptUrl = (event as WebInterceptRequestEvent).request.getRequestUrl();
          hilog.info(0x1999, 'WebviewSurface',
            '[https-intercept] onInterceptRequest fired: id=%{public}s url=%{public}s protocols_size=%{public}d',
            String(data.id), interceptUrl ?? 'null', data.httpsInterceptProtocols?.size ?? 0);
          return handleHttpsIntercept(data, interceptUrl);
        })
        .onTitleReceive((event) => data.onTitleChange(event.title))
        .onPageBegin((e) => {
          if (data.eventOptions.pageBegin === true) {
            data.onPageBegin(e.url);
          }
        })
        .onPageEnd((e) => {
          if (data.eventOptions.pageEnd === true) {
            data.onPageEnd(e.url);
          }
        })
        .onWindowNew((e) => {
          if (data.eventOptions.newWindow !== true) {
            e.handler.setWebController(null);
            return;
          }
          const allow = data.onNewWindow(
            e.targetUrl ?? "",
            e.isAlert ?? false,
            e.isUserTrigger ?? false,
          );
          if (!allow) {
            e.handler.setWebController(null);
          } else {
            // Allow: the embedding runtime permits the new window. `data.onNewWindow`
            // above already ran the synchronous `invokeNativeSync("new-window-request")`
            // round-trip and Rust emitted the `new-window-requested` event
            // unconditionally (src-tauri/src/lib.rs, before the allow/deny branch),
            // so the event is already queued for JS.
            //
            // We cancel ArkWeb's own popup via `setWebController(null)` (non-blocking;
            // `setWebController` on an unhosted controller would permanently block the
            // UI thread) and instead show an in-page NewWindowDialog whose `Web` loads
            // the target URL directly — the OHOS equivalent of "open in a new in-page
            // window" (Allow). The dialog's controller is independent of `e.handler`,
            // so there is no deadlock. The auto suite uses Create mode (create=true →
            // Rust returns Create → allow=false), so this branch only fires for the
            // manual Allow button.
            e.handler.setWebController(null);
            try {
              data.onShowNewWindow?.(new webview.WebviewController(), e.targetUrl ?? '');
            } catch (err) {
              hilog.warn(0x1999, 'WebviewSurface', 'Allow new-window dialog failed: %{public}s', String(err));
            }
          }
        });

      Stack()
        .width("100%")
        .height("100%")
        .backgroundColor(Color.Transparent)
        .hitTestBehavior(HitTestMode.Transparent)
        .onDragEnter((dragEvent: DragEvent) => {
          data.onDragEnter(readDragX(dragEvent), readDragY(dragEvent));
        })
        .onDragMove((dragEvent: DragEvent) => {
          data.onDragMove(readDragX(dragEvent), readDragY(dragEvent));
        })
        .onDrop((dragEvent: DragEvent) => {
          const paths = extractDragPaths(dragEvent);
          data.onDrop(readDragX(dragEvent), readDragY(dragEvent), paths);
        })
        .onDragLeave((dragEvent: DragEvent) => {
          data.onDragLeave(readDragX(dragEvent), readDragY(dragEvent));
        });
    }
    .width("100%")
    .height("100%");
  } else {
    // Direct mode: drag events bound directly on the Web component.
    Web({ src: "", controller: data.controller as webview.WebviewController, renderMode: data.transparent === true ? RenderMode.SYNC_RENDER : RenderMode.ASYNC_RENDER })
      // Always "100%": natural ArkUI layout so the Web follows its parent container on
      // window resize. set_bounds (BuilderNode.update) re-runs this builder but only
      // .position() below consumes style.{x,y} — sizing via fixed px here would pin the
      // Web component and break ArkWeb viewport tracking on resize (bottom cutoff).
      .width("100%")
      .height("100%")
      .position({ x: data.style.x ?? 0, y: data.style.y ?? 0 })
      // Transparent windows: force Web background to transparent so vibrancy/blur
      // effects are visible through the Web component. Without this, the Web renders
      // with its default opaque background, hiding any blur effect.
      .backgroundColor(data.transparent === true ? Color.Transparent : (data.style.backgroundColor ?? undefined))
      .visibility(data.style.visible === false ? Visibility.Hidden : Visibility.Visible)
      // Vibrancy/frosted glass: backdropBlur blurs in-surface pixels of the Web component.
      // Works on opaque containers (Float sub-windows where setWindowContainerColor returns 1300004).
      // The blur radius is read from WindowManager.getPendingBlur() at webview creation time.
      .backdropBlur(data.style.blurRadius ?? 0)
      // Debounce resize JS dispatch to avoid flooding ArkWeb during drag-resize.
      // Mirrors the proven legacy DefaultWebview.ets pattern (ASYNC_RENDER + dispatchEvent).
      .onAreaChange((oldArea: Area, newArea: Area) => {
        hilog.info(0x1999, 'WebviewSurface',
          'onAreaChange: oldW=%{public}s oldH=%{public}s newW=%{public}s newH=%{public}s',
          String(oldArea.width), String(oldArea.height), String(newArea.width), String(newArea.height));
        if (data.resizeDebounceTimer) {
          clearTimeout(data.resizeDebounceTimer);
        }
        data.resizeDebounceTimer = setTimeout(() => {
          data.resizeDebounceTimer = 0;
          try {
            data.controller.runJavaScript('window.dispatchEvent(new Event("resize"));')
              .catch(() => { /* fire-and-forget */ });
          } catch (_e) { /* synchronous throw guard */ }
        }, 50);
      })
      .javaScriptAccess(data.javascriptEnabled ?? true)
        .domStorageAccess(true)
      .mediaPlayGestureAccess(data.autoplay === true ? false : true)
      .javaScriptOnDocumentStart(keySynthesisScripts(data))
      .multiWindowAccess(data.eventOptions.newWindow === true)
      .allowWindowOpenMethod(data.eventOptions.newWindow === true)
      .onControllerAttached(() => {
        handleControllerAttached(data);
      })
      .onLoadIntercept((event) => handleLoadIntercept(data, event.data.getRequestUrl()))
      .onInterceptRequest((event) => {
        const interceptUrl = (event as { request: WebResourceRequest }).request.getRequestUrl();
        hilog.info(0x1999, 'WebviewSurface',
          '[https-intercept] onInterceptRequest(embedded) fired: id=%{public}s url=%{public}s protocols_size=%{public}d',
          String(data.id), interceptUrl ?? 'null', data.httpsInterceptProtocols?.size ?? 0);
        return handleHttpsIntercept(data, interceptUrl);
      })
      .onTitleReceive((event) => data.onTitleChange(event.title))
      .onPageBegin((e) => {
        if (data.eventOptions.pageBegin === true) {
          data.onPageBegin(e.url);
        }
      })
      .onPageEnd((e) => {
        if (data.eventOptions.pageEnd === true) {
          data.onPageEnd(e.url);
        }
      })
      .onDragEnter((dragEvent: DragEvent) => {
        if (data.eventOptions.dragDrop === true) {
          data.onDragEnter(readDragX(dragEvent), readDragY(dragEvent));
        }
      })
      .onDragMove((dragEvent: DragEvent) => {
        if (data.eventOptions.dragDrop === true) {
          data.onDragMove(readDragX(dragEvent), readDragY(dragEvent));
        }
      })
      .onDrop((dragEvent: DragEvent) => {
        if (data.eventOptions.dragDrop === true) {
          const paths = extractDragPaths(dragEvent);
          data.onDrop(readDragX(dragEvent), readDragY(dragEvent), paths);
        }
      })
      .onDragLeave((dragEvent: DragEvent) => {
        if (data.eventOptions.dragDrop === true) {
          data.onDragLeave(readDragX(dragEvent), readDragY(dragEvent));
        }
      })
      .onWindowNew((e) => {
        if (data.eventOptions.newWindow !== true) {
          e.handler.setWebController(null);
          return;
        }
        const allow = data.onNewWindow(
          e.targetUrl ?? "",
          e.isAlert ?? false,
          e.isUserTrigger ?? false,
        );
        if (!allow) {
          e.handler.setWebController(null);
        } else {
          // #85 / Allow: see overlay branch above. Cancel ArkWeb's popup
          // (`setWebController(null)`, non-blocking) and show an in-page
          // NewWindowDialog whose `Web` loads the target URL directly — the OHOS
          // equivalent of "open in a new in-page window". Auto suite uses Create
          // mode so this branch only fires for the manual Allow button.
          e.handler.setWebController(null);
          try {
            data.onShowNewWindow?.(new webview.WebviewController(), e.targetUrl ?? '');
          } catch (err) {
            hilog.warn(0x1999, 'WebviewSurface', 'Allow new-window dialog failed: %{public}s', String(err));
          }
        }
      });
  }
}

/**
 * Document-start scripts with the key-synthesis shim appended (main window
 * only). The shim suppresses ArkWeb's degenerate native keydown/keyup events
 * so pages see only the synthetic stream from MainPage.onKeyPreIme (see
 * native_ability helper/key_synthesis.ets, openspec ohos-webview-key-synthesis).
 *
 * Sub-window (Float) webviews are excluded: they have no key-synthesis wiring
 * (their onKeyPreIme serves other interception purposes, see FloatPage), so
 * suppressing their native key events without synthetic replacement would
 * drop ALL key events there.
 */
function keySynthesisScripts(data: ManagedWebview): WebviewInitializationScript[] {
  const wid = data.windowId ?? 0;
  const base = data.initializationScripts ?? [];
  if (wid !== 0) {
    return base;
  }
  // scriptRules are ArkWeb URL match patterns — an EMPTY array matches no
  // document (the shim silently never runs; observed 2026-08-28 as unsuppressed
  // native key events). "*" alone does not match custom protocols
  // (tauri://localhost), so reuse the UNION of the app's own init-script
  // rules — the shim must run exactly wherever those run. No init scripts → "*".
  const rules: Set<string> = new Set();
  for (const item of base) {
    for (const rule of item.scriptRules) {
      rules.add(rule);
    }
  }
  if (rules.size === 0) {
    rules.add('*');
  }
  const shim: WebviewInitializationScript = { script: KEY_SYNTHESIS_SHIM, scriptRules: Array.from(rules) };
  return base.concat([shim]);
}

function handleControllerAttached(data: ManagedWebview): void {
  if (!data.beginControllerAttach()) {
    return;
  }
  try {
    if (data.userAgent !== undefined && data.userAgent !== null) {
      data.controller.setCustomUserAgent(data.userAgent);
    }
    setupDownloadDelegate(data);
    data.notifyNativeControllerAttached();
    // Inject the attached controller into PredefinedActionExecutor via the
    // primaryWebviewControllerCallback. This is the single injection point that
    // covers both overlay-mode and direct-mode webview attach paths (both funnel
    // into handleControllerAttached). Without this, Tray right-click predefined
    // actions (Copy/Cut/Paste/SelectAll/Undo/Redo) no-op because the executor's
    // controller stays null.
    notifyPrimaryWebviewController(data.controller as ESObject);

    // === §14 fix: register sub-window controller for menu.getTargetController ===
    // Sub-windows only (windowId > 0): main window keeps the one-shot path above.
    // data.controller is the live attached controller at this point (onControllerAttached
    // just fired), so runJavaScript/getSelection work when Tray Copy later resolves it.
    const wid = data.windowId ?? 0;
    hilog.info(0x1999, 'WebviewSurface',
      '[TrayCopyDiag] T3 controllerAttached id=%{public}s data.windowId=%{public}s wid=%{public}d willRegister=%{public}s',
      String(data.id),
      data.windowId === undefined ? 'undefined' : String(data.windowId),
      wid,
      (wid > 0) ? 'true' : 'false');
    if (wid > 0) {
      WindowManager.getInstance().registerWebviewController(wid, data.controller as webview.WebviewController);
    }

    // ohos-webview-key-synthesis: register the controller (ALL windows incl.
    // main — unlike the sub-window-only WindowManager map above) so
    // MainPage.onKeyPreIme can dispatch synthetic DOM key events into it.
    notifyKeySynthesisController(wid, data.controller as webview.WebviewController);

    data.didInitialLoad = true;
    if (data.url) {
      hilog.info(0x1999, 'WebviewSurface',
        '[https-intercept] handleControllerAttached loadUrl: id=%{public}s url=%{public}s protocols_size=%{public}d',
        String(data.id), data.url, data.httpsInterceptProtocols?.size ?? 0);
      data.controller.loadUrl(data.url, headersOf(data.headers));
    } else {
      hilog.info(0x1999, 'WebviewSurface',
        '[https-intercept] handleControllerAttached loadData (no url): id=%{public}s',
        String(data.id));
      data.controller.loadData(data.html!, "text/html", "UTF-8", " ", " ");
    }
    data.markControllerReady();
  } catch (error) {
    const reason = `WebView '${data.id}' controller initialization failed: ${String(error)}`;
    console.error(reason);
    data.failControllerAttach(reason);
  }
}

function handleLoadIntercept(data: ManagedWebview, url: string): boolean {
  // close-window intercept: borderless windows use <a href="http://close-window.invalid/">
  // as a close button. Intercept the navigation and destroy the window.
  if (url && url.startsWith("http://close-window.invalid")) {
    if (typeof data.onCloseWindow === "function") {
      data.onCloseWindow();
    }
    return true; // block navigation
  }
  // file:// interception: ArkWeb consumes OS file drops by navigating to
  // file://<dropped file>, which preempts onDrop. Intercept and forward as drag-drop.
  if (url && url.startsWith("file://")) {
    const path = pathFromFileUrl(url);
    data.onDrop(0, 0, [path]);
    return true; // block navigation
  }
  return data.onNavigationRequest(url);
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
    // Read pending blur radius from WindowManager (set by window set-blur command).
    // This is the WebviewPlugin equivalent of RustWebviewNodeController's pendingBlurs injection.
    const windowId = payload.windowId ?? 0;
    const pendingBlur = WindowManager.getInstance().getPendingBlur(windowId);
    hilog.info(0x1999, 'WebviewSurface',
      'create: pendingBlur read windowId=%{public}d pendingBlur=%{public}f (build-time blur injection)', windowId, pendingBlur);
    if (pendingBlur > 0 && (style.blurRadius === undefined || style.blurRadius === null)) {
      style.blurRadius = pendingBlur;
    }
    // Apply per-window clipboard / zoom-hotkey intercept flags from the create payload.
    // payload values are boolean|null; null → undefined → keep default (true = ArkWeb native).
    // See ohos-webview-flag-clipboard / ohos-webview-flag-zoom-hotkeys specs.
    WindowManager.getInstance().setWebviewFlags(
      windowId,
      payload.clipboard ?? undefined,
      payload.zoomHotkeys ?? undefined,
    );
    hilog.info(0x1999, 'WebviewSurface',
      'create: setWebviewFlags windowId=%{public}d clipboard=%{public}s zoomHotkeys=%{public}s',
      windowId, String(payload.clipboard), String(payload.zoomHotkeys));
    const eventOptions = normalizeEventOptions(payload.eventOptions);
    const parentHandle = payload.parentHandle ?? null;
    const instanceId = this.nextMountKey++;
    const nativeTagId = nextWebviewNativeTagId++;
    const nativeTag = `ohos.webview.${this.pluginContext.sessionId}.${nativeTagId}`;
    // Capture the UIContext here (in `create()`, where `this` is in scope) for the
    // onWindowNew Allow branch, which lives in a `@Builder` free function with no `this`.
    // Same source as the BuilderNode construction below (`this.pluginContext.getUIContext()`).
    const newWindowUiCtx = this.pluginContext.getUIContext();
    const data: ManagedWebview = {
      id: payload.id,
      windowId: payload.windowId ?? null,
      mountParentHandle: parentHandle,
      mountKey: `ohos.webview.${instanceId}`,
      nativeTag,
      httpsInterceptProtocols: new Set<string>(payload.httpsInterceptProtocolList ?? []),
      resizeDebounceTimer: 0,
      onHttpsInterceptRequest: (url: string): WebResourceResponse | null => {
        hilog.info(0x1999, 'WebviewSurface',
          '[https-intercept] onHttpsInterceptRequest enter: id=%{public}s nativeTag=%{public}s url=%{public}s',
          payload.id, nativeTag, url);
        try {
          const response = this.pluginContext.invokeNativeSync(
            "https-intercept",
            HTTPS_INTERCEPT_REQUEST_TYPE,
            HTTPS_INTERCEPT_RESPONSE_TYPE,
            new WebviewHttpsInterceptRequestPayload(payload.id, nativeTag, url) as ESObject,
          ) as WebviewHttpsInterceptResponse;
          hilog.info(0x1999, 'WebviewSurface',
            '[https-intercept] onHttpsInterceptRequest bridge returned: id=%{public}s handled=%{public}s status=%{public}d body_len=%{public}d',
            payload.id,
            response?.handled === true ? 'true' : 'false',
            response?.status ?? 0,
            response?.body?.length ?? 0);
          if (
            response === null ||
            typeof response !== "object" ||
            response.handled !== true
          ) {
            hilog.warn(0x1999, 'WebviewSurface',
              '[https-intercept] onHttpsInterceptRequest returning null (handled=false or invalid response): id=%{public}s url=%{public}s',
              payload.id, url);
            return null;
          }
          const webResponse = new WebResourceResponse();
          const bodyBuffer = new Uint8Array(response.body ?? []).buffer;
          webResponse.setResponseData(bodyBuffer);
          webResponse.setResponseMimeType(response.mimeType || "application/octet-stream");
          webResponse.setResponseCode(response.status || 200);
          webResponse.setResponseIsReady(true);
          hilog.info(0x1999, 'WebviewSurface',
            '[https-intercept] onHttpsInterceptRequest returning WebResourceResponse: id=%{public}s status=%{public}d mime=%{public}s',
            payload.id, response.status || 200, response.mimeType || "application/octet-stream");
          return webResponse;
        } catch (error) {
          hilog.error(0x1999, 'WebviewSurface',
            '[https-intercept] onHttpsInterceptRequest exception: id=%{public}s url=%{public}s error=%{public}s',
            payload.id, url, String(error));
          return null;
        }
      },
      url: payload.url,
      html: payload.html,
      javascriptEnabled: payload.javascriptEnabled,
      devtools: payload.devtools,
      userAgent: payload.userAgent,
      autoplay: payload.autoplay,
      initializationScripts: payload.initializationScripts,
      headers: payload.headers,
      transparent: payload.transparent,
      clipboard: payload.clipboard,
      zoomHotkeys: payload.zoomHotkeys,
      dragDropOverlay: payload.dragDropOverlay,
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
      onDragEnter: (x: number, y: number): void => {
        try {
          notifyNative(
            this.pluginContext,
            "drag-enter",
            DRAG_EVENT_TYPE,
            new WebviewDragEventPayload(payload.id, nativeTag, x, y) as ESObject,
          );
        } catch (error) {
          console.error("WebView drag-enter notification failed: " + String(error));
        }
      },
      onDragMove: (x: number, y: number): void => {
        try {
          notifyNative(
            this.pluginContext,
            "drag-over",
            DRAG_EVENT_TYPE,
            new WebviewDragEventPayload(payload.id, nativeTag, x, y) as ESObject,
          );
        } catch (error) {
          console.error("WebView drag-over notification failed: " + String(error));
        }
      },
      onDrop: (x: number, y: number, paths: string[]): void => {
        try {
          notifyNative(
            this.pluginContext,
            "drag-drop",
            DROP_EVENT_TYPE,
            new WebviewDropEventPayload(payload.id, nativeTag, x, y, paths) as ESObject,
          );
        } catch (error) {
          console.error("WebView drag-drop notification failed: " + String(error));
        }
      },
      onDragLeave: (x: number, y: number): void => {
        try {
          notifyNative(
            this.pluginContext,
            "drag-leave",
            DRAG_EVENT_TYPE,
            new WebviewDragEventPayload(payload.id, nativeTag, x, y) as ESObject,
          );
        } catch (error) {
          console.error("WebView drag-leave notification failed: " + String(error));
        }
      },
      onPageBegin: (url: string): void => {
        try {
          notifyNative(
            this.pluginContext,
            "page-begin",
            PAGE_EVENT_TYPE,
            new WebviewPageEventPayload(payload.id, nativeTag, url) as ESObject,
          );
        } catch (error) {
          console.error("WebView page-begin notification failed: " + String(error));
        }
      },
      onPageEnd: (url: string): void => {
        try {
          notifyNative(
            this.pluginContext,
            "page-end",
            PAGE_EVENT_TYPE,
            new WebviewPageEventPayload(payload.id, nativeTag, url) as ESObject,
          );
        } catch (error) {
          console.error("WebView page-end notification failed: " + String(error));
        }
      },
      onNewWindow: (targetUrl: string, isAlert: boolean, isUserTrigger: boolean): boolean => {
        return invokeNativeBool(
          this.pluginContext,
          "new-window-request",
          NEW_WINDOW_REQUEST_TYPE,
          NEW_WINDOW_RESPONSE_TYPE,
          new WebviewNewWindowRequestPayload(
            payload.id,
            nativeTag,
            targetUrl,
            isAlert,
            isUserTrigger,
          ) as ESObject,
          false, // default deny when no handler
        );
      },
      onShowNewWindow: (controller: webview.WebviewController, targetUrl: string): void => {
        // Allow-branch popup: `.onWindowNew` cancelled ArkWeb's own popup
        // (`setWebController(null)`) and routed here. The dialog's `Web` loads
        // targetUrl directly (NewWindowDialog builder `src=params.url`), so the
        // popup shows the target page as an in-page window — OHOS Allow=dialog.
        try {
          openNewWindowDialog(newWindowUiCtx, controller, targetUrl);
        } catch (err) {
          console.error("[NEWWIN] show dialog failed: " + String(err));
        }
      },
    };
    ensureWebEngineInitialized(callContext);
    if (payload.devtools) {
      enableWebDebuggingIfAvailable();
    }
    // Sub-window webview mounting: when windowId is provided, use the sub-window's
    // UIContext and component root from WindowManager instead of this module's host.
    // (windowId already declared above at blur injection)
    const isSubWindow = windowId > 0;
    hilog.info(0x1999, 'WebviewSurface', 'create: id=%{public}s windowId=%{public}d isSubWindow=%{public}s', payload.id, windowId, isSubWindow ? 'true' : 'false');
    const wm = isSubWindow ? WindowManager.getInstance() : null;

    // Timing guard: if sub-window's componentRoot is not yet registered (FloatPage
    // hasn't aboutToAppear), defer the entire create until registerComponentRoot fires.
    if (isSubWindow && wm !== null && wm.getComponentRoot(windowId) === undefined) {
      hilog.info(0x1999, 'WebviewSurface', 'create: deferring for windowId=%{public}d (componentRoot not ready)', windowId);
      WindowManager.onComponentRootRegistered(windowId, (): void => {
        this.create(payload, callContext);
      });
      return;
    }

    const subUiCtx = wm?.getUIContext(windowId);
    const subRoot = wm?.getComponentRoot(windowId);
    hilog.info(0x1999, 'WebviewSurface', 'create: subUiCtx=%{public}s subRoot=%{public}s', subUiCtx !== undefined ? 'found' : 'undefined', subRoot !== undefined ? 'found' : 'undefined');
    const builderUiCtx = (isSubWindow && subUiCtx) ? subUiCtx : this.pluginContext.getUIContext();
    const node = new BuilderNode<[ManagedWebview]>(builderUiCtx);
    const entry = new WebviewEntry(data, node);
    // Wire up close-window callback: when the webview navigates to close-window.invalid,
    // destroy the Float sub-window via WindowManager. Notify Rust FIRST (mirrors menu.ets
    // closeWindow and FloatPage × button) so the tauri manager drains PENDING_WINDOW_CLOSES
    // and removes its registry entry — otherwise getByLabel returns a zombie handle and the
    // same-label window can never be rebuilt (manual_tests §二十八 close lifecycle defect).
    if (windowId > 0) {
      data.onCloseWindow = (): void => {
        hilog.info(0x1999, 'WebviewSurface', 'onCloseWindow: destroying windowId=%{public}d', windowId);
        try {
          const nativeModule: ESObject = AppStorage.get<ESObject>(NATIVE_MODULE_STORAGE_KEY);
          if (nativeModule && typeof nativeModule.notifyWindowClose === 'function') {
            nativeModule.notifyWindowClose(windowId);
          }
        } catch (e) {
          hilog.warn(0x1999, 'WebviewSurface', 'onCloseWindow notifyWindowClose failed: %{public}s', String(e));
        }
        WindowManager.getInstance().destroyWindow(windowId);
      };
    }
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
        hilog.info(0x1999, 'WebviewSurface', 'create: mounted to parentHandle=%{public}s', parentHandle);
      } else if (isSubWindow && subRoot) {
        // Mount into the Float sub-window's component root
        subRoot.appendChild(frameNode);
        hilog.info(0x1999, 'WebviewSurface', 'create: mounted to subRoot for windowId=%{public}d', windowId);
      } else {
        this.pluginContext.appendChild(data.mountKey, frameNode, (): void => {
          try {
            frameNode.dispose();
          } catch {}
        });
        hilog.info(0x1999, 'WebviewSurface', 'create: mounted to main window (pluginContext)');
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
    // Register runtime blur refresh callback so later set-blur commands update this
    // webview's backdropBlur live (build-time pendingBlur only applies at create).
    if (windowId > 0) {
      WindowManager.getInstance().registerBlurRefreshCallback(windowId, (radius: number): void => {
        entry.data.style.blurRadius = radius > 0 ? radius : null;
        entry.node.update(entry.data);
        hilog.info(0x1999, 'WebviewSurface', 'blur refresh: id=%{public}s windowId=%{public}d radius=%{public}d', payload.id, windowId, radius);
      });
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

  // Runtime blur refresh is handled by WindowManager.registerBlurRefreshCallback
  // (registered in create() for sub-window webviews). See applyWindowBlur.

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
    // Unregister runtime blur refresh callback (sub-window webviews only).
    const wid = entry.data.windowId ?? 0;
    if (wid > 0) {
      WindowManager.getInstance().unregisterBlurRefreshCallback(wid);
    }
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

  async createPdf(
    id: string,
    path: string,
    pdfConfig: WebviewPdfConfig | null,
    callContext: BridgeCallContext,
  ): Promise<boolean> {
    const entry = await this.controllerEntry(id, callContext);
    const controller = entry.data.controller;
    // API 14+ guard: createPdf() and PdfData.pdfArrayBuffer() are API 14+.
    if (typeof controller.createPdf !== "function") {
      return false;
    }
    try {
      // Fixed A4 defaults; the caller-supplied `pdfConfig` overrides per-field.
      const DEFAULT_PDF_CONFIG: webview.PdfConfiguration = {
        width: 8.27,
        height: 11.69,
        marginTop: 0,
        marginBottom: 0,
        marginLeft: 0,
        marginRight: 0,
        shouldPrintBackground: true,
      };
      const cfg: webview.PdfConfiguration = pdfConfig ? {
        width: pdfConfig.width ?? DEFAULT_PDF_CONFIG.width,
        height: pdfConfig.height ?? DEFAULT_PDF_CONFIG.height,
        marginTop: pdfConfig.marginTop ?? DEFAULT_PDF_CONFIG.marginTop,
        marginBottom: pdfConfig.marginBottom ?? DEFAULT_PDF_CONFIG.marginBottom,
        marginLeft: pdfConfig.marginLeft ?? DEFAULT_PDF_CONFIG.marginLeft,
        marginRight: pdfConfig.marginRight ?? DEFAULT_PDF_CONFIG.marginRight,
        shouldPrintBackground: pdfConfig.shouldPrintBackground ?? DEFAULT_PDF_CONFIG.shouldPrintBackground,
      } : DEFAULT_PDF_CONFIG;
      const pdfData = await controller.createPdf(cfg);
      const buffer = pdfData.pdfArrayBuffer().buffer;
      if (!buffer || buffer.byteLength === 0) {
        return false;
      }
      const file = fileIo.openSync(
        path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC,
      );
      await fileIo.write(file.fd, buffer);
      fileIo.closeSync(file);
      return true;
    } catch (error) {
      console.error(`WebView create-pdf failed: ${String(error)}`);
      return false;
    }
  }

  async webPageSnapshot(
    id: string,
    callContext: BridgeCallContext,
  ): Promise<WebviewSnapshotResponse> {
    const entry = await this.controllerEntry(id, callContext);
    const controller = entry.data.controller;
    const pixelMap = await this.snapshotPixelMap(controller);
    try {
      const info = pixelMap.getImageInfoSync();
      const byteCount = pixelMap.getPixelBytesNumber();
      // Only return dimensions + byte count — transferring the full RGBA
      // buffer across NAPI would be extremely slow (1.9MB for 800×600).
      return new WebviewSnapshotResponse(true, info.size.width, info.size.height, byteCount);
    } catch (e) {
      throw new Error(`PixelMap info failed: ${String(e)}`);
    } finally {
      this.releasePixelMap(pixelMap);
    }
  }

  async captureWebview(
    id: string,
    callContext: BridgeCallContext,
  ): Promise<WebviewCaptureResponse> {
    const entry = await this.controllerEntry(id, callContext);
    const controller = entry.data.controller;
    const pixelMap = await this.snapshotPixelMap(controller);
    try {
      const info = pixelMap.getImageInfoSync();
      const packer = image.createImagePacker();
      try {
        // quality is REQUIRED by PackingOption in the API 12 typings even for PNG.
        const packOptions: image.PackingOption = { format: "image/png", quality: 100 };
        const arrayBuffer = await packer.packing(pixelMap, packOptions);
        if (!arrayBuffer || arrayBuffer.byteLength === 0) {
          throw new Error("ImagePacker produced empty PNG buffer");
        }
        // base64 (not raw bytes) — a Vec<u8> in a napi object would cross the bridge as
        // Array<number>, inflating a multi-hundred-KB PNG ~8x in memory.
        const pngBase64 = buffer.from(arrayBuffer).toString("base64");
        return new WebviewCaptureResponse(pngBase64, info.size.width, info.size.height);
      } catch (e) {
        console.error(`[WebviewPlugin] PNG packing failed: ${String(e)}`);
        throw e;
      } finally {
        try {
          packer.release();
        } catch (_packerErr) {
          // best-effort release
        }
      }
    } catch (e) {
      throw new Error(`capture-webview failed: ${String(e)}`);
    } finally {
      this.releasePixelMap(pixelMap);
    }
  }

  async pickColor(
    id: string,
    x: number,
    y: number,
    callContext: BridgeCallContext,
  ): Promise<WebviewPickColorResponse> {
    const entry = await this.controllerEntry(id, callContext);
    const controller = entry.data.controller;
    const pixelMap = await this.snapshotPixelMap(controller);
    try {
      const info = pixelMap.getImageInfoSync();
      if (x < 0 || y < 0 || x >= info.size.width || y >= info.size.height) {
        throw new Error(
          `pick-color coordinates (${x}, ${y}) out of captured bounds ` +
            `${info.size.width}x${info.size.height}`
        );
      }
      // readPixels always writes BGRA_8888 bytes regardless of the PixelMap's own format.
      // The caller provides the destination buffer; readPixels writes into it and returns void.
      const area: image.PositionArea = {
        pixels: new ArrayBuffer(4),
        offset: 0,
        stride: 4,
        region: { x, y, size: { width: 1, height: 1 } },
      };
      await pixelMap.readPixels(area);
      const bgra = new Uint8Array(area.pixels);
      return new WebviewPickColorResponse(bgra[2], bgra[1], bgra[0], bgra[3]);
    } catch (e) {
      throw new Error(`pick-color failed: ${String(e)}`);
    } finally {
      this.releasePixelMap(pixelMap);
    }
  }

  private releasePixelMap(pixelMap: image.PixelMap): void {
    try {
      pixelMap.release();
    } catch (_releaseErr) {
      // best-effort release
    }
  }

  /**
   * Wraps the callback-based webPageSnapshot API in a Promise with retries + timeout and
   * resolves with the live PixelMap. The CALLER owns the PixelMap and must release() it
   * after consuming it. Ported from the legacy DefaultWebview.ets implementation.
   */
  private snapshotPixelMap(controller: webview.WebviewController): Promise<image.PixelMap> {
    const snapshotPromise = new Promise<image.PixelMap>((resolve, reject) => {
      let settled = false;
      const timeoutId = setTimeout(() => {
        if (!settled) {
          settled = true;
          reject(new Error("webPageSnapshot timed out after 10s"));
        }
      }, 10000);

      const done = (fn: () => void) => {
        if (!settled) {
          settled = true;
          clearTimeout(timeoutId);
          fn();
        }
      };

      const attempt = (retriesLeft: number) => {
        if (settled) return;
        try {
          controller.webPageSnapshot(
            { id: "snapshot" },
            (error: BusinessError, result: webview.SnapshotResult) => {
              if (error) {
                if (retriesLeft > 0) {
                  console.warn(
                    `[WebviewPlugin] webPageSnapshot retry (${retriesLeft} left): ${error.message}`
                  );
                  setTimeout(() => attempt(retriesLeft - 1), 500);
                } else {
                  console.error(
                    `[WebviewPlugin] webPageSnapshot failed: ${error.code} - ${error.message}`
                  );
                  done(() =>
                    reject(new Error(`webPageSnapshot failed: ${error.code} - ${error.message}`))
                  );
                }
                return;
              }
              if (!result || result.status !== true || !result.imagePixelMap) {
                console.error("[WebviewPlugin] webPageSnapshot returned empty or failed result");
                done(() => reject(new Error("webPageSnapshot returned empty or failed result")));
                return;
              }
              if (settled) {
                // A late success racing the 10s timeout: nobody will consume this
                // PixelMap — release it instead of leaking it.
                this.releasePixelMap(result.imagePixelMap);
                return;
              }
              done(() => resolve(result.imagePixelMap));
            }
          );
        } catch (e) {
          if (retriesLeft > 0) {
            console.warn(
              `[WebviewPlugin] webPageSnapshot exception (${retriesLeft} left): ${String(e)}`
            );
            setTimeout(() => attempt(retriesLeft - 1), 500);
          } else {
            console.error(`[WebviewPlugin] webPageSnapshot exception: ${String(e)}`);
            done(() => reject(new Error(`webPageSnapshot exception: ${String(e)}`)));
          }
        }
      };

      // Initial delay + up to 3 retries with 500ms intervals
      setTimeout(() => attempt(3), 500);
    });

    return snapshotPromise;
  }

  async setUserAgent(
    id: string,
    userAgent: string,
    callContext: BridgeCallContext,
  ): Promise<void> {
    const entry = await this.controllerEntry(id, callContext);
    try {
      entry.data.controller.setCustomUserAgent(userAgent);
    } catch (error) {
      throw new Error(`Unable to set WebView user agent: ${String(error)}`);
    }
  }

  /**
   * Merges custom-protocol names into the WebView's live https intercept protocol set. The set is
   * deduplicated. Subsequent `onInterceptRequest` callbacks matching `https://<protocol>.localhost/`
   * will dispatch through the `https-intercept` bridge event.
   */
  registerHttpsIntercept(id: string, protocols: string[]): boolean {
    const entry = this.entries.get(id);
    if (!entry) {
      return false;
    }
    for (const protocol of protocols) {
      if (typeof protocol === "string" && protocol.length > 0) {
        entry.data.httpsInterceptProtocols.add(protocol);
      }
    }
    return true;
  }

  setBounds(id: string, x: number, y: number, width: number, height: number): boolean {
    const entry = this.entries.get(id);
    if (!entry) {
      return false;
    }
    // Only x/y drive the Web component's .position(); width/height are intentionally
    // ignored — the Web uses "100%" so it follows its parent container on resize.
    // Storing them as fixed px would pin the Web and break ArkWeb viewport tracking.
    entry.data.style.x = x;
    entry.data.style.y = y;
    entry.node.update(entry.data);
    return true;
  }

  setCookie(url: string, value: string): boolean {
    try {
      webview.WebCookieManager.configCookieSync(url, value);
      return true;
    } catch (error) {
      console.error("WebView set-cookie failed: " + String(error));
      return false;
    }
  }

  async printPdf(id: string, path: string, callContext: BridgeCallContext): Promise<boolean> {
    // The temp PDF at `path` is created by the caller (wry create_pdf) before this runs.
    // Clean it up on every exit path so it doesn't leak in the sandbox cache (mirrors
    // DefaultWebview.ets printPage cleanup). 'succeed' delays deletion because the
    // spooler reads the file asynchronously after the dialog resolves.
    const cleanup = (): void => {
      try { fileIo.unlinkSync(path); } catch (_e) { /* temp PDF cleanup; ignore if already gone */ }
    };
    const ctx = callContext.abilityContext;
    if (!ctx) {
      hilog.error(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "printPdf: abilityContext missing");
      cleanup();
      return false;
    }
    try {
      // 1) Dynamically request PRINT permission (user_grant; undgranted → print fails).
      const atManager = abilityAccessCtrl.createAtManager();
      const permResult = await atManager.requestPermissionsFromUser(ctx, ["ohos.permission.PRINT"]);
      const granted = Array.isArray(permResult.authResults)
        && permResult.authResults.length > 0
        && permResult.authResults[0] === 0;
      if (!granted) {
        hilog.warn(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "printPdf: PRINT permission denied");
        cleanup();
        return false;
      }

      // 2) Bare sandbox path → file:// URI (print files overload requires a file URI array).
      const fileUriStr = fileUri.getUriFromPath(path);
      if (!fileUriStr) {
        hilog.error(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "printPdf: getUriFromPath returned empty for %{public}s", path);
        cleanup();
        return false;
      }

      // 3) Call the official API: print.print(files, context) returns Promise<PrintTask>.
      // Static named import from @kit.BasicServicesKit (API 12 / SDK 5.0.0, 2in1 supported).
      // The prior dynamic import("@ohos.print") resolved printMod.print to a non-function —
      // the kit-level named export `print` is the correct entrypoint per Huawei docs.
      const task = await print.print([fileUriStr], ctx) as ESObject;
      if (!task) {
        hilog.error(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "printPdf: print() returned no PrintTask");
        cleanup();
        return false;
      }

      // 4) Listen for PrintTask events. Each .on is individually try/caught so a missing
      // event on some SDK level doesn't prevent the confirmed ones (succeed/fail) from
      // registering. Official event set: succeed / fail / cancel / block ('block' means
      // the printer is blocked — offline/out-of-paper — NOT "dialog shown", so it stays
      // silent in the normal flow). Each terminal state is also forwarded to Rust via
      // the "print-state" bridge event (best-effort — see notifyPrintState), so the app
      // can observe the print outcome.
      // The task is kept in activePrintTasks: if the only reference were this local,
      // GC after printPdf returns would unregister the framework callback and no
      // terminal event would ever be delivered.
      if (typeof task.on === "function") {
        try { task.on("succeed", () => {
          hilog.info(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "PrintTask 'succeed': job submitted");
          notifyPrintState(this.pluginContext, id, "succeed");
          activePrintTasks.delete(id);
          // The spooler reads the temp PDF asynchronously after job submission; deleting
          // immediately would abort the print. Delay cleanup so the file survives the read.
          setTimeout(cleanup, 10000);
        }); } catch (e) {
          hilog.warn(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "PrintTask 'succeed' registration failed: %{public}s", String(e));
        }
        try { task.on("fail", (err: BusinessError) => {
          hilog.error(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "PrintTask 'fail': %{public}s", String(err?.message ?? err));
          notifyPrintState(this.pluginContext, id, "fail", String(err?.message ?? err) || undefined);
          activePrintTasks.delete(id);
          cleanup();
        }); } catch (e) {
          hilog.warn(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "PrintTask 'fail' registration failed: %{public}s", String(e));
        }
        try { task.on("cancel", () => {
          hilog.info(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "PrintTask 'cancel': user cancelled");
          notifyPrintState(this.pluginContext, id, "cancel");
          activePrintTasks.delete(id);
          cleanup();
        }); } catch (e) {
          hilog.warn(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "PrintTask 'cancel' registration failed: %{public}s", String(e));
        }
        try { task.on("block", () => {
          hilog.info(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "PrintTask 'block': printer blocked");
          notifyPrintState(this.pluginContext, id, "block");
        }); } catch (e) {
          hilog.warn(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "PrintTask 'block' registration failed: %{public}s", String(e));
        }
        activePrintTasks.set(id, task);
        hilog.info(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "PrintTask listeners registered (succeed/fail/cancel/block), task held");
      } else {
        hilog.warn(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "printPdf: PrintTask has no .on method");
      }

      // 5) PrintTask obtained → framework will raise the dialog; no longer unconditionally true.
      // Safety-net cleanup: terminal states (cancel/fail/succeed) should fire and clean up, but
      // some dialog-dismiss paths on OHOS have been observed to not deliver any terminal event,
      // leaking the temp PDF. A 120s unconditional cleanup guards against that without racing the
      // spooler (succeed's 10s delay is shorter and runs first; idempotent unlink is safe twice).
      setTimeout(cleanup, 120000);
      hilog.info(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "printPdf: PrintTask created, dialog pending");
      return true;
    } catch (error) {
      hilog.error(PRINT_LOG_DOMAIN, PRINT_LOG_TAG, "printPdf failed: %{public}s", String(error));
      cleanup();
      return false;
    }
  }

  setWebDebuggingAccess(enabled: boolean): boolean {
    try {
      setWebDebuggingAccessIfAvailable(enabled);
      return true;
    } catch (error) {
      console.error("WebView set-web-debugging-access failed: " + String(error));
      return false;
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

    if (action === "create-pdf") {
      const request = parsePrintRequest(payload);
      const success = await surface.createPdf(request.id, request.path, request.pdfConfig ?? null, context);
      return {
        typeName: PRINT_RESPONSE_TYPE,
        value: new WebviewPrintResponse(success),
      };
    }

    if (action === "web-page-snapshot") {
      const request = parseSnapshotRequest(payload);
      const result = await surface.webPageSnapshot(request.id, context);
      return {
        typeName: SNAPSHOT_RESPONSE_TYPE,
        value: result,
      };
    }

    if (action === "set-user-agent") {
      const request = parseUserAgentRequest(payload);
      await surface.setUserAgent(request.id, request.userAgent, context);
      return {
        typeName: ACKNOWLEDGEMENT_TYPE,
        value: new WebviewAcceptedResponse(true),
      };
    }

    if (action === "register-https-intercept") {
      if (
        payload.typeName !== REGISTER_HTTPS_INTERCEPT_REQUEST_TYPE ||
        payload.value === null ||
        typeof payload.value !== "object"
      ) {
        throw new Error(
          `ohos.webview.register-https-intercept requires bridge type ${REGISTER_HTTPS_INTERCEPT_REQUEST_TYPE}`,
        );
      }
      const request = payload.value as WebviewRegisterHttpsInterceptPayload;
      if (!request?.id?.trim()) {
        throw new Error("WebView register-https-intercept id must not be empty");
      }
      if (!Array.isArray(request.protocols)) {
        throw new Error("WebView register-https-intercept protocols must be an array");
      }
      const accepted = surface.registerHttpsIntercept(request.id, request.protocols);
      return {
        typeName: ACKNOWLEDGEMENT_TYPE,
        value: new WebviewAcceptedResponse(accepted),
      };
    }

    if (action === "set-cookie") {
      if (
        payload.typeName !== SET_COOKIE_REQUEST_TYPE ||
        payload.value === null ||
        typeof payload.value !== "object"
      ) {
        throw new Error(
          `ohos.webview.set-cookie requires bridge type ${SET_COOKIE_REQUEST_TYPE}`,
        );
      }
      const request = payload.value as { id: string; url: string; value: string };
      if (!request?.id?.trim()) {
        throw new Error("WebView set-cookie id must not be empty");
      }
      if (typeof request.url !== "string" || !request.url.trim()) {
        throw new Error("WebView set-cookie url must be a non-empty string");
      }
      if (typeof request.value !== "string") {
        throw new Error("WebView set-cookie value must be a string");
      }
      const accepted = surface.setCookie(request.url, request.value);
      return {
        typeName: ACKNOWLEDGEMENT_TYPE,
        value: new WebviewAcceptedResponse(accepted),
      };
    }

    if (action === "print") {
      const request = parsePrintRequest(payload);
      const accepted = await surface.printPdf(request.id, request.path, context);
      return {
        typeName: ACKNOWLEDGEMENT_TYPE,
        value: new WebviewAcceptedResponse(accepted),
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
    } else if (action === "capture-webview") {
      return {
        typeName: CAPTURE_RESPONSE_TYPE,
        value: await surface.captureWebview(controllerPayload.id, context),
      };
    } else if (action === "pick-color") {
      if (typeof controllerPayload.x !== "number" || typeof controllerPayload.y !== "number" ||
          !Number.isInteger(controllerPayload.x) || !Number.isInteger(controllerPayload.y)) {
        throw new Error("pick-color requires x and y as integers");
      }
      return {
        typeName: PICK_COLOR_RESPONSE_TYPE,
        value: await surface.pickColor(
          controllerPayload.id,
          controllerPayload.x,
          controllerPayload.y,
          context,
        ),
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
    } else if (action === "set-bounds") {
      if (typeof controllerPayload.x !== "number" || typeof controllerPayload.y !== "number" ||
          typeof controllerPayload.width !== "number" || typeof controllerPayload.height !== "number") {
        throw new Error("set-bounds requires x, y, width, and height as numbers");
      }
      accepted = surface.setBounds(controllerPayload.id, controllerPayload.x, controllerPayload.y,
        controllerPayload.width, controllerPayload.height);
    } else if (action === "set-web-debugging-access") {
      if (typeof controllerPayload.visible !== "boolean") {
        throw new Error("set-web-debugging-access.visible must be a boolean");
      }
      accepted = surface.setWebDebuggingAccess(controllerPayload.visible);
    } else if (action === "remove") {
      accepted = surface.remove(controllerPayload.id);
    } else {
      throw new Error(`Unsupported ohos.webview action '${action}'`);
    }
    return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WebviewAcceptedResponse(accepted) };
  }

  onDispose(): void {
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
