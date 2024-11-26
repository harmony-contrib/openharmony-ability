import { common } from '@kit.AbilityKit';
import { NodeContent } from '@kit.ArkUI';

export const RouteName = 'RustAbility';

@Entry({routeName: RouteName, storage: LocalStorage.getShared()})
@Component
struct Index {
  private rootSlot = new NodeContent();
  private uiContext = getContext(this) as common.UIAbilityContext;

  @LocalStorageLink("moduleName") name: string = "";

  async aboutToAppear(): Promise<void> {
    const moduleName = `lib${this.name}.so`;
    const module: ESObject = await import(moduleName);
    module.default.render(this.rootSlot);
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
