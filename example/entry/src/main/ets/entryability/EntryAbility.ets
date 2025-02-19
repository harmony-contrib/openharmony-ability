import { RustAbility } from '@ohos-rs/ability'
import Want from '@ohos.app.ability.Want'
import { AbilityConstant } from '@kit.AbilityKit';
import window from '@ohos.window';

export default class EntryAbility extends RustAbility {
  public moduleName: string = "example"
  public defaultPage: boolean = true;

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    super.onCreate(want, launchParam);
  }

  // async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
  //   super.onWindowStageCreate(windowStage);
  //   await windowStage.loadContent('pages/Index');
  // }
}
