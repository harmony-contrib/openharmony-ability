import { WebHeader } from "@kit.ArkUI";
import { UIContext } from "@ohos.arkui.UIContext";
import { BuilderNode, FrameNode } from "@ohos.arkui.node";
import webview from "@ohos.web.webview";
import {
  AsyncBridgePlugin,
  BridgeCallContext,
  BridgeNodeSlot,
  BridgeNodeSlotRegistry,
  BridgeTypedValue,
  BridgePluginContext,
  BridgePluginFactory,
  DEFAULT_PLUGIN_NODE_SLOT,
} from "@ohos-rs/ability";

const CREATE_REQUEST_TYPE = "ohos.webview.CreateRequest";
const CREATE_RESPONSE_TYPE = "ohos.webview.CreateResponse";
const CONTROLLER_REQUEST_TYPE = "ohos.webview.ControllerRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.webview.Acknowledgement";
const SCRIPT_REQUEST_TYPE = "ohos.webview.ScriptRequest";
const SCRIPT_RESPONSE_TYPE = "ohos.webview.ScriptResponse";
const STRING_RESPONSE_TYPE = "ohos.webview.StringResponse";
const BOUNDS_REQUEST_TYPE = "ohos.webview.BoundsRequest";
const COOKIE_REQUEST_TYPE = "ohos.webview.CookieRequest";
const SNAPSHOT_REQUEST_TYPE = "ohos.webview.SnapshotRequest";
const SNAPSHOT_RESPONSE_TYPE = "ohos.webview.SnapshotResponse";
const BOOL_REQUEST_TYPE = "ohos.webview.BoolRequest";
const BOOL_RESPONSE_TYPE = "ohos.webview.BoolResponse";
const PDF_REQUEST_TYPE = "ohos.webview.PdfRequest";
const NAVIGATION_REQUEST_TYPE = "ohos.webview.NavigationRequest";
const NAVIGATION_RESPONSE_TYPE = "ohos.webview.NavigationResponse";
const DOWNLOAD_START_REQUEST_TYPE = "ohos.webview.DownloadStartRequest";
const DOWNLOAD_START_RESPONSE_TYPE = "ohos.webview.DownloadStartResponse";
const DOWNLOAD_END_EVENT_TYPE = "ohos.webview.DownloadEndEvent";
const TITLE_CHANGE_EVENT_TYPE = "ohos.webview.TitleChangeEvent";
const ENGINE_LIFECYCLE_EVENT_TYPE = "ohos.webview.EngineLifecycleEvent";
const CONTROLLER_EVENT_TYPE = "ohos.webview.ControllerEvent";
const EVENT_ACKNOWLEDGEMENT_TYPE = "ohos.webview.EventAcknowledgement";

/**
 * `setWebDebuggingAccess` is only present on newer ArkWeb SDKs. The plugin keeps its API 12
 * baseline by resolving this optional static API at runtime instead of exposing an API-20-only
 * symbol through the HAR type surface.
 */
interface WebviewDebuggingApi {
  setWebDebuggingAccess?: (enabled: boolean) => void;
  getWebDebuggingAccess?: () => boolean;
}

/** API-14-only `WebCookieManager` surface, resolved at runtime to keep the API 12 baseline. */
interface CookieApi {
  configCookieSync?: (url: string, value: string) => boolean;
}

function enableWebDebuggingIfAvailable(): void {
  const debuggingApi = webview.WebviewController as unknown as WebviewDebuggingApi;
  if (typeof debuggingApi.setWebDebuggingAccess !== "function") {
    console.warn("WebView debugging is unavailable on this ArkWeb API level");
    return;
  }
  debuggingApi.setWebDebuggingAccess(true);
}

interface WebviewStyle {
  x?: number | string | null;
  y?: number | string | null;
  width?: number | string | null;
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
  slotId?: string;
  /** Target OS sub-window id for per-window WebView creation (multi-window support). */
  windowId?: string | null;
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
  slotId?: string | null;
  visible?: boolean | null;
  color?: string | null;
  url?: string | null;
  html?: string | null;
  headers?: Record<string, string> | null;
  zoom?: number | null;
}

interface ScriptPayload {
  id: string;
  slotId?: string | null;
  script: string;
}

interface ManagedWebview extends WebviewCreatePayload {
  controller: WebviewController;
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
  readonly slotId: string;

  constructor(id: string, slotId: string) {
    this.id = id;
    this.slotId = slotId;
  }
}

