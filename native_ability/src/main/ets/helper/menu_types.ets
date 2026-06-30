/**
 * Menu module type definitions
 */
import { SymbolGlyphModifier } from '@kit.ArkUI';

export interface MenuItemData {
  id: string;
  type: 'item' | 'separator' | 'submenu' | 'predefined' | 'check' | 'icon';
  text?: string;
  enabled?: boolean;
  accelerator?: string;
  predefinedType?: PredefinedType;
  checked?: boolean;
  icon?: string;
  nativeIcon?: string;
  submenuItems?: MenuItemData[];
  aboutMetadata?: AboutMetadataData;
}

export interface AboutMetadataData {
  name?: string;
  version?: string;
  shortVersion?: string;
  authors?: string[];
  comments?: string;
  copyright?: string;
  license?: string;
  website?: string;
}

/**
 * Predefined menu item types, which will be translated to system default menu items with 
 * corresponding actions.
 */
export type PredefinedType =
  | 'separator'
  | 'copy' | 'cut' | 'paste' | 'selectAll'
  | 'undo' | 'redo'
  | 'minimize' | 'maximize' | 'fullscreen' | 'recover' | 'restore' | 'destroyWindow' | 'close'
  | 'quit' | 'about' | 'hide' | 'hideOthers' | 'showAll'
  | 'services' | 'bringAllToFront' | 'none';

export interface MenuCreateOptions {
  id?: string;
  items?: MenuItemData[];
}

export interface MenuItemCreateOptions {
  id?: string;
  text: string;
  enabled?: boolean;
  accelerator?: string;
  startIcon?: ResourceStr;
  endIcon?: ResourceStr;
  symbolStartIcon?: SymbolGlyphModifier;
  symbolEndIcon?: SymbolGlyphModifier;
  selected?: boolean;
  selectIcon?: ResourceStr | SymbolGlyphModifier;
}

export interface SubmenuCreateOptions {
  id?: string;
  text: string;
  items?: MenuItemData[];
}

export interface ContextMenuHandle {
  popup: (x?: number, y?: number) => void;
  close: () => void;
}

export interface MenuEventCallback {
  onMenuClick: (menuId: string, itemId: string) => void;
}