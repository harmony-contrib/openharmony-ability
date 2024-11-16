import { hilog } from '@kit.PerformanceAnalysisKit';
import { init } from 'libexample.so';
import { AbilityLifecycleCallback, common, EnvironmentCallback } from '@kit.AbilityKit';
import { NodeContent } from '@kit.ArkUI';

@Entry
@Component
struct Index {
  private rootSlot = new NodeContent();
  private uiContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    const lifecycle = init();
    const applicationContext = this.uiContext.getApplicationContext();

    const abilityCallback = {
      onAbilityForeground: ability => {
        hilog.info(0x0000, "test", "onAbilityForeground")
      }
    } as AbilityLifecycleCallback;

    const environmentCallback = {} as EnvironmentCallback;

    applicationContext.on("abilityLifecycle", lifecycle as ESObject as AbilityLifecycleCallback)
    applicationContext.on("environment", environmentCallback)
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