class WebviewAcceptedResponse {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

class WebviewSnapshotResponse {
  readonly rgba: Uint8Array;
  readonly width: number;
  readonly height: number;

  constructor(rgba: Uint8Array, width: number, height: number) {
    this.rgba = rgba;
    this.width = width;
    this.height = height;
  }
}

class WebviewBoolResponse {
  readonly value: boolean;

  constructor(value: boolean) {
    this.value = value;
  }
}

interface WebviewBoundsPayload {
  id: string;
  slotId?: string | null;
  x: number;
  y: number;
  width: number;
  height: number;
}

interface WebviewCookiePayload {
  id: string;
  slotId?: string | null;
  url: string;
  value: string;
}

interface WebviewSnapshotPayload {
  id: string;
  slotId?: string | null;
}

interface WebviewBoolPayload {
  id: string;
  slotId?: string | null;
  enabled?: boolean | null;
}

interface PdfConfig {
  width?: number | null;
  height?: number | null;
  marginTop?: number | null;
  marginBottom?: number | null;
  marginLeft?: number | null;
  marginRight?: number | null;
  scale?: number | null;
  shouldPrintBackground?: boolean | null;
}

interface WebviewPdfPayload {
  id: string;
  slotId?: string | null;
  path: string;
  config?: PdfConfig | null;
}

function parseBoundsPayload(payload: BridgeTypedValue): WebviewBoundsPayload {
  if (
    payload.typeName !== BOUNDS_REQUEST_TYPE ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`ohos.webview.set-bounds requires bridge type ${BOUNDS_REQUEST_TYPE}`);
  }
  const request = payload.value as WebviewBoundsPayload;
  if (!request?.id?.trim()) {
    throw new Error("WebView bounds controller id must not be empty");
  }
  if (request.width <= 0 || request.height <= 0) {
    throw new Error("WebView bounds width and height must be positive");
  }
  return request;
}

function parseCookiePayload(payload: BridgeTypedValue): WebviewCookiePayload {
  if (
    payload.typeName !== COOKIE_REQUEST_TYPE ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`ohos.webview.set-cookie requires bridge type ${COOKIE_REQUEST_TYPE}`);
  }
  const request = payload.value as WebviewCookiePayload;
  if (!request?.id?.trim() || !request.url?.trim() || !request.value?.trim()) {
    throw new Error("WebView cookie requires non-empty id, url and value");
  }
  return request;
}

function parseSnapshotPayload(payload: BridgeTypedValue): WebviewSnapshotPayload {
  if (
    payload.typeName !== SNAPSHOT_REQUEST_TYPE ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`ohos.webview.snapshot requires bridge type ${SNAPSHOT_REQUEST_TYPE}`);
  }
  const request = payload.value as WebviewSnapshotPayload;
  if (!request?.id?.trim()) {
    throw new Error("WebView snapshot controller id must not be empty");
  }
  return request;
}

function parseBoolPayload(payload: BridgeTypedValue): WebviewBoolPayload {
  if (
    payload.typeName !== BOOL_REQUEST_TYPE ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`ohos.webview debugging requires bridge type ${BOOL_REQUEST_TYPE}`);
  }
  const request = payload.value as WebviewBoolPayload;
  if (!request?.id?.trim()) {
    throw new Error("WebView debugging controller id must not be empty");
  }
  return request;
}

function parsePdfPayload(payload: BridgeTypedValue): WebviewPdfPayload {
  if (
    payload.typeName !== PDF_REQUEST_TYPE ||
    payload.value === null ||
    typeof payload.value !== "object"
  ) {
    throw new Error(`ohos.webview.create-pdf requires bridge type ${PDF_REQUEST_TYPE}`);
  }
  const request = payload.value as WebviewPdfPayload;
  if (!request?.id?.trim() || !request.path?.trim()) {
    throw new Error("WebView PDF requires non-empty id and path");
  }
  return request;
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
  readonly url: string;

  constructor(id: string, url: string) {
    this.id = id;
    this.url = url;
  }
}

interface WebviewNavigationResponse {
  intercept: boolean;
}

class WebviewDownloadStartRequest {
  readonly id: string;
  readonly url: string;
  readonly tempPath: string | null;

  constructor(id: string, url: string, tempPath: string | null) {
    this.id = id;
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
  readonly url: string;
  readonly tempPath: string | null;
  readonly success: boolean;

  constructor(id: string, url: string, tempPath: string | null, success: boolean) {
    this.id = id;
    this.url = url;
    this.tempPath = tempPath;
    this.success = success;
  }
}

class WebviewTitleChangeEvent {
  readonly id: string;
  readonly title: string;

