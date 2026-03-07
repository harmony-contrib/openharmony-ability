import { DefaultXComponent } from "@ohos-rs/ability";
import {
  demoRequestPermissionFromMainThread,
  handleChange,
  setBackgroundColor,
  setVisible,
  toggleBackPressIntercept,
} from "libdemo_native.so";

const MODULE_NAME = "demo_native";

@Entry
@Component
struct Index {
  @State currentDemo: number = 0;
  @State interceptEnabled: boolean = true;
  @State webviewVisible: boolean = true;

  async handlePermissionDemo() {
    const result: number[] = await demoRequestPermissionFromMainThread();
    console.log(`permission result: ${result}`);
  }

  handleToggleBackIntercept() {
    this.interceptEnabled = toggleBackPressIntercept();
    console.log(`backPressIntercept=${this.interceptEnabled}`);
  }

  handleToggleWebviewVisible() {
    const nextVisible = !this.webviewVisible;
    setVisible(nextVisible);
    this.webviewVisible = nextVisible;
  }

  @Builder
  DemoSwitcher(label: string, index: number) {
    Button(label)
      .type(this.currentDemo === index ? ButtonType.Capsule : ButtonType.Normal)
      .onClick(() => {
        this.currentDemo = index;
      })
  }

  @Builder
  XComponentDemo() {
    Column({ space: 12 }) {
      Button("request permission demo")
        .onClick(() => this.handlePermissionDemo())
      Button(this.interceptEnabled ? "back intercept: ON" : "back intercept: OFF")
        .onClick(() => this.handleToggleBackIntercept())
      Text("Swipe back to test intercept behavior.")
      DefaultXComponent({ moduleName: MODULE_NAME })
    }
    .width("100%")
    .height("100%")
  }

  @Builder
  WebviewDemo() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button("create webview")
          .onClick(() => {
            handleChange();
          })
        Button("background red")
          .onClick(() => {
            setBackgroundColor("red");
          })
        Button(this.webviewVisible ? "hide webview" : "show webview")
          .onClick(() => this.handleToggleWebviewVisible())
      }
      DefaultXComponent({ moduleName: MODULE_NAME })
    }
    .width("100%")
    .height("100%")
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        this.DemoSwitcher("XComponent demo", 0)
        this.DemoSwitcher("WebView demo", 1)
      }
      .width("100%")

      If (this.currentDemo === 0) {
        this.XComponentDemo()
      } else {
        this.WebviewDemo()
      }
    }
    .width("100%")
    .height("100%")
    .padding(16)
  }
}
