import { UIAbility, Want } from "@kit.AbilityKit";
import window from "@ohos.window";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { ProcessInitializer } from "./ProcessInitializer";
import { NativeModuleLoader } from "../runtime/NativeModuleLoader";
import { WindowManager, INDEPENDENT_WINDOW_ID_PARAMETER } from "../window/WindowManager";
import { DOMAIN } from "../helper/constants";

export class NativeWindowAbility extends UIAbility {
  private windowId?: number;
  private moduleName?: string;

  onCreate(want: Want): void {
    const windowId = want.parameters?.[INDEPENDENT_WINDOW_ID_PARAMETER];
    if (
      ProcessInitializer.isInitialized() &&
      typeof windowId === "number" &&
      Number.isInteger(windowId) &&
      windowId > 0 &&
      WindowManager.getInstance().hasPendingAbilityWindow(windowId)
    ) {
      this.windowId = windowId;
      this.moduleName = WindowManager.getInstance().pendingWindowModuleName(windowId);
      return;
    }
    // Only the entry Ability initializes process-wide modules after process death.
    // Hosts may override recovery to select their own document or workspace.
    this.restoreApplication(want).catch((error: Error) => {
      hilog.error(
        DOMAIN,
        "NativeWindowAbility",
        "Application restore failed: %{public}s",
        String(error),
      );
    });
  }

  protected async restoreApplication(want: Want): Promise<void> {
    try {
      await this.context.startAbility({
        bundleName: this.context.abilityInfo.bundleName,
        moduleName: this.context.abilityInfo.moduleName,
        abilityName: this.context.currentHapModuleInfo.mainElementName,
        uri: want.uri,
        type: want.type,
        flags: want.flags,
        action: want.action,
        parameters: want.parameters,
        entities: want.entities,
      });
    } finally {
      await this.context.terminateSelf();
    }
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    if (this.windowId === undefined) {
      return;
    }
    WindowManager.getInstance()
      .attachAbilityWindow(this.windowId, stage, this.context)
      .catch(async (error: Error): Promise<void> => {
        hilog.error(
          DOMAIN,
          "NativeWindowAbility",
          "Window creation failed: %{public}s",
          String(error),
        );
        await this.context.terminateSelf();
      })
      .catch((error: Error): void => {
        hilog.error(
          DOMAIN,
          "NativeWindowAbility",
          "Window cleanup failed: %{public}s",
          String(error),
        );
      });
  }

  onPrepareToTerminate(): boolean {
    return (
      this.windowId !== undefined && WindowManager.getInstance().requestWindowClose(this.windowId)
    );
  }

  onWindowStageDestroy(): void {
    const windowId = this.windowId;
    if (windowId === undefined) {
      return;
    }
    this.windowId = undefined;
    const manager = WindowManager.getInstance();
    if (manager.isUIAbilityMainWindow(windowId)) {
      const nativeModule = this.moduleName
        ? NativeModuleLoader.getLoadedModule(this.moduleName)
        : undefined;
      nativeModule?.notifyNativeWindowClose?.(windowId);
      nativeModule?.notifyWindowClose?.(windowId);
      manager.removeWindow(windowId);
    }
    manager.unregisterUIAbilityStage(windowId);
    this.moduleName = undefined;
  }

  onDestroy(): void {
    this.onWindowStageDestroy();
  }
}
