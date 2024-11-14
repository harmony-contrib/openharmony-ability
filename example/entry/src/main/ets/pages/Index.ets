import { hilog } from '@kit.PerformanceAnalysisKit';
import { MyApp } from 'libexample.so';
import { AbilityLifecycleCallback, common, EnvironmentCallback } from '@kit.AbilityKit';
import { NodeContent } from '@kit.ArkUI';

@Entry
@Component
struct Index {
  private rootSlot = new NodeContent();
  private uiContext = getContext(this) as common.UIAbilityContext;
  private app: MyApp | null = null;

  aboutToAppear(): void {
    const applicationContext = this.uiContext.getApplicationContext();

    const abilityCallback = {
      onAbilityForeground: ability => {
        hilog.info(0x0000, "test", "onAbilityForeground")
      }
    } as AbilityLifecycleCallback;

    const environmentCallback = {} as EnvironmentCallback;

    applicationContext.on("abilityLifecycle", abilityCallback)
    applicationContext.on("environment", environmentCallback)

    if (!this.app) {
      this.app = new MyApp(this.rootSlot);
    }
    this.app!.createNativeNode();
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
