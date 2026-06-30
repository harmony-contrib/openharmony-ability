import { MenuItemData } from './menu_types';

const SPECIAL_KEY_MAP: Map<string, string> = new Map([
  ['Escape', 'Esc'],
  ['KEYCODE_ESCAPE', 'Esc'],
  ['Delete', 'Del'],
  ['KEYCODE_DELETE', 'Del'],
  ['Insert', 'Ins'],
  ['KEYCODE_INSERT', 'Ins'],
  ['PageUp', 'PgUp'],
  ['KEYCODE_PAGE_UP', 'PgUp'],
  ['PageDown', 'PgDn'],
  ['KEYCODE_PAGE_DOWN', 'PgDn'],
  ['Enter', 'Enter'],
  ['KEYCODE_ENTER', 'Enter'],
  ['Space', 'Space'],
  ['KEYCODE_SPACE', 'Space'],
  ['Tab', 'Tab'],
  ['KEYCODE_TAB', 'Tab'],
  ['Backquote', '`'],
  ['KEYCODE_BACKQUOTE', '`'],
]);

// OHOS modifier keyCode constants — these arrive as separate key events
// and should NOT be treated as accelerator key candidates
const MODIFIER_KEYCODES: Set<number> = new Set([
  2072, // KEYCODE_CTRL_LEFT
  2073, // KEYCODE_CTRL_RIGHT
  2074, // KEYCODE_SHIFT_LEFT
  2075, // KEYCODE_SHIFT_RIGHT
  2076, // KEYCODE_ALT_LEFT
  2077, // KEYCODE_ALT_RIGHT
  2078, // KEYCODE_META_LEFT
  2079, // KEYCODE_META_RIGHT
]);

// Clipboard accelerators handled natively by webview — intercepting them breaks paste/copy/cut
const CLIPBOARD_ACCELERATORS: Set<string> = new Set([
  'ctrl+c',   // copy
  'ctrl+x',   // cut
  'ctrl+v',   // paste
  'ctrl+a',   // selectAll
  'ctrl+z',   // undo
  'ctrl+y',   // redo
]);

export class AcceleratorMatcher {
  private accelerators: Map<string, MenuItemData> = new Map();
  private matchedItem: MenuItemData | null = null;

  buildFromItems(items: MenuItemData[]): void {
    this.accelerators.clear();
    const queue: MenuItemData[] = [...items];
    while (queue.length > 0) {
      const item = queue.shift()!;
      if (item.accelerator) {
        const keyCombo = this.normalizeAccelerator(item.accelerator);
        this.accelerators.set(keyCombo, item);
      }
      if (item.submenuItems) {
        queue.push(...item.submenuItems);
      }
    }
  }

  private normalizeAccelerator(accel: string): string {
    return accel.toLowerCase();
  }

  matches(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    // Skip modifier-only key events (Ctrl/Shift/Alt arrive separately)
    if (MODIFIER_KEYCODES.has(event.keyCode)) {
      return false;
    }
    const keyText = this.getKeyText(event);
    if (!keyText) {
      return false;
    }
    let combo = '';
    if (this.isModifierPressed(event, 'Ctrl')) combo += 'ctrl+';
    if (this.isModifierPressed(event, 'Shift')) combo += 'shift+';
    if (this.isModifierPressed(event, 'Alt')) combo += 'alt+';
    combo += keyText.toLowerCase();
    // Clipboard shortcuts handled natively by webview — don't intercept
    if (CLIPBOARD_ACCELERATORS.has(combo)) {
      return false;
    }
    console.info(`[Accelerator] combo="${combo}", available=[${Array.from(this.accelerators.keys()).join(',')}]`);
    if (this.accelerators.has(combo)) {
      this.matchedItem = this.accelerators.get(combo)!;
      return true;
    }
    return false;
  }

  private isModifierPressed(event: KeyEvent, modifier: string): boolean {
    if (!event.getModifierKeyState) {
      return false;
    }
    const result = event.getModifierKeyState([modifier]);
    if (typeof result === 'boolean') {
      return result;
    }
    if (result && typeof result === 'object') {
      return !!result[modifier];
    }
    return false;
  }

  getMatchedItem(): MenuItemData | null {
    return this.matchedItem;
  }

  private getKeyText(event: KeyEvent): string | null {
    const text = event.keyText;
    if (!text) {
      return null;
    }
    if (SPECIAL_KEY_MAP.has(text)) {
      return SPECIAL_KEY_MAP.get(text)!;
    }
    // OHOS returns keyText as KEYCODE_* format (e.g. "KEYCODE_O")
    // Strip prefix and normalize to simple key letter
    if (text.startsWith('KEYCODE_')) {
      const raw = text.substring('KEYCODE_'.length);
      // Single letter keys (A-Z, 0-9) → just the letter
      if (raw.length === 1) {
        return raw;
      }
      // Multi-part names like DPAD_UP, SPACE, ESCAPE → check SPECIAL_KEY_MAP first
      // then lowercase for general keys
      if (SPECIAL_KEY_MAP.has(text)) {
        return SPECIAL_KEY_MAP.get(text)!;
      }
      return raw;
    }
    return text;
  }
}