import { UIContext } from "@ohos.arkui.UIContext";
import web_webview from "@ohos.web.webview";
import { ComponentContent, NodeController, BuilderNode, FrameNode } from "@ohos.arkui.node";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { randomString } from "../helper";
import { OnDownloadStartResult, OnWindowNewResult } from "../ability/type";
import { getCookies, setCookie, setWebDebuggingAccess, isWebDebuggingAccess, JsHelper, convertRRGGBBAAtoAARRGGBB, SnapshotData } from "./Utils";
import { WebHeader } from "@kit.ArkUI";
import { router } from '@kit.ArkUI';
import { WindowManager } from '../window/WindowManager';
import { DOMAIN } from '../helper/constants';
import { openNewWindowDialog } from "./NewWindowDialog";
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';

const DEFAULT_PDF_CONFIG: web_webview.PdfConfiguration = {
  width: 8.27,              // A4 width in inches (210mm / 25.4)
  height: 11.69,            // A4 height in inches (297mm / 25.4)
  marginTop: 0,
  marginBottom: 0,
  marginRight: 0,
  marginLeft: 0,
  shouldPrintBackground: true
};

/**
 * Shared onWindowNew handler for both WebBuilder and EmbeddedWebBuilder.
 * Parses event params, calls the NAPI callback, and either opens a dialog or denies.
 */
