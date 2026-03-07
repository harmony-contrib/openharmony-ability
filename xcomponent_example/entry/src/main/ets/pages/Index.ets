import { DefaultXComponent } from "@ohos-rs/ability";
import {
  demoRequestPermissionFromMainThread,
  toggleBackPressIntercept,
} from "libxcomponent_example.so";

const MODULE_NAME = "xcomponent_example";

@Entry
@Component
struct Index {
  @State interceptEnabled: boolean = true;

  async handleClick() {
    const re: number[] = await demoRequestPermissionFromMainThread();
    console.log(`${re}`);
  }

  handleToggleBackIntercept() {
    this.interceptEnabled = toggleBackPressIntercept();
    console.log(`backPressIntercept=${this.interceptEnabled}`);
  }

  build() {
    Row() {
      Column() {
        Button("request permission demo")
          .onClick(() => this.handleClick())
        Button(this.interceptEnabled ? "back intercept: ON" : "back intercept: OFF")
          .onClick(() => this.handleToggleBackIntercept())
        Text("Swipe back to test intercept behavior.")
        DefaultXComponent({ moduleName: MODULE_NAME })
      }.width("100%")
    }.height("100%");
  }
}
