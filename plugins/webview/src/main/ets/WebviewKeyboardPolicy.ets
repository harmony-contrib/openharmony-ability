import { KEY_SYNTHESIS_SHIM } from "@ohos-rs/ability";

export interface WebviewInitializationScript {
  script: string;
  scriptRules: string[];
}

/** Only legacy MainPage-hosted views have a paired pre-IME event synthesizer. */
export function usesLegacyWebviewKeyboard(
  nativeKeyboard: boolean,
  nativeTarget: number | null,
  windowId: number,
): boolean {
  return !nativeKeyboard && nativeTarget === null && windowId === 0;
}

export function webviewKeyboardScripts(
  base: WebviewInitializationScript[],
  legacyKeyboard: boolean,
): WebviewInitializationScript[] {
  if (!legacyKeyboard) return base;
  // Preserve custom protocol match patterns: an empty list matches no document.
  const rules: Set<string> = new Set();
  for (const item of base) {
    for (const rule of item.scriptRules) rules.add(rule);
  }
  if (rules.size === 0) rules.add("*");
  const shim: WebviewInitializationScript = {
    script: KEY_SYNTHESIS_SHIM,
    scriptRules: Array.from(rules),
  };
  return base.concat([shim]);
}
