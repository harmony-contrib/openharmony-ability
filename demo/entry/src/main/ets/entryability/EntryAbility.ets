import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import window from "@ohos.window";
import { AppControlPlugin } from "@ohos-rs/ability-plugin-app-control";
import { AutostartPlugin } from "@ohos-rs/ability-plugin-autostart";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";
import { FilesPlugin } from "@ohos-rs/ability-plugin-files";
import { MenuPlugin } from "@ohos-rs/ability-plugin-menu";
import { PermissionPlugin } from "@ohos-rs/ability-plugin-permission";
import { ResourcePlugin } from "@ohos-rs/ability-plugin-resource";
import { StatusBarPlugin } from "@ohos-rs/ability-plugin-statusbar";
import { UpdaterPlugin } from "@ohos-rs/ability-plugin-updater";
import { UrlPlugin } from "@ohos-rs/ability-plugin-url";
import { VersionPlugin } from "@ohos-rs/ability-plugin-version";
import { WebviewPlugin } from "@ohos-rs/ability-plugin-webview";
import { WindowPlugin } from "@ohos-rs/ability-plugin-window";
import {
  DemoLoginPlugin,
  DemoIdentityProvider,
  DemoMainThreadPlugin,
} from "../bridge/DemoLoginPlugin";
import { DemoNodePlugin } from "../bridge/DemoNodePlugin";
import { DemoTypedPlugin } from "../bridge/DemoRawPlugin";

/** The main WindowStage, shared with the demo pages so the Index page can open a sub window. */
export let demoWindowStage: window.WindowStage | null = null;

const MAIN_NATIVE_MODULE = "demo_native";
export const SUB_WINDOW_NATIVE_MODULE = "demo_sub_native";
const NATIVE_MODULES = [MAIN_NATIVE_MODULE, SUB_WINDOW_NATIVE_MODULE];

export default class EntryAbility extends NativeAbility {
  public moduleName: string[] = NATIVE_MODULES;
  public defaultPage: boolean = false;
  public bridgePlugins = [
    new LazyPlugin(() => new PermissionPlugin()),
    new LazyPlugin(() => new AppControlPlugin()),
    new LazyPlugin(() => new AutostartPlugin()),
    new LazyPlugin(() => new ClipboardPlugin()),
    new LazyPlugin(() => new FilesPlugin()),
    new LazyPlugin(() => new ResourcePlugin()),
    new LazyPlugin(() => new WindowPlugin()),
    new LazyPlugin(() => new WebviewPlugin()),
    new LazyPlugin(() => new UrlPlugin()),
    new LazyPlugin(() => new VersionPlugin()),
    new LazyPlugin(() => new UpdaterPlugin()),
    new LazyPlugin(() => new MenuPlugin()),
    new LazyPlugin(() => new StatusBarPlugin()),
    new LazyPlugin(() => new DemoLoginPlugin(new DemoIdentityProvider())),
    new LazyPlugin(() => new DemoMainThreadPlugin()),
    new LazyPlugin(() => new DemoTypedPlugin()),
    new LazyPlugin(() => new DemoNodePlugin()),
  ];

  protected override async loadWindowStageContent(windowStage: window.WindowStage): Promise<void> {
    demoWindowStage = windowStage;
    try {
      const mainWindow = windowStage.getMainWindowSync();
      // 全屏布局：内容延伸到状态栏下方（状态栏变透明），避免顶部出现系统绘制的黑色状态栏条。
      await mainWindow.setWindowLayoutFullScreen(true);
      await windowStage.loadContent("pages/Index");
    } catch (error) {
      throw new Error(`Unable to load demo WindowStage content: ${String(error)}`);
    }
  }

  onWindowStageDestroy(): void {
    super.onWindowStageDestroy();
    demoWindowStage = null;
  }
}
