// Immersive title bar with scroll-driven dynamic blur, shared by every tab root
// (HdsNavigation) and sub page (HdsNavDestination). HDS interpolates the
// backdrop from `originalStyle` (at rest) to `scrollEffectStyle` (scrolled past
// BLUR_END_OFFSET) and draws the blur itself; we only pick colours and offsets.
//
// Wiring a page takes three things, all required:
//   1. the scroll container owns a Scroller and sets `.clip(false)` — clipping
//      would cut content off at the bar's edge, leaving nothing to blur;
//   2. `.titleBar(blurTitleBar(...))` + `.bindToScrollable([scroller])`;
//   3. `.titleMode(MINI)` on the HdsNavigation / HdsNavDestination.
import {
  DividerShowType, hdsMaterial, HdsNavigationMenuItemOptions, HdsNavigationTitleBarOptions, HdsTitleBarContentStyle,
  ScrollEffectType, SystemMaterialParams
} from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

// Scroll distance (vp) over which the blur fades in fully.
const BLUR_END_OFFSET: number = 24;

export interface BlurTitleBarExtra {
  subTitle?: ResourceStr;
  menu?: Array<HdsNavigationMenuItemOptions>;
}

let materialChecked: boolean = false;
let materialAvailable: boolean = false;

// Glass material for the back / menu buttons (API 23+, not on 2in1 where the
// system degrades it anyway). Back-button tint and material must share this
// check: tinting for "material on" while it silently isn't leaves a flat,
// invisible button.
function titleBarMaterialAvailable(): boolean {
  if (materialChecked) {
    return materialAvailable;
  }
  materialChecked = true;
  if (deviceInfo.sdkApiVersion < 23 || deviceInfo.deviceType === '2in1') {
    return false;
  }
  try {
    materialAvailable = hdsMaterial.getSystemMaterialTypes().includes(hdsMaterial.MaterialType.IMMERSIVE);
  } catch (_) {
    materialAvailable = false;
  }
  return materialAvailable;
}

function bestScrollEffectType(): ScrollEffectType {
  return deviceInfo.sdkApiVersion >= 23 ? ScrollEffectType.IMMERSIVE_GRADIENT_BLUR : ScrollEffectType.COMMON_BLUR;
}

function bestSystemMaterialEffect(): SystemMaterialParams | undefined {
  if (!titleBarMaterialAvailable()) {
    return undefined;
  }
  return { materialType: hdsMaterial.MaterialType.ADAPTIVE, materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE };
}

function contentStyle(titleColor: ResourceColor, subTitleColor: ResourceColor,
  pageColor: ResourceColor): HdsTitleBarContentStyle {
  // With material, leave the button background to HDS so the glass shows;
  // without it, an opaque page-coloured disc keeps the icon legible over
  // scrolled content.
  const iconBg: ResourceColor | undefined = titleBarMaterialAvailable() ? undefined : pageColor;
  return {
    titleStyle: { mainTitleColor: titleColor, subTitleColor: subTitleColor },
    menuStyle: { backgroundColor: iconBg, iconColor: $r('sys.color.icon_primary') },
    backIconStyle: { backgroundColor: iconBg, iconColor: $r('sys.color.icon_primary') },
  };
}

// `pageColor` / `pageColorClear` must share the same RGB (clear = alpha 0):
// HDS interpolates linearly between them, and a different RGB (e.g. a generic
// transparent white) flashes grey on dark pages mid-scroll. The bar is clear at
// rest so it is seamless with the page; only the scroll blur gives it a body.
export function blurTitleBar(mainTitle: ResourceStr, titleColor: ResourceColor, subTitleColor: ResourceColor,
  pageColor: ResourceColor, pageColorClear: ResourceColor, extra?: BlurTitleBarExtra): HdsNavigationTitleBarOptions {
  const style: HdsTitleBarContentStyle = contentStyle(titleColor, subTitleColor, pageColor);
  const subTitle: ResourceStr | undefined = extra?.subTitle;
  return {
    // Content lays out below the bar automatically; the bar's backdrop extends
    // under the status bar while the title/buttons avoid it.
    enableComponentSafeArea: true,
    avoidLayoutSafeArea: true,
    style: {
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: bestScrollEffectType(),
        blurEffectiveStartOffset: LengthMetrics.vp(0),
        blurEffectiveEndOffset: LengthMetrics.vp(BLUR_END_OFFSET),
      },
      systemMaterialEffect: bestSystemMaterialEffect(),
      originalStyle: {
        backgroundStyle: { backgroundColor: pageColorClear },
        contentStyle: style,
      },
      scrollEffectStyle: {
        backgroundStyle: { backgroundColor: pageColorClear },
        contentStyle: style,
      },
    },
    content: {
      title: subTitle === undefined ? { mainTitle: mainTitle } : { mainTitle: mainTitle, subTitle: subTitle },
      divider: { showType: DividerShowType.OFF },
      menu: extra?.menu === undefined ? undefined : { value: extra.menu },
    },
  };
}
