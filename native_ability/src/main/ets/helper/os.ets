import process from "@ohos.process";
import common from "@ohos.app.ability.common";
import { appRecovery } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WindowManager } from "../window/WindowManager";
import { DOMAIN } from './constants';

/**
 * exit current application
 */
export const exit = (code: number) => {
  const pro = new process.ProcessManager();
  pro.exit(code);
};

/**
 * Restart the application via appRecovery.restartApp().
 *
 * Calls enableAppRecovery() before restartApp() to ensure recovery is configured.
 * (Ideally this would be in AbilityStage.onCreate(), but SDK 12 hvigor does not
 * support the abilityStage field in module.json5.)
 *
 * Requires module.json5 to set recoverable: true on the target Ability.
 * Has a 60-second cooldown between calls.
 *
 * @returns 0 on success, -2 on failure
 */
export const restart = (): number => {
  try {
    hilog.info(DOMAIN, 'os.restart', 'enabling appRecovery');
    appRecovery.enableAppRecovery(
      appRecovery.RestartFlag.ALWAYS_RESTART,
      appRecovery.SaveOccasionFlag.SAVE_WHEN_ERROR,
      appRecovery.SaveModeFlag.SAVE_WITH_FILE
    );
    hilog.info(DOMAIN, 'os.restart', 'calling appRecovery.restartApp()');
    appRecovery.restartApp();
    hilog.info(DOMAIN, 'os.restart', 'appRecovery.restartApp() returned');
    return 0;
  } catch (err) {
    const error = err as Error;
    hilog.error(DOMAIN, 'os.restart', 'appRecovery.restartApp failed: %{public}s', error.message);
    return -2;
  }
};
