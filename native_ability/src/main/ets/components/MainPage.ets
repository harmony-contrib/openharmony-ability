import { DefaultXComponent } from "./DefaultXComponent";
import { Loadable } from "../helper/loadable";

export const RouteName = "NativeAbility";

@Entry({ routeName: RouteName })
@Component
struct Index {
  @StorageProp("moduleName") moduleNames: string | string[] = "";
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";
  private nativeModule: ESObject = null;
  @State private primaryModuleName: string = "";

  async aboutToAppear(): Promise<void> {
    const moduleName = Loadable.resolvePrimaryModuleName(this.moduleNames);
    if (!moduleName) {
      throw new Error("dynamic moduleName is empty");
    }

    this.nativeModule = await Loadable.load(moduleName, this.loadMode);
    this.primaryModuleName = moduleName;
  }

  onBackPress(): boolean {
    if (typeof this.nativeModule?.on_back_press_intercept === "function") {
      return this.nativeModule.on_back_press_intercept();
    }
    return false;
  }

  build() {
    Row() {
      Column() {
        if (this.primaryModuleName) {
          DefaultXComponent({ moduleName: this.primaryModuleName });
        }
      }.width("100%")
    }.height("100%");
  }
}
