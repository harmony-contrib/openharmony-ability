/* auto-generated by OHOS-RS */
/* eslint-disable */

export interface ApplicationLifecycle {
  environmentCallback: EnvironmentCallback
  windowStageEventCallback: WindowStageEventCallback
}

export interface ArkTSHelper {
  exit: (arg: number) => void
  createWebview: (arg: WebViewInitData) => Object
}

export interface EnvironmentCallback {
  onConfigurationUpdated: () => void
  onMemoryLevel: (arg: number) => void
}

export interface WebViewComponentEventCallback {
  onComponentCreated: () => void
  onComponentDestroyed: () => void
}

export interface WebViewInitData {
  url?: string
  id?: string
  style?: WebViewStyle
}

export interface WebViewStyle {
  x?: number | string
  y?: number | string
}

export interface WindowStageEventCallback {
  onWindowStageCreate: () => void
  onWindowStageDestroy: () => void
  onAbilityCreate: () => void
  onAbilityDestroy: () => void
  onAbilitySaveState: () => void
  onAbilityRestoreState: () => void
  onWindowStageEvent: (arg: number) => void
  onWindowSizeChange: (arg: object) => void
  onWindowRectChange: (arg: object) => void
}

export declare function handleChange(): void

export declare function init(): ApplicationLifecycle

export declare function webviewRender(helper: ArkTSHelper): WebViewComponentEventCallback
export declare function setBackgroundColor(color: string): void
export declare function setVisible(visible: boolean): void
