import web_webview from "@ohos.web.webview";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { BusinessError } from "@kit.BasicServicesKit";
import { DOMAIN } from "./constants";

// ─── ohos-webview-key-synthesis ──────────────────────────────────────────────
//
// ArkWeb on OHOS routes physical-keyboard text through the IME insertion
// pipeline (device-verified 2026-08-28): DOM keydown fires once per physical
// press with EMPTY key/code, auto-repeat never reaches the DOM as repeated
// keydowns (only as IME text insertions — preventDefault cannot stop them),
// and every repeat cycle synthesizes a degenerate keydown/keyup pair with no
// identity. Front-end key handling (e.repeat, e.code matching, games, hotkey
// libraries) is therefore structurally broken on ArkWeb.
//
// MainPage.onKeyPreIme receives CLEAN auto-repeat: consecutive Down events
// carrying keyCode (~51ms interval, no interleaved Up — device-verified).
// This helper converts those pre-IME events into synthetic DOM
// KeyboardEvents dispatched into the webview, and the injected shim
// (KEY_SYNTHESIS_SHIM) suppresses ArkWeb's degenerate native key events so
// the page sees one consistent synthetic stream.
//
// Registry direction: WebviewPlugin (plugin package) cannot be imported by
// native_ability (dependency direction is plugin -> native_ability), so the
// webview plugin pushes its controllers in via notifyKeySynthesisController —
// same pattern as notifyPrimaryWebviewController / setPredefinedActionExecutor.

interface DomKeyInfo {
  /** DOM KeyboardEvent.code (e.g. "KeyJ", "ArrowLeft") */
  code: string;
  /** DOM KeyboardEvent.key (e.g. "j", "Enter"); letters are lowercased, shift applied at dispatch */
  key: string;
  /** Legacy DOM keyCode (e.which-compatible) */
  keyCode: number;
  /** DOM KeyLocation: 0 standard, 1 left, 2 right, 3 numpad */
  location: number;
}

interface ModifierState {
  ctrl: boolean;
  shift: boolean;
  alt: boolean;
  meta: boolean;
}

/** windowId -> attached webview controller (fed by WebviewPlugin.handleControllerAttached) */
const controllers: Map<number, web_webview.WebviewController> = new Map();

/** Keys currently held — repeat = Down for an already-held key (mirrors tao's PRESSED_KEYS). */
const pressedKeys: Set<number> = new Set();

/**
 * Keys whose keydown was actually dispatched. Gates keyup pairing: an Up for
 * a key whose Down was consumed by an onKeyPreIme interceptor (accelerator /
 * clipboard / ESC) must not emit an orphan keyup into the page.
 */
const dispatchedKeys: Set<number> = new Set();

/** Modifier state tracked from the key stream itself (self-contained — getModifierKeyState's return shape is ambiguous). */
const modState: ModifierState = { ctrl: false, shift: false, alt: false, meta: false };

const CTRL_KEYS: Set<number> = new Set([2072, 2073]); // KEYCODE_CTRL_LEFT / RIGHT
const SHIFT_KEYS: Set<number> = new Set([2047, 2048]); // KEYCODE_SHIFT_LEFT / RIGHT
const ALT_KEYS: Set<number> = new Set([2045, 2046]); // KEYCODE_ALT_LEFT / RIGHT
const META_KEYS: Set<number> = new Set([2076, 2077]); // KEYCODE_META_LEFT / RIGHT

const LETTERS: string = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

/**
 * Page-side shim injected via javaScriptOnDocumentStart (main-window webviews
 * only). Suppresses ArkWeb's degenerate native keydown/keyup (empty identity,
 * phantom repeat pairs) at window capture phase so only the synthetic stream
 * from this helper reaches page listeners.
 *
 * Suppression stops propagation only — ArkWeb's internal default actions
 * (IME text insertion) are unaffected (stopImmediatePropagation does not
 * preventDefault), so typing keeps working while listeners see clean events.
 */
