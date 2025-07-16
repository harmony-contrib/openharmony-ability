import { AbilityConstant, Configuration, UIAbility, Want } from "@kit.AbilityKit";
import window from "@ohos.window";
import webview from '@ohos.web.webview';
import * as Entry from '../components/MainPage'
import * as Webview from '../webview/DefaultPage'
import { ApplicationLifecycle, Module } from './type'

export const STATE_KEY = 'ohos.rs.ability.application.state';

export class RustAbility extends UIAbility {
  /**
   * load dynamic library
   */
  public moduleName: string = "";
  /**
   * Jump to defaultPage by default
   * @default true
   */
  public defaultPage: boolean = true;
  /**
   * Current page mode,support xcomponent and webview
   * @default xcomponent
   */
  public mode: 'xcomponent' | 'webview' = 'xcomponent';

  private nativeModule: Module | null = null;
  private lifecycle: ApplicationLifecycle | null = null;

  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    const isRestore: boolean = want.parameters?.['ohos.ability.params.abilityRecoveryRestart'] as boolean ?? false;
    const state = isRestore ? want.parameters?.[STATE_KEY] as string ?? '' : '';

    AppStorage.setOrCreate("moduleName", this.moduleName);

    const packageName = `lib${this.moduleName}.so`;
    const module: ESObject = await import(packageName);
    this.nativeModule = module.default;
    this.nativeModule!.registerCustomProtocol();
    webview.WebviewController.initializeWebEngine();
    this.lifecycle = this.nativeModule!.init();
    this.lifecycle?.windowStageEventCallback.onAbilityCreate(state);
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    this.lifecycle?.windowStageEventCallback.onWindowStageCreate();

    windowStage.on('windowStageEvent', (event: window.WindowStageEventType) => {
      this.lifecycle?.windowStageEventCallback.onWindowStageEvent(event);
    })

    if (this.defaultPage) {
      await windowStage.loadContentByName(this.mode === 'xcomponent' ? Entry.RouteName : Webview.RouteName);
    }
  }

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    this.lifecycle?.environmentCallback.onMemoryLevel(level);
  }

  onDestroy(): void | Promise<void> {
    this.lifecycle?.windowStageEventCallback.onAbilityDestroy();
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.lifecycle?.environmentCallback.onConfigurationUpdated(newConfig);
  }

  onSaveState(reason: AbilityConstant.StateType, wantParam: Record<string, Object>): AbilityConstant.OnSaveResult {
    const ret = this.lifecycle?.windowStageEventCallback.onAbilitySaveState();
    wantParam[STATE_KEY] = ret as string;
    return AbilityConstant.OnSaveResult.RECOVERY_AGREE;
  }
}