function handleWindowNew(
  event: { targetUrl?: string; isAlert?: boolean; isUserTrigger?: boolean; handler: { setWebController: (ctrl: web_webview.WebviewController | null) => void } },
  data: WebviewNodeData,
  tag: string,
): void {
  const targetUrl: string = event.targetUrl ?? '';
  const isAlert: boolean = event.isAlert ?? false;
  const isUserTrigger: boolean = event.isUserTrigger ?? false;
  hilog.debug(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: targetUrl=%{public}s, isAlert=%{public}s, isUserTrigger=%{public}s',
    tag, targetUrl, String(isAlert), String(isUserTrigger));
  try {
    if (typeof data?.onWindowNew === 'function') {
      const result: OnWindowNewResult = data.onWindowNew(targetUrl, isAlert, isUserTrigger);
      if (result.allow) {
        hilog.debug(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: ALLOW — opening dialog', tag);
        const newCtrl = new web_webview.WebviewController();
        event.handler.setWebController(newCtrl);
        // Defer dialog to next tick so the callback returns immediately
        if (data?.uiContext) {
          const uiCtx = data.uiContext;
          setTimeout(() => {
            openNewWindowDialog(uiCtx, newCtrl, targetUrl);
          }, 0);
        } else {
          hilog.warn(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: no uiContext, cannot open dialog', tag);
        }
      } else {
        hilog.debug(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: DENY', tag);
        event.handler.setWebController(null);
      }
    } else {
      hilog.debug(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: no handler, default DENY', tag);
      event.handler.setWebController(null);
    }
  } catch (e) {
    hilog.error(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew exception, calling setWebController(null): %{public}s',
      tag, JSON.stringify(e));
    event.handler.setWebController(null);
  }
}

export interface WebviewStyle {
  x?: number | string;
  y?: number | string;
  width?: number | string;
  height?: number | string;
  backgroundColor?: string | Color | number;
  visible?: boolean;
}

export interface WebviewInitData {
  webTag?: string;
  url: string;
  windowId?: number;
  style?: WebviewStyle;
  controller?: WebviewController;
  uiContext?: UIContext;
  javascriptEnable?: boolean;
  devtools?: boolean;
  autoplay?: boolean;
  userAgent?: string;
  initializationScripts?: ScriptItem[];
  headers?: Record<string, string>;
  html?: string;
  transparent?: boolean;
  onDragAndDrop?: (event: string) => void;
  onDownloadStart?: (url: string, tempPath: string | undefined) => OnDownloadStartResult;
  onDownloadEnd?: (url: string, tempPath: string | undefined, success: boolean) => void;
  onNavigationRequest?: (url: string) => boolean;
  onTitleChange?: (title: string) => void;
  onPageBegin?: (url: string) => void;
  onPageEnd?: (url: string) => void;
  onCloseWindow?: () => void;
  onWindowNew?: (targetUrl: string, isAlert: boolean, isUserTrigger: boolean) => OnWindowNewResult;
}

interface WebviewNodeData extends WebviewInitData {
  controller: WebviewController;
  didInitialLoad?: boolean;
}

@Builder
function WebBuilder(data: WebviewNodeData) {
  // init with empty url and reload with loadUrl or loadData with onControllerAttach
  Web({
    src: "",
    controller: data.controller as web_webview.WebviewController,
    renderMode: data?.transparent ? RenderMode.SYNC_RENDER : RenderMode.ASYNC_RENDER
  })
    .width(data.style?.width ?? "100%")
    .height(data.style?.height ?? "100%")
    .position({
      x: data.style?.x ?? 0,
      y: data.style?.y ?? 0,
    })
    .backgroundColor(convertRRGGBBAAtoAARRGGBB(data?.style?.backgroundColor))
    .visibility(data?.style?.visible === false ? Visibility.Hidden : Visibility.Visible)
    .javaScriptAccess(data?.javascriptEnable)
    .domStorageAccess(true)
    .mediaPlayGestureAccess(
      typeof data?.autoplay === "boolean" && data.autoplay === true ? false : true,
    )
    .javaScriptOnDocumentStart(data?.initializationScripts)
    .onControllerAttached(() => {
      hilog.info(DOMAIN, 'DefaultWebview', 'onControllerAttached fired');
      // Guard against repeated onControllerAttached calls (re-render or system events)
      if (data.didInitialLoad === true) {
        return;
      }
      data.didInitialLoad = true;
      const ctrl = data.controller;
      // Set up download delegate after controller is attached
      setupDownloadDelegate(data);
      // Set custom User-Agent if provided
      if (data.userAgent) {
        try {
          ctrl.setCustomUserAgent(data.userAgent);
        } catch (error) {
          hilog.error(DOMAIN, 'DefaultWebview', 'setCustomUserAgent failed: %{public}s', JSON.stringify(error));
        }
      }
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
    .onErrorReceive((event) => {
      hilog.error(DOMAIN, 'DefaultWebview', 'Web onErrorReceive: %{public}s', JSON.stringify(event));
      if (event.error) {
        // Only replace page content for main frame errors; ignore sub-resource errors
        if (!event.request.isMainFrame()) {
          hilog.warn(DOMAIN, 'DefaultWebview', 'Sub-resource error ignored, code: %{public}d', event.error.getErrorCode());
          return;
        }
        const ctrl = data.controller;
        const errorCode = event.error.getErrorCode();
        const errorInfo = event.error.getErrorInfo();
        hilog.error(DOMAIN, 'DefaultWebview', 'Main frame load failed: %{public}d - %{public}s', errorCode, errorInfo);

        const errorHtml = `
          <html>
            <body style="display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f5f5f5;font-family:sans-serif;">
              <div style="text-align:center;padding:20px;">
                <h2>Network Error</h2>
                <p>Failed to load the page. Please check your connection.</p>
                <p style="color:#666;font-size:12px;">Error: ${errorCode} - ${errorInfo}</p>
              </div>
            </body>
          </html>
        `;
        ctrl.loadData(errorHtml, 'text/html', 'UTF-8', ' ', ' ');
      }
    })
    .onLoadIntercept((event) => {
      const url = event.data.getRequestUrl();
      // OHOS: intercept close-window URL to destroy the parent window.
      // This is used by test windows that cannot attach JS event listeners
      // due to OHOS Web component initialization_script limitations.
      if (url && event.data.isMainFrame() && url.startsWith('http://close-window.invalid')) {
        hilog.info(DOMAIN, 'DefaultWebview', 'Intercepted close-window URL, destroying window %{public}d', data?.windowId ?? -1);
        if (typeof data?.onCloseWindow === 'function') {
          data.onCloseWindow();
        }
        return true; // block navigation
      }
      if (typeof data?.onNavigationRequest === "function") {
        hilog.info(DOMAIN, 'DefaultWebview', 'onLoadIntercept → onNavigationRequest called: %{public}s', url);
        // onLoadIntercept: true = block, false = allow
        // onNavigationRequest: true = allow, false = block
        // So we negate the return value
        const ret = data.onNavigationRequest(url);
        hilog.info(DOMAIN, 'DefaultWebview', 'onNavigationRequest result: %{public}s, onLoadIntercept returns: %{public}s', ret ? 'allow' : 'block', ret ? 'false(allow)' : 'true(block)');
        return !ret;
      }
      return false;
    })
    .onTitleReceive((e) => {
      if (typeof data?.onTitleChange === "function") {
        hilog.info(DOMAIN, 'DefaultWebview', 'onTitleReceive → onTitleChange called: %{public}s', e.title);
        data.onTitleChange(e.title);
      }
    })
    .onPageBegin((e) => {
      if (typeof data?.onPageBegin === "function") {
        data.onPageBegin(e.url);
      }
    })
    .onPageEnd((e) => {
      if (typeof data?.onPageEnd === "function") {
        data.onPageEnd(e.url);
      }
    })
    .multiWindowAccess(true)
    .allowWindowOpenMethod(true)
    .onWindowNew((event) => {
      handleWindowNew(event, data, 'WebBuilder');
    });
}

@Builder
function EmbeddedWebBuilder(data: WebviewNodeData) {
  // The embedded path needs a bounded ArkTS root so hit testing stays clipped
  // to the host slot owned by native. A bare `Web` component can render in the
  // right place while still participating in input as an unbounded layer.
  Stack() {
    Web({
      src: "",
      controller: data.controller as web_webview.WebviewController,
      renderMode: data?.transparent ? RenderMode.SYNC_RENDER : RenderMode.ASYNC_RENDER
    })
      .width(data.style?.width ?? "100%")
      .height(data.style?.height ?? "100%")
      .backgroundColor(convertRRGGBBAAtoAARRGGBB(data?.style?.backgroundColor))
      .javaScriptAccess(data?.javascriptEnable)
      .domStorageAccess(true)
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
        // Set up download delegate after controller is attached
        setupDownloadDelegate(data);
        // Set custom User-Agent if provided
        if (data.userAgent) {
          try {
            ctrl.setCustomUserAgent(data.userAgent);
          } catch (error) {
            hilog.error(DOMAIN, 'DefaultWebview', 'setCustomUserAgent failed: %{public}s', JSON.stringify(error));
          }
        }
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
      .onErrorReceive((event) => {
        hilog.error(DOMAIN, 'DefaultWebview', 'Embedded Web onErrorReceive: %{public}s', JSON.stringify(event));
        if (event.error) {
          if (!event.request.isMainFrame()) {
            hilog.warn(DOMAIN, 'DefaultWebview', 'Embedded sub-resource error ignored, code: %{public}d', event.error.getErrorCode());
            return;
          }
          const ctrl = data.controller;
          const errorCode = event.error.getErrorCode();
          const errorInfo = event.error.getErrorInfo();
          hilog.error(DOMAIN, 'DefaultWebview', 'Embedded Main frame load failed: %{public}d - %{public}s', errorCode, errorInfo);
          const errorHtml = `
            <html>
              <body style="display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f5f5f5;font-family:sans-serif;">
                <div style="text-align:center;padding:20px;">
                  <h2>Network Error</h2>
                  <p>Failed to load the page. Please check your connection.</p>
                  <p style="color:#666;font-size:12px;">Error: ${errorCode} - ${errorInfo}</p>
                </div>
              </body>
            </html>
          `;
          ctrl.loadData(errorHtml, 'text/html', 'UTF-8', ' ', ' ');
        }
      })
      .onLoadIntercept((event) => {
        if (typeof data?.onNavigationRequest === "function") {
          const url = event.data.getRequestUrl();
          // onLoadIntercept: true = block, false = allow
          // onNavigationRequest: true = allow, false = block
          const ret = data.onNavigationRequest(url);
          return !ret;
        }
        return false;
      })
      .onTitleReceive((e) => {
        if (typeof data?.onTitleChange === "function") {
          data.onTitleChange(e.title);
        }
      })
      .onPageBegin((e) => {
        if (typeof data?.onPageBegin === "function") {
          data.onPageBegin(e.url);
        }
      })
      .onPageEnd((e) => {
        if (typeof data?.onPageEnd === "function") {
          data.onPageEnd(e.url);
        }
      })
      .multiWindowAccess(true)
      .allowWindowOpenMethod(true)
      .onWindowNew((event) => {
        handleWindowNew(event, data, 'EmbeddedWebBuilder');
      })
    }
  .width(data.style?.width ?? "100%")
  .height(data.style?.height ?? "100%")
  .position({
    x: data.style?.x ?? 0,
    y: data.style?.y ?? 0,
  })
  .backgroundColor(Color.Transparent)
  .clip(true)
  .visibility(data?.style?.visible === false ? Visibility.Hidden : Visibility.Visible)
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
    setWebDebuggingAccess(true);
  }

  return prepared;
}

function setupDownloadDelegate(data: WebviewNodeData) {
  if (typeof data?.onDownloadStart !== "function" && typeof data?.onDownloadEnd !== "function") {
    hilog.info(DOMAIN, 'DefaultWebview', 'setupDownloadDelegate: no download handlers registered');
    return;
  }

  hilog.info(DOMAIN, 'DefaultWebview', 'setupDownloadDelegate: registering download delegate');
  const download = new web_webview.WebDownloadDelegate();

  if (typeof data?.onDownloadStart === "function") {
    download.onBeforeDownload((e) => {
      const url = e.getUrl();
      const tempPath = e.getFullPath();
      hilog.info(DOMAIN, 'DefaultWebview', 'onBeforeDownload → onDownloadStart: %{public}s', url);
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
      hilog.info(DOMAIN, 'DefaultWebview', 'onDownloadFinish → onDownloadEnd: %{public}s, success=true', url);
      data.onDownloadEnd!(url, tempPath, true);
    });
    download.onDownloadFailed((e) => {
      const url = e.getUrl();
      hilog.info(DOMAIN, 'DefaultWebview', 'onDownloadFailed → onDownloadEnd: %{public}s, success=false', url);
      data.onDownloadEnd!(url, undefined, false);
    });
  }

  data.controller.setDownloadDelegate(download);
}

function buildJsHelper(controller: WebviewController): JsHelper {
  const getUrl = () => {
    return controller.getUrl();
  };
  const getCookiesHelper = (url: string) => {
    return getCookies(url) as string;
  };
  const setCookieHelper = (url: string, value: string) => {
    setCookie(url, value);
  };
  const setWebDebuggingAccessHelper = (enabled: boolean) => {
    setWebDebuggingAccess(enabled);
  };
  const isWebDebuggingAccessHelper = (): boolean => {
    return isWebDebuggingAccess();
  };
  const loadUrl = (url: string, header?: Record<string, string>) => {
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
  };

  const loadHtml = (html: string) => {
    controller.loadData(html, "text/html", "UTF-8", " ", " ");
  };

  const zoom = (scale: number) => {
    controller.zoom(scale);
  };

  const refresh = () => {
    controller.refresh();
  };

  const requestFocus = () => {
    controller.requestFocus();
  };

  const clearAllBrowsingData = () => {
    web_webview.WebStorage.deleteAllData(true);
    web_webview.WebDataBase.deleteHttpAuthCredentials();
    controller.removeCache(true);
    controller.clearHistory();
  };

  const runJavaScript = (code: string, cb: (result?: string) => void) => {
    controller.runJavaScript(code).then((ret) => {
      cb(ret ?? undefined);
    }).catch((err) => {
      hilog.error(DOMAIN, 'DefaultWebview', 'runJavaScript ERR message=%{public}s code=%{public}s', String(err?.message || err), code.substring(0, 120));
      cb(undefined);
    });
  };

  const webPageSnapshot = (): Promise<SnapshotData> => {
    return new Promise<SnapshotData>((resolve, reject) => {
      // Overall timeout: reject if not completed within 10s
      let settled = false;
      const timeoutId = setTimeout(() => {
        if (!settled) {
          settled = true;
          reject(new Error('webPageSnapshot timed out after 10s'));
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
          controller.webPageSnapshot({ id: "snapshot" }, (error: BusinessError, result: web_webview.SnapshotResult) => {
            if (error) {
              if (retriesLeft > 0) {
                hilog.warn(DOMAIN, 'DefaultWebview', 'webPageSnapshot attempt failed (%{public}s), retrying (%{public}d left)...', error.message, retriesLeft);
                setTimeout(() => attempt(retriesLeft - 1), 500);
              } else {
                hilog.error(DOMAIN, 'DefaultWebview', 'webPageSnapshot error: %{public}s', JSON.stringify(error));
                done(() => reject(new Error(`webPageSnapshot failed: ${error.code} - ${error.message}`)));
              }
              return;
            }
            if (!result || result.status !== true || !result.imagePixelMap) {
              done(() => reject(new Error('webPageSnapshot returned empty or failed result')));
              return;
            }
            const pixelMap = result.imagePixelMap;
            try {
              const info = pixelMap.getImageInfoSync();
              const byteCount = pixelMap.getPixelBytesNumber();
              const buffer = new ArrayBuffer(byteCount);
              pixelMap.readPixelsToBufferSync(buffer);
              const rgba = new Uint8Array(buffer);
              done(() => resolve({
                rgba: rgba,
                width: info.size.width,
                height: info.size.height,
              }));
            } catch (e) {
              hilog.error(DOMAIN, 'DefaultWebview', 'webPageSnapshot PixelMap conversion error: %{public}s', String(e));
              done(() => reject(new Error(`PixelMap conversion failed: ${String(e)}`)));
            } finally {
              try {
                pixelMap.release();
              } catch (releaseErr) {
                hilog.warn(DOMAIN, 'DefaultWebview', 'webPageSnapshot PixelMap release warning: %{public}s', String(releaseErr));
              }
            }
          });
        } catch (e) {
          if (retriesLeft > 0) {
            hilog.warn(DOMAIN, 'DefaultWebview', 'webPageSnapshot exception (%{public}s), retrying (%{public}d left)...', String(e), retriesLeft);
            setTimeout(() => attempt(retriesLeft - 1), 500);
          } else {
            hilog.error(DOMAIN, 'DefaultWebview', 'webPageSnapshot exception: %{public}s', String(e));
            done(() => reject(new Error(`webPageSnapshot exception: ${String(e)}`)));
          }
        }
      };
      // Initial delay + up to 3 retries with 500ms intervals
      setTimeout(() => attempt(3), 500);
    });
  };

  const activePdfOps = new Map<string, boolean>();

  const createPdf = (path: string, config: Record<string, number | boolean>, callback: (success: boolean) => void) => {
    // Per-path mutex: prevent concurrent writes to the same file
    if (activePdfOps.has(path)) {
      hilog.warn(DOMAIN, 'DefaultWebview', 'createPdf: operation already in progress for %{public}s', path);
      callback(false);
      return;
    }
    activePdfOps.set(path, true);
    const done = (success: boolean) => { activePdfOps.delete(path); callback(success); };

    // API 14+ guard: createPdf is not available on API 12/13 devices
    if (typeof controller.createPdf !== 'function') {
      hilog.error(DOMAIN, 'DefaultWebview', 'createPdf requires API 14+, not available on this device');
      done(false);
      return;
    }

    // Merge user config with defaults
    const mergedConfig: web_webview.PdfConfiguration = { ...DEFAULT_PDF_CONFIG };
    if (config) {
      if (config['width'] !== undefined) mergedConfig.width = config['width'] as number;
      if (config['height'] !== undefined) mergedConfig.height = config['height'] as number;
      if (config['marginTop'] !== undefined) mergedConfig.marginTop = config['marginTop'] as number;
      if (config['marginBottom'] !== undefined) mergedConfig.marginBottom = config['marginBottom'] as number;
      if (config['marginLeft'] !== undefined) mergedConfig.marginLeft = config['marginLeft'] as number;
      if (config['marginRight'] !== undefined) mergedConfig.marginRight = config['marginRight'] as number;
      if (config['shouldPrintBackground'] !== undefined) mergedConfig.shouldPrintBackground = config['shouldPrintBackground'] as boolean;
      if (config['scale'] !== undefined) mergedConfig.scale = config['scale'] as number;
    }

    controller.createPdf(mergedConfig)
      .then(async (result) => {
        try {
          const buffer = result.pdfArrayBuffer().buffer;
          if (buffer.byteLength === 0) {
            hilog.warn(DOMAIN, 'DefaultWebview', 'createPdf: empty PDF buffer (blank page?)');
            done(false);
            return;
          }
          const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
          try {
            await fileIo.write(file.fd, buffer);
            done(true);
          } catch (writeErr) {
            hilog.error(DOMAIN, 'DefaultWebview', 'createPdf write failed: %{public}s', JSON.stringify(writeErr));
            done(false);
          } finally {
            fileIo.closeSync(file);
          }
        } catch (err) {
          hilog.error(DOMAIN, 'DefaultWebview', 'createPdf file IO failed: %{public}s', JSON.stringify(err));
          done(false);
        }
      })
      .catch((err) => {
        hilog.error(DOMAIN, 'DefaultWebview', 'createPdf failed: %{public}s', JSON.stringify(err));
        done(false);
      });
  };
  return {
    getUrl,
    getCookies: getCookiesHelper,
    setCookie: setCookieHelper,
    setWebDebuggingAccess: setWebDebuggingAccessHelper,
    isWebDebuggingAccess: isWebDebuggingAccessHelper,
    loadUrl,
    loadHtml,
    zoom,
    refresh,
    requestFocus,
    clearAllBrowsingData,
    runJavaScript,
    webPageSnapshot,
    setBackgroundColor: (_color: number) => {},
    setVisible: (_visible: boolean) => {},
    setBounds: (_x: number, _y: number, _width: number, _height: number) => {},
    dispose: () => {},
    createPdf,
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

    const newEntry: WebviewNodeData = { ...entry, style: style };
    this.webviewEntries.set(webTag, newEntry);
    node.update(newEntry);
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
    // Pass UIContext for promptAction (e.g., openNewWindowDialog)
    if (!data.uiContext && this.uiContext) {
      data.uiContext = this.uiContext;
    }
    const prepared = ensureWebviewNodeData(data);
    const webTag = prepared.webTag!;
    if (this.rootNode === null) {
      this.rootNode = new FrameNode(this.uiContext!);
    }

    const node = new BuilderNode<[WebviewNodeData]>(this.uiContext!);
    node.build(webViewWrap, prepared);

    const controller = this.buildData(prepared.controller);
    this.webviewEntries.set(webTag, prepared);
    this.webviewList.set(webTag, node);

    this.rootNode?.appendChild(node.getFrameNode());

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

    this.rootNode?.removeChild(node.getFrameNode());
  }

  getPrimaryWebviewController(): web_webview.WebviewController | null {
    const firstEntry = this.webviewEntries.values().next().value;
    return (firstEntry as WebviewNodeData)?.controller ?? null;
  }
}

export class EmbeddedWebviewManager {
  private uiContext: UIContext;
  private entries: Map<string, EmbeddedWebviewEntry> = new Map();

  constructor(uiContext: UIContext) {
    this.uiContext = uiContext;
  }

  createWebview(data: WebviewInitData): EmbeddedWebviewHandle {
    // Pass UIContext for promptAction (e.g., openNewWindowDialog)
    if (!data.uiContext) {
      data.uiContext = this.uiContext;
    }
    const prepared = ensureWebviewNodeData(data);
    const webTag = prepared.webTag!;

    const content = new ComponentContent<WebviewNodeData>(
      this.uiContext,
      embeddedWebViewWrap,
      prepared,
    );

    content.update(prepared);

    const controller = buildJsHelper(prepared.controller);
    this.entries.set(webTag, {
      data: prepared,
      content,
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

    const newData: WebviewNodeData = { ...entry.data, style: style };
    entry.data = newData;
    entry.content.update(newData);
  }

  removeWebview(webTag: string) {
    const entry = this.entries.get(webTag);
    if (!entry) {
      return;
    }

    this.entries.delete(webTag);
    entry.content.dispose();
  }
}

// extend WebviewController method
declare class WebviewController extends web_webview.WebviewController {
  getCookies: (url: string) => string;
  setBackgroundColor: (color: number) => void;
  setVisible: (visible: boolean) => void;
  setBounds: (x: number, y: number, width: number, height: number) => void;
  dispose: () => void;
  clearAllBrowsingData: () => void;
}
