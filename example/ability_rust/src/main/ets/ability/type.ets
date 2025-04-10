import { NodeContent } from "@kit.ArkUI"

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

export interface Module {
  init: (helper: ArkHelper) => ApplicationLifecycle,
  render: (slot: NodeContent) => void
}

export interface Render {
  onFrame: () => void
}

export interface ArkHelper {
  exit: (code: number) => void
}