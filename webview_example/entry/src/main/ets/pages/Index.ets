import { hilog } from '@kit.PerformanceAnalysisKit';
import { DefaultWebViewComponent } from '@ohos-rs/ability';
import { handleChange } from "libexample.so"

const DOMAIN = 0x0000;

@Entry
@Component
struct Index {
  @State message: string = 'Hello World';

  build() {
    Row() {
      Column() {
        Row() {
          Button("add baidu webview").onClick(() => {
            handleChange();
          })
        }
        DefaultWebViewComponent()
      }
      .width('100%')
    }
    .height('100%')
  }
}
