import { UIContext } from '@ohos.arkui.UIContext';
import web_webview from '@ohos.web.webview'
import { NodeController, BuilderNode, FrameNode } from '@ohos.arkui.node';
import { randomString } from '../helper';
import { common } from '@kit.AbilityKit';
import { ArkHelper, WebViewComponentEventCallback, WebViewInitData as NativeWebViewInitData } from '../ability/type';
import { exit } from "../helper";
import { getCookies, JsHelper } from './Utils';
import { WebHeader } from '@kit.ArkUI';

export interface WebviewStyle {
  x?: number | string;
  y?: number | string;
  backgroundColor?: string | Color;
  visible?: string;
}

export interface WebviewInitData {
  webTag?: string;
  url: string;
  style?: WebviewStyle;
  controller?: WebviewController;
  javascriptEnable?: boolean
  devtools?: boolean
  autoplay?: boolean
  userAgent?: string
  initializationScripts?: ScriptItem[]
  headers?: Record<string, string>
  html?: string
}

interface WebviewNodeData extends WebviewInitData {
  controller: WebviewController;
}

@Builder
function WebBuilder(data: WebviewNodeData) {
  // init with empty url and reload with loadUrl or loadData with onControllerAttach
  Web({ src: '', controller: data.controller as web_webview.WebviewController })
    .width("100%")
    .height("100%")
    .position({
      x: data.style?.x || 0,
      y: data.style?.y || 0
    })
    .backgroundColor(data?.style?.backgroundColor)
    .visibility(data?.style?.visible === 'hidden' ? Visibility.Hidden : Visibility.Visible)
    .javaScriptAccess(data?.javascriptEnable)
    .mediaPlayGestureAccess((typeof data?.autoplay === 'boolean' && data.autoplay === true) ? false : true)
    .javaScriptOnDocumentStart(data?.initializationScripts)
    .onControllerAttached(() => {
      const ctrl = data.controller;
      // load url or html string
      if (data?.url) {
        const header: WebHeader[] =
          Object.keys((data?.headers || {}) as Record<string, string>).reduce((t: WebHeader[], i) => {
            t.push({ headerKey: i, headerValue: data.headers![i] } as WebHeader);
            return t
          }, [])
        ctrl.loadUrl(data.url, header)
      } else {
        ctrl.loadData(data!.html, 'text/html', 'UTF-8', ' ', ' ')
      }
    })
}

const webViewWrap = wrapBuilder<WebviewNodeData[]>(WebBuilder);

interface AddWebviewMethod {
  webTag: string
  controller: JsHelper
}

export class RustWebviewNodeController extends NodeController {
  private rootNode: FrameNode | null = null;
  private webviewList: Map<string, BuilderNode<WebviewNodeData[]>> = new Map();
  private webviewData: Map<string, JsHelper> = new Map();
  private uiContext: UIContext | null = null;

  constructor(uiContext: UIContext) {
    super();
    this.uiContext = uiContext;
  }

  private buildData(controller: WebviewController) {
    const getUrl = () => {
      return controller.getUrl()
    }
    const getCookiesHelper = (url: string) => {
      return getCookies(url) as string;
    }
    const loadUrl = (url: string) => {
      controller.loadUrl(url)
    }
    const zoom = (scale: number) => {
      controller.zoom(scale)
    }

    const refresh = () => {
      controller.refresh();
    }

    const requestFocus = () => {
      controller.requestFocus();
    }

    // clear browsing data
    const clearAllBrowsingData = () => {
      web_webview.WebStorage.deleteAllData(true);
      web_webview.WebDataBase.deleteHttpAuthCredentials();
      controller.removeCache(true);
      controller.clearHistory();
    }

    const runJavaScript = (code: string, cb: (result?: string) => void) => {
      controller.runJavaScript(code).then(ret => {
        cb(ret)
      })
    }

    const data: JsHelper = {
      getUrl,
      getCookies: getCookiesHelper,
      loadUrl,
      zoom,
      refresh,
      requestFocus,
      clearAllBrowsingData,
      runJavaScript,
    } as JsHelper
    return data;
  }

