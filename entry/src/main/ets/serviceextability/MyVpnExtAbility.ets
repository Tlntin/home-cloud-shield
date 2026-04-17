import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import vpnclientbridge from 'libvpnclientbridge.so';

const DOMAIN = 0x0000;
const TAG = 'vpn_ext';
const APP_BUNDLE_NAME = 'com.tlntin.home_cloud_shield';
const VPN_DIR_NAME = 'vpn';
const STATUS_FILE_NAME = 'status.json';
const RULES_FILE_NAME = 'filters.txt';
const QUERY_LOG_FILE_NAME = 'dns_queries.jsonl';
const DEBUG_LOG_FILE_NAME = 'debug.log';
const WANT_STATUS_FILE_PATH = 'statusFilePath';
const WANT_RULES_FILE_PATH = 'rulesFilePath';
const WANT_QUERY_LOG_FILE_PATH = 'queryLogFilePath';
const WANT_DEBUG_LOG_FILE_PATH = 'debugLogFilePath';
const WANT_DNS_CACHE_TTL_SECONDS = 'dnsCacheTtlSeconds';
const WANT_LOG_RETENTION_DAYS = 'logRetentionDays';
const WANT_LOG_MAX_SIZE_MB = 'logMaxSizeMb';
const WANT_CLEAR_DNS_LOG_ON_START = 'clearDnsLogOnStart';
const WANT_CLEAR_DEBUG_LOG_ON_START = 'clearDebugLogOnStart';
const DEFAULT_DNS_CACHE_TTL_SECONDS = 3600;
const DEFAULT_LOG_RETENTION_DAYS = 0;
const DEFAULT_LOG_MAX_SIZE_MB = 0;
const TUN_ADDRESS_IP = '10.8.0.2';
const DNS_SERVER_IP = '10.8.0.1';
const IPV4_ROUTE = '10.8.0.0';
const IPV4_PREFIX_LENGTH = 24;
const TUN_ADDRESS_IPV6 = 'fd00:ad00::2';
const DNS_SERVER_IPV6 = 'fd00:ad00::1';
const IPV6_ROUTE = 'fd00:ad00::';
const IPV6_PREFIX_LENGTH = 64;
const UPSTREAM_DNS_IP = '94.140.14.14';
const LEGACY_DEFAULT_RULES_TEXT = [
  '! AdGuard-style DNS rules',
  '! Supported examples:',
  '!   ||doubleclick.net^',
  '!   @@||allowed.example.com^',
  '!   ads.example.org',
  '||doubleclick.net^',
  '||googleadservices.com^',
  '||googlesyndication.com^'
].join('\n');

interface NativeStats {
  running: boolean;
  tunFd: number;
  startedAtMs: number;
  totalPackets: number;
  totalBytes: number;
  ipv4Packets: number;
  ipv6Packets: number;
  tcpPackets: number;
  udpPackets: number;
  dnsPackets: number;
  allowedQueries: number;
  blockedQueries: number;
  loggedQueries: number;
  dnsCacheHits: number;
  dnsCacheMisses: number;
  lastQueryDomain: string;
  lastMatchedRule: string;
  lastError: string;
}

interface StatusSnapshot {
  phase: string;
  running: boolean;
  note: string;
  updatedAt: string;
  tunFd: number;
  nativeStats: NativeStats;
}

export default class MyVpnExtAbility extends VpnExtensionAbility {
  private vpnConnection?: vpnExtension.VpnConnection;
  private tunFd: number = -1;
  private statusFilePath: string = '';
  private rulesFilePath: string = '';
  private queryLogFilePath: string = '';
  private debugLogFilePath: string = '';
  private dnsCacheTtlSeconds: number = DEFAULT_DNS_CACHE_TTL_SECONDS;
  private logRetentionDays: number = DEFAULT_LOG_RETENTION_DAYS;
  private logMaxSizeMb: number = DEFAULT_LOG_MAX_SIZE_MB;
  private clearDnsLogOnStart: boolean = false;
  private clearDebugLogOnStart: boolean = false;
  private statusTimer: number = -1;
  private lastPhase: string = 'idle';
  private lastRunning: boolean = false;
  private lastNote: string = 'DNS filter has not been started yet.';

