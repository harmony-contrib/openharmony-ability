import { EagerPlugin, LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import Want from "@ohos.app.ability.Want";
import { AbilityConstant } from "@kit.AbilityKit";
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

export default class EntryAbility extends NativeAbility {
  public moduleName: string = "demo_native";
  public defaultPage: boolean = false;
  public bridgePlugins = [
    new LazyPlugin(() => new PermissionPlugin()),
    new LazyPlugin(() => new AppControlPlugin()),
    new LazyPlugin(() => new ClipboardPlugin()),
    new LazyPlugin(() => new FilesPlugin()),
    new EagerPlugin(new ResourcePlugin()),
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

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    super.onCreate(want, launchParam);
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      await mainWindow.setWindowLayoutFullScreen(false);
      super.onWindowStageCreate(windowStage);
      await windowStage.loadContent("pages/Index");
    } catch (error) {
      throw new Error(`Unable to initialize the demo window: ${String(error)}`);
    }
  }
}