export const KEY_SYNTHESIS_SHIM: string =
  "(function(){" +
  "if(window.__ohosKeySynthesis){return;}" +
  "window.__ohosKeySynthesis=true;" +
  '["keydown","keyup"].forEach(function(type){' +
  "window.addEventListener(type,function(e){" +
  "if(!e.__ohosSynthetic){e.stopImmediatePropagation();}" +
  "},true);});" +
  "})();";

/**
 * ohos keyCode (multimodalInput.keyCode enum) -> DOM key info.
 * Special keys table; letters/digits/F-keys/numpad digits resolved by range
 * (contiguous in the ohos enum: A=2017..Z=2042, 0=2000..9=2009,
 * F1=2090..F12=2101, Numpad0=2103..Numpad9=2112).
 */
const SPECIAL_KEYS: Map<number, DomKeyInfo> = new Map();
SPECIAL_KEYS.set(2012, { code: "ArrowUp", key: "ArrowUp", keyCode: 38, location: 0 });
SPECIAL_KEYS.set(2013, { code: "ArrowDown", key: "ArrowDown", keyCode: 40, location: 0 });
SPECIAL_KEYS.set(2014, { code: "ArrowLeft", key: "ArrowLeft", keyCode: 37, location: 0 });
SPECIAL_KEYS.set(2015, { code: "ArrowRight", key: "ArrowRight", keyCode: 39, location: 0 });
SPECIAL_KEYS.set(2043, { code: "Comma", key: ",", keyCode: 188, location: 0 });
SPECIAL_KEYS.set(2044, { code: "Period", key: ".", keyCode: 190, location: 0 });
SPECIAL_KEYS.set(2045, { code: "AltLeft", key: "Alt", keyCode: 18, location: 1 });
SPECIAL_KEYS.set(2046, { code: "AltRight", key: "Alt", keyCode: 18, location: 2 });
SPECIAL_KEYS.set(2047, { code: "ShiftLeft", key: "Shift", keyCode: 16, location: 1 });
SPECIAL_KEYS.set(2048, { code: "ShiftRight", key: "Shift", keyCode: 16, location: 2 });
SPECIAL_KEYS.set(2049, { code: "Tab", key: "Tab", keyCode: 9, location: 0 });
SPECIAL_KEYS.set(2050, { code: "Space", key: " ", keyCode: 32, location: 0 });
SPECIAL_KEYS.set(2054, { code: "Enter", key: "Enter", keyCode: 13, location: 0 });
SPECIAL_KEYS.set(2055, { code: "Backspace", key: "Backspace", keyCode: 8, location: 0 });
SPECIAL_KEYS.set(2056, { code: "Backquote", key: "`", keyCode: 192, location: 0 });
SPECIAL_KEYS.set(2057, { code: "Minus", key: "-", keyCode: 189, location: 0 });
SPECIAL_KEYS.set(2058, { code: "Equal", key: "=", keyCode: 187, location: 0 });
SPECIAL_KEYS.set(2059, { code: "BracketLeft", key: "[", keyCode: 219, location: 0 });
SPECIAL_KEYS.set(2060, { code: "BracketRight", key: "]", keyCode: 221, location: 0 });
SPECIAL_KEYS.set(2061, { code: "Backslash", key: "\\", keyCode: 220, location: 0 });
SPECIAL_KEYS.set(2062, { code: "Semicolon", key: ";", keyCode: 186, location: 0 });
SPECIAL_KEYS.set(2063, { code: "Quote", key: "'", keyCode: 222, location: 0 });
SPECIAL_KEYS.set(2064, { code: "Slash", key: "/", keyCode: 191, location: 0 });
SPECIAL_KEYS.set(2068, { code: "PageUp", key: "PageUp", keyCode: 33, location: 0 });
SPECIAL_KEYS.set(2069, { code: "PageDown", key: "PageDown", keyCode: 34, location: 0 });
SPECIAL_KEYS.set(2070, { code: "Escape", key: "Escape", keyCode: 27, location: 0 });
SPECIAL_KEYS.set(2071, { code: "Delete", key: "Delete", keyCode: 46, location: 0 });
SPECIAL_KEYS.set(2072, { code: "ControlLeft", key: "Control", keyCode: 17, location: 1 });
SPECIAL_KEYS.set(2073, { code: "ControlRight", key: "Control", keyCode: 17, location: 2 });
SPECIAL_KEYS.set(2074, { code: "CapsLock", key: "CapsLock", keyCode: 20, location: 0 });
SPECIAL_KEYS.set(2075, { code: "ScrollLock", key: "ScrollLock", keyCode: 145, location: 0 });
SPECIAL_KEYS.set(2076, { code: "MetaLeft", key: "Meta", keyCode: 91, location: 1 });
SPECIAL_KEYS.set(2077, { code: "MetaRight", key: "Meta", keyCode: 93, location: 2 });
SPECIAL_KEYS.set(2081, { code: "Home", key: "Home", keyCode: 36, location: 0 });
SPECIAL_KEYS.set(2082, { code: "End", key: "End", keyCode: 35, location: 0 });
SPECIAL_KEYS.set(2083, { code: "Insert", key: "Insert", keyCode: 45, location: 0 });
SPECIAL_KEYS.set(2102, { code: "NumLock", key: "NumLock", keyCode: 144, location: 0 });
SPECIAL_KEYS.set(2113, { code: "NumpadDivide", key: "/", keyCode: 111, location: 3 });
SPECIAL_KEYS.set(2114, { code: "NumpadMultiply", key: "*", keyCode: 106, location: 3 });
SPECIAL_KEYS.set(2115, { code: "NumpadSubtract", key: "-", keyCode: 109, location: 3 });
SPECIAL_KEYS.set(2116, { code: "NumpadAdd", key: "+", keyCode: 107, location: 3 });
SPECIAL_KEYS.set(2117, { code: "NumpadDecimal", key: ".", keyCode: 110, location: 3 });
SPECIAL_KEYS.set(2118, { code: "NumpadComma", key: ",", keyCode: 110, location: 3 });
SPECIAL_KEYS.set(2119, { code: "NumpadEnter", key: "Enter", keyCode: 13, location: 3 });
SPECIAL_KEYS.set(2120, { code: "NumpadEqual", key: "=", keyCode: 187, location: 3 });

