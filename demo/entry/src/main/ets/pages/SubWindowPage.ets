import { DefaultXComponent } from "@ohos-rs/ability";
import window from "@ohos.window";
import { createSubWindowWebview } from "libdemo_native.so";

/** Must match the `window_key` used by `create_sub_window_webview` on the Rust side. */
export const SUB_WINDOW_KEY = "sub";
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
          "This page owns a second DefaultXComponent with a unique windowKey, so its plugin " +
            "tree never touches the main window's.",
        )
          .fontSize(12)
          .fontColor("#666")
          .textAlign(TextAlign.Center)
        Button(this.busy ? "working…" : "create webview here")
          .enabled(!this.busy)
          .onClick(() => {
            this.handleCreateWebview();
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
        DefaultXComponent({ moduleName: "demo_native", windowKey: SUB_WINDOW_KEY })
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
