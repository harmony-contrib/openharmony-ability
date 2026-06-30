import { MenuItemData } from './menu_types';

export interface MenuOffset {
  x: number;
  y: number;
}

export interface MenuState {
  isShown: boolean;
  menuId: string;
  items: MenuItemData[];
  offset: MenuOffset;
  onDisappear?: () => void;
}

export class MenuStateController {
  private state: MenuState = {
    isShown: false,
    menuId: '',
    items: [],
    offset: { x: 0, y: 0 },
  };

  private stateChangeCallbacks: Set<(state: MenuState) => void> = new Set();

  getState(): MenuState {
    const s = this.state;
    return {
      isShown: s.isShown,
      menuId: s.menuId,
      items: s.items,
      offset: { x: s.offset.x, y: s.offset.y },
      onDisappear: s.onDisappear,
    };
  }

  subscribe(callback: (state: MenuState) => void): () => void {
    this.stateChangeCallbacks.add(callback);
    return () => {
      this.stateChangeCallbacks.delete(callback);
    };
  }

  private notifyStateChange(): void {
    const state = this.getState();
    this.stateChangeCallbacks.forEach(cb => cb(state));
  }

  showMenu(menuId: string, items: MenuItemData[], x: number, y: number): void {
    const newState: MenuState = {
      isShown: true,
      menuId,
      items,
      offset: { x, y },
    };
    this.state = newState;
    this.notifyStateChange();
  }

  hideMenu(): void {
    const s = this.state;
    const newState: MenuState = {
      isShown: false,
      menuId: s.menuId,
      items: s.items,
      offset: s.offset,
      onDisappear: s.onDisappear,
    };
    this.state = newState;
    this.notifyStateChange();
  }

  updateItems(items: MenuItemData[]): void {
    const s = this.state;
    const newState: MenuState = {
      isShown: s.isShown,
      menuId: s.menuId,
      items,
      offset: s.offset,
      onDisappear: s.onDisappear,
    };
    this.state = newState;
    this.notifyStateChange();
  }
}
