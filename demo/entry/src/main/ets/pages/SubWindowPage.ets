import { DefaultXComponent } from "@ohos-rs/ability";
import window from "@ohos.window";
import { createSubWindowWebview, subWindowKeyboardInset } from "libdemo_sub_native.so";
import { SUB_WINDOW_NATIVE_MODULE } from "../entryability/EntryAbility";

export const SUB_WINDOW_NAME = "demo_sub_window";

@Entry
@Component
struct SubWindowPage {
  @State status: string = "";
  @State busy: boolean = false;

  async handleCreateWebview() {
    this.busy = true;
    this.status = "";
    try {
      await createSubWindowWebview();
      this.status = "✓ WebView mounted into this window's node tree";
    } catch (error) {
      this.status = `✗ ${String(error)}`;
    } finally {
      this.busy = false;
    }
  }

  async handleQueryAvoidArea() {
    this.busy = true;
    try {
      this.status = `✓ sub-window keyboard bottom inset=${await subWindowKeyboardInset()}`;
    } catch (error) {
      this.status = `✗ avoid-area query failed: ${String(error)}`;
    } finally {
      this.busy = false;
    }
  }

  async handleClose() {
    this.busy = true;
    try {
      const subWindow = await window.findWindow(SUB_WINDOW_NAME);
      await subWindow.destroyWindow();
    } catch (error) {
      this.status = `✗ close failed: ${String(error)}`;
      this.busy = false;
    }
  }

  build() {
    Stack() {
      Column({ space: 12 }) {
        Text("Sub window")
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
        Text(
          "This page owns a second DefaultXComponent backed by demo_sub_native, so its plugin " +
            "tree and Rust runtime are independent from demo_native.",
        )
          .fontSize(12)
          .fontColor("#666")
          .textAlign(TextAlign.Center)
        Button(this.busy ? "working…" : "create webview here")
          .enabled(!this.busy)
          .onClick(() => {
            this.handleCreateWebview();
          })
        Button("query this window's keyboard inset")
          .enabled(!this.busy)
          .onClick(() => {
            this.handleQueryAvoidArea();
          })
        Button("close window")
          .backgroundColor("#aa3333")
          .enabled(!this.busy)
          .onClick(() => {
            this.handleClose();
          })
        Text(this.status)
          .fontSize(12)
          .fontColor(this.status.startsWith("✗") ? "#aa3333" : "#227722")
          .textAlign(TextAlign.Center)
        DefaultXComponent({ moduleName: SUB_WINDOW_NATIVE_MODULE })
          .width("100%")
          .layoutWeight(1)
          .borderRadius(12)
      }
      .width("100%")
      .height("100%")
      .padding(12)
    }
    .width("100%")
    .height("100%")
    .backgroundColor("#f5f5f5");
  }
}
