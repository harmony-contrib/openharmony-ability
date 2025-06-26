import { hilog } from '@kit.PerformanceAnalysisKit';
import { DefaultWebViewComponent } from '@ohos-rs/ability';
import { handleChange, setBackgroundColor, setVisible } from "libwebview_example.so"

const DOMAIN = 0x0000;

@Entry
@Component
struct Index {
  @State message: string = 'Hello World';
  @State visible: boolean = true

  build() {
    Row() {
      Column() {
        Row() {
          Button("add baidu webview").onClick(() => {
            handleChange();
          })
          Button('changeData').onClick(() => {
            setBackgroundColor("red")
          })
          Button('changeVisible').onClick(() => {
            setVisible(!this.visible)
            this.visible = !this.visible;
          })
        }
        DefaultWebViewComponent()
      }
      .width('100%')
    }
    .height('100%')
  }
}
