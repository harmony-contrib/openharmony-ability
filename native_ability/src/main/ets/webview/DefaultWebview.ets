import { UIContext } from "@ohos.arkui.UIContext";
import web_webview from "@ohos.web.webview";
import { ComponentContent, NodeController, BuilderNode, FrameNode } from "@ohos.arkui.node";
import hilog from "@ohos.hilog";
import { randomString } from "../helper";
import { OnDownloadStartResult } from "../ability/type";
import { getCookies, JsHelper } from "./Utils";
import { WebHeader } from "@kit.ArkUI";

const TAG = "OHRSWebview";

export interface WebviewStyle {
  x?: number | string;
  y?: number | string;
  backgroundColor?: string | Color;
  visible?: boolean | string;
}

export interface WebviewInitData {
  webTag?: string;
  url: string;
  style?: WebviewStyle;
  controller?: WebviewController;
  javascriptEnable?: boolean;
  devtools?: boolean;
  autoplay?: boolean;
  userAgent?: string;
  initializationScripts?: ScriptItem[];
  headers?: Record<string, string>;
  html?: string;
  onDragAndDrop?: (event: string) => void;
  onDownloadStart?: (url: string, tempPath: string | undefined) => OnDownloadStartResult;
  onDownloadEnd?: (url: string, tempPath: string | undefined, success: boolean) => void;
  onNavigationRequest?: (url: string) => boolean;
  onTitleChange?: (title: string) => void;
}

interface WebviewNodeData extends WebviewInitData {
  controller: WebviewController;
  didInitialLoad?: boolean;
}

function describeWebviewError(error: ESObject): string {
  const message: string = Reflect.get(error, "message");
  if (typeof message === "string" && message.length > 0) {
    return message;
  }

  try {
    return JSON.stringify(error);
  } catch (_) {
    return `${error}`;
  }
}

function describeStyleValue(value?: number | string): string {
  if (typeof value === "number" || typeof value === "string") {
    return `${value}`;
  }
  return "undefined";
}

function describeWebviewStyle(style: WebviewStyle): string {
  return `x=${describeStyleValue(style.x)}, y=${describeStyleValue(style.y)}, visible=${style.visible}, backgroundColor=${style.backgroundColor}`;
}

function logWebviewError(stage: string, detail: string) {
  hilog.error(0x0000, TAG, `${stage}: ${detail}`);
}

@Builder
function WebBuilder(data: WebviewNodeData) {
  // init with empty url and reload with loadUrl or loadData with onControllerAttach
  Web({ src: "", controller: data.controller as web_webview.WebviewController })
    .width("100%")
    .height("100%")
    .position({
      x: data.style?.x ?? 0,
      y: data.style?.y ?? 0,
    })
    .backgroundColor(data?.style?.backgroundColor)
    .visibility(
      data?.style?.visible === false || data?.style?.visible === "hidden"
        ? Visibility.Hidden
        : Visibility.Visible,
    )
    .javaScriptAccess(data?.javascriptEnable)
    .mediaPlayGestureAccess(
      typeof data?.autoplay === "boolean" && data.autoplay === true ? false : true,
    )
    .javaScriptOnDocumentStart(data?.initializationScripts)
    .onControllerAttached(() => {
      const ctrl = data.controller;
      // load url or html string
      if (data?.url) {
        const header: WebHeader[] = Object.keys(
          (data?.headers || {}) as Record<string, string>,
        ).reduce((t: WebHeader[], i) => {
          t.push({ headerKey: i, headerValue: data.headers![i] } as WebHeader);
          return t;
        }, []);
        ctrl.loadUrl(data.url, header);
      } else {
        ctrl.loadData(data!.html, "text/html", "UTF-8", " ", " ");
      }
    })
    .onLoadIntercept((event) => {
      if (typeof data?.onNavigationRequest === "function") {
        const url = event.data.getRequestUrl();
        const ret = data.onNavigationRequest(url);
        return ret;
      }
      return false;
    })
    .onTitleReceive((e) => {
      if (typeof data?.onTitleChange === "function") {
        data.onTitleChange(e.title);
      }
    });
}

