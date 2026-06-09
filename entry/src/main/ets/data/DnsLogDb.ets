import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

// SQLite-backed store for DNS query-log events. The native layer keeps appending
// the jsonl file (cross-process WAL written by the VPN extension or the main
// process); the main process incrementally ingests new lines into this RDB and
// the UI runs all counts / pagination / filtering / leaderboard as cheap SQL,
// instead of re-scanning the whole jsonl every refresh tick. AdGuardHome's own
// querylog (full DNS-proxy mode) is ingested through the same table.

const DB_NAME = 'dns_log.db';
// v2: full-mode (AdGuardHome) rows in v1 were stored with broken blocked
// detection (everything "allowed") and an inaccurate source; on upgrade the
// table is wiped once so stats are correct from then on.
const DB_VERSION = 2;
const TABLE = 'dns_queries';

const SQL_CREATE = `
CREATE TABLE IF NOT EXISTS ${TABLE} (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL DEFAULT 0,
  domain TEXT NOT NULL DEFAULT '',
  qtype TEXT NOT NULL DEFAULT '',
  action TEXT NOT NULL DEFAULT 'allowed',
  rule TEXT NOT NULL DEFAULT '',
  source TEXT NOT NULL DEFAULT '',
  origin TEXT NOT NULL DEFAULT 'app',
  req_bytes INTEGER NOT NULL DEFAULT 0,
  resp_bytes INTEGER NOT NULL DEFAULT 0
)`;
const SQL_IDX_TS = `CREATE INDEX IF NOT EXISTS idx_dns_ts ON ${TABLE}(ts)`;
const SQL_IDX_ACTION_TS = `CREATE INDEX IF NOT EXISTS idx_dns_action_ts ON ${TABLE}(action, ts)`;
const SQL_IDX_DOMAIN = `CREATE INDEX IF NOT EXISTS idx_dns_domain ON ${TABLE}(domain)`;

// One DNS query-log row, shaped to match the UI's QueryLogEntry.
export interface DnsLogRow {
  ts: number;
  domain: string;
  qtype: string;
  action: string;
  rule: string;
  source: string;
  requestBytes: number;
  responseBytes: number;
  totalDnsBytes: number;
}

export interface DnsLogSummary {
  total: number;
  allowed: number;
  blocked: number;
  requestBytes: number;
  responseBytes: number;
  totalDnsBytes: number;
  lastDomain: string;
  lastRule: string;
}

export type DnsActionFilter = 'all' | 'allowed' | 'blocked';

export class DnsLogDb {
  private store: relationalStore.RdbStore | undefined = undefined;
  private initPromise: Promise<boolean> | undefined = undefined;

  isReady(): boolean {
    return this.store !== undefined;
  }

  async init(context: common.Context): Promise<boolean> {
    if (this.store !== undefined) {
      return true;
    }
    if (this.initPromise !== undefined) {
      return this.initPromise;
    }
    this.initPromise = this.doInit(context);
    try {
      return await this.initPromise;
    } finally {
      if (this.store === undefined) {
        this.initPromise = undefined;  // allow retry on failure
      }
    }
  }

  private async doInit(context: common.Context): Promise<boolean> {
    const config: relationalStore.StoreConfig = {
      name: DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1,
      encrypt: false,
    };
    try {
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
      let oldVersion: number = 0;
      try {
        oldVersion = (await store.execute('PRAGMA user_version')) as number;
      } catch (verErr) {
        oldVersion = 0;
      }
      await store.execute(SQL_CREATE);
      await store.execute(SQL_IDX_TS);
      await store.execute(SQL_IDX_ACTION_TS);
      await store.execute(SQL_IDX_DOMAIN);
      // One-time migration: an existing pre-v2 table holds rows whose blocked
      // status/source were computed wrongly, so wipe it (a fresh install has
      // oldVersion 0 and is left alone).
      if (oldVersion > 0 && oldVersion < DB_VERSION) {
        await store.execute(`DELETE FROM ${TABLE}`);
      }
      await store.execute(`PRAGMA user_version=${DB_VERSION}`);
      this.store = store;
      return true;
    } catch (err) {
      return false;
    }
  }

