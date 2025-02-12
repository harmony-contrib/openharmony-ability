import { common } from '@kit.AbilityKit';
import { NodeContent } from '@kit.ArkUI';
import { displaySync } from '@kit.ArkGraphics2D';
import { Render } from '../ability/type';

export const RouteName = 'RustAbility';

@Component
export struct DefaultXComponent {
  private rootSlot = new NodeContent();
  private uiContext = getContext(this) as common.UIAbilityContext;
  private render: Render | null = null;
  private displaySyncInstance = displaySync.create();
  private nativeModule: ESObject;

  @StorageProp("moduleName") name: string = "";

  async aboutToAppear(): Promise<void> {
    const moduleName = `lib${this.name}.so`;
    const module: ESObject = await import(moduleName);
    this.nativeModule = module.default;
    this.render = module.default.render(this.rootSlot, () => {
      // make sure redraw after surface is created
      this.displaySyncInstance.on("frame", this.render!.onFrame);
      this.displaySyncInstance.start();
    });
  }

  aboutToDisappear(): void {
    this.displaySyncInstance.off("frame", this.render!.onFrame);
  }

  build() {
    ContentSlot(this.rootSlot)
  }
}