  private isLegacyDefaultRulesText(content: string): boolean {
    return content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim() === LEGACY_DEFAULT_RULES_TEXT;
  }

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, '==/vpn_ext/onCreate/ ability=%{public}s', want.abilityName ?? '');
    this.ensureRuntimeFiles(want);
    this.writeStatus('starting', false, 'Preparing DNS filter runtime.');
    this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    this.setupVpn().catch((err: BusinessError) => {
      const message = this.errorMessage(err);
      this.writeStatus('error', false, message);
      hilog.error(DOMAIN, TAG, '==/vpn_ext/setup_error/ %{public}s', message);
      this.destroyVpn().catch(() => {
      });
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', '==/vpn_ext/onDestroy/');
    this.destroyVpn().catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, '==/vpn_ext/destroy_error/ %{public}s', this.errorMessage(err));
    });
  }

  private ensureRuntimeFiles(want: Want): void {
    const vpnDir = `${this.context.filesDir}/${VPN_DIR_NAME}`;
    const statusPath = this.wantStringParam(want, WANT_STATUS_FILE_PATH);
    const rulesPath = this.wantStringParam(want, WANT_RULES_FILE_PATH);
    const queryLogPath = this.wantStringParam(want, WANT_QUERY_LOG_FILE_PATH);
    const debugLogPath = this.wantStringParam(want, WANT_DEBUG_LOG_FILE_PATH);

    this.statusFilePath = statusPath.length > 0 ? statusPath : `${vpnDir}/${STATUS_FILE_NAME}`;
    this.rulesFilePath = rulesPath.length > 0 ? rulesPath : `${vpnDir}/${RULES_FILE_NAME}`;
    this.queryLogFilePath = queryLogPath.length > 0 ? queryLogPath : `${vpnDir}/${QUERY_LOG_FILE_NAME}`;
    this.debugLogFilePath = debugLogPath.length > 0 ? debugLogPath : `${vpnDir}/${DEBUG_LOG_FILE_NAME}`;
    this.dnsCacheTtlSeconds = this.wantNumberParam(want, WANT_DNS_CACHE_TTL_SECONDS, DEFAULT_DNS_CACHE_TTL_SECONDS);
    this.logRetentionDays = this.wantNumberParam(want, WANT_LOG_RETENTION_DAYS, DEFAULT_LOG_RETENTION_DAYS);
    this.logMaxSizeMb = this.wantNumberParam(want, WANT_LOG_MAX_SIZE_MB, DEFAULT_LOG_MAX_SIZE_MB);
    this.clearDnsLogOnStart = this.wantBooleanParam(want, WANT_CLEAR_DNS_LOG_ON_START, false);
    this.clearDebugLogOnStart = this.wantBooleanParam(want, WANT_CLEAR_DEBUG_LOG_ON_START, false);
    try {
      fileIo.mkdirSync(vpnDir, true);
    } catch (_) {
    }

    const existingRules: string = this.readTextFile(this.rulesFilePath);
    if (this.isLegacyDefaultRulesText(existingRules)) {
      this.writeTextFile(this.rulesFilePath, '');
    }
    this.prepareLogFile(this.queryLogFilePath, this.clearDnsLogOnStart, this.logRetentionDays, this.logMaxSizeMb, true);
    this.prepareLogFile(this.debugLogFilePath, this.clearDebugLogOnStart, this.logRetentionDays, this.logMaxSizeMb, false);
    hilog.info(
      DOMAIN,
      TAG,
      '==/vpn_ext/runtime_files/ status=%{public}s rules=%{public}s query=%{public}s',
      this.statusFilePath,
      this.rulesFilePath,
      this.queryLogFilePath
    );
    this.appendDebugLog(`==/vpn_ext/runtime_files/ status=${this.statusFilePath} rules=${this.rulesFilePath} query=${this.queryLogFilePath}`);
  }

  private wantStringParam(want: Want, key: string): string {
    try {
      const value = want.parameters?.[key];
      return typeof value === 'string' ? value : '';
    } catch (_) {
      return '';
    }
  }

  private wantNumberParam(want: Want, key: string, fallback: number): number {
    try {
      const value = want.parameters?.[key];
      if (typeof value === 'number' && Number.isFinite(value) && value >= 0) {
        return Math.floor(value);
      }
      if (typeof value === 'string') {
        const parsed = parseInt(value, 10);
        if (Number.isFinite(parsed) && parsed >= 0) {
          return parsed;
        }
      }
    } catch (_) {
    }
    return fallback;
  }

  private wantBooleanParam(want: Want, key: string, fallback: boolean): boolean {
    try {
      const value = want.parameters?.[key];
      return typeof value === 'boolean' ? value : fallback;
    } catch (_) {
      return fallback;
    }
  }

  private prepareLogFile(path: string, clearOnStart: boolean, retentionDays: number, maxSizeMb: number,
    isDnsQueryLog: boolean): void {
    if (clearOnStart) {
      this.writeTextFile(path, '');
      return;
    }
    this.ensureTextFileExists(path);
    this.pruneLogFileByDays(path, retentionDays, isDnsQueryLog);
    this.truncateLogFileIfNeeded(path, maxSizeMb);
  }

  private pruneLogFileByDays(path: string, retentionDays: number, isDnsQueryLog: boolean): void {
    if (retentionDays <= 0) {
      return;
    }
    const content: string = this.readTextFile(path);
    if (content.trim().length === 0) {
      return;
    }
    const cutoffMs: number = Date.now() - retentionDays * 24 * 60 * 60 * 1000;
    const originalLines: string[] = content.split('\n');
    const keptLines: string[] = [];
    originalLines.forEach((rawLine: string) => {
      const line: string = rawLine.trim();
      if (line.length === 0) {
        return;
      }
      if (this.shouldKeepLogLine(line, cutoffMs, isDnsQueryLog)) {
        keptLines.push(line);
      }
    });
    if (keptLines.length === originalLines.filter((line: string) => line.trim().length > 0).length) {
      return;
    }
    this.writeTextFile(path, this.normalizeLogFileContent(keptLines));
    hilog.info(DOMAIN, TAG, '==/vpn_ext/log_pruned_days/ path=%{public}s days=%{public}d', path, retentionDays);
    this.appendDebugLog(`==/vpn_ext/log_pruned_days/ path=${path} days=${retentionDays}`);
  }

  private shouldKeepLogLine(line: string, cutoffMs: number, isDnsQueryLog: boolean): boolean {
    const timestampMs: number = isDnsQueryLog ? this.parseDnsLogTimestamp(line) : this.parseDebugLogTimestamp(line);
    if (!Number.isFinite(timestampMs)) {
      return true;
    }
    return timestampMs >= cutoffMs;
  }

  private parseDnsLogTimestamp(line: string): number {
    try {
      const entry = JSON.parse(line) as Record<string, number>;
      const ts = entry.ts;
      return typeof ts === 'number' && Number.isFinite(ts) ? ts : NaN;
    } catch (_) {
      return NaN;
    }
  }

  private parseDebugLogTimestamp(line: string): number {
    const firstSpace: number = line.indexOf(' ');
    if (firstSpace <= 0) {
      return NaN;
    }
    return Date.parse(line.slice(0, firstSpace));
  }

  private normalizeLogFileContent(lines: string[]): string {
    if (lines.length === 0) {
      return '';
    }
    return `${lines.join('\n')}\n`;
  }

  private truncateLogFileIfNeeded(path: string, maxSizeMb: number): void {
    if (maxSizeMb <= 0) {
      return;
    }
    const content: string = this.readTextFile(path);
    const maxChars: number = maxSizeMb * 1024 * 1024;
    if (content.length <= maxChars) {
      return;
    }
    let truncated: string = content.slice(content.length - maxChars);
    const firstNewlineIndex: number = truncated.indexOf('\n');
    if (firstNewlineIndex >= 0 && firstNewlineIndex < truncated.length - 1) {
      truncated = truncated.slice(firstNewlineIndex + 1);
    }
    this.writeTextFile(path, this.normalizeLogFileContent(truncated.split('\n').filter((line: string) => line.trim().length > 0)));
    hilog.info(DOMAIN, TAG, '==/vpn_ext/log_truncated/ path=%{public}s max_mb=%{public}d', path, maxSizeMb);
    this.appendDebugLog(`==/vpn_ext/log_truncated/ path=${path} max_mb=${maxSizeMb}`);
  }

  private ensureTextFileExists(path: string): void {
    let f: fileIo.File | undefined = undefined;
    try {
      f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    } catch (_) {
    } finally {
      if (f !== undefined) {
        try {
          fileIo.closeSync(f);
        } catch (_) {
        }
      }
    }
  }

  private buildVpnConfig(): vpnExtension.VpnConfig {
    return {
      addresses: [{
        address: {
          address: TUN_ADDRESS_IP,
          family: 1,
        },
        prefixLength: IPV4_PREFIX_LENGTH,
      }, {
        address: {
          address: TUN_ADDRESS_IPV6,
          family: 2,
        },
        prefixLength: IPV6_PREFIX_LENGTH,
      }],
      routes: [{
        interface: 'vpn-tun',
        destination: {
          address: {
            address: IPV4_ROUTE,
            family: 1,
            port: 0,
          },
          prefixLength: IPV4_PREFIX_LENGTH,
        },
        gateway: {
          address: '0.0.0.0',
          family: 1,
          port: 0,
        },
        hasGateway: false,
        isDefaultRoute: false,
      }, {
        interface: 'vpn-tun',
        destination: {
          address: {
            address: IPV6_ROUTE,
            family: 2,
            port: 0,
          },
          prefixLength: IPV6_PREFIX_LENGTH,
        },
        gateway: {
          address: '::',
          family: 2,
          port: 0,
        },
        hasGateway: false,
        isDefaultRoute: false,
      }],
      mtu: 1400,
      dnsAddresses: [DNS_SERVER_IP, DNS_SERVER_IPV6],
      isIPv4Accepted: true,
      isIPv6Accepted: true,
      blockedApplications: [APP_BUNDLE_NAME],
    };
  }

  private logVpnConfig(): void {
    hilog.info(
      DOMAIN,
      TAG,
      '==/vpn_ext/config/ tun4=%{public}s dns4=%{public}s route4=%{public}s/%{public}d tun6=%{public}s dns6=%{public}s route6=%{public}s/%{public}d upstream=%{public}s',
      TUN_ADDRESS_IP,
      DNS_SERVER_IP,
      IPV4_ROUTE,
      IPV4_PREFIX_LENGTH,
      TUN_ADDRESS_IPV6,
      DNS_SERVER_IPV6,
      IPV6_ROUTE,
      IPV6_PREFIX_LENGTH,
      UPSTREAM_DNS_IP
    );
    this.appendDebugLog(`==/vpn_ext/config/ tun4=${TUN_ADDRESS_IP} dns4=${DNS_SERVER_IP} route4=${IPV4_ROUTE}/${IPV4_PREFIX_LENGTH} tun6=${TUN_ADDRESS_IPV6} dns6=${DNS_SERVER_IPV6} route6=${IPV6_ROUTE}/${IPV6_PREFIX_LENGTH} upstream=${UPSTREAM_DNS_IP}`);
  }

  private async setupVpn(): Promise<void> {
    if (this.vpnConnection === undefined) {
      throw new Error('VpnConnection is not available');
    }

    try {
      this.logVpnConfig();
      this.writeStatus('creating', false, 'Creating DNS-only VPN and preparing the local filter engine.');
      this.tunFd = await this.vpnConnection.create(this.buildVpnConfig());
      hilog.info(DOMAIN, TAG, '==/vpn_ext/tun_created/ fd=%{public}d', this.tunFd);
      this.appendDebugLog(`==/vpn_ext/tun_created/ fd=${this.tunFd}`);
      if (this.tunFd < 0) {
        throw new Error('VPN create returned an invalid tun fd (-1). Please check system VPN authorization state.');
      }
      const nativeError: string | undefined = vpnclientbridge.startDnsFilter(
        this.tunFd,
        DNS_SERVER_IP,
        UPSTREAM_DNS_IP,
        this.rulesFilePath,
        this.queryLogFilePath,
        this.dnsCacheTtlSeconds
      );
      hilog.info(
        DOMAIN,
        TAG,
        '==/vpn_ext/native_start/ fd=%{public}d dns4=%{public}s upstream=%{public}s rules=%{public}s query=%{public}s cache_ttl=%{public}d',
        this.tunFd,
        DNS_SERVER_IP,
        UPSTREAM_DNS_IP,
        this.rulesFilePath,
        this.queryLogFilePath,
        this.dnsCacheTtlSeconds
      );
      this.appendDebugLog(`==/vpn_ext/native_start/ fd=${this.tunFd} dns4=${DNS_SERVER_IP} upstream=${UPSTREAM_DNS_IP} rules=${this.rulesFilePath} query=${this.queryLogFilePath} cache_ttl=${this.dnsCacheTtlSeconds}`);
      if (nativeError !== undefined) {
        throw new Error(nativeError);
      }
    } catch (err) {
      throw new Error(this.errorMessage(err));
    }

    this.startStatusPump();
    this.writeStatus(
      'running',
      true,
      'DNS-only VPN is active. DNS requests are visible, rule-matched, and forwarded or blocked locally.'
    );
    hilog.info(DOMAIN, TAG, '==/vpn_ext/running/ tun_fd=%{public}d', this.tunFd);
    this.appendDebugLog(`==/vpn_ext/running/ tun_fd=${this.tunFd}`);
  }

  private startStatusPump(): void {
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
    }

    this.statusTimer = setInterval(() => {
      this.writeStatus(
        'running',
        true,
        'DNS-only VPN is active. DNS requests are visible, rule-matched, and forwarded or blocked locally.'
      );
    }, 1000);
  }

  private async destroyVpn(): Promise<void> {
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }

    const nativeError: string | undefined = vpnclientbridge.stopDnsFilter();
    if (nativeError !== undefined) {
      hilog.error(DOMAIN, TAG, '==/vpn_ext/native_stop_error/ %{public}s', nativeError);
      this.appendDebugLog(`==/vpn_ext/native_stop_error/ ${nativeError}`);
    } else {
      hilog.info(DOMAIN, TAG, '%{public}s', '==/vpn_ext/native_stop_ok/');
      this.appendDebugLog('==/vpn_ext/native_stop_ok/');
    }

    if (this.vpnConnection !== undefined) {
      try {
        await this.vpnConnection.destroy();
      } catch (err) {
        hilog.error(DOMAIN, TAG, '==/vpn_ext/connection_destroy_error/ %{public}s', this.errorMessage(err));
        this.appendDebugLog(`==/vpn_ext/connection_destroy_error/ ${this.errorMessage(err)}`);
      }
    }

    const preserveFailure: boolean = this.lastPhase === 'error';
    this.tunFd = -1;
    if (preserveFailure) {
      this.writeStatus('error', false, this.lastNote);
    } else {
      this.writeStatus('stopped', false, 'DNS-only VPN has been stopped.');
    }
  }

  private parseNativeStats(): NativeStats {
    try {
      return JSON.parse(vpnclientbridge.getStats()) as NativeStats;
    } catch (err) {
      return {
        running: false,
        tunFd: this.tunFd,
        startedAtMs: 0,
        totalPackets: 0,
        totalBytes: 0,
        ipv4Packets: 0,
        ipv6Packets: 0,
        tcpPackets: 0,
        udpPackets: 0,
        dnsPackets: 0,
        allowedQueries: 0,
        blockedQueries: 0,
        loggedQueries: 0,
        dnsCacheHits: 0,
        dnsCacheMisses: 0,
        lastQueryDomain: '',
        lastMatchedRule: '',
        lastError: this.errorMessage(err),
      };
    }
  }

  private writeStatus(phase: string, running: boolean, note: string): void {
    this.lastPhase = phase;
    this.lastRunning = running;
    this.lastNote = note;
    const snapshot: StatusSnapshot = {
      phase: phase,
      running: running,
      note: note,
      updatedAt: new Date().toISOString(),
      tunFd: this.tunFd,
      nativeStats: this.parseNativeStats(),
    };
    this.writeTextFile(this.statusFilePath, JSON.stringify(snapshot));
  }

  private readTextFile(path: string): string {
    try {
      return fileIo.readTextSync(path);
    } catch (_) {
      return '';
    }
  }

  private writeTextFile(path: string, content: string): void {
    let f: fileIo.File | undefined = undefined;
    try {
      f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, content);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '==/vpn_ext/write_file_error/ path=%{public}s err=%{public}s', path,
        this.errorMessage(err));
      this.appendDebugLog(`==/vpn_ext/write_file_error/ path=${path} err=${this.errorMessage(err)}`);
    } finally {
      if (f !== undefined) {
        try {
          fileIo.closeSync(f);
        } catch (_) {
        }
      }
    }
  }

  private appendDebugLog(line: string): void {
    let f: fileIo.File | undefined = undefined;
    try {
      f = fileIo.openSync(this.debugLogFilePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
      fileIo.writeSync(f.fd, `${new Date().toISOString()} ${line}\n`);
    } catch (_) {
    } finally {
      if (f !== undefined) {
        try {
          fileIo.closeSync(f);
        } catch (_) {
        }
      }
    }
  }

  private errorMessage(err: Object): string {
    try {
      const msg = (err as Error).message;
      if (msg.length > 0) {
        return msg;
      }
    } catch (_) {
    }

    try {
      return JSON.stringify(err);
    } catch (_) {
      return `${err}`;
    }
  }
}
