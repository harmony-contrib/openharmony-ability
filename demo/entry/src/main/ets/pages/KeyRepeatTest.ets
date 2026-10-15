import { hilog } from "@kit.PerformanceAnalysisKit";
import { KeyCode } from "@kit.InputKit";

const DOMAIN = 0x0000;

@Entry
@Component
struct KeyRepeatTest {
  @State private keyTestLog: string[] = [];
  private pressedKeys: Set<number> = new Set();

  build() {
    Column() {
      Row() {
        Text("Key Repeat Test (ArkUI level)")
          .fontSize(18)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
        Blank()
        SymbolGlyph($r("sys.symbol.xmark"))
          .fontSize(24)
          .fontColor([Color.White])
          .onClick(() => {
            this.keyTestLog = [];
            this.pressedKeys.clear();
          })
      }
      .width("100%")
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })
      Text("Hold a key to test repeat detection. Press ESC or ✕ to clear log.")
        .fontSize(13)
        .fontColor("#AAA")
        .padding({ left: 16, bottom: 8 })
      Scroll() {
        Column() {
          ForEach(
            this.keyTestLog,
            (item: string) => {
              Text(item)
                .fontSize(14)
                .fontFamily("monospace")
                .fontColor(item.includes("repeat=true") ? "#4CAF50" : "#CCC")
                .fontWeight(item.includes("repeat=true") ? FontWeight.Bold : FontWeight.Normal)
                .width("100%");
            },
            (item: string, index: number) => index.toString(),
          )
        }
        .width("100%")
        .padding({ left: 16, right: 16 })
      }.layoutWeight(1)
    }
    .id("keyTestOverlay")
    .width("100%")
    .height("100%")
    .backgroundColor("#1E1E1E")
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      // ESC to clear log
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE) {
        this.keyTestLog = [];
        this.pressedKeys.clear();
        return;
      }

      const keyCode = event.keyCode;
      const keyText = event.keyText || `code:${keyCode}`;
      let isRepeat = false;

      if (event.type === KeyType.Down) {
        isRepeat = this.pressedKeys.has(keyCode);
        this.pressedKeys.add(keyCode);
      } else if (event.type === KeyType.Up) {
        this.pressedKeys.delete(keyCode);
      }

      const entry = `key="${keyText}" type=${event.type === KeyType.Down ? "Down" : "Up"} repeat=${isRepeat}`;
      this.keyTestLog = [...this.keyTestLog.slice(-49), entry];
      hilog.info(DOMAIN, "KeyTest", "%{public}s", entry);
    })
    .onAppear(() => {
      try {
        focusControl.requestFocus("keyTestOverlay");
      } catch (e) {
        hilog.warn(DOMAIN, "KeyTest", "focusControl failed: %{public}s", String(e));
      }
    });
  }
}
