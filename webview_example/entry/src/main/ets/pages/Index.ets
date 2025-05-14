import { hilog } from '@kit.PerformanceAnalysisKit';
import { RustWebviewNodeController, WebviewInitData } from '@ohos-rs/ability';

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
            const data: WebviewInitData = { url: 'https://www.baidu.com' };
            this.webviewController.addWebview(data)
          })

          Button("add bing webview").onClick(() => {
            const data: WebviewInitData = {
              url: 'https://www.bing.com', style: {
                x: 100,
                y: 100
              }
            };
            this.webviewController.addWebview(data)
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
