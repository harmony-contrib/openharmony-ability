/**
 * Reusable demo card: title + optional hint + action buttons + a single status line.
 *
 * The status line encodes four states through `statusColor` (idle / running / success / error)
 * while `busy` swaps the top-right indicator for a `LoadingProgress` and disables the buttons.
 *
 * Actions are plain data ([`DemoButton`]) whose closures are created by the parent component, so
 * every handler keeps its parent `this` binding — no `@BuilderParam` indirection.
 */
import { LengthMetrics } from "@ohos.arkui.node";

/** One demo action: a label and a closure that already captures the owning component's `this`. */
export class DemoButton {
  label: string;
  onAction: () => void;

  constructor(label: string, onAction: () => void) {
    this.label = label;
    this.onAction = onAction;
  }
}
@Component
export struct DemoCard {
  @Prop title: string = "";
  @Prop hint: string = "";
  @Prop statusText: string = "";
  @Prop statusColor: ResourceColor = $r("app.color.status_idle");
  @Prop busy: boolean = false;
  buttons: Array<DemoButton> = [];

  build() {
    Column({ space: 12 }) {
      Row() {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r("app.color.text_primary"))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        if (this.busy) {
          LoadingProgress().width(18).height(18).color($r("app.color.status_running"));
        } else {
          Circle().width(8).height(8).fill(this.statusColor);
        }
      }
      .width("100%")
      .alignItems(VerticalAlign.Center)

      if (this.hint !== "") {
        Text(this.hint).fontSize(12).fontColor($r("app.color.text_hint")).lineHeight(17);
      }

      if (this.buttons.length > 0) {
        Flex({
          wrap: FlexWrap.Wrap,
          space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) },
        }) {
          ForEach(
            this.buttons,
            (button: DemoButton) => {
              Button(button.label)
                .layoutWeight(1)
                .height(40)
                .fontSize(13)
                .fontColor($r("app.color.accent"))
                .backgroundColor($r("app.color.action_bg"))
                .borderRadius(8)
                .enabled(!this.busy)
                .onClick(() => button.onAction());
            },
            (button: DemoButton) => button.label,
          )
        }.width("100%");
      }
      Row({ space: 6 }) {
        Circle()
          .width(6)
          .height(6)
          .fill(this.statusColor)
        Text(this.statusText)
          .fontSize(13)
          .fontColor(this.statusColor)
          .lineHeight(18)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width("100%")
      .alignItems(VerticalAlign.Center)
      .padding({ top: 2 })
    }
    .width("100%")
    .padding(14)
    .backgroundColor($r("app.color.card_bg"))
    .borderRadius(12)
    .border({ width: 1, color: $r("app.color.card_border") });
  }
}
