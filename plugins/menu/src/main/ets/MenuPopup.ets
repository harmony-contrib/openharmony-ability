import { SymbolGlyphModifier } from "@kit.ArkUI";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { MenuItemData } from "./menu";
@Component
export struct MenuPopup {
  @Prop items: MenuItemData[];
  @Prop offset: Position;
  @Prop onItemClick: (item: MenuItemData) => void;
  @Prop onDisappear: () => void;
  @State isShown: boolean = true;

  private pasteButtonBackgroundColor(): ResourceColor {
    try {
      const hostContext = this.getUIContext().getHostContext();
      if (hostContext) {
        const cardBg = hostContext.resourceManager.getColorSync(
          $r("sys.color.ohos_id_color_card_bg").id,
        );
        return ((cardBg & 0x00ffffff) | 0x1a000000) >>> 0;
      }
    } catch (error) {
      hilog.warn(
        0x1999,
        "MenuPopup",
        "Cannot resolve menu surface color: %{public}s",
        String(error),
      );
    }
    return $r("sys.color.checkbox_container_focus_color_unselected");
  }

  private nativeIconSymbol(nativeIcon?: string): SymbolGlyphModifier | undefined {
    switch (nativeIcon) {
      case "sys.symbol.ohos_star":
        return new SymbolGlyphModifier($r("sys.symbol.ohos_star"))
          .fontSize(16)
          .fontColor([$r("sys.color.icon_primary")]);
      case "sys.symbol.ohos_lock":
        return new SymbolGlyphModifier($r("sys.symbol.ohos_lock"))
          .fontSize(16)
          .fontColor([$r("sys.color.icon_primary")]);
      case "sys.symbol.ohos_wifi":
        return new SymbolGlyphModifier($r("sys.symbol.ohos_wifi"))
          .fontSize(16)
          .fontColor([$r("sys.color.icon_primary")]);
      case "sys.symbol.folder":
        return new SymbolGlyphModifier($r("sys.symbol.folder"))
          .fontSize(16)
          .fontColor([$r("sys.color.icon_primary")]);
      default:
        return undefined;
    }
  }

  build() {
    Column()
      .width(1)
      .height(1)
      .position({ x: 0, y: 0 })
      .bindContextMenu(this.isShown, this.MenuContent, {
        offset: this.offset,
        aboutToDisappear: () => {
          this.isShown = false;
          this.onDisappear?.();
        },
      })
      .focusable(false);
  }

  @Builder
  MenuContent() {
    Menu() {
      ForEach(this.items, (item: MenuItemData) => {
        this.buildMenuItem(item);
      })
    };
  }

  @Builder
  buildMenuItem(item: MenuItemData) {
    if (item.type === "separator") {
      Divider()
        .width(256)
        .color($r("sys.color.ohos_id_color_list_separator"))
        .margin({ left: 12, right: 12 });
    } else if (item.predefinedType === "paste") {
      Stack({ alignContent: Alignment.End }) {
        if (item.accelerator) {
          Text(item.accelerator)
            .fontSize($r("sys.float.Body_L"))
            .fontWeight(FontWeight.Regular)
            .fontColor($r("sys.color.font_secondary"))
            .textAlign(TextAlign.End)
            .margin({ right: $r("sys.float.padding_level6") })
            .opacity((item.enabled ?? true) ? 1.0 : $r("sys.float.interactive_disable"))
            .hitTestBehavior(HitTestMode.None);
        }
        PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
          .width("100%")
          .height($r("sys.float.option_min_height"))
          .align(Alignment.Start)
          .fontSize($r("sys.float.Body_L"))
          .fontWeight(FontWeight.Regular)
          .fontColor($r("sys.color.font_primary"))
          .backgroundColor(this.pasteButtonBackgroundColor())
          .borderRadius($r("sys.float.inner_border_radius_token"))
          .padding({
            left: $r("sys.float.padding_level6"),
            right: $r("sys.float.padding_level6"),
            top: $r("sys.float.padding_level2"),
            bottom: $r("sys.float.padding_level2"),
          })
          .enabled(item.enabled ?? true)
          .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
            if (result !== PasteButtonOnClickResult.SUCCESS) {
              return;
            }
            this.itemClick(item);
          })
      }.width(280);
    } else if (item.type === "item" || item.type === "predefined") {
      MenuItem({
        content: item.text ?? "",
        labelInfo: item.accelerator,
        symbolStartIcon: this.nativeIconSymbol(item.nativeIcon),
      })
        .enabled(item.enabled ?? true)
        .onClick(() => {
          this.itemClick(item);
        });
    } else if (item.type === "check") {
      MenuItem({
        content: item.text ?? "",
        labelInfo: item.accelerator,
        symbolStartIcon: this.nativeIconSymbol(item.nativeIcon),
      })
        .enabled(item.enabled ?? true)
        .selectIcon(true)
        .selected(item.checked ?? false)
        .onChange((checked: boolean) => {
          item.checked = checked;
          this.itemClick(item);
        });
    } else if (item.type === "icon") {
      MenuItem({
        content: item.text ?? "",
        labelInfo: item.accelerator,
        symbolStartIcon: this.nativeIconSymbol(item.nativeIcon),
      })
        .enabled(item.enabled ?? true)
        .onClick(() => {
          this.itemClick(item);
        });
    } else if (item.type === "submenu") {
      MenuItem({
        content: item.text ?? "",
        symbolStartIcon: this.nativeIconSymbol(item.nativeIcon),
        builder: () => this.SubmenuContent(item.submenuItems ?? []),
      }).enabled(item.enabled ?? true);
    }
  }

  @Builder
  SubmenuContent(items: MenuItemData[]) {
    Menu() {
      ForEach(items, (item: MenuItemData) => {
        this.buildMenuItem(item);
      })
    };
  }

  itemClick(item: MenuItemData) {
    this.isShown = false;
    this.onItemClick(item);
  }
}
