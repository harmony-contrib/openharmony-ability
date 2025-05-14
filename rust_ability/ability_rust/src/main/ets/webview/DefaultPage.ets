import { RustWebviewNodeController } from "./DefaultWebview";

export const RouteName = 'RustWebViewAbility';

@Entry({ routeName: RouteName })
@Component
struct Index {
  private webviewController = new RustWebviewNodeController(this.getUIContext());

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

