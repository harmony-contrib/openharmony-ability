import { NodeContent } from "@kit.ArkUI";
import {
  ArkHelper,
  WebViewInitData as NativeWebViewInitData,
  WindowAvoidAreaInfo,
} from "../ability/type";
import { exit } from "../helper";
import { Loadable } from "../helper/loadable";
import { requestPermission } from "../helper/permission";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import {
  RustWebviewNodeController,
  WebviewStyle,
  WebviewInitData,
} from "../webview/DefaultWebview";

export const RouteName = "RustAbility";
@Component
export struct DefaultXComponent {
  moduleName: string = "";
  private rootSlot = new NodeContent();
  private webviewController = new RustWebviewNodeController(this.getUIContext());
  private nativeModule: ESObject;
  private helper: ArkHelper = {
    exit,
    requestPermission: async (permission: string | string[]): Promise<number | number[]> => {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return await requestPermission(context, permission);
    },
    getWindowAvoidArea: (type: number): WindowAvoidAreaInfo | undefined => {
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const win = context.windowStage.getMainWindowSync();
        const avoidType = type as window.AvoidAreaType;
        return {
          type: avoidType,
          area: win.getWindowAvoidArea(avoidType),
        } as WindowAvoidAreaInfo;
      } catch (_) {
        return undefined;
      }
    },
    createWebview: (data: NativeWebViewInitData) => {
      const initScripts: ScriptItem[] = (data?.initializationScripts || []).map((i) => {
        return {
          script: i,
          scriptRules: ["*"],
        } as ScriptItem;
      });
      const init: WebviewInitData = {
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
        onTitleChange: data?.onTitleChange,
      } as WebviewInitData;

      if (data?.transparent && !init.style?.backgroundColor) {
        init.style!.backgroundColor = Color.Transparent;
      }
      const ret = this.webviewController.addWebview(init);

      ret.controller.setBackgroundColor = (color: string) => {
        init.style!.backgroundColor = color;
        const node = this.webviewController.getWebviewNode(ret.webTag);
        node?.update(init);
      };

      ret.controller.setVisible = (visible: boolean) => {
        init.style!.visible = visible ? "visible" : "hidden";
        const node = this.webviewController.getWebviewNode(ret.webTag);
        node?.update(init);
      };

      return ret.controller;
    },
  };
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";

  async aboutToAppear(): Promise<void> {
    const moduleName = this.moduleName.trim();
    if (!moduleName) {
      throw new Error("DefaultXComponent.moduleName is required");
    }
    this.nativeModule = await Loadable.load(moduleName, this.loadMode);
    this.nativeModule.render(this.helper, this.rootSlot);
  }

  build() {
    Stack() {
      ContentSlot(this.rootSlot)
      Row() {
        Column() {
          NodeContainer(this.webviewController)
            .height("100%")
            .width("100%")
        }.width("100%")
      }
      .height("100%")
      .hitTestBehavior(HitTestMode.Transparent)
    };
  }
}
