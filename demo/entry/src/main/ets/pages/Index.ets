import { LengthMetrics } from "@ohos.arkui.node";
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
  demoOpenUrl,
  demoFileDialogOpen,
  demoFileDialogSave,
  demoResourceManagerReady,
  demoResourceRawDirCount,
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
  @State urlResult: string = "not called";
  @State fileDialogResult: string = "not called";
  @State resourceManagerResult: string = "not inspected";
  @State resourceRawDirResult: string = "not inspected";

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

  async handleOpenUrl() {
    this.urlResult = "opening…";
    try {
      await demoOpenUrl();
      this.urlResult = "opened via ohos.url / context.openLink";
    } catch (error) {
      this.urlResult = `open failed: ${String(error)}`;
    }
  }

  async handleFileDialogOpen() {
    this.fileDialogResult = "picking…";
    try {
      const files = await demoFileDialogOpen();
      this.fileDialogResult =
        files.length > 0 ? `selected ${files.length}: ${files[0]}` : "cancelled";
    } catch (error) {
      this.fileDialogResult = `open dialog failed: ${String(error)}`;
    }
  }

  async handleFileDialogSave() {
    this.fileDialogResult = "picking…";
    try {
      const files = await demoFileDialogSave();
      this.fileDialogResult = files.length > 0 ? `saved to ${files[0]}` : "cancelled";
    } catch (error) {
      this.fileDialogResult = `save dialog failed: ${String(error)}`;
    }
  }

  handleResourceManagerReady() {
    this.resourceManagerResult = demoResourceManagerReady()
      ? "installed: wrapper pushed resourceManager on ability-create"
      : "NOT installed yet (plugin missing or push failed)";
  }

  handleResourceRawDir() {
    const count = demoResourceRawDirCount();
    this.resourceRawDirResult =
      count >= 0 ? `raw dir entries: ${count}` : "not installed yet (returned -1)";
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
    Scroll() {
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
        DefaultXComponent({ moduleName: MODULE_NAME })
          .width("100%")
          .height(280)
      }
      .width("100%")
      .padding(8)
    }
    .width("100%")
    .height("100%")
    .scrollable(ScrollDirection.Vertical);
  }

  @Builder
  WebviewDemo() {
    Column({ space: 12 }) {
      Flex({
        wrap: FlexWrap.Wrap,
        space: { main: LengthMetrics.vp(12), cross: LengthMetrics.vp(8) },
      }) {
        Button("create webview")
          .onClick(() => this.handleCreateWebview())
        Button("background red")
          .onClick(() => this.handleWebviewBackground())
        Button("run JavaScript")
          .onClick(() => this.handleWebviewScript())
        Button(this.webviewVisible ? "hide webview" : "show webview")
          .onClick(() => this.handleToggleWebviewVisible())
      }.width("100%")
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

  @Builder
  PlatformServicesDemo() {
    Scroll() {
      Column({ space: 12 }) {
        Text("PR #65 native platform services (ohos.url / ohos.files)")
          .fontSize(14)
          .fontColor("#333")
        Button("open external URL (ohos.url)")
          .onClick(() => this.handleOpenUrl())
        Text(this.urlResult)
        Button("open file dialog: multi-select + filters (ohos.files)")
          .onClick(() => this.handleFileDialogOpen())
        Button("save file dialog: PDF filter (ohos.files)")
          .onClick(() => this.handleFileDialogSave())
        Text(this.fileDialogResult)
        Text(
          "File dialog params are structured named N-API values; filter strings are converted only inside the plugin.",
        )
          .fontSize(12)
          .fontColor("#888")
      }
      .width("100%")
      .padding(8)
    }
    .width("100%")
    .height("100%")
    .scrollable(ScrollDirection.Vertical);
  }

  @Builder
  ResourceDemo() {
    Scroll() {
      Column({ space: 12 }) {
        Text("ohos.resource plugin (ArkTS wrapper -> native pointer)")
          .fontSize(14)
          .fontColor("#333")
        Button("check resource manager installed")
          .onClick(() => this.handleResourceManagerReady())
        Text(this.resourceManagerResult)
        Button("count raw file dir entries")
          .onClick(() => this.handleResourceRawDir())
        Text(this.resourceRawDirResult)
        Text(
          "The wrapper pushes resourceManager on ability-create; reads run through ohos-resource-manager-binding (C API), no ArkTS round-trip.",
        )
          .fontSize(12)
          .fontColor("#888")
      }
      .width("100%")
      .padding(8)
    }
    .width("100%")
    .height("100%")
    .scrollable(ScrollDirection.Vertical);
  }

  build() {
    Column({ space: 16 }) {
      Flex({
        wrap: FlexWrap.Wrap,
        space: { main: LengthMetrics.vp(12), cross: LengthMetrics.vp(8) },
      }) {
        this.DemoSwitcher("XComponent demo", 0)
        this.DemoSwitcher("WebView + slot demo", 1)
        this.DemoSwitcher("Platform services demo", 2)
        this.DemoSwitcher("Resource demo", 3)
      }.width("100%")
      if (this.currentDemo === 0) {
        this.XComponentDemo();
      }
      if (this.currentDemo === 1) {
        this.WebviewDemo();
      }
      if (this.currentDemo === 2) {
        this.PlatformServicesDemo();
      }
      if (this.currentDemo === 3) {
        this.ResourceDemo();
      }
    }
    .width("100%")
    .height("100%")
    .padding(16);
  }
}
