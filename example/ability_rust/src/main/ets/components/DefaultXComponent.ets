import { common } from '@kit.AbilityKit';
import { NodeContent } from '@kit.ArkUI';
import { displaySync } from '@kit.ArkGraphics2D';

export const RouteName = 'RustAbility';

@Component
export struct DefaultXComponent {
  private rootSlot = new NodeContent();
  private uiContext = getContext(this) as common.UIAbilityContext;
  private displaySyncInstance = displaySync.create();
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
