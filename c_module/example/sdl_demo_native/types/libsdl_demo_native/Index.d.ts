/* eslint-disable */

export interface AbilityInitContext {
  basePath?: string;
  prefPath?: string;
  preferredLocales?: string;
  moduleName?: string;
  resourceManager?: object;
}

export interface BridgePluginDeclaration {
  id: string;
  execution: string;
  requires: Array<string>;
}

export interface EnvironmentCallback {
  onConfigurationUpdated: (arg: object) => void;
  onMemoryLevel: (level: number) => void;
}

export interface KeyboardCallback {
  onKeyboardHeightChange: (height: number) => void;
}

export interface WindowStageEventCallback {
  onWindowStageCreate: () => void;
  onWindowStageDestroy: () => void;
  onAbilityCreate: (restoredState: string) => void;
  onAbilityDestroy: () => void;
  onAbilitySaveState: () => string;
  onWindowStageEvent: (event: number) => void;
  onWindowSizeChange: (size: object) => void;
  onWindowRectChange: (rect: object) => void;
  onAvoidAreaChange: (area: object) => void;
}

export interface ApplicationLifecycle {
  bridgePlugins: Array<BridgePluginDeclaration>;
  environmentCallback: EnvironmentCallback;
  windowStageEventCallback: WindowStageEventCallback;
  keyboardEventCallback: KeyboardCallback;
}

export declare function init(
  bindings: object,
  bridgeOwner: string,
  context?: AbilityInitContext,
): ApplicationLifecycle;
export declare function disposeBridge(bridgeOwner: string): void;
export declare function render(slot: NodeContent, renderOwner: string): void;
export declare function disposeRender(renderOwner: string): void;
export declare function disposeAllRenders(): void;
export declare function onBackPressIntercept(): boolean;
export declare function onBridgeLifecycle(kind: string): void;
export declare function onBridgeSyncEvent(
  pluginId: string,
  event: string,
  requestTypeName: string,
  responseTypeName: string,
  value: unknown,
): unknown;