@Builder
function EmbeddedWebBuilder(data: WebviewNodeData) {
  // The embedded path needs a bounded ArkTS root so hit testing stays clipped
  // to the host slot owned by native. A bare `Web` component can render in the
  // right place while still participating in input as an unbounded layer.
  Stack() {
    Web({ src: "", controller: data.controller as web_webview.WebviewController })
      .width("100%")
      .height("100%")
      .backgroundColor(data?.style?.backgroundColor)
      .javaScriptAccess(data?.javascriptEnable)
      .mediaPlayGestureAccess(
        typeof data?.autoplay === "boolean" && data.autoplay === true ? false : true,
      )
      .javaScriptOnDocumentStart(data?.initializationScripts)
      .onControllerAttached(() => {
        if (data.didInitialLoad === true) {
          return;
        }
        data.didInitialLoad = true;
        const ctrl = data.controller;
        if (data?.url) {
          const header: WebHeader[] = Object.keys(
            (data?.headers || {}) as Record<string, string>,
          ).reduce((t: WebHeader[], i) => {
            t.push({ headerKey: i, headerValue: data.headers![i] } as WebHeader);
            return t;
          }, []);
          ctrl.loadUrl(data.url, header);
        } else {
          ctrl.loadData(data!.html, "text/html", "UTF-8", " ", " ");
        }
      })
      .onLoadIntercept((event) => {
        if (typeof data?.onNavigationRequest === "function") {
          const url = event.data.getRequestUrl();
          const ret = data.onNavigationRequest(url);
          return ret;
        }
        return false;
      })
      .onTitleReceive((e) => {
        if (typeof data?.onTitleChange === "function") {
          data.onTitleChange(e.title);
        }
      })
  }
  .width("100%")
  .height("100%")
  .clip(true)
  .visibility(
    data?.style?.visible === false || data?.style?.visible === "hidden"
      ? Visibility.Hidden
      : Visibility.Visible,
  )
  .hitTestBehavior(HitTestMode.Default);
}

const webViewWrap = wrapBuilder<[WebviewNodeData]>(WebBuilder);
const embeddedWebViewWrap = wrapBuilder<[WebviewNodeData]>(EmbeddedWebBuilder);

interface AddWebviewMethod {
  webTag: string;
  controller: JsHelper;
}

export interface EmbeddedWebviewHandle extends AddWebviewMethod {
  content: ComponentContent<WebviewNodeData>;
}

interface EmbeddedWebviewEntry {
  data: WebviewNodeData;
  content: ComponentContent<WebviewNodeData>;
  controller: JsHelper;
}

function ensureWebviewNodeData(data: WebviewInitData): WebviewNodeData {
  if (!data.webTag) {
    data.webTag = randomString();
  }
  if (!data.controller) {
    data.controller = new web_webview.WebviewController(data.webTag) as WebviewController;
  }
  data.style = data.style || {};
  if (typeof data.javascriptEnable !== "boolean") {
    data.javascriptEnable = true;
  }
  const prepared = data as WebviewNodeData;
  prepared.didInitialLoad = prepared.didInitialLoad === true;

  if (prepared?.devtools) {
    web_webview.WebviewController.setWebDebuggingAccess(true);
  }

  return prepared;
}

function setupDownloadDelegate(data: WebviewNodeData) {
  if (typeof data?.onDownloadStart !== "function" && typeof data?.onDownloadEnd !== "function") {
    return;
  }

  const download = new web_webview.WebDownloadDelegate();

  if (typeof data?.onDownloadStart === "function") {
    download.onBeforeDownload((e) => {
      const url = e.getUrl();
      const tempPath = e.getFullPath();
      const ret = data.onDownloadStart!(url, tempPath);

      if (ret.allow) {
        e.start(ret.tempPath || tempPath);
      } else {
        e.cancel();
      }
    });
  }

  if (typeof data?.onDownloadEnd === "function") {
    download.onDownloadFinish((e) => {
      const url = e.getUrl();
      const tempPath = e.getFullPath();
      data.onDownloadEnd!(url, tempPath, true);
    });
    download.onDownloadFailed((e) => {
      const url = e.getUrl();
      data.onDownloadEnd!(url, undefined, false);
    });
  }

  try {
    data.controller.setDownloadDelegate(download);
  } catch (error) {
    const detail = `setDownloadDelegate(${data.webTag}) failed: ${describeWebviewError(error)}`;
    logWebviewError("webview/downloadDelegate", detail);
    throw new Error(detail);
  }
}

