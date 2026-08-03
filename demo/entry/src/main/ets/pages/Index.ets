import {
  BridgeNodeHost,
  DefaultXComponent,
  invokeNativeBackPressInterceptor,
} from "@ohos-rs/ability";
import {
  createDemoWebview,
  demoRequestPermissionFromMainThread,
  evaluateDemoWebviewScript,
  demoPluginLogin,
  demoPluginBytes,
  demoPluginProfile,
  demoPluginSyncContext,
  demoPluginString,
  setBackgroundColor,
  setVisible,
  toggleBackPressIntercept,
} from "libdemo_native.so";

const MODULE_NAME = "demo_native";
const WEBVIEW_SLOT = "webview-panel";

@Entry
@Component
struct Index {
  @State currentDemo: number = 0;
  @State interceptEnabled: boolean = true;
  @State webviewVisible: boolean = true;
  @State loginResult: string = "not signed in";
  @State rawPayloadResult: string = "not called";
  @State profileResult: string = "not called";
  @State mainThreadResult: string = "not inspected";
  @State webviewResult: string = "WebView not created";
  @State webviewScriptResult: string = "JavaScript not called";

  async handlePermissionDemo() {
    const result: number[] = await demoRequestPermissionFromMainThread();
    console.log(`permission result: ${result}`);
  }

  async handlePluginLogin() {
    this.loginResult = "signing in on a Rust worker…";
    try {
      this.loginResult = await demoPluginLogin();
    } catch (error) {
      this.loginResult = `login failed: ${String(error)}`;
    }
  }

  handleSyncPluginContext() {
    try {
      this.mainThreadResult = demoPluginSyncContext();
    } catch (error) {
      this.mainThreadResult = `sync plugin failed: ${String(error)}`;
    }
  }

  async handleRawPayloadDemo() {
    try {
      const text = await demoPluginString();
      const bytes = await demoPluginBytes();
      this.rawPayloadResult = `${text}; bytes=${bytes.join(",")}`;
    } catch (error) {
      this.rawPayloadResult = `raw payload failed: ${String(error)}`;
    }
  }

  async handleProfileDemo() {
    try {
      const profile = await demoPluginProfile();
      this.profileResult = `${profile.userId}: visits=${profile.visitCount}`;
    } catch (error) {
      this.profileResult = `named type failed: ${String(error)}`;
    }
  }

  handleToggleBackIntercept() {
    this.interceptEnabled = toggleBackPressIntercept();
    console.log(`backPressIntercept=${this.interceptEnabled}`);
  }

  onBackPress(): boolean {
    const intercepted = invokeNativeBackPressInterceptor(MODULE_NAME);
    console.log(`native back press intercepted=${intercepted}`);
    return intercepted;
  }

  async handleCreateWebview() {
    try {
      await createDemoWebview();
      this.webviewResult = "WebView mounted in business slot";
    } catch (error) {
      this.webviewResult = `create failed: ${String(error)}`;
    }
  }

  async handleToggleWebviewVisible() {
    const nextVisible = !this.webviewVisible;
    try {
      await setVisible(nextVisible);
      this.webviewVisible = nextVisible;
    } catch (error) {
      this.webviewResult = `visibility failed: ${String(error)}`;
    }
  }

  async handleWebviewBackground() {
    try {
      await setBackgroundColor("#ffdddd");
    } catch (error) {
      this.webviewResult = `style failed: ${String(error)}`;
    }
  }

  async handleWebviewScript() {
    try {
      this.webviewScriptResult = await evaluateDemoWebviewScript();
    } catch (error) {
      this.webviewScriptResult = `JavaScript failed: ${String(error)}`;
    }
  }

  @Builder
  DemoSwitcher(label: string, index: number) {
    Button(label)
      .type(this.currentDemo === index ? ButtonType.Capsule : ButtonType.Normal)
      .onClick(() => {
        this.currentDemo = index;
      });
  }

  @Builder
  WebviewUnderlay() {
    Column() {
      Text("This is business-owned content below the plugin node slot.")
        .fontSize(14)
        .fontColor("#666")
    }
    .width("100%")
    .height("100%")
    .justifyContent(FlexAlign.Center);
  }

  @Builder
  WebviewOverlay() {
    Row() {
      Text("Business overlay — the WebView plugin owns only its FrameNode")
        .fontSize(12)
        .fontColor("#ffffff")
    }
    .padding(8)
    .backgroundColor("#66000000")
    .alignSelf(ItemAlign.Start);
  }

  @Builder
  XComponentDemo() {
    Column({ space: 12 }) {
      Button("request permission demo")
        .onClick(() => this.handlePermissionDemo())
      Button("async bridge login demo")
        .onClick(() => this.handlePluginLogin())
      Text(this.loginResult)
      Button("sync main-thread plugin demo")
        .onClick(() => this.handleSyncPluginContext())
      Text(this.mainThreadResult)
      Button("String + Uint8Array typed plugin demo")
        .onClick(() => this.handleRawPayloadDemo())
      Text(this.rawPayloadResult)
      Button("named #[napi(object)] type demo")
        .onClick(() => this.handleProfileDemo())
      Text(this.profileResult)
      Button(this.interceptEnabled ? "back intercept: ON" : "back intercept: OFF")
        .onClick(() => this.handleToggleBackIntercept())
      Text("Swipe back to test intercept behavior.")
      DefaultXComponent({ moduleName: MODULE_NAME }).layoutWeight(1)
    }
    .width("100%")
    .height("100%");
  }

  @Builder
  WebviewDemo() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button("create webview")
          .onClick(() => this.handleCreateWebview())
        Button("background red")
          .onClick(() => this.handleWebviewBackground())
        Button("run JavaScript")
          .onClick(() => this.handleWebviewScript())
        Button(this.webviewVisible ? "hide webview" : "show webview")
          .onClick(() => this.handleToggleWebviewVisible())
      }
      Text(this.webviewResult)
      Text(`document.title: ${this.webviewScriptResult}`)
      Stack() {
        DefaultXComponent({ moduleName: MODULE_NAME })
        BridgeNodeHost({
          moduleName: MODULE_NAME,
          slotId: WEBVIEW_SLOT,
          underlay: this.WebviewUnderlay,
          foreground: this.WebviewOverlay,
        })
      }
      .layoutWeight(1)
      .width("100%")
    }
    .width("100%")
    .height("100%");
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        this.DemoSwitcher("XComponent demo", 0)
        this.DemoSwitcher("WebView + slot demo", 1)
      }.width("100%")
      if (this.currentDemo === 0) {
        this.XComponentDemo();
      }
      if (this.currentDemo !== 0) {
        this.WebviewDemo();
      }
    }
    .width("100%")
    .height("100%")
    .padding(16);
  }
}
