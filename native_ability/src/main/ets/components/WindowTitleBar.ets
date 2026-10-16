// Match OpenHarmony's container-modal title and control-button layout:
// frameworks/core/components_ng/pattern/container_modal/interfaces/customtitle.js
export const WINDOW_TITLE_BAR_HEIGHT: number = 37;
const CONTROL_SIZE: number = 28;
const CONTROL_ICON_SIZE: number = 20;
const CONTROL_SPACING: number = 12;

@Component
struct WindowControlButton {
  @Prop icon: Resource = $r("app.media.window_minimize");
  @Prop label: Resource = $r("app.string.window_minimize");
  @Prop @Watch("resetInteraction") available: boolean = true;
  @Prop @Watch("resetInteraction") windowFocused: boolean = true;
  @Prop closeButton: boolean = false;
  onActivate: () => void = () => {};
  @State private hovered: boolean = false;
  @State private pressed: boolean = false;

  resetInteraction(): void {
    if (!this.available || !this.windowFocused) {
      this.hovered = false;
      this.pressed = false;
    }
  }

  private buttonBackgroundColor(): ResourceColor {
    if (this.available && this.pressed) {
      return this.closeButton ? $r("sys.color.warning") : $r("sys.color.interactive_click");
    }
    if (this.available && this.hovered) {
      return this.closeButton
        ? $r("sys.color.warning")
        : $r("sys.color.container_modal_button_hover_baseboard");
    }
    return Color.Transparent;
  }

  private iconColor(): Resource {
    if (this.closeButton && this.available && (this.hovered || this.pressed)) {
      return $r("sys.color.icon_on_primary");
    }
    return $r("sys.color.icon_primary");
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Image(this.icon)
        .width(CONTROL_ICON_SIZE)
        .height(CONTROL_ICON_SIZE)
        .fillColor(this.iconColor())
        .scale({ x: this.hovered ? 1.1 : 1, y: this.hovered ? 1.1 : 1 })
        .draggable(false)
        .focusable(false)
    }
    .width(CONTROL_SIZE)
    .height(CONTROL_SIZE)
    .borderRadius(4)
    .padding(0)
    .backgroundColor(this.buttonBackgroundColor())
    .hoverEffect(HoverEffect.None)
    .enabled(this.available)
    .opacity(this.available && this.windowFocused ? 1 : 0.4)
    .focusable(false)
    .accessibilityText(this.label)
    // Enlarge the hit target into the gaps without overlapping another button
    // or extending below the title bar into the menu/content.
    .responseRegion({ x: -6, y: -4.5, width: 40, height: WINDOW_TITLE_BAR_HEIGHT })
    .onHover((hovered: boolean) => {
      this.hovered = hovered;
      if (!hovered) {
        this.pressed = false;
      }
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => this.onActivate());
  }
}
@Component
export struct WindowTitleBar {
  @Prop title: string = "";
  @Prop decorations: boolean = true;
  @Prop windowFocused: boolean = true;
  @Prop maximized: boolean = false;
  @Prop minimizable: boolean = true;
  @Prop maximizable: boolean = true;
  @Prop closable: boolean = true;
  onDrag: (event: TouchEvent) => void = () => {};
  onMinimize: () => void = () => {};
  onMaximize: () => void = () => {};
  onClose: () => void = () => {};

  build() {
    Row() {
      Row() {
        if (this.decorations) {
          Text(this.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r("sys.color.ohos_id_color_primary"))
            .opacity(this.windowFocused ? 1 : 0.4)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
        }
      }
      .layoutWeight(1)
      .height("100%")
      .padding({ left: 20, right: 12 })
      .clip(true)
      .onTouch((event: TouchEvent) => this.onDrag(event))

      if (this.decorations) {
        Row({ space: CONTROL_SPACING }) {
          WindowControlButton({
            icon: this.maximized ? $r("app.media.window_restore") : $r("app.media.window_maximize"),
            label: this.maximized
              ? $r("app.string.window_restore")
              : $r("app.string.window_maximize"),
            available: this.maximizable,
            windowFocused: this.windowFocused,
            onActivate: () => this.onMaximize(),
          })
          WindowControlButton({
            icon: $r("app.media.window_minimize"),
            label: $r("app.string.window_minimize"),
            available: this.minimizable,
            windowFocused: this.windowFocused,
            onActivate: () => this.onMinimize(),
          })
          WindowControlButton({
            icon: $r("app.media.window_close"),
            label: $r("app.string.window_close"),
            available: this.closable,
            windowFocused: this.windowFocused,
            closeButton: true,
            onActivate: () => this.onClose(),
          })
        }
        .height("100%")
        .padding({ left: 12, right: 20 });
      }
    }
    .width("100%")
    .height(WINDOW_TITLE_BAR_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(
      this.decorations
        ? this.windowFocused
          ? $r("sys.color.container_modal_background")
          : $r("sys.color.container_modal_unfocus_background")
        : Color.Transparent,
    );
  }
}
