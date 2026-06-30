import { MenuItemData, MenuManager } from '../helper/menu';

@Component
export struct MenuPopup {
  @Prop items: MenuItemData[];
  @Prop offset: Position;
  @Prop onItemClick: (item: MenuItemData) => void;
  @Prop onDisappear: () => void;
  @State isShown: boolean = true;

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
        }
      })
  }

  @Builder
  MenuContent() {
    Menu() {
      ForEach(this.items, (item: MenuItemData) => {
        this.buildMenuItem(item);
      });
    }
  }

  @Builder
  buildMenuItem(item: MenuItemData) {
    if (item.type === 'separator') {
      MenuDivider()
    } else if (item.type === 'item' || item.type === 'predefined') {
      MenuItem({ content: item.text ?? '', labelInfo: item.accelerator })
        .enabled(item.enabled ?? true)
        .onClick(() => {
          this.itemClick(item);
        });
    } else if (item.type === 'check') {
      MenuItem({ content: item.text ?? '' })
        .enabled(item.enabled ?? true)
        .type(MenuItemType.Check)
        .checked(item.checked ?? false)
        .onChange((checked: boolean) => {
          item.checked = checked;
          this.itemClick(item);
        });
    } else if (item.type === 'icon') {
      MenuItem({ content: item.text ?? '', labelInfo: item.accelerator })
        .enabled(item.enabled ?? true)
        .onClick(() => {
          this.itemClick(item);
        });
    } else if (item.type === 'submenu') {
      MenuItem({ 
        content: item.text ?? '',
        builder: () => this.SubmenuContent(item.submenuItems ?? [])
      });
    }
  }

  @Builder
  SubmenuContent(items: MenuItemData[]) {
    Menu() {
      ForEach(items, (item: MenuItemData) => {
        this.buildMenuItem(item);
      });
    }
  }

  itemClick(item: MenuItemData) {
    this.isShown = false;
    this.onItemClick(item);
  }
}