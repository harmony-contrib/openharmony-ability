import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import window from "@ohos.window";
import { AppControlPlugin } from "@ohos-rs/ability-plugin-app-control";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";
import { AccountPlugin } from "@ohos-rs/ability-plugin-account";
import { UpdaterPlugin } from "@ohos-rs/ability-plugin-updater";
import { GlobalShortcutPlugin } from "@ohos-rs/ability-plugin-global-shortcut";
import { DeepLinkPlugin } from "@ohos-rs/ability-plugin-deep-link";
import { AutostartPlugin } from "@ohos-rs/ability-plugin-autostart";
import { FilesPlugin } from "@ohos-rs/ability-plugin-files";
import { PermissionPlugin } from "@ohos-rs/ability-plugin-permission";
import { ResourcePlugin } from "@ohos-rs/ability-plugin-resource";
import { UrlPlugin } from "@ohos-rs/ability-plugin-url";
import { WebviewPlugin } from "@ohos-rs/ability-plugin-webview";
import { WindowPlugin } from "@ohos-rs/ability-plugin-window";
import { MenuPlugin } from "@ohos-rs/ability-plugin-menu";
import { StatusbarPlugin } from "@ohos-rs/ability-plugin-statusbar";
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
  public defaultPage: boolean = true;
  public bridgePlugins = [
    new LazyPlugin(() => new PermissionPlugin()),
    new LazyPlugin(() => new AppControlPlugin()),
    new LazyPlugin(() => new FilesPlugin()),
    new LazyPlugin(() => new ResourcePlugin()),
    new LazyPlugin(() => new WindowPlugin()),
    new LazyPlugin(() => new WebviewPlugin()),
    new LazyPlugin(() => new UrlPlugin()),
    new LazyPlugin(() => new ClipboardPlugin()),
    new LazyPlugin(() => new GlobalShortcutPlugin()),
    new LazyPlugin(() => new DeepLinkPlugin()),
    new LazyPlugin(() => new AutostartPlugin()),
    new LazyPlugin(() => new MenuPlugin()),
    new LazyPlugin(() => new StatusbarPlugin()),
    new LazyPlugin(() => new AccountPlugin()),
    new LazyPlugin(() => new UpdaterPlugin()),
    new LazyPlugin(() => new DemoLoginPlugin(new DemoIdentityProvider())),
    new LazyPlugin(() => new DemoMainThreadPlugin()),
    new LazyPlugin(() => new DemoTypedPlugin()),
    new LazyPlugin(() => new DemoNodePlugin()),
  ];

  protected override async loadWindowStageContent(windowStage: window.WindowStage): Promise<void> {
    demoWindowStage = windowStage;
    try {
      const mainWindow = windowStage.getMainWindowSync();
      // 全屏布局改成 best-effort:在 PC 自由窗口(mode 102)上 await 该调用会让
      // 后续 loadContent 的内容挂载永不完成(SetUIContent timeout, uiContent 恒 null)。
      mainWindow.setWindowLayoutFullScreen(true).catch(() => {});
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
