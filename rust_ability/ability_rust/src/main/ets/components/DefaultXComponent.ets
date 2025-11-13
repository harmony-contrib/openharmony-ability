import { NodeContent } from '@kit.ArkUI';
import { ArkHelper, WebViewInitData as NativeWebViewInitData } from '../ability/type';
import { exit } from "../helper";
import { RustWebviewNodeController, WebviewStyle, WebviewInitData } from '../webview/DefaultWebview';

export const RouteName = 'RustAbility';

@Component
export struct DefaultXComponent {
  private rootSlot = new NodeContent();
  private webviewController = new RustWebviewNodeController(this.getUIContext());
  private nativeModule: ESObject;
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
          initializationScripts: initScripts,
          onDragAndDrop: data?.onDragAndDrop,
          onDownloadStart: data?.onDownloadStart,
          onDownloadEnd: data?.onDownloadEnd,
          onNavigationRequest: data?.onNavigationRequest,
          onTitleChange: data?.onTitleChange
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

  async aboutToAppear(): Promise<void> {
    const moduleName = `lib${this.name}.so`;
    const module: ESObject = await import(moduleName);
    this.nativeModule = module.default;

    module.default.render(this.helper, this.rootSlot);
  }

  build() {
    Stack(){
      ContentSlot(this.rootSlot)
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
}
