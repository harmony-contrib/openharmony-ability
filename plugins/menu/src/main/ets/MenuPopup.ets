import { SymbolGlyphModifier } from "@kit.ArkUI";
import { MenuItemData } from "./menu";
@Component
export struct MenuPopup {
  @Prop items: MenuItemData[];
  @Prop offset: Position;
  @Prop onItemClick: (item: MenuItemData) => void;
  @Prop onDisappear: () => void;
  @State isShown: boolean = true;

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
