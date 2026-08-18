import { DefaultXComponent } from "./DefaultXComponent";
import { Log } from "../runtime/Log";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";
import { invokeNativeBackPressInterceptor } from "../runtime/BackPress";

export const RouteName = "NativeAbility";

@Entry({ routeName: RouteName })
@Component
struct Index {
  @StorageProp("moduleName") moduleNames: string | string[] = "";
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";
  @State private primaryModuleName: string = "";

  aboutToAppear(): void {
    // ArkUI never awaits lifecycle callbacks; supervise the module load explicitly.
    void this.loadPrimaryModule().catch((error: Error) => {
      Log.error(`[MainPage] failed to load the primary native module: ${String(error)}`);
    });
  }

  private async loadPrimaryModule(): Promise<void> {
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
