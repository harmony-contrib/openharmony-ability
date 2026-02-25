import { DefaultXComponent } from "./DefaultXComponent";
import { Loadable } from "../helper/loadable";

export const RouteName = "RustAbility";

@Entry({ routeName: RouteName })
@Component
struct Index {
  @StorageProp("moduleName") name: string = "";
  private nativeModule: ESObject = null;

  async aboutToAppear(): Promise<void> {
    const moduleName = `lib${this.name}.so`;
    this.nativeModule = await Loadable.load(moduleName, "async");
  }

  onBackPress(): boolean {
    // Call the back press interceptor from Rust
    if (typeof this.nativeModule?.on_back_press_intercept === "function") {
      return this.nativeModule.on_back_press_intercept();
    }
    return false;
  }

  build() {
    Row() {
      Column() {
        DefaultXComponent()
      }.width("100%")
    }.height("100%");
  }
}
