import { DefaultXComponent } from "@ohos-rs/ability";
import { demoRequestPermissionFromMainThread } from "libxcomponent_example.so";

@Entry
@Component
struct Index {
  private permissionDemoCalled: boolean = false;

  async handleClick() {
    const re: number[] = await demoRequestPermissionFromMainThread();
    console.log(`${re}`);
  }

  build() {
    Row() {
      Column() {
        Button()
          .onClick(() => this.handleClick())
        DefaultXComponent()
      }.width("100%")
    }.height("100%");
  }
}