function domKeyInfoOf(keyCode: number): DomKeyInfo | null {
  if (keyCode >= 2017 && keyCode <= 2042) {
    const index = keyCode - 2017;
    const letter = LETTERS.charAt(index);
    return { code: "Key" + letter, key: letter.toLowerCase(), keyCode: 65 + index, location: 0 };
  }
  if (keyCode >= 2000 && keyCode <= 2009) {
    const digit = keyCode - 2000;
    return { code: "Digit" + digit, key: String(digit), keyCode: 48 + digit, location: 0 };
  }
  if (keyCode >= 2090 && keyCode <= 2101) {
    const n = keyCode - 2090 + 1;
    const name = "F" + n;
    return { code: name, key: name, keyCode: 112 + n - 1, location: 0 };
  }
  if (keyCode >= 2103 && keyCode <= 2112) {
    const digit = keyCode - 2103;
    return { code: "Numpad" + digit, key: String(digit), keyCode: 96 + digit, location: 3 };
  }
  return SPECIAL_KEYS.get(keyCode) ?? null;
}

function updateModifiers(keyCode: number, down: boolean): void {
  if (CTRL_KEYS.has(keyCode)) {
    modState.ctrl = down;
  }
  if (SHIFT_KEYS.has(keyCode)) {
    modState.shift = down;
  }
  if (ALT_KEYS.has(keyCode)) {
    modState.alt = down;
  }
  if (META_KEYS.has(keyCode)) {
    modState.meta = down;
  }
}

