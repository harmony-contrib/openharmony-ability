export { MenuPlugin } from "./src/main/ets/MenuPlugin";

// Menu UI cluster, migrated from the core package (rs<->ets correspondence:
// crates/plugin-menu ↔ this package). Exported for cross-package consumers
// (e.g. the statusbar plugin's menu-item helpers) and for apps embedding the
// menubar directly.
export { MenuBarComponent } from "./src/main/ets/MenuBarComponent";
export {
  setMenuClickHandler,
  getMenuClickHandler,
  unregisterMenuClickHandler,
  setMenuBarRecoverFn,
  getMenuBarRecoverFn,
  unregisterMenuBarRecoverFn,
  getMenuDataCallback,
  registerMenuDataCallback,
  unregisterMenuDataCallback,
  windowKeyForId,
  isMenubarVisible,
} from "./src/main/ets/MenuBarComponent";
export type { MenuDataCallback } from "./src/main/ets/MenuBarComponent";
// MenuPopup.ets ships unreferenced, exactly as in the core package before the
// split (nothing imported it and the core index never exported it) — the file
// migrates verbatim, so its unexported status migrates too.
export {
  setPredefinedActionExecutor,
  getPredefinedActionExecutor,
  PredefinedActionExecutor,
  MenuManager,
} from "./src/main/ets/menu";
export {
  AcceleratorMatcher,
  getAcceleratorMatcher,
  unregisterAcceleratorMatcher,
} from "./src/main/ets/accelerator_matcher";
export type {
  MenuItemData,
  AboutMetadataData,
  PredefinedType,
  MenuCreateOptions,
  MenuItemCreateOptions,
  SubmenuCreateOptions,
  ContextMenuHandle,
  MenuEventCallback,
} from "./src/main/ets/menu_types";
