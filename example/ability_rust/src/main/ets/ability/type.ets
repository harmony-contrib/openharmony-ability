import { NodeContent } from "@kit.ArkUI"

export interface ApplicationLifecycle {
  environmentCallback: EnvironmentCallback
  windowStageEventCallback: WindowStageEventCallback
}

export interface EnvironmentCallback {
  onConfigurationUpdated: () => void
  onMemoryLevel: () => void
}

export interface WindowStageEventCallback {
  onWindowStageCreate: () => void
  onWindowStageDestroy: () => void
  onAbilityCreate: () => void
  onAbilityDestroy: () => void
  onAbilitySaveState: () => void
  onWindowStageEvent: (arg: number) => void
  onWindowSizeChange: (arg: object) => void
  onWindowRectChange: (arg: object) => void
}

export interface Module {
  init: () => ApplicationLifecycle,
  render: (slot: NodeContent) => void
}