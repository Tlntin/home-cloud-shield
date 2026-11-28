import { parseAppSplitDnsAllowlist } from './AppSplit';

export type RuleQueryType = 'all' | 'A' | 'AAAA';

export interface VisualDnsRule {
  domain: string;
  allow: boolean;
  includeSubdomains: boolean;
  queryType: RuleQueryType;
}

export function normalizeRuleDomain(input: string): string {
  const value: string = input.trim();
  if (/[\s,，]/.test(value)) {
    return '';
  }
  return parseAppSplitDnsAllowlist(value)?.[0] ?? '';
}

export function formatVisualDnsRule(domain: string, allow: boolean, includeSubdomains: boolean,
  queryType: RuleQueryType): string {
  const host: string = includeSubdomains ? `||${domain}^` : `|${domain}|`;
  return `${allow ? '@@' : ''}${host}${queryType === 'all' ? '' : `$dnstype=${queryType}`}`;
}

export function parseVisualDnsRule(line: string): VisualDnsRule | undefined {
  const parts: RegExpExecArray | null = /^(@@)?(\|\||\|)([a-z0-9.-]+)(\^|\|)(?:\$dnstype=(A|AAAA))?$/i.exec(line);
  if (parts === null || (parts[2] === '||' && parts[4] !== '^')) {
    return undefined;
  }
  const domain: string = normalizeRuleDomain(parts[3]);
  if (!domain) {
    return undefined;
  }
  const type: string | undefined = parts[5]?.toUpperCase();
  return {
    domain,
    allow: parts[1] === '@@',
    includeSubdomains: parts[2] === '||',
    queryType: type === 'A' || type === 'AAAA' ? type : 'all',
  };
}
