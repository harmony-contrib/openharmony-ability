import { UIAbility, Want } from "@kit.AbilityKit";
import window from "@ohos.window";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { Module } from "./type";
import { ProcessInitializer } from "./ProcessInitializer";
import { WindowManager, INDEPENDENT_WINDOW_ID_PARAMETER } from "../window/WindowManager";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from "../helper/constants";

export class NativeWindowAbility extends UIAbility {
  private windowId?: number;

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
      return;
    }
    // Recents can relaunch a workspace after its process was killed. Only the
    // entry Ability may initialize Rust and restore the editor's saved session.
    this.restorePrimaryAbility().catch((error: Error) => {
      hilog.error(
        DOMAIN,
        "NativeWindowAbility",
        "Workspace restore failed: %{public}s",
        String(error),
      );
    });
  }

  private async restorePrimaryAbility(): Promise<void> {
    try {
      await this.context.startAbility({
        bundleName: this.context.abilityInfo.bundleName,
        moduleName: this.context.abilityInfo.moduleName,
        abilityName: this.context.currentHapModuleInfo.mainElementName,
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
          "Workspace creation failed: %{public}s",
          String(error),
        );
        await this.context.terminateSelf();
      })
      .catch((error: Error): void => {
        hilog.error(
          DOMAIN,
          "NativeWindowAbility",
          "Workspace cleanup failed: %{public}s",
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
      const nativeModule = AppStorage.get<Module>(NATIVE_MODULE_STORAGE_KEY);
      nativeModule?.notifyNativeWindowClose?.(windowId);
      nativeModule?.notifyWindowClose?.(windowId);
      manager.removeWindow(windowId);
    }
    manager.unregisterUIAbilityStage(windowId);
  }

  onDestroy(): void {
    this.onWindowStageDestroy();
  }
}
