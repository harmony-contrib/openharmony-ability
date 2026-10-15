import { MenuItemData } from "./menu_types";
import { KeyCode } from "@kit.InputKit";

// NOTE: the per-window clipboard / zoom-hotkey flags that used to live here moved
// to the core window layer (native_ability/src/main/ets/helper/window_flags.ets):
// they are window-builder configuration set only by WindowManager.setWebviewFlags,
// so they must not live in (nor be imported from) the menu package. The menu
// plugin's key port reads them through the "@ohos-rs/ability" barrel.

// Per-window matcher registry. Each window's MenuBarComponent owns one matcher
// (rebuilt in place when that window's menubar data changes) and the key port
// looks the same instance up by windowId — this preserves the per-window
// accelerator scoping the core pages used to own as private fields. MenuBarComponent
// unregisters its entry in aboutToDisappear, mirroring its other registries.
const windowMatchers: Map<number, AcceleratorMatcher> = new Map();

export function getAcceleratorMatcher(windowId: number): AcceleratorMatcher {
  let matcher = windowMatchers.get(windowId);
  if (!matcher) {
    matcher = new AcceleratorMatcher();
    windowMatchers.set(windowId, matcher);
  }
  return matcher;
}

export function unregisterAcceleratorMatcher(windowId: number): void {
  windowMatchers.delete(windowId);
}

export function resetAcceleratorModifiers(windowId: number): void {
  windowMatchers.get(windowId)?.resetModifiers();
}

const SPECIAL_KEY_MAP: Map<string, string> = new Map([
  ["Escape", "Esc"],
  ["KEYCODE_ESCAPE", "Esc"],
  ["Delete", "Del"],
  ["KEYCODE_DELETE", "Del"],
  ["Insert", "Ins"],
  ["KEYCODE_INSERT", "Ins"],
  ["PageUp", "PgUp"],
  ["KEYCODE_PAGE_UP", "PgUp"],
  ["PageDown", "PgDn"],
  ["KEYCODE_PAGE_DOWN", "PgDn"],
  ["Enter", "Enter"],
  ["KEYCODE_ENTER", "Enter"],
  ["Space", "Space"],
  ["KEYCODE_SPACE", "Space"],
  ["Tab", "Tab"],
  ["KEYCODE_TAB", "Tab"],
  ["Backquote", "`"],
  ["KEYCODE_BACKQUOTE", "`"],
]);

// OHOS modifier keyCode constants — these arrive as separate key events
// and should NOT be treated as accelerator key candidates
const MODIFIER_KEYCODES: Set<number> = new Set([
  2072, // KEYCODE_CTRL_LEFT
  2073, // KEYCODE_CTRL_RIGHT
  2047, // KEYCODE_SHIFT_LEFT
  2048, // KEYCODE_SHIFT_RIGHT
  2045, // KEYCODE_ALT_LEFT
  2046, // KEYCODE_ALT_RIGHT
  2076, // KEYCODE_META_LEFT
  2077, // KEYCODE_META_RIGHT
]);

// The menu port uses these to preserve WebView editing policy. Matching itself
// is independent of the window's renderer.
const CLIPBOARD_ACCELERATORS: Set<string> = new Set([
  "ctrl+c", // copy
  "ctrl+x", // cut
  "ctrl+v", // paste
  "ctrl+a", // selectAll
  "ctrl+z", // undo
  "ctrl+y", // redo
]);

// Used only when ArkUI supplies a key name/empty text instead of a character.
// A printable keyText always takes precedence, including non-US layouts.
const SHIFTED_KEYS: Map<string, string> = new Map([
  ["1", "!"],
  ["2", "@"],
  ["3", "#"],
  ["4", "$"],
  ["5", "%"],
  ["6", "^"],
  ["7", "&"],
  ["8", "*"],
  ["9", "("],
  ["0", ")"],
  ["-", "_"],
  ["=", "+"],
  ["[", "{"],
  ["]", "}"],
  ["\\", "|"],
  [";", ":"],
  ["'", '"'],
  [",", "<"],
  [".", ">"],
  ["/", "?"],
  ["`", "~"],
]);
const SHIFTED_CHARACTERS: Set<string> = new Set(SHIFTED_KEYS.values());

export class AcceleratorMatcher {
  private accelerators: Map<string, MenuItemData> = new Map();
  private matchedItem: MenuItemData | null = null;
  private pressedModifiers: Set<number> = new Set();