function buildJsHelper(controller: WebviewController): JsHelper {
  const getUrl = () => {
    return controller.getUrl();
  };
  const getCookiesHelper = (url: string) => {
    return getCookies(url) as string;
  };
  const loadUrl = (url: string, header?: Record<string, string>) => {
    try {
      const headers = Object.keys((header || {}) as Record<string, string>).reduce(
        (t, i) => {
          if (!!header![i]) {
            t.push({ headerKey: i, headerValue: header![i] });
          }
          return t;
        },
        [] as Array<WebHeader>,
      );
      controller.loadUrl(url, headers);
    } catch (error) {
      const detail = `loadUrl(${url}) failed: ${describeWebviewError(error)}`;
      logWebviewError("loadUrl", detail);
      throw new Error(detail);
    }
  };

  const loadHtml = (html: string) => {
    try {
      controller.loadData(html, "text/html", "UTF-8", " ", " ");
    } catch (error) {
      const detail = `loadHtml failed: ${describeWebviewError(error)}`;
      logWebviewError("loadHtml", detail);
      throw new Error(detail);
    }
  };

  const zoom = (scale: number) => {
    try {
      controller.zoom(scale);
    } catch (error) {
      const detail = `zoom(${scale}) failed: ${describeWebviewError(error)}`;
      logWebviewError("zoom", detail);
      throw new Error(detail);
    }
  };

  const refresh = () => {
    try {
      controller.refresh();
    } catch (error) {
      const detail = `refresh failed: ${describeWebviewError(error)}`;
      logWebviewError("refresh", detail);
      throw new Error(detail);
    }
  };

  const requestFocus = () => {
    try {
      controller.requestFocus();
    } catch (error) {
      const detail = `requestFocus failed: ${describeWebviewError(error)}`;
      logWebviewError("requestFocus", detail);
      throw new Error(detail);
    }
  };

  const clearAllBrowsingData = () => {
    try {
      web_webview.WebStorage.deleteAllData(true);
      web_webview.WebDataBase.deleteHttpAuthCredentials();
      controller.removeCache(true);
      controller.clearHistory();
    } catch (error) {
      const detail = `clearAllBrowsingData failed: ${describeWebviewError(error)}`;
      logWebviewError("clearAllBrowsingData", detail);
      throw new Error(detail);
    }
  };

  const runJavaScript = (code: string, cb: (result?: string) => void) => {
    controller
      .runJavaScript(code)
      .then((ret) => {
        cb(ret);
      })
      .catch((error: ESObject) => {
        const detail = `runJavaScript failed: ${describeWebviewError(error)}`;
        logWebviewError("runJavaScript", detail);
        throw new Error(detail);
      });
  };

  return {
    getUrl,
    getCookies: getCookiesHelper,
    loadUrl,
    loadHtml,
    zoom,
    refresh,
    requestFocus,
    clearAllBrowsingData,
    runJavaScript,
  } as JsHelper;
}

export class RustWebviewNodeController extends NodeController {
  private rootNode: FrameNode | null = null;
  private webviewEntries: Map<string, WebviewNodeData> = new Map();
  private webviewList: Map<string, BuilderNode<[WebviewNodeData]>> = new Map();
  private uiContext: UIContext | null = null;

  constructor(uiContext: UIContext) {
    super();
    this.uiContext = uiContext;
  }

  updateWebviewStyle(webTag: string, style: WebviewStyle) {
    const entry = this.webviewEntries.get(webTag);
    const node = this.webviewList.get(webTag);
    if (!entry || !node) {
      return;
    }

    entry.style = style;
    try {
      node.update(entry);
    } catch (error) {
      const detail = `updateWebviewStyle(${webTag}) failed: ${describeWebviewError(error)}; style={${describeWebviewStyle(style)}}`;
      logWebviewError("overlay/update", detail);
      throw new Error(detail);
    }
  }

  private buildData(controller: WebviewController) {
    return buildJsHelper(controller);
  }

