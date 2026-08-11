import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import window from "@ohos.window";
import { AppControlPlugin } from "@ohos-rs/ability-plugin-app-control";
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
const MAIN_ONLY = [MAIN_NATIVE_MODULE];
const WEBVIEW_MODULES = [MAIN_NATIVE_MODULE, SUB_WINDOW_NATIVE_MODULE];

export default class EntryAbility extends NativeAbility {
  public moduleName: string[] = WEBVIEW_MODULES;
  public defaultPage: boolean = false;
  public bridgePlugins = [
    new LazyPlugin(() => new PermissionPlugin(), MAIN_ONLY),
    new LazyPlugin(() => new AppControlPlugin(), MAIN_ONLY),
    new LazyPlugin(() => new ClipboardPlugin(), MAIN_ONLY),
    new LazyPlugin(() => new FilesPlugin(), MAIN_ONLY),
    new LazyPlugin(() => new ResourcePlugin(), MAIN_ONLY),
    new LazyPlugin(() => new WindowPlugin(), WEBVIEW_MODULES),
    new LazyPlugin(() => new WebviewPlugin(), WEBVIEW_MODULES),
    new LazyPlugin(() => new UrlPlugin(), MAIN_ONLY),
    new LazyPlugin(() => new VersionPlugin(), MAIN_ONLY),
    new LazyPlugin(() => new UpdaterPlugin(), MAIN_ONLY),
    new LazyPlugin(() => new MenuPlugin(), MAIN_ONLY),
    new LazyPlugin(() => new StatusBarPlugin(), MAIN_ONLY),
    new LazyPlugin(() => new DemoLoginPlugin(new DemoIdentityProvider()), MAIN_ONLY),
    new LazyPlugin(() => new DemoMainThreadPlugin(), MAIN_ONLY),
    new LazyPlugin(() => new DemoTypedPlugin(), MAIN_ONLY),
    new LazyPlugin(() => new DemoNodePlugin(), MAIN_ONLY),
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
