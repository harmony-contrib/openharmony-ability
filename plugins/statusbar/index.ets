export { StatusbarPlugin } from "./src/main/ets/StatusbarPlugin";

// Statusbar helpers, migrated from the core package (rs<->ets correspondence:
// crates/plugin-statusbar ↔ this package).
export {
  setAbilityContext,
  getAbilityContext,
  setCurrentAbilityName,
  CURRENT_ABILITY_NAME_KEY,
  createPixelMapFromRgba,
  createPixelMapFromRgbaWH,
  fillMenuItemAbilityName,
  processMenuItemIcons,
  reRegisterStatusBarClickHandlers,
} from "./src/main/ets/StatusBarUtils";
export type { StatusBarIconRgba } from "./src/main/ets/StatusBarUtils";
