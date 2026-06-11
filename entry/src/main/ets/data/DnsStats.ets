import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { DnsLogRow, DnsLogSummary } from './DnsLogDb';

// Persistent DNS query-log counters. The home stat cards used to run a full
// COUNT(*)/SUM() over the whole SQLite table every refresh tick, which freezes
// (and can OOM-crash) the UI once the table holds tens of thousands of rows.
// Instead the totals are maintained incrementally: every ingested log batch
// bumps these counters, and they are persisted in a Preferences store so a
// relaunch restores them without touching the table at all.
//
// Semantics: the counters are cumulative since the last "clear DNS requests".
// Retention pruning (which deletes old rows from the table) intentionally does
// NOT decrease them — the stat cards show lifetime totals, while the request
// list/pagination keeps reflecting what is actually stored.

const PREFS_NAME = 'dns_stats';
const KEY_TOTAL = 'total';
const KEY_BLOCKED = 'blocked';
const KEY_REQ_BYTES = 'reqBytes';
const KEY_RESP_BYTES = 'respBytes';
const KEY_LAST_DOMAIN = 'lastDomain';
const KEY_LAST_RULE = 'lastRule';
// Set once the counters have been initialized (either fresh-zero or seeded from
// the pre-existing table contents on first upgrade to incremental stats).
const KEY_SEEDED = 'seeded';

export class DnsStats {
  private prefs: preferences.Preferences | undefined = undefined;
  private total: number = 0;
  private blocked: number = 0;
  private requestBytes: number = 0;
  private responseBytes: number = 0;
  private lastDomain: string = '';
  private lastRule: string = '';
  private seeded: boolean = false;

  load(context: common.Context): void {
    if (this.prefs !== undefined) {
      return;
    }
    try {
      const options: preferences.Options = { name: PREFS_NAME };
      const p: preferences.Preferences = preferences.getPreferencesSync(context, options);
      this.prefs = p;
      this.total = p.getSync(KEY_TOTAL, 0) as number;
      this.blocked = p.getSync(KEY_BLOCKED, 0) as number;
      this.requestBytes = p.getSync(KEY_REQ_BYTES, 0) as number;
      this.responseBytes = p.getSync(KEY_RESP_BYTES, 0) as number;
      this.lastDomain = p.getSync(KEY_LAST_DOMAIN, '') as string;
      this.lastRule = p.getSync(KEY_LAST_RULE, '') as string;
      this.seeded = p.getSync(KEY_SEEDED, false) as boolean;
    } catch (err) {
    }
  }

  isSeeded(): boolean {
    return this.seeded;
  }

  // One-time migration: adopt the totals computed from the pre-existing table so
  // upgrading users keep their history, then switch to incremental updates.
  seedFrom(summary: DnsLogSummary): void {
    this.total = summary.total;
    this.blocked = summary.blocked;
    this.requestBytes = summary.requestBytes;
    this.responseBytes = summary.responseBytes;
    if (summary.lastDomain.length > 0) {
      this.lastDomain = summary.lastDomain;
      this.lastRule = summary.lastRule;
    }
    this.seeded = true;
    this.persist();
  }

  markSeeded(): void {
    this.seeded = true;
    this.persist();
  }

  // Bump counters for a freshly ingested batch (rows are in file order, so the
  // last one is the newest).
  addRows(rows: DnsLogRow[]): void {
    if (rows.length === 0) {
      return;
    }
    for (const r of rows) {
      this.total += 1;
      if (r.action.trim().toLowerCase() === 'blocked') {
        this.blocked += 1;
      }
      this.requestBytes += r.requestBytes;
      this.responseBytes += r.responseBytes;
    }
    const newest: DnsLogRow = rows[rows.length - 1];
    this.lastDomain = newest.domain;
    this.lastRule = newest.rule;
    this.persist();
  }

  reset(): void {
    this.total = 0;
    this.blocked = 0;
    this.requestBytes = 0;
    this.responseBytes = 0;
    this.lastDomain = '';
    this.lastRule = '';
    this.seeded = true;
    this.persist();
  }

  toSummary(): DnsLogSummary {
    return {
      total: this.total,
      allowed: Math.max(0, this.total - this.blocked),
      blocked: this.blocked,
      requestBytes: this.requestBytes,
      responseBytes: this.responseBytes,
      totalDnsBytes: this.requestBytes + this.responseBytes,
      lastDomain: this.lastDomain,
      lastRule: this.lastRule,
    };
  }

  private persist(): void {
    const p: preferences.Preferences | undefined = this.prefs;
    if (p === undefined) {
      return;
    }
    try {
      p.putSync(KEY_TOTAL, this.total);
      p.putSync(KEY_BLOCKED, this.blocked);
      p.putSync(KEY_REQ_BYTES, this.requestBytes);
      p.putSync(KEY_RESP_BYTES, this.responseBytes);
      p.putSync(KEY_LAST_DOMAIN, this.lastDomain);
      p.putSync(KEY_LAST_RULE, this.lastRule);
      p.putSync(KEY_SEEDED, this.seeded);
      p.flush();
    } catch (err) {
    }
  }
}

export const dnsStats: DnsStats = new DnsStats();
