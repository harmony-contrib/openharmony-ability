import { DefaultXComponent } from "./DefaultXComponent";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";
import { invokeNativeBackPressInterceptor } from "../runtime/BackPress";

export const RouteName = "NativeAbility";

@Entry({ routeName: RouteName })
@Component
struct Index {
  @StorageProp("moduleName") moduleNames: string | string[] = "";
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";
  @State private primaryModuleName: string = "";

  async aboutToAppear(): Promise<void> {
    const moduleName = NativeModuleLoader.resolveModuleNames(this.moduleNames)[0] ?? "";
    if (!moduleName) {
      throw new Error("dynamic moduleName is empty");
    }

    await NativeModuleLoader.load(moduleName, this.loadMode);
    this.primaryModuleName = moduleName;
  }

  onBackPress(): boolean {
    return invokeNativeBackPressInterceptor(this.primaryModuleName);
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
