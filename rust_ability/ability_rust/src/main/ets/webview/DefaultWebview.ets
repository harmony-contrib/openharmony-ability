import { UIContext } from '@ohos.arkui.UIContext';
import web_webview from '@ohos.web.webview'
import { NodeController, BuilderNode, FrameNode } from '@ohos.arkui.node';
import { randomString } from '../helper';
import { common } from '@kit.AbilityKit';
import { ArkHelper, WebViewComponentEventCallback, WebViewInitData as NativeWebViewInitData } from '../ability/type';
import { exit } from "../helper";
import { getCookies } from './Utils';

export interface WebviewStyle {
  x?: number | string;
  y?: number | string;
  backgroundColor?: string;
  visible?: string;
}

export interface WebviewInitData {
  webTag?: string;
  url: string;
  style?: WebviewStyle;
  controller?: WebviewController;
}

interface WebviewNodeData extends WebviewInitData {
  controller: WebviewController;
}

@Builder
function WebBuilder(data: WebviewNodeData) {
  Web({ src: data.url, controller: data.controller as web_webview.WebviewController })
    .width("100%")
    .height("100%")
    .position({
      x: data.style?.x || 0,
      y: data.style?.y || 0
    })
    .backgroundColor(data?.style?.backgroundColor)
    .visibility(data?.style?.visible === 'hidden' ? Visibility.Hidden : Visibility.Visible)
}

const webViewWrap = wrapBuilder<WebviewNodeData[]>(WebBuilder);

interface AddWebviewMethod {
  webTag: string
  controller: WebviewController
}

export class RustWebviewNodeController extends NodeController {
  private rootNode: FrameNode | null = null;
  private webviewList: Map<string, BuilderNode<WebviewNodeData[]>> = new Map();
  private uiContext: UIContext | null = null;

  constructor(uiContext: UIContext) {
    super();
    this.uiContext = uiContext;
  }

  makeNode(uiContext: UIContext): FrameNode {
    if(this.rootNode === null) {
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

    if(this.rootNode === null) {
      this.rootNode = new FrameNode(this.uiContext!)
    }

    const node: BuilderNode<WebviewNodeData[]> = new BuilderNode(this.uiContext!);
    node.build(webViewWrap, data);
    this.webviewList.set(data.webTag, node);

    this.rootNode?.appendChild(node.getFrameNode());
    return {
      webTag: data.webTag,
      controller: data.controller
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
      const init: WebviewInitData =
        { webTag: data?.id, url: data?.url || '', style: (data.style || {}) as WebviewStyle } as WebviewInitData;
      const ret = this.webviewController.addWebview(init)

      const ctrl = ret.controller;

      // set getCookies method
      ctrl.getCookies = getCookies;
      ctrl.setBackgroundColor = (color: string) => {
        init.style!.backgroundColor = color;
        const node = this.webviewController.getWebviewNode(ret.webTag);
        node?.update(init)
      }

      ctrl.setVisible = (visible: boolean) => {
        init.style!.visible = visible ? 'visible' : 'hidden';
        const node = this.webviewController.getWebviewNode(ret.webTag);
        node?.update(init)
      }
      // Return controller and use controller to control webview behavior
      return ctrl
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

