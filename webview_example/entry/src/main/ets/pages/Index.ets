import { DefaultXComponent } from "@ohos-rs/ability";
import { handleChange, setBackgroundColor, setVisible } from "libwebview_example.so";

@Entry
@Component
struct Index {
  @State message: string = "Hello World";
  @State visible: boolean = true;

  build() {
    Row() {
      Column() {
        Row() {
          Button("add baidu webview")
            .onClick(() => {
              handleChange();
            })
          Button("changeData")
            .onClick(() => {
              setBackgroundColor("red");
            })
          Button("changeVisible")
            .onClick(() => {
              setVisible(!this.visible);
              this.visible = !this.visible;
            })
        }
        DefaultXComponent()
      }.width("100%")
    }.height("100%");
  }
}
