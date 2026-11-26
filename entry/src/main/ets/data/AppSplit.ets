// Per-app VPN routing ("分应用代理"). The VPN extension maps these onto
// VpnConfig.blockedApplications / trustedApplications, which the system treats
// as mutually exclusive:
//   - 'bypass': listed apps skip the tun (their DNS is not filtered);
//   - 'only':   only listed apps go through the tun (everything else bypasses).
// Only meaningful in VPN mode — the DNS-proxy mode never creates a tun.

export type AppSplitMode = 'off' | 'bypass' | 'only';
export const APP_TUNNEL_LOG_FILE = 'app_connections.log';
export const APP_TUNNEL_RULES_MAX_LENGTH = 16384;

export interface AppSplitEntry {
  bundle: string;
  name: string;
  enabled: boolean;
}

export interface AppSplitFile {
  mode: string;
  bundles: string[];
  dnsAllowlist?: string[];
  tunnelRules?: string;
}

export function parseAppSplitDnsAllowlist(text: string): string[] | undefined {
  const domains: Set<string> = new Set<string>();
  for (const item of text.split(/[\s,，]+/)) {
    const domain: string = item.toLowerCase().replace(/\.$/, '');
    if (item.length === 0) {
      continue;
    }
    if (domain.length > 253 || !domain.includes('.') || /^(\d+\.)+\d+$/.test(domain) ||
      !domain.split('.').every((label: string) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) {
      return undefined;
    }
    domains.add(domain);
  }
  return Array.from(domains);
}

export function appSplitDnsAllowlistRules(domains: string[], defaultBlockRule: string): string[] {
  return [defaultBlockRule].concat(domains.map((domain: string) => `@@|${domain}|`));
}

// Since API 23 the system accepts up to 256 bundles per list (64 before). Our own
// bundle always occupies one blockedApplications slot (see MyVpnExtAbility).
export const APP_SPLIT_MAX_BUNDLES: number = 255;

// New entries follow the DevEco SDK app.json schema. Keep the old format for
// saved and imported entries so an update never drops an existing selection.
const BUNDLE_NAME_PATTERN: RegExp = /^[A-Za-z](?:[A-Za-z0-9_]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9_]*[A-Za-z0-9])?){2,}$/;
const LEGACY_BUNDLE_NAME_PATTERN: RegExp = /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$/;

function matchesBundleName(bundle: string, pattern: RegExp): boolean {
  return bundle.length >= 7 && bundle.length <= 128 && pattern.test(bundle);
}

export function isValidBundleName(bundle: string): boolean {
  return matchesBundleName(bundle, BUNDLE_NAME_PATTERN);
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
    if (!matchesBundleName(bundle, LEGACY_BUNDLE_NAME_PATTERN) || seen.has(bundle)) {
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