  // Batch-insert rows (one transaction). origin tags the source file ('app' or
  // 'agh') so per-origin watermarks can be recomputed after a restart.
  async insertRows(rows: DnsLogRow[], origin: string): Promise<void> {
    if (this.store === undefined || rows.length === 0) {
      return;
    }
    const buckets: relationalStore.ValuesBucket[] = [];
    for (const r of rows) {
      const bucket: relationalStore.ValuesBucket = {
        'ts': r.ts,
        'domain': r.domain,
        'qtype': r.qtype,
        'action': r.action,
        'rule': r.rule,
        'source': r.source,
        'origin': origin,
        'req_bytes': r.requestBytes,
        'resp_bytes': r.responseBytes,
      };
      buckets.push(bucket);
    }
    try {
      await this.store.batchInsert(TABLE, buckets);
    } catch (err) {
    }
  }

  // Newest ts already stored for an origin; used as the ingest watermark so a
  // full re-scan after launch / log rotation re-inserts only genuinely new rows.
  async maxTs(origin: string): Promise<number> {
    if (this.store === undefined) {
      return 0;
    }
    try {
      const rs = await this.store.querySql(`SELECT COALESCE(MAX(ts), 0) AS m FROM ${TABLE} WHERE origin = ?`, [origin]);
      let out: number = 0;
      if (rs.goToNextRow()) {
        out = rs.getLong(rs.getColumnIndex('m'));
      }
      rs.close();
      return Number.isFinite(out) ? out : 0;
    } catch (err) {
      return 0;
    }
  }

  async summary(): Promise<DnsLogSummary> {
    const empty: DnsLogSummary = {
      total: 0, allowed: 0, blocked: 0, requestBytes: 0, responseBytes: 0,
      totalDnsBytes: 0, lastDomain: '', lastRule: '',
    };
    if (this.store === undefined) {
      return empty;
    }
    try {
      const rs = await this.store.querySql(
        `SELECT COUNT(*) AS total,`
        + ` COALESCE(SUM(CASE WHEN action = 'blocked' THEN 1 ELSE 0 END), 0) AS blocked,`
        + ` COALESCE(SUM(req_bytes), 0) AS rq, COALESCE(SUM(resp_bytes), 0) AS rp FROM ${TABLE}`);
      let total: number = 0;
      let blocked: number = 0;
      let rq: number = 0;
      let rp: number = 0;
      if (rs.goToNextRow()) {
        total = rs.getLong(rs.getColumnIndex('total'));
        blocked = rs.getLong(rs.getColumnIndex('blocked'));
        rq = rs.getLong(rs.getColumnIndex('rq'));
        rp = rs.getLong(rs.getColumnIndex('rp'));
      }
      rs.close();

      let lastDomain: string = '';
      let lastRule: string = '';
      const rs2 = await this.store.querySql(
        `SELECT domain, rule FROM ${TABLE} ORDER BY ts DESC, id DESC LIMIT 1`);
      if (rs2.goToNextRow()) {
        lastDomain = rs2.getString(rs2.getColumnIndex('domain'));
        lastRule = rs2.getString(rs2.getColumnIndex('rule'));
      }
      rs2.close();

      return {
        total: total,
        allowed: total - blocked,
        blocked: blocked,
        requestBytes: rq,
        responseBytes: rp,
        totalDnsBytes: rq + rp,
        lastDomain: lastDomain,
        lastRule: lastRule,
      };
    } catch (err) {
      return empty;
    }
  }

