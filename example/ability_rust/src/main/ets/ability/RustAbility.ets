import { AbilityConstant, UIAbility, Want } from "@kit.AbilityKit";
import window from "@ohos.window";
import * as Entry from '../components/MainPage'
import { BusinessError } from "@kit.BasicServicesKit";
import { ApplicationLifecycle, Module } from './type'

const storage: LocalStorage = new LocalStorage();

export class RustAbility extends UIAbility {
  public moduleName: string = "";
  private nativeModule: Module | null = null;
  private lifecycle: ApplicationLifecycle | null = null;

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    const packageName = `lib${this.moduleName}.so`;
    const module: ESObject = await import(packageName);
    this.nativeModule = module.default;
    this.lifecycle = this.nativeModule!.init();
    this.lifecycle?.windowStageEventCallback.onAbilityCreate();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    storage.setAndLink("moduleName", this.moduleName);
    windowStage.loadContentByName(Entry.RouteName, storage, (err: BusinessError) => {

    })
  }
}