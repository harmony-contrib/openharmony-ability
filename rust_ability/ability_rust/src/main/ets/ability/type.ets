import { NodeContent } from "@kit.ArkUI"
import { BusinessError } from "@kit.BasicServicesKit"

export interface ApplicationLifecycle {
  environmentCallback: EnvironmentCallback
  windowStageEventCallback: WindowStageEventCallback
}

export interface EnvironmentCallback {
  onConfigurationUpdated: (arg: object) => void
  onMemoryLevel: (arg: number) => void
}

export interface WindowStageEventCallback {
  onWindowStageCreate: () => void
  onWindowStageDestroy: () => void
  onAbilityCreate: (arg: string) => void
  onAbilityDestroy: () => void
  onAbilitySaveState: () => string
  onWindowStageEvent: (arg: number) => void
  onWindowSizeChange: (arg: object) => void
  onWindowRectChange: (arg: object) => void
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

export interface Module {
  init: () => ApplicationLifecycle,
  // XComponent mode
  render: (helper: ArkHelper, slot: NodeContent) => void

  // Webview mode
  webviewRender: (helper: ArkHelper) => WebViewComponentEventCallback
}

export interface ArkHelper {
  exit: (code: number) => void
  createWebview: (data: WebViewInitData) => Object
  hello: () => void
}