  // Build the "WHERE ..." clause + bind args for an action filter + free-text
  // search (domain/qtype/action/rule). Returns clause starting with " WHERE" or ''.
  private buildWhere(action: string, search: string): WhereClause {
    const conds: string[] = [];
    const args: Array<relationalStore.ValueType> = [];
    if (action !== 'all') {
      conds.push('action = ?');
      args.push(action);
    }
    const kw: string = search.trim().toLowerCase();
    if (kw.length > 0) {
      const like: string = `%${kw}%`;
      conds.push('(LOWER(domain) LIKE ? OR LOWER(qtype) LIKE ? OR LOWER(action) LIKE ? OR LOWER(rule) LIKE ?)');
      args.push(like, like, like, like);
    }
    const clause: string = conds.length > 0 ? ` WHERE ${conds.join(' AND ')}` : '';
    return { clause: clause, args: args };
  }

  async countFor(action: string, search: string): Promise<number> {
    if (this.store === undefined) {
      return 0;
    }
    try {
      const where: WhereClause = this.buildWhere(action, search);
      const rs = await this.store.querySql(`SELECT COUNT(*) AS c FROM ${TABLE}${where.clause}`, where.args);
      let out: number = 0;
      if (rs.goToNextRow()) {
        out = rs.getLong(rs.getColumnIndex('c'));
      }
      rs.close();
      return out;
    } catch (err) {
      return 0;
    }
  }

  // One page of matching rows, newest first.
  async page(action: string, search: string, limit: number, offset: number): Promise<DnsLogRow[]> {
    return this.queryRows(action, search, limit, offset);
  }

  // The most recent `limit` rows regardless of filter (drives the leaderboard).
  async recentRows(limit: number): Promise<DnsLogRow[]> {
    return this.queryRows('all', '', limit, 0);
  }

  // All matching rows (capped) for export.
  async allFiltered(action: string, search: string, cap: number): Promise<DnsLogRow[]> {
    return this.queryRows(action, search, cap, 0);
  }

  private async queryRows(action: string, search: string, limit: number, offset: number): Promise<DnsLogRow[]> {
    const out: DnsLogRow[] = [];
    if (this.store === undefined) {
      return out;
    }
    try {
      const where: WhereClause = this.buildWhere(action, search);
      const args: Array<relationalStore.ValueType> = where.args.slice();
      args.push(limit, offset);
      const rs = await this.store.querySql(
        `SELECT ts, domain, qtype, action, rule, source, req_bytes, resp_bytes FROM ${TABLE}`
        + `${where.clause} ORDER BY ts DESC, id DESC LIMIT ? OFFSET ?`, args);
      const iTs: number = rs.getColumnIndex('ts');
      const iDomain: number = rs.getColumnIndex('domain');
      const iQtype: number = rs.getColumnIndex('qtype');
      const iAction: number = rs.getColumnIndex('action');
      const iRule: number = rs.getColumnIndex('rule');
      const iSource: number = rs.getColumnIndex('source');
      const iReq: number = rs.getColumnIndex('req_bytes');
      const iResp: number = rs.getColumnIndex('resp_bytes');
      while (rs.goToNextRow()) {
        const req: number = rs.getLong(iReq);
        const resp: number = rs.getLong(iResp);
        out.push({
          ts: rs.getLong(iTs),
          domain: rs.getString(iDomain),
          qtype: rs.getString(iQtype),
          action: rs.getString(iAction),
          rule: rs.getString(iRule),
          source: rs.getString(iSource),
          requestBytes: req,
          responseBytes: resp,
          totalDnsBytes: req + resp,
        });
      }
      rs.close();
    } catch (err) {
    }
    return out;
  }

  async clear(): Promise<void> {
    if (this.store === undefined) {
      return;
    }
    try {
      await this.store.execute(`DELETE FROM ${TABLE}`);
    } catch (err) {
    }
  }

  async pruneOlderThan(cutoffMs: number): Promise<void> {
    if (this.store === undefined || cutoffMs <= 0) {
      return;
    }
    try {
      await this.store.execute(`DELETE FROM ${TABLE} WHERE ts < ?`, [cutoffMs]);
    } catch (err) {
    }
  }
}

interface WhereClause {
  clause: string;
  args: Array<relationalStore.ValueType>;
}

export const dnsLogDb: DnsLogDb = new DnsLogDb();
