import { AbilityConstant, ConfigurationConstant, UIAbility, Want, wantConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { CONFIG_CONTINUE_KEY, CONFIG_CONTINUE_SOURCE, configSync } from '../data/ConfigSync';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private currentWindowStage?: window.WindowStage;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.receiveContinuation(want, launchParam);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onNewWant(want, launchParam);
    this.receiveContinuation(want, launchParam);
  }

  private receiveContinuation(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION) {
      const key = want.parameters?.[CONFIG_CONTINUE_KEY];
      const source = want.parameters?.[CONFIG_CONTINUE_SOURCE];
      if (typeof key === 'string') {
        configSync.queueContinuation(key, typeof source === 'string' ? source : '');
      }
    }
  }

  async onContinue(parameters: Record<string, Object>): Promise<AbilityConstant.OnContinueResult> {
    const target = parameters['targetDevice'];
    if (typeof target !== 'string' || !target || !configSync.isEnabled()) {
      return AbilityConstant.OnContinueResult.REJECT;
    }
    try {
      const result = await configSync.send(this.context, target, { continuation: true });
      parameters[CONFIG_CONTINUE_KEY] = result.key;
      const source = configSync.localNetworkId(this.context);
      if (source) {
        parameters[CONFIG_CONTINUE_SOURCE] = source;
      }
      // Keep the source ability alive so its DNS proxy can continue filtering.
      parameters[wantConstant.Params.SUPPORT_CONTINUE_SOURCE_EXIT_KEY] = false;
      parameters[wantConstant.Params.SUPPORT_CONTINUE_PAGE_STACK_KEY] = false;
      return AbilityConstant.OnContinueResult.AGREE;
    } catch (_) {
      hilog.warn(DOMAIN, 'ConfigSync', 'Could not send settings for continuation');
      return AbilityConstant.OnContinueResult.REJECT;
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.currentWindowStage = windowStage;
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    windowStage.getMainWindow().then(async (mainWindow: window.Window) => {
      try {
        await mainWindow.setWindowLayoutFullScreen(true);
      } catch (err) {
        hilog.error(DOMAIN, 'testTag', 'Failed to enable immersive layout. Cause: %{public}s', JSON.stringify(err));
      }

      try {
        await mainWindow.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000'
        });
      } catch (err) {
        hilog.error(DOMAIN, 'testTag', 'Failed to set system bar properties. Cause: %{public}s', JSON.stringify(err));
      }
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'Failed to get main window. Cause: %{public}s', JSON.stringify(err));
    });
  }

  onWindowStageRestore(windowStage: window.WindowStage): void {
    if (this.currentWindowStage !== windowStage) {
      this.onWindowStageCreate(windowStage);
    }
  }

  onWindowStageDestroy(): void {
    this.currentWindowStage = undefined;
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
