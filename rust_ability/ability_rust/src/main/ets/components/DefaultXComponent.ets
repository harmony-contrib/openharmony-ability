import { common } from '@kit.AbilityKit';
import { NodeContent } from '@kit.ArkUI';

export const RouteName = 'RustAbility';

@Component
export struct DefaultXComponent {
  private rootSlot = new NodeContent();
  private uiContext = getContext(this) as common.UIAbilityContext;
  private nativeModule: ESObject;

  @StorageProp("moduleName") name: string = "";

  async aboutToAppear(): Promise<void> {
    const moduleName = `lib${this.name}.so`;
    const module: ESObject = await import(moduleName);
    this.nativeModule = module.default;
    module.default.render(this.rootSlot);
  }


  build() {
    ContentSlot(this.rootSlot)
  }
}
