import { DefaultXComponent, invokeNativeBackPressInterceptor } from "@ohos-rs/ability";
import { MenuBarComponent, MenuPopupComponent } from "@ohos-rs/ability-plugin-menu";
import { demoWindowStage, SUB_WINDOW_NATIVE_MODULE } from "../entryability/EntryAbility";
import { SUB_WINDOW_NAME } from "./SubWindowPage";
import {
  createBottomDemoWebview,
  createComposedDemoWebview,
  createDemoWebview,
  demoAutostartIsEnabled,
  demoAutostartOpenSettings,
  demoClipboardWriteImage,
  demoCreateOsWindow,
  demoDestroyOsWindow,
  demoMenuPopup,
  demoMenuSetMenubar,
  demoRequestPermissionFromMainThread,
  demoRestart,
  demoSetColorMode,
  demoStatusbarAdd,
  demoStatusbarRemove,
  demoUpdaterCheck,
  demoVersionInfo,
  evaluateDemoWebviewScript,
  demoPluginLogin,
  demoPluginBytes,
  demoPluginProfile,
  demoPluginSyncContext,
  demoPluginSyncFromWorker,
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
import { DemoButton, DemoCard } from "../components/DemoCard";

const MODULE_NAME = "demo_native";

@Entry
@Component
struct Index {
  @State currentDemo: number = 0;
  @State busyKey: string = "";
  @State interceptEnabled: boolean = true;
  @State webviewVisible: boolean = true;
  @State permissionResult: string = "";
  @State loginResult: string = "";
  @State mainThreadResult: string = "";
  @State syncFromWorkerResult: string = "";
  @State rawPayloadResult: string = "";
  @State profileResult: string = "";
  @State interceptResult: string = "";
  @State webviewStatus: string = "";
  @State urlResult: string = "";
  @State fileDialogResult: string = "";
  @State clipboardResult: string = "";
  @State updaterResult: string = "";
  @State menuResult: string = "";
  @State statusbarResult: string = "";
  @State versionResult: string = "";
  @State windowResult: string = "";
  @State appControlResult: string = "";
  @State autostartResult: string = "";
  @State resourceStatus: string = "";
  private osWindowId: number = -1;

  private tabs: string[] = ["XComponent", "WebView", "Platform", "Resource"];

  // ---------- status helpers ----------

  statusTextOf(key: string, result: string): string {
    if (this.busyKey === key) {
      return "running…";
    }
    if (result === "") {
      return "not run yet";
    }
    return result;
  }

  statusColorOf(key: string, result: string): ResourceColor {
    if (this.busyKey === key) {
      return $r("app.color.status_running");
    }
    if (result === "") {
      return $r("app.color.status_idle");
    }
    if (result.startsWith("✗")) {
      return $r("app.color.status_error");
    }
    return $r("app.color.status_success");
  }

  // ---------- handlers ----------

  async handlePermissionDemo() {
    this.busyKey = "permission";
    this.permissionResult = "";
    try {
      const result: number[] = await demoRequestPermissionFromMainThread();
      this.permissionResult =
        result.length === 0 ? "✓ already requested" : `✓ result codes=${result.join(",")}`;
    } catch (error) {
      this.permissionResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handlePluginLogin() {
    this.busyKey = "login";
    this.loginResult = "";
    try {
      this.loginResult = `✓ ${await demoPluginLogin()}`;
    } catch (error) {
      this.loginResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  handleSyncPluginContext() {
    this.busyKey = "sync-main";
    this.mainThreadResult = "";
    try {
      this.mainThreadResult = `✓ ${demoPluginSyncContext()}`;
    } catch (error) {
      this.mainThreadResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleSyncPluginFromWorker() {
    this.busyKey = "sync-worker";
    this.syncFromWorkerResult = "";
    try {
      this.syncFromWorkerResult = `✓ ${await demoPluginSyncFromWorker()}`;
    } catch (error) {
      this.syncFromWorkerResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleRawPayloadDemo() {
    this.busyKey = "raw";
    this.rawPayloadResult = "";
    try {
      const text = await demoPluginString();
      const bytes = await demoPluginBytes();
      this.rawPayloadResult = `✓ ${text}; bytes=${bytes.join(",")}`;
    } catch (error) {
      this.rawPayloadResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleProfileDemo() {
    this.busyKey = "profile";
    this.profileResult = "";
    try {
      const profile = await demoPluginProfile();
      this.profileResult = `✓ ${profile.userId}: visits=${profile.visitCount}`;
    } catch (error) {
      this.profileResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  handleToggleBackIntercept() {
    this.interceptEnabled = toggleBackPressIntercept();
    this.interceptResult = this.interceptEnabled ? "✓ intercept is ON" : "✓ intercept is OFF";
  }

  async handleCreateWebview() {
    this.busyKey = "webview";
    this.webviewStatus = "";
    try {
      await createDemoWebview();
      this.webviewStatus = "✓ WebView mounted into demo_native's component root";
    } catch (error) {
      this.webviewStatus = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleCreateComposedWebview() {
    this.busyKey = "webview";
    this.webviewStatus = "";
    try {
      await createComposedDemoWebview();
      this.webviewStatus = "✓ WebView mounted under an ohos.node container tree";
    } catch (error) {
      this.webviewStatus = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleCreateBottomWebview() {
    this.busyKey = "webview";
    this.webviewStatus = "";
    try {
      await createBottomDemoWebview();
      this.webviewStatus = "✓ WebView pinned to the bottom edge (y=70%, height=30%)";
    } catch (error) {
      this.webviewStatus = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleOpenSubWindow() {
    this.busyKey = "webview";
    this.webviewStatus = "";
    try {
      const stage = demoWindowStage;
      if (stage === null) {
        throw new Error("WindowStage is not ready");
      }
      const subWindow = await stage.createSubWindow(SUB_WINDOW_NAME);
      // Size the sub window against the main window and park it on the right side, so it is
      // large enough to use and does not cover the demo controls on the left.
      const mainWindow = stage.getMainWindowSync();
      const mainRect = mainWindow.getWindowProperties().windowRect;
      const width = Math.min(760, Math.floor(mainRect.width * 0.7));
      const height = Math.min(1100, Math.floor(mainRect.height * 0.85));
      await subWindow.resize(width, height);
      await subWindow.moveWindowTo(
        mainRect.width - width - 16,
        Math.max(24, Math.floor((mainRect.height - height) / 2)),
      );
      await subWindow.setUIContent("pages/SubWindowPage");
      await subWindow.showWindow();
      this.webviewStatus = `✓ sub window opened: its DefaultXComponent owns module '${SUB_WINDOW_NATIVE_MODULE}'`;
    } catch (error) {
      this.webviewStatus = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleToggleWebviewVisible() {
    this.busyKey = "webview";
    const nextVisible = !this.webviewVisible;
    try {
      await setVisible(nextVisible);
      this.webviewVisible = nextVisible;
      this.webviewStatus = `✓ visibility=${nextVisible}`;
    } catch (error) {
      this.webviewStatus = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleWebviewBackground() {
    this.busyKey = "webview";
    this.webviewStatus = "";
    try {
      await setBackgroundColor("#ffdddd");
      this.webviewStatus = "✓ background set to #ffdddd";
    } catch (error) {
      this.webviewStatus = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleWebviewScript() {
    this.busyKey = "webview";
    this.webviewStatus = "";
    try {
      const title = await evaluateDemoWebviewScript();
      this.webviewStatus = `✓ document.title = ${title}`;
    } catch (error) {
      this.webviewStatus = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleOpenUrl() {
    this.busyKey = "url";
    this.urlResult = "";
    try {
      await demoOpenUrl();
      this.urlResult = "✓ opened via ohos.url / context.openLink";
    } catch (error) {
      this.urlResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleFileDialogOpen() {
    this.busyKey = "files";
    this.fileDialogResult = "";
    try {
      const files = await demoFileDialogOpen();
      this.fileDialogResult =
        files.length > 0 ? `✓ selected ${files.length}: ${files[0]}` : "✓ cancelled";
    } catch (error) {
      this.fileDialogResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleFileDialogSave() {
    this.busyKey = "files";
    this.fileDialogResult = "";
    try {
      const files = await demoFileDialogSave();
      this.fileDialogResult = files.length > 0 ? `✓ saved to ${files[0]}` : "✓ cancelled";
    } catch (error) {
      this.fileDialogResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleClipboardWrite() {
    this.busyKey = "clipboard";
    this.clipboardResult = "";
    try {
      await demoClipboardWriteImage();
      this.clipboardResult = "✓ wrote a 2×2 RGBA PixelMap to the system clipboard";
    } catch (error) {
      this.clipboardResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleAutostartStatus() {
    this.busyKey = "autostart";
    this.autostartResult = "";
    try {
      const enabled = await demoAutostartIsEnabled();
      this.autostartResult = `✓ autostart enabled=${enabled}`;
    } catch (error) {
      this.autostartResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleAutostartSettings() {
    this.busyKey = "autostart";
    this.autostartResult = "";
    try {
      await demoAutostartOpenSettings();
      this.autostartResult = "✓ opened app-launch management settings";
    } catch (error) {
      this.autostartResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleUpdaterCheck() {
    this.busyKey = "updater";
    this.updaterResult = "";
    try {
      const update: string | null = await demoUpdaterCheck();
      this.updaterResult = update === null ? "✓ no later version" : `✓ ${update}`;
    } catch (error) {
      this.updaterResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleMenuSet() {
    this.busyKey = "menu";
    this.menuResult = "";
    try {
      await demoMenuSetMenubar();
      this.menuResult = "✓ menubar published for business windowId=main";
    } catch (error) {
      this.menuResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleMenuPopup() {
    this.busyKey = "menu";
    this.menuResult = "";
    try {
      await demoMenuPopup(24, 180);
      this.menuResult = "✓ popup published at (24, 180)";
    } catch (error) {
      this.menuResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleStatusbarAdd() {
    this.busyKey = "statusbar";
    this.statusbarResult = "";
    try {
      await demoStatusbarAdd();
      this.statusbarResult = "✓ process status bar owner claimed by this plugin instance";
    } catch (error) {
      this.statusbarResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleStatusbarRemove() {
    this.busyKey = "statusbar";
    this.statusbarResult = "";
    try {
      await demoStatusbarRemove();
      this.statusbarResult = "✓ status bar item removed";
    } catch (error) {
      this.statusbarResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  handleVersionInfo() {
    this.busyKey = "version";
    this.versionResult = "";
    try {
      this.versionResult = `✓ ${demoVersionInfo()}`;
    } catch (error) {
      this.versionResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleCreateOsWindow() {
    this.busyKey = "window";
    this.windowResult = "";
    try {
      this.osWindowId = await demoCreateOsWindow();
      this.windowResult = `✓ created platform window id=${this.osWindowId}`;
    } catch (error) {
      this.windowResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  async handleDestroyOsWindow() {
    this.busyKey = "window";
    this.windowResult = "";
    try {
      if (this.osWindowId < 0) {
        throw new Error("create a platform window first");
      }
      await demoDestroyOsWindow(this.osWindowId);
      this.windowResult = `✓ destroyed platform window id=${this.osWindowId}`;
      this.osWindowId = -1;
    } catch (error) {
      this.windowResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  handleSetColorMode(mode: number) {
    this.busyKey = "app-control";
    this.appControlResult = "";
    try {
      demoSetColorMode(mode);
      this.appControlResult = `✓ color mode=${mode}`;
    } catch (error) {
      this.appControlResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  handleRestart() {
    this.busyKey = "app-control";
    this.appControlResult = "";
    try {
      demoRestart();
      this.appControlResult = "✓ restart requested";
    } catch (error) {
      this.appControlResult = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  handleResourceManagerReady() {
    this.busyKey = "resource";
    this.resourceStatus = "";
    try {
      this.resourceStatus = demoResourceManagerReady()
        ? "✓ installed: wrapper pushed resourceManager on ability-create"
        : "✗ NOT installed yet (plugin missing or push failed)";
    } catch (error) {
      this.resourceStatus = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  handleResourceRawDir() {
    this.busyKey = "resource";
    this.resourceStatus = "";
    try {
      const count = demoResourceRawDirCount();
      this.resourceStatus =
        count >= 0 ? `✓ raw dir entries: ${count}` : "✗ not installed yet (returned -1)";
    } catch (error) {
      this.resourceStatus = `✗ ${String(error)}`;
    } finally {
      this.busyKey = "";
    }
  }

  // ---------- shared builders ----------

  @Builder
  Header() {
    Column({ space: 6 }) {
      Text("ohos-rs demo")
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r("app.color.text_primary"))
      Row({ space: 8 }) {
        Text("native module")
          .fontSize(12)
          .fontColor($r("app.color.text_hint"))
        Text(MODULE_NAME)
          .fontSize(12)
          .fontColor($r("app.color.accent"))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor($r("app.color.action_bg"))
          .borderRadius(10)
      }
    }
    .width("100%")
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  TabBar() {
    Row({ space: 8 }) {
      ForEach(
        this.tabs,
        (label: string, index: number) => {
          Button(label)
            .type(ButtonType.Normal)
            .layoutWeight(1)
            .height(36)
            .fontSize(14)
            .fontColor(this.currentDemo === index ? Color.White : $r("app.color.text_secondary"))
            .backgroundColor(
              this.currentDemo === index ? $r("app.color.accent") : $r("app.color.tab_bg"),
            )
            .borderRadius(18)
            .onClick(() => {
              this.currentDemo = index;
            });
        },
        (label: string) => label,
      )
    }.width("100%");
  }

  // ---------- tab content builders ----------

  @Builder
  XComponentDemo() {
    Scroll() {
      Column({ space: 12 }) {
        DemoCard({
          title: "Permission",
          hint: "async bridge → ohos.permission plugin",
          statusText: this.statusTextOf("permission", this.permissionResult),
          statusColor: this.statusColorOf("permission", this.permissionResult),
          busy: this.busyKey === "permission",
          buttons: [
            new DemoButton("request microphone permission", (): void => {
              this.handlePermissionDemo();
            }),
          ],
        })
        DemoCard({
          title: "Async login",
          hint: "Rust worker → TSFN → ArkTS Promise → future",
          statusText: this.statusTextOf("login", this.loginResult),
          statusColor: this.statusColorOf("login", this.loginResult),
          busy: this.busyKey === "login",
          buttons: [
            new DemoButton("login", (): void => {
              this.handlePluginLogin();
            }),
          ],
        })
        DemoCard({
          title: "Sync plugin · main thread",
          hint: "with_main_thread_bridge(env, …).call_sync",
          statusText: this.statusTextOf("sync-main", this.mainThreadResult),
          statusColor: this.statusColorOf("sync-main", this.mainThreadResult),
          busy: this.busyKey === "sync-main",
          buttons: [
            new DemoButton("inspect (main thread)", (): void => this.handleSyncPluginContext()),
          ],
        })
        DemoCard({
          title: "Sync plugin · Rust worker",
          hint: "call_sync_from_worker (TSFN), execution on main thread",
          statusText: this.statusTextOf("sync-worker", this.syncFromWorkerResult),
          statusColor: this.statusColorOf("sync-worker", this.syncFromWorkerResult),
          busy: this.busyKey === "sync-worker",
          buttons: [
            new DemoButton("inspect (Rust worker)", (): void => {
              this.handleSyncPluginFromWorker();
            }),
          ],
        })
        DemoCard({
          title: "Typed values · String + bytes",
          hint: "std.string + std.bytes, no JSON",
          statusText: this.statusTextOf("raw", this.rawPayloadResult),
          statusColor: this.statusColorOf("raw", this.rawPayloadResult),
          busy: this.busyKey === "raw",
          buttons: [
            new DemoButton("echo string + reverse bytes", (): void => {
              this.handleRawPayloadDemo();
            }),
          ],
        })
        DemoCard({
          title: "Typed values · named object",
          hint: "demo.Profile via #[napi(object)]",
          statusText: this.statusTextOf("profile", this.profileResult),
          statusColor: this.statusColorOf("profile", this.profileResult),
          busy: this.busyKey === "profile",
          buttons: [
            new DemoButton("bump demo.Profile", (): void => {
              this.handleProfileDemo();
            }),
          ],
        })
        DemoCard({
          title: "Back press intercept",
          hint: "swipe back to test intercept behavior",
          statusText: this.statusTextOf("back-press", this.interceptResult),
          statusColor: this.statusColorOf("back-press", this.interceptResult),
          busy: false,
          buttons: [
            new DemoButton(
              this.interceptEnabled ? "back intercept: ON" : "back intercept: OFF",
              (): void => this.handleToggleBackIntercept(),
            ),
          ],
        })
        DefaultXComponent({ moduleName: MODULE_NAME })
          .width("100%")
          .height(280)
          .borderRadius(12)
      }
      .width("100%")
      .padding({ top: 4, bottom: 16 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .width("100%")
    .height("100%");
  }

  @Builder
  WebviewDemo() {
    Column({ space: 12 }) {
      DemoCard({
        title: "WebView lifecycle",
        hint: "create → style → run JavaScript → visibility",
        statusText: this.statusTextOf("webview", this.webviewStatus),
        statusColor: this.statusColorOf("webview", this.webviewStatus),
        busy: this.busyKey === "webview",
        buttons: [
          new DemoButton("create webview", (): void => {
            this.handleCreateWebview();
          }),
          new DemoButton("create composed webview", (): void => {
            this.handleCreateComposedWebview();
          }),
          new DemoButton("create bottom webview", (): void => {
            this.handleCreateBottomWebview();
          }),
          new DemoButton("open sub window", (): void => {
            this.handleOpenSubWindow();
          }),
          new DemoButton("background red", (): void => {
            this.handleWebviewBackground();
          }),
          new DemoButton("run JavaScript", (): void => {
            this.handleWebviewScript();
          }),
          new DemoButton(this.webviewVisible ? "hide webview" : "show webview", (): void => {
            this.handleToggleWebviewVisible();
          }),
        ],
      })
      Stack() {
        // Layer order is declaration order: business content below and above this module's
        // component tree. The WebView plugin (and any other plugin) mounts its FrameNode into that
        // tree; there is no BridgeNodeHost or named slot anymore.
        this.WebviewUnderlay()
        DefaultXComponent({ moduleName: MODULE_NAME })
        this.WebviewOverlay()
      }
      .layoutWeight(1)
      .width("100%")
      .borderRadius(12)
    }
    .width("100%")
    .height("100%")
    .padding({ top: 4 });
  }

  @Builder
  PlatformServicesDemo() {
    Stack() {
      Scroll() {
        Column({ space: 12 }) {
          MenuBarComponent({ windowId: "main" })
          DemoCard({
            title: "Menu",
            hint: "context-free plugin state keyed by session + business windowId",
            statusText: this.statusTextOf("menu", this.menuResult),
            statusColor: this.statusColorOf("menu", this.menuResult),
            busy: this.busyKey === "menu",
            buttons: [
              new DemoButton("publish menubar", (): void => {
                this.handleMenuSet();
              }),
              new DemoButton("show popup", (): void => {
                this.handleMenuPopup();
              }),
            ],
          })
          DemoCard({
            title: "System status bar",
            hint: "process-level platform owner; latest successful mutation receives callbacks",
            statusText: this.statusTextOf("statusbar", this.statusbarResult),
            statusColor: this.statusColorOf("statusbar", this.statusbarResult),
            busy: this.busyKey === "statusbar",
            buttons: [
              new DemoButton("add item", (): void => {
                this.handleStatusbarAdd();
              }),
              new DemoButton("remove item", (): void => {
                this.handleStatusbarRemove();
              }),
            ],
          })
          DemoCard({
            title: "OS sub-window",
            hint: "async create/destroy; platform Window remains inside the plugin instance",
            statusText: this.statusTextOf("window", this.windowResult),
            statusColor: this.statusColorOf("window", this.windowResult),
            busy: this.busyKey === "window",
            buttons: [
              new DemoButton("create window", (): void => {
                this.handleCreateOsWindow();
              }),
              new DemoButton("destroy window", (): void => {
                this.handleDestroyOsWindow();
              }),
            ],
          })
          DemoCard({
            title: "Clipboard",
            hint: "requires=[]; system pasteboard does not need an Ability platform object",
            statusText: this.statusTextOf("clipboard", this.clipboardResult),
            statusColor: this.statusColorOf("clipboard", this.clipboardResult),
            busy: this.busyKey === "clipboard",
            buttons: [
              new DemoButton("write RGBA image", (): void => {
                this.handleClipboardWrite();
              }),
            ],
          })
          DemoCard({
            title: "Version and syscap",
            hint: "sync requires=[]; deviceInfo + global canIUse",
            statusText: this.statusTextOf("version", this.versionResult),
            statusColor: this.statusColorOf("version", this.versionResult),
            busy: this.busyKey === "version",
            buttons: [
              new DemoButton("query", (): void => {
                this.handleVersionInfo();
              }),
            ],
          })
          DemoCard({
            title: "AppGallery updater",
            hint: "ability-scoped async check",
            statusText: this.statusTextOf("updater", this.updaterResult),
            statusColor: this.statusColorOf("updater", this.updaterResult),
            busy: this.busyKey === "updater",
            buttons: [
              new DemoButton("check update", (): void => {
                this.handleUpdaterCheck();
              }),
            ],
          })
          DemoCard({
            title: "Autostart",
            hint: "ability-scoped; query API 21+ or open system app-launch settings",
            statusText: this.statusTextOf("autostart", this.autostartResult),
            statusColor: this.statusColorOf("autostart", this.autostartResult),
            busy: this.busyKey === "autostart",
            buttons: [
              new DemoButton("query status", (): void => {
                this.handleAutostartStatus();
              }),
              new DemoButton("open settings", (): void => {
                this.handleAutostartSettings();
              }),
            ],
          })
          DemoCard({
            title: "Application control",
            hint: "sync main-thread plugin; restart is process-global with a 3s cooldown",
            statusText: this.statusTextOf("app-control", this.appControlResult),
            statusColor: this.statusColorOf("app-control", this.appControlResult),
            busy: this.busyKey === "app-control",
            buttons: [
              new DemoButton("dark", (): void => this.handleSetColorMode(0)),
              new DemoButton("light", (): void => this.handleSetColorMode(1)),
              new DemoButton("system", (): void => this.handleSetColorMode(2)),
              new DemoButton("restart app", (): void => this.handleRestart()),
            ],
          })
          DemoCard({
            title: "Open external URL",
            hint: "ohos.url / context.openLink",
            statusText: this.statusTextOf("url", this.urlResult),
            statusColor: this.statusColorOf("url", this.urlResult),
            busy: this.busyKey === "url",
            buttons: [
              new DemoButton("open external URL", (): void => {
                this.handleOpenUrl();
              }),
            ],
          })
          DemoCard({
            title: "File dialogs",
            hint: "structured DialogOptions, not JSON",
            statusText: this.statusTextOf("files", this.fileDialogResult),
            statusColor: this.statusColorOf("files", this.fileDialogResult),
            busy: this.busyKey === "files",
            buttons: [
              new DemoButton("open (multi-select)", (): void => {
                this.handleFileDialogOpen();
              }),
              new DemoButton("save (PDF)", (): void => {
                this.handleFileDialogSave();
              }),
            ],
          })
          // This tab exercises the ui-context-gated Window plugin. The component is distinct
          // from the components on other tabs because only one tab is mounted at a time.
          DefaultXComponent({ moduleName: MODULE_NAME })
            .width(1)
            .height(1)
            .opacity(0)
        }
        .width("100%")
        .padding({ top: 4, bottom: 16 })
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .width("100%")
      .height("100%")
      MenuPopupComponent({ windowId: "main" })
    }
    .width("100%")
    .height("100%");
  }

  @Builder
  ResourceDemo() {
    Scroll() {
      Column({ space: 12 }) {
        DemoCard({
          title: "Resource manager",
          hint: "ohos.resource wrapper pushes resourceManager on ability-create",
          statusText: this.statusTextOf("resource", this.resourceStatus),
          statusColor: this.statusColorOf("resource", this.resourceStatus),
          busy: this.busyKey === "resource",
          buttons: [
            new DemoButton("check installed", (): void => this.handleResourceManagerReady()),
            new DemoButton("count raw dir", (): void => this.handleResourceRawDir()),
          ],
        })
        Text(
          "Raw file reads run through ohos-resource-manager-binding (C API), no ArkTS round-trip.",
        )
          .fontSize(12)
          .fontColor($r("app.color.text_hint"))
          .lineHeight(17)
          .padding({ left: 4, right: 4 })
      }
      .width("100%")
      .padding({ top: 4, bottom: 16 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .width("100%")
    .height("100%");
  }

  @Builder
  WebviewUnderlay() {
    Column() {
      Text("Business-owned content below the session node tree.")
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

  onBackPress(): boolean {
    const intercepted = invokeNativeBackPressInterceptor(MODULE_NAME);
    console.log(`native back press intercepted=${intercepted}`);
    return intercepted;
  }

  build() {
    Column({ space: 12 }) {
      this.Header()
      this.TabBar()
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
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor($r("app.color.page_bg"));
  }
}
