import { parseAppSplitDnsAllowlist } from './AppSplit';

export type RuleQueryType = 'all' | 'A' | 'AAAA';
export type RuleMatchScope = 'exact' | 'domainAndSubdomains' | 'wildcard';

export interface VisualDnsRule {
  domain: string;
  allow: boolean;
  scope: RuleMatchScope;
  queryType: RuleQueryType;
}

export interface RuleEditTemplate {
  field: 'domain' | 'pattern' | 'comment' | 'expression';
  value: string;
  prefix: string;
  suffix: string;
}

export interface RuleLineItem {
  line: string;
  index: number;
  domain: string;
  comment: boolean;
}

function isRuleComment(line: string): boolean {
  return line.startsWith('!') || line.startsWith('#');
}

export class RuleEditorLineSource implements IDataSource {
  private lines: string[] = [];
  private indices: number[] = [];
  private comments: number = 0;
  private listeners: Set<DataChangeListener> = new Set<DataChangeListener>();

  reload(content: string): void {
    this.lines = content.split('\n');
    this.indices = [];
    this.comments = 0;
    for (let index = 0; index < this.lines.length; index++) {
      const line: string = this.lines[index].trim();
      if (line.length > 0) {
        this.indices.push(index);
        if (isRuleComment(line)) {
          this.comments++;
        }
      }
    }
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }

  totalCount(): number {
    return this.indices.length;
  }

  commentCount(): number {
    return this.comments;
  }

  getData(position: number): RuleLineItem {
    const index: number = this.indices[position];
    const line: string = this.lines[index].trim();
    const comment: boolean = isRuleComment(line);
    return { line, index, domain: comment ? '' : (parseVisualDnsRule(line)?.domain ?? ''), comment };
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.add(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners.delete(listener);
  }
}

export function normalizeRuleDomain(input: string): string {
  const value: string = input.trim();
  if (/[\s,，]/.test(value)) {
    return '';
  }
  return parseAppSplitDnsAllowlist(value)?.[0] ?? '';
}

function domainEditTemplate(parts: RegExpExecArray | null): RuleEditTemplate | undefined {
  if (parts === null || !normalizeRuleDomain(parts[2])) {
    return undefined;
  }
  return { field: 'domain', prefix: parts[1], value: parts[2], suffix: parts[3] };
}

export function ruleEditTemplate(line: string): RuleEditTemplate {
  const comment: RegExpExecArray | null = /^([!#][ \t]*)(.*)$/.exec(line);
  if (comment !== null) {
    return { field: 'comment', prefix: comment[1], value: comment[2], suffix: '' };
  }
  const pattern: RegExpExecArray | null = /^((?:@@)?\/)((?:\\.|[^/\\])*)(\/(?:\$.*)?)$/.exec(line);
  if (pattern !== null) {
    return { field: 'pattern', prefix: pattern[1], value: pattern[2], suffix: pattern[3] };
  }
  // Keep anchors, modifiers, hosts addresses, and inline comments outside the editable domain.
  return domainEditTemplate(/^((?:@@)?\|{1,2}(?:\*\.)?)([a-z0-9.-]+)([\^|]?(?:\$\S+)?)$/i.exec(line)) ??
    domainEditTemplate(/^((?:(?:\d{1,3}\.){3}\d{1,3}|[a-f0-9:]*:[a-f0-9:.]*)[ \t]+)([a-z0-9.-]+)((?:[ \t]+#.*)?)$/i.exec(line)) ??
    domainEditTemplate(/^()([a-z0-9.-]+)((?:[ \t]+#.*)?)$/i.exec(line)) ??
    { field: 'expression', prefix: '', value: line, suffix: '' };
}

export function formatRuleEditTemplate(template: RuleEditTemplate, value: string): string {
  if (template.field === 'domain') {
    const domain: string = normalizeRuleDomain(value);
    return domain ? `${template.prefix}${value === template.value ? value : domain}${template.suffix}` : '';
  }
  if (/[\r\n]/.test(value) || (template.field !== 'comment' && value.trim().length === 0)) {
    return '';
  }
  return `${template.prefix}${value}${template.suffix}`.trim();
}

export function formatVisualDnsRule(domain: string, allow: boolean, scope: RuleMatchScope,
  queryType: RuleQueryType): string {
  const host: string = scope === 'exact' ? `|${domain}|` : `${scope === 'wildcard' ? '||*.' : '||'}${domain}^`;
  return `${allow ? '@@' : ''}${host}${queryType === 'all' ? '' : `$dnstype=${queryType}`}`;
}

export function parseVisualDnsRule(line: string): VisualDnsRule | undefined {
  const parts: RegExpExecArray | null = /^(@@)?(\|\|\*\.|\|\||\|)([a-z0-9.-]+)(\^|\|)(?:\$dnstype=(A|AAAA))?$/i.exec(line);
  if (parts === null || (parts[2] !== '|' && parts[4] !== '^')) {
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
    scope: parts[2] === '||*.' ? 'wildcard' : (parts[2] === '||' ? 'domainAndSubdomains' : 'exact'),
    queryType: type === 'A' || type === 'AAAA' ? type : 'all',
  };
}
