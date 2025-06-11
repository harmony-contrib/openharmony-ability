import { RustAbility } from '@ohos-rs/ability'
import Want from '@ohos.app.ability.Want'
import { AbilityConstant } from '@kit.AbilityKit';
import window from '@ohos.window';

export default class EntryAbility extends RustAbility {
  public moduleName: string = "webview_example"
  public defaultPage: boolean = false;
  public mode: 'xcomponent' | 'webview' = 'webview'

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    super.onCreate(want, launchParam);
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    const window = windowStage.getMainWindowSync();
    await window.setWindowLayoutFullScreen(false);
    super.onWindowStageCreate(windowStage);

    await windowStage.loadContent("pages/Index")
  }
}
