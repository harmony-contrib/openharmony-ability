import { init } from 'libexample.so';
import { AbilityLifecycleCallback, common, EnvironmentCallback } from '@kit.AbilityKit';
import { NodeContent } from '@kit.ArkUI';

@Entry
@Component
struct Index {
  private rootSlot = new NodeContent();
  private uiContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    const lifecycle = init(this.rootSlot);
    const applicationContext = this.uiContext.getApplicationContext();

    applicationContext.on("abilityLifecycle",
      lifecycle.windowStageEventCallback as ESObject as AbilityLifecycleCallback)
    applicationContext.on("environment", lifecycle.environmentCallback as ESObject as EnvironmentCallback)
  }

  build() {
    Row() {
      Column() {
        ContentSlot(this.rootSlot)
      }
      .width('100%')
    }
    .height('100%')
  }
}