  makeNode(uiContext: UIContext): FrameNode {
    if (this.rootNode === null) {
      this.rootNode = new FrameNode(uiContext);
    }
    return this.rootNode;
  }

  addWebview(data: WebviewInitData): AddWebviewMethod {
    const prepared = ensureWebviewNodeData(data);
    const webTag = prepared.webTag!;
    if (this.rootNode === null) {
      this.rootNode = new FrameNode(this.uiContext!);
    }

    const node = new BuilderNode<[WebviewNodeData]>(this.uiContext!);
    try {
      node.build(webViewWrap, prepared);
    } catch (error) {
      const detail = `addWebview(${webTag}) build failed: ${describeWebviewError(error)}`;
      logWebviewError("overlay/build", detail);
      throw new Error(detail);
    }

    const controller = this.buildData(prepared.controller);
    setupDownloadDelegate(prepared);
    this.webviewEntries.set(webTag, prepared);
    this.webviewList.set(webTag, node);

    try {
      this.rootNode?.appendChild(node.getFrameNode());
    } catch (error) {
      const detail = `addWebview(${webTag}) append failed: ${describeWebviewError(error)}`;
      logWebviewError("overlay/append", detail);
      throw new Error(detail);
    }

    return {
      webTag,
      controller,
    };
  }

  removeWebview(webTag: string) {
    const node = this.webviewList.get(webTag);
    if (!node) {
      return;
    }

    this.webviewEntries.delete(webTag);
    this.webviewList.delete(webTag);

    try {
      this.rootNode?.removeChild(node.getFrameNode());
    } catch (error) {
      const detail = `removeWebview(${webTag}) failed: ${describeWebviewError(error)}`;
      logWebviewError("overlay/remove", detail);
      throw new Error(detail);
    }
  }

  getWebviewNode(webTag: string) {
    return this.webviewList.get(webTag);
  }
}

export class EmbeddedWebviewManager {
  private uiContext: UIContext;
  private entries: Map<string, EmbeddedWebviewEntry> = new Map();

  constructor(uiContext: UIContext) {
    this.uiContext = uiContext;
  }

  createWebview(data: WebviewInitData): EmbeddedWebviewHandle {
    const prepared = ensureWebviewNodeData(data);
    const webTag = prepared.webTag!;
    setupDownloadDelegate(prepared);

    const content = new ComponentContent<WebviewNodeData>(
      this.uiContext,
      embeddedWebViewWrap,
      prepared,
    );

    try {
      content.update(prepared);
    } catch (error) {
      const detail = `createEmbeddedWebview(${webTag}) build failed: ${describeWebviewError(error)}`;
      logWebviewError("embedded/build", detail);
      throw new Error(detail);
    }

    const controller = buildJsHelper(prepared.controller);
    this.entries.set(webTag, {
      data: prepared,
      content,
      controller,
    });

    return {
      webTag,
      controller,
      content,
    };
  }

  updateWebviewStyle(webTag: string, style: WebviewStyle) {
    const entry = this.entries.get(webTag);
    if (!entry) {
      return;
    }

    entry.data.style = style;
    try {
      entry.content.update(entry.data);
    } catch (error) {
      const detail = `updateEmbeddedWebviewStyle(${webTag}) failed: ${describeWebviewError(error)}; style={${describeWebviewStyle(style)}}`;
      logWebviewError("embedded/update", detail);
      throw new Error(detail);
    }
  }

  removeWebview(webTag: string) {
    const entry = this.entries.get(webTag);
    if (!entry) {
      return;
    }

    this.entries.delete(webTag);
    try {
      entry.content.dispose();
    } catch (error) {
      const detail = `disposeEmbeddedWebview(${webTag}) failed: ${describeWebviewError(error)}`;
      logWebviewError("embedded/dispose", detail);
      throw new Error(detail);
    }
  }
}

// extend WebviewController method
declare class WebviewController extends web_webview.WebviewController {
  getCookies: (url: string) => string;
  setStyle: (style: WebviewStyle) => void;
  setBackgroundColor: (color: string) => void;
  setVisible: (visible: boolean) => void;
  dispose: () => void;
  clearAllBrowsingData: () => void;
}