  makeNode(uiContext: UIContext): FrameNode {
    if (this.rootNode === null) {
      this.rootNode = new FrameNode(uiContext);
    }
    return this.rootNode
  }

  addWebview(data: WebviewInitData): AddWebviewMethod {
    if (!data.webTag) {
      data.webTag = randomString()
    }
    if (!data.controller) {
      data.controller = new web_webview.WebviewController(data.webTag) as WebviewController
    }

    if (this.rootNode === null) {
      this.rootNode = new FrameNode(this.uiContext!)
    }

    const node: BuilderNode<WebviewNodeData[]> = new BuilderNode(this.uiContext!);
    node.build(webViewWrap, data);
    this.webviewList.set(data.webTag, node);

    const controller = this.buildData(data.controller);
    this.webviewData.set(data.webTag, controller);

    this.rootNode?.appendChild(node.getFrameNode());
    return {
      webTag: data.webTag,
      controller
    };
  }

  getWebviewNode(webTag: string) {
    return this.webviewList.get(webTag)
  }
}

// extend WebviewController method
declare class WebviewController extends web_webview.WebviewController {
  getCookies: (url: string) => string
  setBackgroundColor: (color: string) => void
  setVisible: (visible: boolean) => void
  clearAllBrowsingData: () => void
}

@Component
export struct DefaultWebViewComponent {
  private uiContext = getContext(this) as common.UIAbilityContext;
  private nativeModule: ESObject;
  private webviewController = new RustWebviewNodeController(this.getUIContext());
  // keep ref avoid release
  private helper: ArkHelper = {
    exit,
    createWebview: (data: NativeWebViewInitData) => {
      const initScripts: ScriptItem[] = (data?.initializationScripts || []).map(i => {
        return {
          script: i,
          scriptRules: ['*']
        } as ScriptItem
      })
      // url set to empty string avoid double load.
      const init: WebviewInitData =
        {
          webTag: data?.id,
          url: data?.url,
          html: data?.html,
          headers: data?.headers,
          style: (data.style || {}) as WebviewStyle,
          javascriptEnable: data?.javascriptEnable ?? true,
          userAgent: data?.userAgent,
          devtools: data?.devtools,
          autoplay: data?.autoplay,
          initializationScripts: initScripts
        } as WebviewInitData;

      // transparent only be set when backgroundColor is null.
      if (data?.transparent && !init.style?.backgroundColor) {
        init.style!.backgroundColor = Color.Transparent;
      }
      const ret = this.webviewController.addWebview(init)

      ret.controller.setBackgroundColor = (color: string) => {
        init.style!.backgroundColor = color;
        const node = this.webviewController.getWebviewNode(ret.webTag);
        node?.update(init)
      }

      ret.controller.setVisible = (visible: boolean) => {
        init.style!.visible = visible ? 'visible' : 'hidden';
        const node = this.webviewController.getWebviewNode(ret.webTag);
        node?.update(init)
      }

      // Return controller and use controller to control webview behavior
      return ret.controller;
    },
  }
  @StorageProp("moduleName") name: string = "";
  private lifecycleCallback: WebViewComponentEventCallback | null = null;

  async aboutToAppear(): Promise<void> {
    const moduleName = `lib${this.name}.so`;
    const module: ESObject = await import(moduleName);
    this.nativeModule = module.default;

    const ret: WebViewComponentEventCallback = module.default.webviewRender(this.helper);
    this.lifecycleCallback = ret;

    ret.onComponentCreated();
  }

  aboutToDisappear(): void {
    this.lifecycleCallback?.onComponentDestroyed?.();
  }

  build() {
    Row() {
      Column() {
        NodeContainer(this.webviewController)
          .height("100%")
          .width("100%")
      }
      .width('100%')
    }
    .height('100%')
  }
}