  trackModifiers(event: KeyEvent): void {
    if (!MODIFIER_KEYCODES.has(event.keyCode)) {
      return;
    }
    if (event.type === KeyType.Down) {
      this.pressedModifiers.add(event.keyCode);
    } else if (event.type === KeyType.Up) {
      this.pressedModifiers.delete(event.keyCode);
    }
  }

  resetModifiers(): void {
    this.pressedModifiers.clear();
  }

  buildFromItems(items: MenuItemData[]): void {
    this.accelerators.clear();
    const queue: MenuItemData[] = [...items];
    while (queue.length > 0) {
      const item = queue.shift()!;
      if (item.enabled === false) {
        continue;
      }
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
    return accel.toLowerCase().replace("pgup", "pageup").replace("pgdn", "pagedown");
  }

  matches(event: KeyEvent): boolean {
    this.matchedItem = null;
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
    const shift = this.isModifierPressed(event, "Shift");
    const candidates: string[] = [keyText];
    if (shift && this.printableKeyText(event) === null) {
      const shifted = SHIFTED_KEYS.get(keyText);
      if (shifted) {
        candidates.unshift(shifted);
      }
    }
    for (const key of candidates) {
      if (this.matchKey(event, key, shift)) {
        return true;
      }
    }
    // Logical accelerators such as Ctrl++ may omit the Shift used to type +.
    // An explicitly registered Shift chord always wins over this fallback.
    if (shift) {
      for (const key of candidates) {
        if (SHIFTED_CHARACTERS.has(key) && this.matchKey(event, key, false)) {
          return true;
        }
      }
    }
    return false;
  }

  private matchKey(event: KeyEvent, key: string, shift: boolean): boolean {
    let combo = "";
    if (this.isModifierPressed(event, "Ctrl")) combo += "ctrl+";
    if (shift) combo += "shift+";
    if (this.isModifierPressed(event, "Alt")) combo += "alt+";
    if (this.isModifierPressed(event, "Super")) combo += "super+";
    this.matchedItem = this.accelerators.get(combo + key.toLowerCase()) ?? null;
    return this.matchedItem !== null;
  }

  private isModifierPressed(event: KeyEvent, modifier: string): boolean {
    // ArkUI accepts Ctrl/Shift/Alt here; Super is tracked from physical events.
    // A rejected snapshot must not abort WebView key forwarding.
    if (modifier !== "Super") {
      try {
        if (event.getModifierKeyState?.([modifier])) {
          return true;
        }
      } catch {
        // Physical Down/Up tracking remains available below.
      }
    }
    // Some ArkUI function-key events lose the modifier snapshot: on this
    // emulator Alt Down reports true, but the following F4 reports false.
    // Keep the physical Down/Up sequence per window, cleared on focus loss.
    switch (modifier) {
      case "Ctrl":
        return this.pressedModifiers.has(2072) || this.pressedModifiers.has(2073);
      case "Shift":
        return this.pressedModifiers.has(2047) || this.pressedModifiers.has(2048);
      case "Alt":
        return this.pressedModifiers.has(2045) || this.pressedModifiers.has(2046);
      case "Super":
        return this.pressedModifiers.has(2076) || this.pressedModifiers.has(2077);
      default:
        return false;
    }
  }

  getMatchedItem(): MenuItemData | null {
    return this.matchedItem;
  }

  /**
   * Returns true if the key event is a clipboard accelerator (Ctrl+C/X/V/A/Z/Y).
   * Used by onKeyPreIme to block native clipboard shortcuts when with_clipboard(false).
   * Includes modified variants so disabling WebView editing also blocks those.
   * The menu port, rather than the matcher, decides whether this policy applies.
   */
  matchesClipboardShortcut(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (MODIFIER_KEYCODES.has(event.keyCode)) {
      return false;
    }
    const keyText = this.getKeyText(event);
    if (!keyText) {
      return false;
    }
    let combo = "";
    if (this.isModifierPressed(event, "Ctrl")) combo += "ctrl+";
    combo += keyText.toLowerCase();
    return CLIPBOARD_ACCELERATORS.has(combo);
  }

  matchesNativeClipboardShortcut(event: KeyEvent): boolean {
    return (
      this.matchesClipboardShortcut(event) &&
      !this.isModifierPressed(event, "Shift") &&
      !this.isModifierPressed(event, "Alt") &&
      !this.isModifierPressed(event, "Super")
    );
  }

  /**
   * Returns true if the key event is a zoom hotkey (Ctrl+=/-/0, incl. KEYCODE_* forms).
   * Used by onKeyPreIme to block native zoom when with_zoom_hotkeys(false).
   * See ohos-webview-flag-zoom-hotkeys spec.
   */
  matchesZoomShortcut(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (MODIFIER_KEYCODES.has(event.keyCode)) {
      return false;
    }
    if (!this.isModifierPressed(event, "Ctrl")) {
      return false;
    }
    const keyText = this.getKeyText(event);
    if (!keyText) {
      return false;
    }
    const k = keyText.toLowerCase();
    return k === "+" || k === "=" || k === "0" || k === "-" || k === "equals" || k === "minus";
  }

  private printableKeyText(event: KeyEvent): string | null {
    const text = event.keyText;
    if (text && Array.from(text).length === 1 && text.charCodeAt(0) >= 32 && text !== "\u007f") {
      return text === " " ? "Space" : text;
    }
    return null;
  }

  private getKeyText(event: KeyEvent): string | null {
    const character = this.printableKeyText(event);
    if (character !== null) {
      return character;
    }
    // Ctrl chords may have an empty, symbolic or control-character keyText.
    if (event.keyCode >= KeyCode.KEYCODE_A && event.keyCode <= KeyCode.KEYCODE_Z) {
      return String.fromCharCode(97 + event.keyCode - KeyCode.KEYCODE_A);
    }
    if (event.keyCode >= KeyCode.KEYCODE_0 && event.keyCode <= KeyCode.KEYCODE_9) {
      return String(event.keyCode - KeyCode.KEYCODE_0);
    }
    if (event.keyCode >= KeyCode.KEYCODE_F1 && event.keyCode <= KeyCode.KEYCODE_F12) {
      return `f${event.keyCode - KeyCode.KEYCODE_F1 + 1}`;
    }
    switch (event.keyCode) {
      case KeyCode.KEYCODE_DPAD_LEFT:
        return "left";
      case KeyCode.KEYCODE_DPAD_RIGHT:
        return "right";
      case KeyCode.KEYCODE_DPAD_UP:
        return "up";
      case KeyCode.KEYCODE_DPAD_DOWN:
        return "down";
      case KeyCode.KEYCODE_PAGE_UP:
        return "pageup";
      case KeyCode.KEYCODE_PAGE_DOWN:
        return "pagedown";
      case KeyCode.KEYCODE_TAB:
        return "tab";
      case KeyCode.KEYCODE_ESCAPE:
        return "esc";
      case KeyCode.KEYCODE_FORWARD_DEL:
        return "del";
      case KeyCode.KEYCODE_DEL:
        return "backspace";
      case KeyCode.KEYCODE_INSERT:
        return "ins";
      case KeyCode.KEYCODE_MOVE_HOME:
        return "home";
      case KeyCode.KEYCODE_MOVE_END:
        return "end";
      case KeyCode.KEYCODE_ENTER:
        return "enter";
      case KeyCode.KEYCODE_SPACE:
        return "space";
      case KeyCode.KEYCODE_MINUS:
        return "-";
      case KeyCode.KEYCODE_EQUALS:
        return "=";
      case KeyCode.KEYCODE_LEFT_BRACKET:
        return "[";
      case KeyCode.KEYCODE_RIGHT_BRACKET:
        return "]";
      case KeyCode.KEYCODE_SLASH:
        return "/";
      case KeyCode.KEYCODE_BACKSLASH:
        return "\\";
      case KeyCode.KEYCODE_SEMICOLON:
        return ";";
      case KeyCode.KEYCODE_APOSTROPHE:
        return "'";
      case KeyCode.KEYCODE_COMMA:
        return ",";
      case KeyCode.KEYCODE_PERIOD:
        return ".";
      case KeyCode.KEYCODE_GRAVE:
        return "`";
    }
    const text = event.keyText;
    if (!text || text.charCodeAt(0) < 32) {
      return null;
    }
    if (SPECIAL_KEY_MAP.has(text)) {
      return SPECIAL_KEY_MAP.get(text)!;
    }
    // OHOS returns keyText as KEYCODE_* format (e.g. "KEYCODE_O")
    // Strip prefix and normalize to simple key letter
    if (text.startsWith("KEYCODE_")) {
      const raw = text.substring("KEYCODE_".length);
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
