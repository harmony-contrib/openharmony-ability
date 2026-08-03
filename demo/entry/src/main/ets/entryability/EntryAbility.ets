import { NativeAbility } from "@ohos-rs/ability";
import Want from "@ohos.app.ability.Want";
import { AbilityConstant } from "@kit.AbilityKit";
import window from "@ohos.window";
import { createAppControlPlugin } from "@ohos-rs/plugin-app-control";
import { createFilesPlugin } from "@ohos-rs/plugin-files";
import { createPermissionPlugin } from "@ohos-rs/plugin-permission";
import { createUrlPlugin } from "@ohos-rs/plugin-url";
import { createWebviewPlugin } from "@ohos-rs/plugin-webview";
import { createWindowPlugin } from "@ohos-rs/plugin-window";
import { createDemoLoginPlugin, createDemoMainThreadPlugin } from "../bridge/DemoLoginPlugin";
import { createDemoNodePlugin } from "../bridge/DemoNodePlugin";
import { createDemoRawPlugin } from "../bridge/DemoRawPlugin";

export default class EntryAbility extends NativeAbility {
  public moduleName: string = "demo_native";
  public defaultPage: boolean = false;
  public bridgePlugins = [
    createPermissionPlugin(),
    createAppControlPlugin(),
    createFilesPlugin(),
    createWindowPlugin(),
    createWebviewPlugin(),
    createUrlPlugin(),
    createDemoLoginPlugin(),
    createDemoMainThreadPlugin(),
    createDemoRawPlugin(),
    createDemoNodePlugin(),
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
