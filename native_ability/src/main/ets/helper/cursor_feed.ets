/**
 * Shared cursor-position feed helper (ohos-cursor-passthrough D2).
 *
 * Both ArkUI hosts of runtime windows -- MainPage (main window) and SubWindowPage
 * (sub-windows) -- call {@link feedCursorFromMouse} from their root
 * `onMouse` (Move/Press) so EVERY window's mouse traffic updates the
 * process-level cursor snapshot. Root-cause-1 fix: SubWindowPage had no onMouse
 * at all, so a cursor over a sub-window left the snapshot at the last
 * main-window coordinate (the consumer's hit-test then never matched ->
 * `set_ignore_cursor_events` stayed true -> the whole toolbar was
 * unclickable).
 *
 * Root-cause-2 fix lives in the coordinate source below: the fed value is
 * the event's SCREEN-GLOBAL frame (`displayX`, or `globalDisplayX` on
 * API 20+), not the component-relative `event.x/y` the MainPage used to feed.
 * `cursor_position()` multiplies by scale -> screen-global physical px -- the
 * tao upstream semantic (Windows `GetCursorPos`).
 *
 * Single source of truth: coordinate extraction / guards / semantics comments
 * live ONLY here. The two pages must not inline any of it.
 *
 * Module-reference policy (D2): the helper does NOT read AppStorage. Each
 * caller passes its own module reference (MainPage: its own `this.nativeModule`
 * -- AppStorage is a process-global single value a spawned instance would
 * overwrite, see MainPage.ets:35-36 admonition; SubWindowPage: the same
 * `AppStorage.get(NATIVE_MODULE_STORAGE_KEY)` reference its other NAPI calls
 * already use, seeded process-wide by ProcessInitializer before any page
 * exists). NAPI spelling is camelCase (`updateCursorPosition`) -- the
 * `#[napi]` macro generates camelCase names (ohos-constraints section2.1).
 */
import { hilog } from "@kit.PerformanceAnalysisKit";
import { deviceInfo } from "@kit.BasicServicesKit";
import { Module } from "../ability/type";
import { DOMAIN } from "./constants";

/** Fixed hilog tag for feed traces -- the trace-gated assertions (tasks 1.2
 * seg 0 re-run phase / seg 5, 5.5 R2 arbitration) grep for this tag. */
const CURSOR_FEED_TAG = "cursor_feed";

/**
 * Feeds the process cursor snapshot from one ArkUI mouse event (best-effort).
 *
 * On any guard miss the snapshot is left untouched (non-finite fields never
 * overwrite the snapshot) and a `cursor_feed_skip`-tagged debug line explains
 * why -- skip lines never carry the `cursor_feed` tag so "no feed trace" stays
 * literal for the trace-greps (anchor them on `/cursor_feed:`, NOT the bare
 * `cursor_feed` substring, which also matches `cursor_feed_skip`).
 * Errors from the NAPI call are swallowed (cursor tracking is best-effort,
 * mirroring the MainPage status quo ante).
 */
export function feedCursorFromMouse(
  module: Module | null | undefined,
  event: MouseEvent,
): void {
  try {
    if (typeof module?.updateCursorPosition !== "function") {
      hilog.debug(
        DOMAIN,
        "cursor_feed_skip",
        "module guard miss: updateCursorPosition not a function",
      );
      return;
    }
    // Guard 2 -- version-select (D1 multi-display reserve): globalDisplayX
    // only exists (and only means "global display") since API 20.
    // Design-exact condition guards X; the generic finite validation in
    // guard 3 still validates the adopted pair, so a half-present
    // globalDisplayY (unreachable per D2) skips the feed instead of feeding
    // a mixed pair.
    let gx: number;
    let gy: number;
    let adoptedField: string;
    if (
      deviceInfo.sdkApiVersion >= 20 &&
      Number.isFinite(event.globalDisplayX)
    ) {
      gx = event.globalDisplayX;
      gy = event.globalDisplayY;
      adoptedField = "globalDisplayX";
    } else {
      gx = event.displayX;
      gy = event.displayY;
      adoptedField = "displayX";
    }
    // Guard 3 -- finite validation (D2): skip leaves the last snapshot in
    // place -- never poison it with NaN. The raw values of the ADOPTED
    // fields are logged (not fixed displayX/Y) so the line stays truthful
    // when globalDisplayX was adopted (audit round 1 minor).
    if (!Number.isFinite(gx) || !Number.isFinite(gy)) {
      const rawX =
        adoptedField === "globalDisplayX"
          ? event.globalDisplayX
          : event.displayX;
      const rawY =
        adoptedField === "globalDisplayX"
          ? event.globalDisplayY
          : event.displayY;
      hilog.debug(
        DOMAIN,
        "cursor_feed_skip",
        "coordinate guard miss: %{public}s=(%{public}s,%{public}s) not finite",
        adoptedField,
        String(rawX),
        String(rawY),
      );
      return;
    }
    module.updateCursorPosition(gx, gy);
    hilog.debug(
      DOMAIN,
      CURSOR_FEED_TAG,
      "feed %{public}s=(%{public}s,%{public}s)",
      adoptedField,
      String(gx),
      String(gy),
    );
  } catch (e) {
    // Silently ignore -- cursor tracking is best-effort (MainPage status quo).
  }
}
