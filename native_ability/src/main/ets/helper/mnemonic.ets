/**
 * Menu mnemonic stripping (issue Eulogizethesun/tauri#205 / C60).
 *
 * OHOS has no keyboard mnemonics, so `&` markers must not reach a rendered
 * menu label. muda's serializer deliberately keeps the raw text (`&` =
 * mnemonic marker, `&&` = escaped literal `&`) and the status-bar consumer
 * strips its own copy (tray-icon `strip_mnemonics`) — the ArkTS menu
 * components (MenuBarComponent, MenuPopup) are the menubar/popup consumers,
 * so they apply the identical semantics at their render points: single `&`
 * is dropped, `&&` collapses to one literal `&`.
 *
 * Display-only: the data model keeps the raw text — click routing keys on
 * item.id, accelerator matching on item.accelerator — and the
 * onMenubarJsonChange diagnostics log intentionally prints raw values (do
 * not misread raw text in the log as "not stripped"). Do NOT also strip in
 * muda's serializer: the tray path already strips, so a second strip there
 * would eat literal ampersands ("A&&B" → "AB").
 *
 * The \u0000 sentinel shields escaped `&&` pairs from the single-`&`
 * removal; muda's serialized labels cannot contain NUL, so it never leaks.
 */
const MNEMONIC_SENTINEL = "\u0000";

export function stripMnemonics(text: string): string {
  return text
    .replace(/&&/g, MNEMONIC_SENTINEL)
    .replace(/&/g, "")
    .replace(new RegExp(MNEMONIC_SENTINEL, "g"), "&");
}
