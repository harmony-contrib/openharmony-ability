import { NodeContent, SymbolGlyphModifier } from "@kit.ArkUI";
import resourceManager from "@ohos.resourceManager";
import { MenuItemData, MenuCreateOptions, MenuItemCreateOptions, SubmenuCreateOptions } from "../helper/menu_types";
import { image } from "@kit.ImageKit";
import { emitter } from "@kit.BasicServicesKit";

export interface ApplicationLifecycle {
  environmentCallback: EnvironmentCallback;
  windowStageEventCallback: WindowStageEventCallback;
  keyboardEventCallback: KeyboardCallback;
}

export interface EnvironmentCallback {
  onConfigurationUpdated: (arg: object) => void;
  onMemoryLevel: (arg: number) => void;
}

export interface KeyboardCallback {
  onKeyboardHeightChange: (height: number) => void;
}

// Must match napi-generated index.d.ts inline type for onNewWant
export interface NewWantData {
  uri: string;
  parametersJson: string;
}

export interface WindowStageEventCallback {
  onWindowStageCreate: () => void;
  onWindowStageDestroy: () => void;
  onAbilityCreate: (arg: string) => void;
  onAbilityDestroy: () => void;
  onAbilitySaveState: () => string;
  onWindowStageEvent: (arg: number) => void;
  onWindowSizeChange: (arg: object) => void;
  onWindowRectChange: (arg: object) => void;
  onAvoidAreaChange: (arg: object) => void;
  onNewWant: (data: NewWantData) => void;
}

export interface WebViewComponentEventCallback {
  onComponentCreated: () => void;
  onComponentDestroyed: () => void;
}

export interface OnDownloadStartResult {
  allow?: boolean;
  tempPath?: string;
}

export interface OnWindowNewResult {
  allow: boolean;
}

export interface WebViewInitData {
  url?: string;
  id?: string;
  windowId?: number;
  style?: WebViewStyle;
  javascriptEnable?: boolean;
  devtools?: boolean;
  transparent?: boolean;
  autoplay?: boolean;
  userAgent?: string;
  initializationScripts?: string[];
  headers?: Record<string, string>;
  html?: string;
  onDragAndDrop?: (event: string) => void;
  onDownloadStart?: (url: string, tempPath: string | undefined) => OnDownloadStartResult;
  onDownloadEnd?: (url: string, tempPath: string | undefined, success: boolean) => void;
  onNavigationRequest?: (url: string) => boolean;
  onTitleChange?: (title: string) => void;
  onPageBegin?: (url: string) => void;
  onPageEnd?: (url: string) => void;
  onCloseWindow?: () => void;
  onWindowNew?: (targetUrl: string, isAlert: boolean, isUserTrigger: boolean) => OnWindowNewResult;
}

export interface WebViewStyle {
  x?: number | string;
  y?: number | string;
  width?: number | string;
  height?: number | string;
  visible?: boolean;
  backgroundColor?: string | Color | number;
}

export interface AbilityInitContext {
  basePath?: string;
  prefPath?: string;
  preferredLocales?: string;
  moduleName?: string;
  resourceManager?: resourceManager.ResourceManager;
  sdkApiVersion?: number;
  distributionOSApiVersion?: number;
}

export interface Module {
  init: (context?: AbilityInitContext) => ApplicationLifecycle;
  render: (helper: ArkHelper, slot: NodeContent) => void;
  registerCustomProtocol?: () => void;
}

export interface StatusBarIconRgba {
  white?: Uint8Array;
  black?: Uint8Array;
}

export interface WindowConfig {
  name: string;
  /** @deprecated Unused — OHOS createSubWindow only accepts name. Retained for NAPI compat. */
  type: number;
  windowId: number;
  width?: number;
  height?: number;
  x?: number;
  y?: number;
  decorations?: boolean;     // Phase 2: show/hide title bar, default true
  transparent?: boolean;     // Phase 3: window background transparent, default false
  backgroundColor?: number;  // Phase 3: window background color in 0xAARRGGBB format
}

export interface ArkHelper {
  exit: (code: number) => void;
  restart: () => number;
  updaterCheck: () => Promise<Object>;
  updaterShowDialog: () => Promise<number>;
  updaterDownloadAndInstall: () => Promise<void>;
  createWebview: (data: WebViewInitData) => Object;
  createEmbeddedWebview: (data: WebViewInitData) => Object;
  requestPermission: (permission: string | string[]) => Promise<number | number[]>;
  getWindowAvoidArea: (type: number, windowId: number) => WindowAvoidAreaInfo | undefined;
  createOSWindow: (config: WindowConfig) => Promise<number>;
  setWindowDecorations: (windowId: number, decorations: boolean) => void;
  setWindowBackgroundColor: (windowId: number, color: number) => void;
  loadUrl: (id: number, url: string) => void;
  createMenu?: (options: MenuCreateOptions) => Promise<string>;
  createMenuItem?: (options: MenuItemCreateOptions) => Promise<string>;
  createSubmenu?: (options: SubmenuCreateOptions) => Promise<string>;
  appendMenuItem?: (menuId: string, itemId: string) => Promise<void>;
  popupMenu?: (menuId: string, x?: number, y?: number) => Promise<void>;
  destroyMenu?: (menuId: string) => Promise<void>;
  addToStatusBarWithRgba: (iconsRgba: StatusBarIconRgba, iconSize: number, quickOperation: ESObject, statusBarGroupMenu?: ESObject[][], hoverTips?: string) => void;
  updateStatusBarIconWithRgba: (iconsRgba: StatusBarIconRgba, iconSize: number) => void;
  registerIconClickHandler: (eventName: string, callback: Callback<emitter.EventData>) => void;
  registerMenuClickHandler: (eventName: string, callback: Callback<emitter.EventData>) => void;
  unregisterIconClickHandler: (eventName: string) => void;
  unregisterMenuClickHandler: (eventName: string) => void;
  updateStatusBarMenu: (statusBarGroupMenu: ESObject[][]) => void;
  updateStatusBarHoverTips: (hoverTips: string) => void;
  removeFromStatusBar: () => void;
  executePredefinedAction: (actionType: string) => void;
  setColorMode: (mode: number) => void;
  checkCanIUse: (syscap: string) => boolean;
  writeImageToClipboard: (rgbaData: Uint8Array, width: number, height: number) => Promise<void>;
  autostartEnable: () => Promise<void>;
  autostartDisable: () => Promise<void>;
  autostartIsEnabled: () => Promise<boolean>;
}

export interface WindowAvoidAreaInfo {
  type: number;
  area: Object;
}
