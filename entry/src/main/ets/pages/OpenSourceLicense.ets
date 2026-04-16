import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { window } from '@kit.ArkUI';

const LICENSE_RAWFILE = 'adguard_open_source_licenses.txt';
type LicenseStringKey = 'licenseTitle' | 'licenseSubtitle' | 'back' | 'loadingLicense' | 'licenseUnavailable';

function resolveLicenseStringResource(key: LicenseStringKey): number {
  switch (key) {
    case 'licenseTitle': return $r('app.string.licenseTitle').id;
    case 'licenseSubtitle': return $r('app.string.licenseSubtitle').id;
    case 'back': return $r('app.string.back').id;
    case 'loadingLicense': return $r('app.string.loadingLicense').id;
    case 'licenseUnavailable': return $r('app.string.licenseUnavailable').id;
  }
}

@Entry
@Component
struct OpenSourceLicensePage {
  @State loading: boolean = true;
  @State errorText: string = '';
  @State lines: string[] = [];
  @State avoidPaddingTop: number = 0;
  @State avoidPaddingBottom: number = 0;
  private mainWindow?: window.Window;
  private hasBoundWindowAvoidAreaListeners: boolean = false;

  private isDarkModeActive(): boolean {
    try {
      return this.getHostContext().config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (_) {
      return false;
    }
  }

  private t(key: LicenseStringKey, ...args: Array<string | number>): string {
    try {
      return this.getHostContext().resourceManager.getStringSync(resolveLicenseStringResource(key), ...args);
    } catch (_) {
      return key;
    }
  }

  private getHostContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    void this.initWindowAvoidPadding();
    this.loadLicense();
  }

  private async initWindowAvoidPadding(): Promise<void> {
    try {
      this.mainWindow = await window.getLastWindow(this.getHostContext());
      this.updateWindowAvoidPadding();
      if (!this.hasBoundWindowAvoidAreaListeners && this.mainWindow !== undefined) {
        this.mainWindow.on('avoidAreaChange', () => {
          this.updateWindowAvoidPadding();
        });
        this.mainWindow.on('windowSizeChange', () => {
          this.updateWindowAvoidPadding();
        });
        this.hasBoundWindowAvoidAreaListeners = true;
      }
    } catch (_) {
      this.avoidPaddingTop = 0;
      this.avoidPaddingBottom = 0;
    }
  }

  private updateWindowAvoidPadding(): void {
    if (this.mainWindow === undefined) {
      this.avoidPaddingTop = 0;
      this.avoidPaddingBottom = 0;
      return;
    }
    try {
      const uiContext = this.getUIContext();
      let topInsetVp = 0;
      let bottomInsetVp = 0;
      try {
        const systemArea: window.AvoidArea = this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        topInsetVp = Math.max(topInsetVp, uiContext.px2vp(systemArea.topRect.height));
        bottomInsetVp = Math.max(bottomInsetVp, uiContext.px2vp(systemArea.bottomRect.height));
      } catch (_) {
      }
      try {
        const navArea: window.AvoidArea =
          this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        bottomInsetVp = Math.max(bottomInsetVp, uiContext.px2vp(navArea.bottomRect.height));
      } catch (_) {
      }
      this.avoidPaddingTop = Math.max(0, Math.round(topInsetVp));
      this.avoidPaddingBottom = Math.max(0, Math.round(bottomInsetVp));
    } catch (_) {
      this.avoidPaddingTop = 0;
      this.avoidPaddingBottom = 0;
    }
  }

  private contentTopInset(): number {
    return Math.max(20, this.avoidPaddingTop + 12);
  }

  private contentBottomInset(): number {
    return Math.max(16, this.avoidPaddingBottom + 12);
  }

  private async loadLicense(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    this.lines = [];
    try {
      const fileData: Uint8Array = await this.getHostContext().resourceManager.getRawFileContent(LICENSE_RAWFILE);
      const textDecoder = util.TextDecoder.create('utf-8');
      const licenseText: string = textDecoder.decodeToString(fileData);
      if (!licenseText || licenseText.trim().length === 0) {
        this.errorText = this.t('licenseUnavailable');
      } else {
        this.lines = licenseText.split('\n');
      }
    } catch (_) {
      this.errorText = this.t('licenseUnavailable');
    } finally {
      this.loading = false;
    }
  }

  build() {
    Stack() {
      Column() {}
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 135,
          colors: this.isDarkModeActive()
            ? [['#09111F', 0.0], ['#0E1A30', 0.42], ['#111D35', 1.0]]
            : [['#F8FBFF', 0.0], ['#F2F7FF', 0.42], ['#FAFCFF', 1.0]]
        })

      Column({ space: 14 }) {
        Column({ space: 12 }) {
          Row({ space: 12 }) {
            Button(this.t('back'))
              .height(38)
              .backgroundColor(this.isDarkModeActive() ? '#22324B' : '#EAF1FB')
              .fontColor(this.isDarkModeActive() ? '#F3F6FB' : '#16304B')
              .borderRadius(14)
              .onClick(() => {
                this.getUIContext().getRouter().back();
              })
            Text(this.t('licenseTitle'))
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.isDarkModeActive() ? '#F3F6FB' : '#16304B')
          }
          .width('100%')

          Text(this.t('licenseSubtitle'))
            .fontSize(14)
            .lineHeight(22)
            .fontColor(this.isDarkModeActive() ? '#AAB7CA' : '#5B6C82')
            .width('100%')

          Row({ space: 10 }) {
            Text(`RAWFILE · ${LICENSE_RAWFILE}`)
              .fontSize(11)
              .fontColor(this.isDarkModeActive() ? '#B8C5D9' : '#46607C')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(this.isDarkModeActive() ? '#1A2940' : '#EDF4FF')
              .borderRadius(999)
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(20)
        .backgroundColor(this.isDarkModeActive() ? '#D9152236' : '#FEFFFF')
        .borderRadius(28)
        .border({ width: 1, color: this.isDarkModeActive() ? '#29405F' : '#DBE7F5' })
        .shadow({ radius: 12, color: this.isDarkModeActive() ? '#52000000' : '#100F2742' })

        if (this.loading) {
          Column() {
            Text(this.t('loadingLicense'))
              .fontSize(14)
              .fontColor(this.isDarkModeActive() ? '#AAB7CA' : '#5B6C82')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.errorText.length > 0) {
          Column() {
            Text(this.errorText)
              .fontSize(14)
              .fontColor('#B42318')
              .padding(12)
              .backgroundColor(this.isDarkModeActive() ? '#472A2A' : '#F7E4DE')
              .borderRadius(14)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.lines, (line: string, index: number) => {
                Text(line.length > 0 ? line : ' ')
                  .width('100%')
                  .fontSize(13)
                  .lineHeight(21)
                  .fontColor(this.isDarkModeActive() ? '#E8EEF8' : '#24364A')
              }, (_line: string, index: number) => `${index}`)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 18, right: 18, top: 18, bottom: 26 })
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(this.isDarkModeActive() ? '#162235' : '#FFFFFF')
          .borderRadius(24)
          .border({ width: 1, color: this.isDarkModeActive() ? '#29405F' : '#DBE7F5' })
          .shadow({ radius: 10, color: this.isDarkModeActive() ? '#52000000' : '#100F2742' })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: this.contentTopInset(), bottom: this.contentBottomInset() })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkModeActive() ? '#0E182A' : '#F6FAFF')
  }
}