  constructor(id: string, title: string) {
    this.id = id;
    this.title = title;
  }
}

class WebviewEngineLifecycleEvent {
  readonly phase: string;

  constructor(phase: string) {
    this.phase = phase;
  }
}

class WebviewControllerEvent {
  readonly id: string;

  constructor(id: string) {
    this.id = id;
  }
}

interface WebviewEventAcknowledgement {
  accepted: boolean;
}

let webEngineInitialized = false;

/**
 * Custom schemes must be registered by Rust before this call. The two events let the Rust
 * WebView facade flush declarations immediately before the engine is initialized and seal the
 * declaration set afterwards.
 */
function ensureWebEngineInitialized(context: BridgePluginContext): void {
  if (webEngineInitialized) {
    return;
  }
  notifyNative(
    context,
    "before-engine-init",
    ENGINE_LIFECYCLE_EVENT_TYPE,
    new WebviewEngineLifecycleEvent("before-engine-init") as ESObject,
  );
  webview.WebviewController.initializeWebEngine();
  webEngineInitialized = true;
  notifyNative(
    context,
    "engine-initialized",
    ENGINE_LIFECYCLE_EVENT_TYPE,
    new WebviewEngineLifecycleEvent("engine-initialized") as ESObject,
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
  if (style.width !== undefined && style.width !== null) {
    normalized.width = style.width;
  }
  if (style.height !== undefined && style.height !== null) {
    normalized.height = style.height;
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

function withSlotId(payload: WebviewCreatePayload, slotId: string): WebviewCreatePayload {
  const copied: WebviewCreatePayload = {
    id: payload.id,
    slotId,
    windowId: payload.windowId,
    url: payload.url,
    html: payload.html,
    style: payload.style,
    javascriptEnabled: payload.javascriptEnabled,
    devtools: payload.devtools,
    userAgent: payload.userAgent,
    autoplay: payload.autoplay,
    initializationScripts: payload.initializationScripts,
    headers: payload.headers,
    transparent: payload.transparent,
    eventOptions: payload.eventOptions,
  };
  return copied;
}

function navigationDecision(context: BridgePluginContext, id: string, url: string): boolean {
  try {
    const response = context.invokeNativeSync(
      "navigation-request",
      NAVIGATION_REQUEST_TYPE,
      NAVIGATION_RESPONSE_TYPE,
      new WebviewNavigationRequest(id, url) as ESObject,
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
  url: string,
  tempPath: string | null,
): WebviewDownloadStartResponse {
  try {
    const response = context.invokeNativeSync(
      "download-start",
      DOWNLOAD_START_REQUEST_TYPE,
      DOWNLOAD_START_RESPONSE_TYPE,
      new WebviewDownloadStartRequest(id, url, tempPath) as ESObject,
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
    .backgroundColor(data.style.backgroundColor)
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

/** One mounted surface per generic BridgeNodeSlot; it owns only ArkTS nodes. */
class WebviewSurface {
  private readonly root: FrameNode;
  private readonly entries: Map<string, WebviewEntry> = new Map();
  private disposed = false;
  readonly slot: BridgeNodeSlot;
  private readonly uiContext: UIContext;
  private readonly pluginContext: BridgePluginContext;

  constructor(slot: BridgeNodeSlot, uiContext: UIContext, pluginContext: BridgePluginContext) {
    this.slot = slot;
    this.uiContext = uiContext;
    this.pluginContext = pluginContext;
    this.root = new FrameNode(uiContext);
    slot.mount("ohos.webview.surface", this.root, () => this.dispose(false));
  }

  async create(payload: WebviewCreatePayload, callContext: BridgeCallContext): Promise<void> {
    this.assertActive();
    this.assertCallActive(callContext);
    this.remove(payload.id);
    const style = normalizeStyle(payload.style, payload.transparent);
    const eventOptions = normalizeEventOptions(payload.eventOptions);
    const data: ManagedWebview = {
      id: payload.id,
      slotId: payload.slotId,
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
      controller: new webview.WebviewController(payload.id) as WebviewController,
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
        return navigationDecision(this.pluginContext, payload.id, url);
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
            new WebviewTitleChangeEvent(payload.id, title) as ESObject,
          );
        } catch (error) {
          console.error("WebView title notification failed: " + String(error));
        }
      },
      onDownloadStart: (url: string, tempPath: string | null): WebviewDownloadStartResponse => {
        return downloadStartDecision(this.pluginContext, payload.id, url, tempPath);
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
            new WebviewDownloadEndEvent(payload.id, url, tempPath, success) as ESObject,
          );
        } catch (error) {
          console.error("WebView download-end notification failed: " + String(error));
        }
      },
    };
    if (payload.devtools) {
      enableWebDebuggingIfAvailable();
    }
    const node = new BuilderNode<[ManagedWebview]>(this.uiContext);
    const entry = new WebviewEntry(data, node);
    data.beginControllerAttach = (): boolean => entry.beginControllerAttach();
    data.notifyNativeControllerAttached = (): void => {
      notifyNative(
        this.pluginContext,
        "controller-attached",
        CONTROLLER_EVENT_TYPE,
        new WebviewControllerEvent(data.id) as ESObject,
      );
    };
    data.markControllerReady = (): void => entry.markControllerReady();
    data.failControllerAttach = (reason: string): void => entry.failController(reason);
    let registered = false;
    try {
      node.build(webviewBuilder, data);
      this.entries.set(payload.id, entry);
      registered = true;
      this.root.appendChild(node.getFrameNode());
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

  setBounds(id: string, x: number, y: number, width: number, height: number): boolean {
    const entry = this.entries.get(id);
    if (!entry) {
      return false;
    }
    entry.data.style.x = x;
    entry.data.style.y = y;
    entry.data.style.width = width;
    entry.data.style.height = height;
    entry.node.update(entry.data);
    return true;
  }

  setCookie(id: string, url: string, value: string): boolean {
    // `configCookieSync` requires API 14; on older devices the runtime check rejects the call.
    // oxlint-disable-next-line arkts/system-api-version
    const cookieApi = webview.WebCookieManager as unknown as CookieApi;
    if (typeof cookieApi.configCookieSync !== "function") {
      throw new Error("WebCookieManager.configCookieSync is unavailable on this API level");
    }
    try {
      cookieApi.configCookieSync(url, value);
      return true;
    } catch (error) {
      throw new Error(`Unable to set WebView cookie: ${String(error)}`);
    }
  }

  async snapshot(id: string, callContext: BridgeCallContext): Promise<WebviewSnapshotResponse> {
    const entry = await this.controllerEntry(id, callContext);
    try {
      const result = await entry.data.controller.getWebPageSnapshot();
      return new WebviewSnapshotResponse(result.rgba, result.width, result.height);
    } catch (error) {
      throw new Error(`Unable to capture WebView snapshot: ${String(error)}`);
    }
  }

  async createPdf(id: string, path: string, config: PdfConfig | null): Promise<boolean> {
    const entry = await this.controllerEntry(id, undefined);
    try {
      const pdfConfig: webview.PdfConfiguration = {};
      if (config?.width !== undefined && config?.width !== null) {
        pdfConfig.width = config.width;
      }
      if (config?.height !== undefined && config?.height !== null) {
        pdfConfig.height = config.height;
      }
      if (config?.marginTop !== undefined && config?.marginTop !== null) {
        pdfConfig.marginTop = config.marginTop;
      }
      if (config?.marginBottom !== undefined && config?.marginBottom !== null) {
        pdfConfig.marginBottom = config.marginBottom;
      }
      if (config?.marginLeft !== undefined && config?.marginLeft !== null) {
        pdfConfig.marginLeft = config.marginLeft;
      }
      if (config?.marginRight !== undefined && config?.marginRight !== null) {
        pdfConfig.marginRight = config.marginRight;
      }
      if (config?.scale !== undefined && config?.scale !== null) {
        pdfConfig.scale = config.scale;
      }
      if (config?.shouldPrintBackground !== undefined && config?.shouldPrintBackground !== null) {
        pdfConfig.shouldPrintBackground = config.shouldPrintBackground;
      }
      await entry.data.controller.createPdf(path, pdfConfig);
      return true;
    } catch (error) {
      throw new Error(`Unable to create WebView PDF: ${String(error)}`);
    }
  }

  setDebuggingAccess(enabled: boolean): boolean {
    const debuggingApi = webview.WebviewController as unknown as WebviewDebuggingApi;
    if (typeof debuggingApi.setWebDebuggingAccess !== "function") {
      throw new Error("Web debugging access is unavailable on this ArkWeb API level");
    }
    debuggingApi.setWebDebuggingAccess(enabled);
    return true;
  }

  isDebuggingAccess(): boolean {
    const debuggingApi = webview.WebviewController as unknown as WebviewDebuggingApi;
    if (typeof debuggingApi.getWebDebuggingAccess !== "function") {
      return false;
    }
    return debuggingApi.getWebDebuggingAccess();
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

  remove(id: string, expected?: WebviewEntry): boolean {
    const entry = this.entries.get(id);
    if (!entry || (expected !== undefined && entry !== expected)) {
      return false;
    }
    this.entries.delete(id);
    entry.failController(`WebView '${id}' was removed before its controller attached`);
    try {
      this.root.removeChild(entry.node.getFrameNode());
    } catch {}
    try {
      notifyNative(
        this.pluginContext,
        "controller-removed",
        CONTROLLER_EVENT_TYPE,
        new WebviewControllerEvent(id) as ESObject,
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

  dispose(unmount: boolean): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    for (const id of Array.from(this.entries.keys())) {
      this.remove(id);
    }
    if (unmount) {
      this.slot.unmount("ohos.webview.surface");
    }
    this.root.dispose();
  }

  private assertActive(): void {
    if (this.disposed) {
      throw new Error("WebView surface is already disposed");
    }
  }

  private async controllerEntry(
    id: string,
    callContext: BridgeCallContext | undefined,
  ): Promise<WebviewEntry> {
    const entry = this.entries.get(id);
    if (!entry) {
      throw new Error(`Unknown WebView controller '${id}'`);
    }
    if (callContext === undefined) {
      await entry.waitForController(() => {});
      return entry;
    }
    this.assertCallActive(callContext);
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

function surfaceKey(context: BridgePluginContext, slotId: string): string {
  return `${context.sessionId}:${context.moduleName}:${slotId}`;
}

class WebviewSurfaceRegistry {
  private static readonly surfaces: Map<string, WebviewSurface> = new Map();

  static get(context: BridgePluginContext, slotId: string): WebviewSurface {
    const slot = BridgeNodeSlotRegistry.require(context.sessionId, context.moduleName, slotId);
    return WebviewSurfaceRegistry.forSlot(context, slot);
  }

  /**
   * `create` is asynchronous, so it may wait for a business-owned BridgeNodeHost that is still
   * entering the page. Controller actions deliberately remain immediate and use `get` above.
   */
  static async getWhenMounted(
    surfaceContext: BridgePluginContext,
    slotId: string,
    callContext: BridgeCallContext,
  ): Promise<WebviewSurface> {
    const slot = await BridgeNodeSlotRegistry.waitFor(
      surfaceContext.sessionId,
      surfaceContext.moduleName,
      slotId,
      callContext.onCancel,
    );
    if (!slot.isActive() || !surfaceContext.isActive() || !callContext.isActive()) {
      throw new Error("Bridge session is no longer active while waiting for the WebView node slot");
    }
    return WebviewSurfaceRegistry.forSlot(surfaceContext, slot);
  }

  private static forSlot(context: BridgePluginContext, slot: BridgeNodeSlot): WebviewSurface {
    const key = surfaceKey(context, slot.slotId);
    const current = WebviewSurfaceRegistry.surfaces.get(key);
    if (current && current.slot === slot) {
      return current;
    }
    if (current !== undefined) {
      current.dispose(false);
    }
    const surface = new WebviewSurface(slot, slot.uiContext, context);
    WebviewSurfaceRegistry.surfaces.set(key, surface);
    return surface;
  }

  static disposeSession(context: BridgePluginContext): void {
    const prefix = `${context.sessionId}:${context.moduleName}:`;
    const keys: string[] = Array.from(WebviewSurfaceRegistry.surfaces.keys());
    for (const key of keys) {
      if (!key.startsWith(prefix)) {
        continue;
      }
      const surface = WebviewSurfaceRegistry.surfaces.get(key);
      if (surface !== undefined) {
        WebviewSurfaceRegistry.surfaces.delete(key);
        surface.dispose(true);
      }
    }
  }
}

class WebviewPlugin implements AsyncBridgePlugin {
  readonly id = "ohos.webview";
  readonly version = 1;
  readonly execution = "async";
  readonly requires: ["ui-context"] = ["ui-context"];
  private readonly pluginContext: BridgePluginContext;

  constructor(pluginContext: BridgePluginContext) {
    this.pluginContext = pluginContext;
  }

  onInstall(context: BridgePluginContext): void {
    ensureWebEngineInitialized(context);
  }

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }
    if (action === "create") {
      const createPayload = ensureCreatePayload(parseCreatePayload(payload));
      const slotId = createPayload.slotId || DEFAULT_PLUGIN_NODE_SLOT;
      const payloadWithSlot = withSlotId(createPayload, slotId);
      const surface = await WebviewSurfaceRegistry.getWhenMounted(
        this.pluginContext,
        slotId,
        context,
      );
      await surface.create(payloadWithSlot, context);
      if (!context.isActive()) {
        throw new Error(
          "Bridge session is no longer active after WebView controller initialization",
        );
      }
      return {
        typeName: CREATE_RESPONSE_TYPE,
        value: new WebviewCreatedResponse(createPayload.id, slotId),
      };
    }

    if (action === "evaluate-script") {
      const scriptPayload = parseScriptPayload(payload);
      const slotId = scriptPayload.slotId || DEFAULT_PLUGIN_NODE_SLOT;
      const result = await WebviewSurfaceRegistry.get(this.pluginContext, slotId).evaluateScript(
        scriptPayload.id,
        scriptPayload.script,
        context,
      );
      return {
        typeName: SCRIPT_RESPONSE_TYPE,
        value: new WebviewScriptResponse(result),
      };
    }

    const controllerPayload = parseControllerPayload(payload, action);
    if (!controllerPayload?.id?.trim()) {
      throw new Error("WebView controller id must not be empty");
    }
    const slotId = controllerPayload.slotId || DEFAULT_PLUGIN_NODE_SLOT;
    const surface = WebviewSurfaceRegistry.get(this.pluginContext, slotId);
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
    } else if (action === "set-bounds") {
      const bounds = parseBoundsPayload(payload);
      const boundsSlotId = bounds.slotId || DEFAULT_PLUGIN_NODE_SLOT;
      accepted = WebviewSurfaceRegistry.get(this.pluginContext, boundsSlotId).setBounds(
        bounds.id,
        bounds.x,
        bounds.y,
        bounds.width,
        bounds.height,
      );
    } else if (action === "set-cookie") {
      const cookie = parseCookiePayload(payload);
      const cookieSlotId = cookie.slotId || DEFAULT_PLUGIN_NODE_SLOT;
      accepted = WebviewSurfaceRegistry.get(this.pluginContext, cookieSlotId).setCookie(
        cookie.id,
        cookie.url,
        cookie.value,
      );
    } else if (action === "snapshot") {
      const snapshotRequest = parseSnapshotPayload(payload);
      const snapshotSlotId = snapshotRequest.slotId || DEFAULT_PLUGIN_NODE_SLOT;
      const snapshot = await WebviewSurfaceRegistry.get(
        this.pluginContext,
        snapshotSlotId,
      ).snapshot(snapshotRequest.id, context);
      return { typeName: SNAPSHOT_RESPONSE_TYPE, value: snapshot };
    } else if (action === "set-debugging-access") {
      const debugRequest = parseBoolPayload(payload);
      if (typeof debugRequest.enabled !== "boolean") {
        throw new Error("set-debugging-access.enabled must be a boolean");
      }
      accepted = surface.setDebuggingAccess(debugRequest.enabled);
    } else if (action === "is-debugging-access") {
      parseBoolPayload(payload);
      return {
        typeName: BOOL_RESPONSE_TYPE,
        value: new WebviewBoolResponse(surface.isDebuggingAccess()),
      };
    } else if (action === "create-pdf") {
      const pdfRequest = parsePdfPayload(payload);
      const pdfSlotId = pdfRequest.slotId || DEFAULT_PLUGIN_NODE_SLOT;
      accepted = await WebviewSurfaceRegistry.get(this.pluginContext, pdfSlotId).createPdf(
        pdfRequest.id,
        pdfRequest.path,
        pdfRequest.config ?? null,
      );
    } else if (action === "remove") {
      accepted = surface.remove(controllerPayload.id);
    } else {
      throw new Error(`Unsupported ohos.webview action '${action}'`);
    }
    return { typeName: ACKNOWLEDGEMENT_TYPE, value: new WebviewAcceptedResponse(accepted) };
  }

  onDispose(context: BridgePluginContext): void {
    WebviewSurfaceRegistry.disposeSession(context);
  }
}

export function createWebviewPlugin(): BridgePluginFactory {
  return {
    id: "ohos.webview",
    version: 1,
    execution: "async",
    requires: ["ui-context"],
    create: (context: BridgePluginContext): AsyncBridgePlugin => new WebviewPlugin(context),
  };
}

declare class WebviewController extends webview.WebviewController {}
