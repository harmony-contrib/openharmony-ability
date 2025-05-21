import { hilog } from '@kit.PerformanceAnalysisKit';
import { RustWebviewNodeController, WebviewInitData } from '@ohos-rs/ability';
import {init} from "libark_web.so"

const DOMAIN = 0x0000;

@Entry
@Component
struct Index {
  @State message: string = 'Hello World';
  private webviewController = new RustWebviewNodeController(this.getUIContext());

  build() {
    Row() {
      Column() {
        Row() {
          Button("add baidu webview").onClick(() => {
            init(() => {
              const data: WebviewInitData = { url: 'https://www.baidu.com' };
              return this.webviewController.addWebview(data)
            })
          })

        }

        NodeContainer(this.webviewController)
          .height("100%")
          .width("100%")
      }
      .width('100%')
    }
    .height('100%')
  }
}
