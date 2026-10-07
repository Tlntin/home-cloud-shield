// Per-app VPN routing ("分应用代理"). The VPN extension maps these onto
// VpnConfig.blockedApplications / trustedApplications, which the system treats
// as mutually exclusive:
//   - 'bypass': listed apps skip the tun (their DNS is not filtered);
//   - 'only':   only listed apps go through the tun (everything else bypasses).
// Only meaningful in VPN mode — the DNS-proxy mode never creates a tun.

export type AppSplitMode = 'off' | 'bypass' | 'only';

export interface AppSplitEntry {
  bundle: string;
  name: string;
  enabled: boolean;
}

export interface AppSplitPreset {
  bundle: string;
  name: string;
  nameEn: string;
}

// Since API 23 the system accepts up to 256 bundles per list (64 before). Our own
// bundle always occupies one blockedApplications slot (see MyVpnExtAbility).
export const APP_SPLIT_MAX_BUNDLES: number = 255;

// HarmonyOS NEXT bundle names, checked against a real device's `bm dump -a`
// (they differ from the Android package names, e.g. 淘宝 = taobao4hmos).
export const APP_SPLIT_PRESETS: AppSplitPreset[] = [
  { bundle: 'com.tencent.wechat', name: '微信', nameEn: 'WeChat' },
  { bundle: 'com.tencent.mqq', name: 'QQ', nameEn: 'QQ' },
  { bundle: 'com.alipay.mobile.client', name: '支付宝', nameEn: 'Alipay' },
  { bundle: 'com.taobao.taobao4hmos', name: '淘宝', nameEn: 'Taobao' },
  { bundle: 'com.tmall.tmall4hmos', name: '天猫', nameEn: 'Tmall' },
  { bundle: 'com.jd.hm.mall', name: '京东', nameEn: 'JD' },
  { bundle: 'com.sankuai.hmeituan', name: '美团', nameEn: 'Meituan' },
  { bundle: 'com.xingin.xhs_hos', name: '小红书', nameEn: 'Xiaohongshu' },
  { bundle: 'com.amap.hmapp', name: '高德地图', nameEn: 'Amap' },
  { bundle: 'com.ctrip.harmonynext', name: '携程旅行', nameEn: 'Trip.com' },
  { bundle: 'com.qiyi.video.hmy', name: '爱奇艺', nameEn: 'iQIYI' },
  { bundle: 'com.youku.next', name: '优酷', nameEn: 'Youku' },
  { bundle: 'com.tencent.hm.qqmusic', name: 'QQ音乐', nameEn: 'QQ Music' },
  { bundle: 'com.kugou.hmmusic', name: '酷狗音乐', nameEn: 'Kugou Music' },
  { bundle: 'com.ximalaya.ting.xmharmony', name: '喜马拉雅', nameEn: 'Ximalaya' },
  { bundle: 'com.dragon.read.next', name: '番茄小说', nameEn: 'Fanqie Novel' },
  { bundle: 'com.dingtalk.hmos', name: '钉钉', nameEn: 'DingTalk' },
  { bundle: 'com.ss.feishu', name: '飞书', nameEn: 'Feishu' },
  { bundle: 'com.tencent.wework.hmos', name: '企业微信', nameEn: 'WeCom' },
  { bundle: 'com.tencent.meeting.app', name: '腾讯会议', nameEn: 'Tencent Meeting' },
  { bundle: 'com.quark.ohosbrowser', name: '夸克', nameEn: 'Quark' },
  { bundle: 'com.uc.mobile', name: 'UC浏览器', nameEn: 'UC Browser' },
  { bundle: 'com.baidu.netdisk.hmos', name: '百度网盘', nameEn: 'Baidu Netdisk' },
  { bundle: 'com.coolapk.hmclient', name: '酷安', nameEn: 'Coolapk' },
  { bundle: 'com.ruanmei.ithome.hosnext', name: 'IT之家', nameEn: 'IT Home' },
  { bundle: 'com.max.hos.xiaoheihe', name: '小黑盒', nameEn: 'Xiaoheihe' },
];

// Bundle names are reverse-DNS style: letters, digits, '_' and '.', at least
// two segments, each starting with a letter. (7–128 chars per the bundle spec.)
const BUNDLE_NAME_PATTERN: RegExp = /^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$/;

export function isValidBundleName(bundle: string): boolean {
  return bundle.length >= 7 && bundle.length <= 128 && BUNDLE_NAME_PATTERN.test(bundle);
}

export function findAppSplitPreset(bundle: string): AppSplitPreset | undefined {
  return APP_SPLIT_PRESETS.find((p: AppSplitPreset) => p.bundle === bundle);
}

export function normalizeAppSplitMode(value: string | undefined): AppSplitMode {
  return value === 'bypass' || value === 'only' ? value : 'off';
}

// Sanitize a persisted/imported list: valid bundle names only, de-duplicated,
// capped to what the system accepts.
export function normalizeAppSplitList(raw: AppSplitEntry[] | undefined): AppSplitEntry[] {
  const out: AppSplitEntry[] = [];
  if (!Array.isArray(raw)) {
    return out;
  }
  const seen: Set<string> = new Set<string>();
  for (const item of raw) {
    if (item === undefined || item === null || typeof item.bundle !== 'string') {
      continue;
    }
    const bundle: string = item.bundle.trim();
    if (!isValidBundleName(bundle) || seen.has(bundle)) {
      continue;
    }
    seen.add(bundle);
    out.push({
      bundle: bundle,
      name: typeof item.name === 'string' ? item.name.trim() : '',
      enabled: item.enabled !== false,
    });
    if (out.length >= APP_SPLIT_MAX_BUNDLES) {
      break;
    }
  }
  return out;
}