function buildDispatchScript(type: string, dom: DomKeyInfo, repeat: boolean): string {
  // Shift+letter -> uppercase DOM key (best-effort: shifted digits/symbols
  // are layout-dependent and stay unshifted — documented limitation).
  const key =
    modState.shift && dom.key.length === 1 && dom.key >= "a" && dom.key <= "z"
      ? dom.key.toUpperCase()
      : dom.key;
  return (
    "(function(){" +
    "var t=document.activeElement||document.body;if(!t){return;}" +
    "var e=new KeyboardEvent(" +
    JSON.stringify(type) +
    "," +
    "{key:" +
    JSON.stringify(key) +
    ",code:" +
    JSON.stringify(dom.code) +
    "," +
    "bubbles:true,cancelable:true,composed:true,repeat:" +
    repeat +
    "," +
    "location:" +
    dom.location +
    "," +
    "ctrlKey:" +
    modState.ctrl +
    ",shiftKey:" +
    modState.shift +
    "," +
    "altKey:" +
    modState.alt +
    ",metaKey:" +
    modState.meta +
    "," +
    "keyCode:" +
    dom.keyCode +
    ",which:" +
    dom.keyCode +
    ",charCode:0});" +
    "Object.defineProperty(e,'__ohosSynthetic',{value:true});" +
    "try{Object.defineProperty(e,'isTrusted',{get:function(){return true;}});}catch(err){}" +
    "t.dispatchEvent(e);})();"
  );
}

function dispatchKeyEvent(
  type: string,
  keyCode: number,
  repeat: boolean,
  windowId: number,
): boolean {
  const controller = controllers.get(windowId);
  if (!controller) {
    return false;
  }
  const dom = domKeyInfoOf(keyCode);
  if (!dom) {
    // Unmapped key (media keys etc.): no DOM equivalent — skip dispatch, but
    // the pressed-set is still maintained by the caller.
    return false;
  }
  controller
    .runJavaScript(buildDispatchScript(type, dom, repeat))
    .then(() => {
      // Fire-and-forget; success is silent to avoid per-event log spam at
      // ~20Hz during auto-repeat.
    })
    .catch((err: BusinessError) => {
      hilog.warn(DOMAIN, "KeySynthesis", "runJavaScript failed: %{public}s", String(err));
    });
  return true;
}

/**
 * Entry point wired into MainPage.onKeyPreIme (fall-through path only — the
 * interceptor branches above return early, so consumed accelerators never
 * reach the page). Maintains the pressed/dispatched sets and dispatches a
 * synthetic DOM KeyboardEvent into the window's webview.
 */
export function synthesizeDomKeyEvent(event: KeyEvent, windowId: number): void {
  const keyCode = event.keyCode;
  if (event.type === KeyType.Down) {
    // Modifier state first: the modifier's own keydown reports it as pressed
    // (browser semantics), and later letter keys read the live state.
    updateModifiers(keyCode, true);
    const repeat = pressedKeys.has(keyCode);
    pressedKeys.add(keyCode);
    if (dispatchKeyEvent("keydown", keyCode, repeat, windowId)) {
      dispatchedKeys.add(keyCode);
    }
  } else if (event.type === KeyType.Up) {
    // Clear modifier state first: the modifier's own keyup reports it as
    // released (browser semantics).
    updateModifiers(keyCode, false);
    pressedKeys.delete(keyCode);
    if (dispatchedKeys.delete(keyCode)) {
      dispatchKeyEvent("keyup", keyCode, false, windowId);
    }
  }
}

/** Controller registry feed — called by WebviewPlugin.handleControllerAttached (all windows incl. main). */
export function notifyKeySynthesisController(
  windowId: number,
  controller: web_webview.WebviewController,
): void {
  controllers.set(windowId, controller);
}
