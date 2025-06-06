import { UIContext } from '@ohos.arkui.UIContext';
import web_webview from '@ohos.web.webview'
import { NodeController, BuilderNode, FrameNode } from '@ohos.arkui.node';
import { randomString } from '../helper';
import { common } from '@kit.AbilityKit';
import { ArkHelper, WebViewComponentEventCallback, WebViewInitData as NativeWebViewInitData } from '../ability/type';
import { exit } from "../helper";

export interface WebviewStyle {
  x?: number | string;
  y?: number | string;
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
  Web({ src: data.url, controller: data.controller })
    .width("100%")
    .height("100%")
    .position({
      x: data.style?.x || 0,
      y: data.style?.y || 0
    })
}

const webViewWrap = wrapBuilder<WebviewNodeData[]>(WebBuilder);

export class RustWebviewNodeController extends NodeController {
  private rootNode: FrameNode | null = null;
  private webviewList: Array<BuilderNode<WebviewNodeData[]>> = [];
  private uiContext: UIContext | null = null;

  constructor(uiContext: UIContext) {
    super();
    this.uiContext = uiContext;
  }

  makeNode(uiContext: UIContext): FrameNode {
    this.rootNode = new FrameNode(uiContext);
    return this.rootNode
  }

  addWebview(data: WebviewInitData) {
    const webTag: string = data?.webTag || randomString();

    const node: BuilderNode<WebviewNodeData[]> = new BuilderNode(this.uiContext!);
    node.build(webViewWrap,
      { url: data.url, controller: data?.controller || new web_webview.WebviewController(webTag), style: data?.style });
    this.webviewList.push(node);

    this.rootNode?.appendChild(node.getFrameNode());
    return webTag;
  }
}


@Component
export struct DefaultWebViewComponent {
  private uiContext = getContext(this) as common.UIAbilityContext;
  private nativeModule: ESObject;
  private webviewController = new RustWebviewNodeController(this.getUIContext());
  @StorageProp("moduleName") name: string = "";
  private lifecycleCallback: WebViewComponentEventCallback | null = null;

  async aboutToAppear(): Promise<void> {
    const moduleName = `lib${this.name}.so`;
    const module: ESObject = await import(moduleName);
    this.nativeModule = module.default;

    const helper: ArkHelper = {
      exit,
      createWebview: (err, data: NativeWebViewInitData) => {
        const init: WebviewInitData = { url: data.url, style: data.style as WebviewStyle } as WebviewInitData;
        const id = this.webviewController.addWebview(init)
        return id
      }
    }
    const ret: WebViewComponentEventCallback = module.default.webviewRender(helper);
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

