import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { connection, vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
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
const UPSTREAM_DNS_FILE_NAME = 'upstream.txt';
const WANT_STATUS_FILE_PATH = 'statusFilePath';
const WANT_RULES_FILE_PATH = 'rulesFilePath';
const WANT_QUERY_LOG_FILE_PATH = 'queryLogFilePath';
const WANT_DEBUG_LOG_FILE_PATH = 'debugLogFilePath';
const WANT_UPSTREAM_DNS_FILE_PATH = 'upstreamDnsFilePath';
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
const UPSTREAM_DNS_IP = '119.29.29.29';
// Host-route prefix lengths used to pull individual DNS resolver IPs into the
// tun (see PUBLIC_DNS_RESOLVERS / dnsCaptureRouteIps).
const IPV4_HOST_PREFIX_LENGTH = 32;
const IPV6_HOST_PREFIX_LENGTH = 128;
// Debounce window for network-change events. A single Wi-Fi (dis)connect fires
// several callbacks (netAvailable + properties + capabilities) in a burst; we
// wait for it to settle, then re-evaluate the capture routes once.
const NET_CHANGE_DEBOUNCE_MS = 1500;
// Well-known public DNS resolvers. This is a DNS-only split-tunnel VPN: only the
// tun subnet is routed, and we merely advertise 10.8.0.1 as the resolver. But on
// Wi-Fi the system and many apps send DNS straight to the network's DHCP resolver
// or a hard-coded public resolver instead of 10.8.0.1; those packets are outside
// the tun subnet, so they escape the filter (this is why interception "stops"
// once Wi-Fi connects). We add a /32 (or /128) host route for each resolver below
// — plus the underlying network's actual DNS servers, fetched at start — so those
// queries are captured too. No routing loop results: blockedApplications excludes
// this app, so our own upstream forwarding sockets still egress on the real
// network even when their destination IP is one of these.
const PUBLIC_DNS_RESOLVERS: string[] = [
  // AliDNS
  '223.5.5.5', '223.6.6.6', '2400:3200::1', '2400:3200:baba::1',
  // DNSPod / Tencent
  '119.29.29.29', '182.254.116.116', '2402:4e00::',
  // 114DNS
  '114.114.114.114', '114.114.115.115',
  // Baidu
  '180.76.76.76',
  // Google
  '8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844',
  // Cloudflare
  '1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001',
  // Quad9 / OpenDNS
  '9.9.9.9', '208.67.222.222', '208.67.220.220',
];
// Full-mode (embedded AdGuardHome) runtime files and fixed loopback ports.
const AGH_CONFIG_FILE_NAME = 'AdGuardHome.yaml';
const AGH_WORK_DIR_NAME = 'agh';
const AGH_LOG_FILE_NAME = 'agh.log';
const AGH_DNS_PORT = 5354;
const AGH_HTTP_PORT_DEFAULT = 3000;
const WANT_AGH_HTTP_PORT = 'aghHttpPort';
const AGH_SCHEMA_VERSION = 29;
const WANT_FILTER_MODE = 'filterMode';
const FILTER_MODE_FULL = 'full';
const FILTER_MODE_LIGHTWEIGHT = 'lightweight';
// Full-mode-only AdGuardHome extras, passed from the UI as JSON strings and
// baked into AdGuardHome.yaml at start (online filter subscriptions, DNS
// rewrites, and advanced DNS settings). They are ignored in lightweight mode.
const WANT_AGH_FILTERS_JSON = 'aghFiltersJson';
const WANT_AGH_REWRITES_JSON = 'aghRewritesJson';
const WANT_AGH_ADVANCED_JSON = 'aghAdvancedJson';
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

// Full-mode AdGuardHome extras decoded from the Want JSON params.
interface AghFilterEntry {
  id: number;
  name: string;
  url: string;
  enabled: boolean;
}

interface AghRewriteEntry {
  domain: string;
  answer: string;
}

interface AghAdvancedConfig {
  blockingMode: string;
  upstreamMode: string;
  enableDnssec: boolean;
  cacheEnabled: boolean;
  cacheSizeMb: number;
  cacheOptimistic: boolean;
  ratelimit: number;
}

export default class MyVpnExtAbility extends VpnExtensionAbility {
  private vpnConnection?: vpnExtension.VpnConnection;
  private tunFd: number = -1;
  private statusFilePath: string = '';
  private rulesFilePath: string = '';
  private queryLogFilePath: string = '';
  private debugLogFilePath: string = '';
  private upstreamDnsFilePath: string = '';
  private upstreamDnsIp: string = UPSTREAM_DNS_IP;
  private filterMode: string = FILTER_MODE_LIGHTWEIGHT;
  private aghConfigFilePath: string = '';
  private aghWorkDirPath: string = '';
  private aghLogFilePath: string = '';
  private aghFiltersJson: string = '[]';
  private aghRewritesJson: string = '[]';
  private aghAdvancedJson: string = '';
  private aghHttpPort: number = AGH_HTTP_PORT_DEFAULT;
  private dnsCacheTtlSeconds: number = DEFAULT_DNS_CACHE_TTL_SECONDS;
  private logRetentionDays: number = DEFAULT_LOG_RETENTION_DAYS;
  private logMaxSizeMb: number = DEFAULT_LOG_MAX_SIZE_MB;
  private clearDnsLogOnStart: boolean = false;
  private clearDebugLogOnStart: boolean = false;
  private statusTimer: number = -1;
  private lastPhase: string = 'idle';
  private lastRunning: boolean = false;
  private lastNote: string = 'DNS filter has not been started yet.';
  private lastRulesSignature: string = '';
  private lastUpstreamSignature: string = '';
  // Network-change watcher (Tier 2): when the underlying network switches, its
  // DNS servers change, so the per-resolver host routes baked into the tun at
  // create() go stale. We watch for changes and rebuild the tun when the set of
  // captured resolver IPs actually differs.
  private netConn?: connection.NetConnection;
  private netListenerActive: boolean = false;
  private netChangeDebounceTimer: number = -1;
  private lastDnsCaptureSignature: string = '';
  private reconfiguring: boolean = false;
  private netRecheckPending: boolean = false;

  private isLegacyDefaultRulesText(content: string): boolean {
    return content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim() === LEGACY_DEFAULT_RULES_TEXT;
  }

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, '==/vpn_ext/onCreate/ ability=%{public}s', want.abilityName ?? '');
    this.ensureRuntimeFiles(want);
    // Smoke test (increment 1): prove the prebuilt AdGuardHome full-mode .so
    // links and loads inside the native module. Does not affect the lightweight
    // DNS path.
    try {
      const aghVer: string = vpnclientbridge.aghVersion();
      hilog.info(DOMAIN, TAG, '==/vpn_ext/agh_version/ %{public}s', aghVer);
      this.appendDebugLog(`==/vpn_ext/agh_version/ ${aghVer}`);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '==/vpn_ext/agh_version_error/ %{public}s', this.errorMessage(err));
    }
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
    const upstreamDnsPath = this.wantStringParam(want, WANT_UPSTREAM_DNS_FILE_PATH);

    this.statusFilePath = statusPath.length > 0 ? statusPath : `${vpnDir}/${STATUS_FILE_NAME}`;
    this.rulesFilePath = rulesPath.length > 0 ? rulesPath : `${vpnDir}/${RULES_FILE_NAME}`;
    this.queryLogFilePath = queryLogPath.length > 0 ? queryLogPath : `${vpnDir}/${QUERY_LOG_FILE_NAME}`;
    this.debugLogFilePath = debugLogPath.length > 0 ? debugLogPath : `${vpnDir}/${DEBUG_LOG_FILE_NAME}`;
    this.upstreamDnsFilePath = upstreamDnsPath.length > 0 ? upstreamDnsPath : `${vpnDir}/${UPSTREAM_DNS_FILE_NAME}`;
    this.filterMode = this.wantStringParam(want, WANT_FILTER_MODE) === FILTER_MODE_FULL
      ? FILTER_MODE_FULL
      : FILTER_MODE_LIGHTWEIGHT;
    this.aghConfigFilePath = `${vpnDir}/${AGH_CONFIG_FILE_NAME}`;
    this.aghWorkDirPath = `${vpnDir}/${AGH_WORK_DIR_NAME}`;
    this.aghLogFilePath = `${vpnDir}/${AGH_LOG_FILE_NAME}`;
    this.aghFiltersJson = this.wantStringParam(want, WANT_AGH_FILTERS_JSON);
    this.aghRewritesJson = this.wantStringParam(want, WANT_AGH_REWRITES_JSON);
    this.aghAdvancedJson = this.wantStringParam(want, WANT_AGH_ADVANCED_JSON);
    const httpPort: number = this.wantNumberParam(want, WANT_AGH_HTTP_PORT, AGH_HTTP_PORT_DEFAULT);
    this.aghHttpPort = (httpPort >= 1024 && httpPort <= 65535) ? httpPort : AGH_HTTP_PORT_DEFAULT;
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
    this.upstreamDnsIp = this.readUpstreamDnsFromFile();
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

  private buildVpnConfig(dnsCaptureIps: string[]): vpnExtension.VpnConfig {
    const routes: vpnExtension.RouteInfo[] = [{
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
    }];
    // Pull each well-known/underlying DNS resolver IP into the tun via a host
    // route so DNS sent to them (instead of our advertised 10.8.0.1) is captured.
    dnsCaptureIps.forEach((ip: string) => {
      routes.push(this.buildHostRoute(ip));
    });

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
      routes: routes,
      mtu: 1400,
      dnsAddresses: [DNS_SERVER_IP, DNS_SERVER_IPV6],
      isIPv4Accepted: true,
      isIPv6Accepted: true,
      blockedApplications: [APP_BUNDLE_NAME],
    };
  }

  // Build a single-host (/32 or /128) tun route for one resolver IP.
  private buildHostRoute(ip: string): vpnExtension.RouteInfo {
    const isV6: boolean = ip.includes(':');
    return {
      interface: 'vpn-tun',
      destination: {
        address: {
          address: ip,
          family: isV6 ? 2 : 1,
          port: 0,
        },
        prefixLength: isV6 ? IPV6_HOST_PREFIX_LENGTH : IPV4_HOST_PREFIX_LENGTH,
      },
      gateway: {
        address: isV6 ? '::' : '0.0.0.0',
        family: isV6 ? 2 : 1,
        port: 0,
      },
      hasGateway: false,
      isDefaultRoute: false,
    };
  }

  // The full, de-duplicated list of resolver IPs to capture via host routes:
  // the built-in public resolvers plus the underlying network's current DNS
  // servers. Our own tun/DNS addresses and loopback are excluded.
  private dnsCaptureRouteIps(underlyingDnsIps: string[]): string[] {
    const skip: string[] = [DNS_SERVER_IP, DNS_SERVER_IPV6, TUN_ADDRESS_IP, TUN_ADDRESS_IPV6];
    const out: string[] = [];
    const consider = (raw: string): void => {
      const ip: string = raw.trim();
      if (ip.length === 0 || skip.includes(ip) || out.includes(ip)) {
        return;
      }
      if (ip.startsWith('127.') || ip === '::1' || ip === '0.0.0.0' || ip === '::') {
        return;
      }
      if (!this.isLikelyIpAddress(ip)) {
        return;
      }
      out.push(ip);
    };
    PUBLIC_DNS_RESOLVERS.forEach(consider);
    underlyingDnsIps.forEach(consider);
    return out;
  }

  // Read the DNS servers of the current default (physical) network. Called just
  // before create(), while the underlying network is still the default, so on
  // Wi-Fi this returns the DHCP-pushed resolver(s) (e.g. the gateway). Best
  // effort: any failure (e.g. missing permission) degrades to public resolvers
  // only.
  private async queryUnderlyingDnsServers(): Promise<string[]> {
    const result: string[] = [];
    try {
      const netHandle: connection.NetHandle = await connection.getDefaultNet();
      if (netHandle.netId === 0) {
        return result;
      }
      const props: connection.ConnectionProperties = await connection.getConnectionProperties(netHandle);
      const servers: connection.NetAddress[] = props.dnses ?? [];
      servers.forEach((s: connection.NetAddress) => {
        const ip: string = (s.address ?? '').trim();
        if (ip.length > 0 && this.isLikelyIpAddress(ip) && !result.includes(ip)) {
          result.push(ip);
        }
      });
    } catch (err) {
      this.appendDebugLog(`==/vpn_ext/underlying_dns_error/ ${this.errorMessage(err)}`);
    }
    return result;
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
      this.upstreamDnsIp
    );
    this.appendDebugLog(`==/vpn_ext/config/ tun4=${TUN_ADDRESS_IP} dns4=${DNS_SERVER_IP} route4=${IPV4_ROUTE}/${IPV4_PREFIX_LENGTH} tun6=${TUN_ADDRESS_IPV6} dns6=${DNS_SERVER_IPV6} route6=${IPV6_ROUTE}/${IPV6_PREFIX_LENGTH} upstream=${this.upstreamDnsIp}`);
  }

  private async setupVpn(): Promise<void> {
    if (this.vpnConnection === undefined) {
      throw new Error('VpnConnection is not available');
    }

    await this.createTunAndStartFilter();

    // startDnsFilter already loaded the current rules and upstream, so seed the
    // baselines to avoid a redundant reload/apply on the first watch tick.
    this.lastRulesSignature = this.rulesFileSignature();
    this.lastUpstreamSignature = this.upstreamFileSignature();
    this.startStatusPump();
    // Re-pull the underlying DNS into the tun whenever the network changes
    // (e.g. Wi-Fi <-> cellular), so the capture host routes don't go stale.
    this.registerNetworkListener();
    this.writeStatus(
      'running',
      true,
      'DNS-only VPN is active. DNS requests are visible, rule-matched, and forwarded or blocked locally.'
    );
    hilog.info(DOMAIN, TAG, '==/vpn_ext/running/ tun_fd=%{public}d', this.tunFd);
    this.appendDebugLog(`==/vpn_ext/running/ tun_fd=${this.tunFd}`);
  }

  // Create the tun and start the native DNS filter using routes computed from
  // the current network. Shared by initial setup and live network-change
  // reconfiguration. Throws on any failure.
  private async createTunAndStartFilter(): Promise<void> {
    if (this.vpnConnection === undefined) {
      throw new Error('VpnConnection is not available');
    }

    try {
      this.logVpnConfig();
      this.writeStatus('creating', false, 'Creating DNS-only VPN and preparing the local filter engine.');
      // Capture DNS sent to the underlying network's resolvers and common public
      // resolvers (not just our advertised 10.8.0.1) so filtering survives Wi-Fi.
      const underlyingDns: string[] = await this.queryUnderlyingDnsServers();
      const dnsCaptureIps: string[] = this.dnsCaptureRouteIps(underlyingDns);
      this.lastDnsCaptureSignature = dnsCaptureIps.join(',');
      this.appendDebugLog(`==/vpn_ext/dns_capture_routes/ underlying=[${underlyingDns.join(',')}] captured=${dnsCaptureIps.length}`);
      hilog.info(DOMAIN, TAG, '==/vpn_ext/dns_capture_routes/ underlying=%{public}s captured=%{public}d',
        underlyingDns.join(','), dnsCaptureIps.length);
      this.tunFd = await this.vpnConnection.create(this.buildVpnConfig(dnsCaptureIps));
      hilog.info(DOMAIN, TAG, '==/vpn_ext/tun_created/ fd=%{public}d', this.tunFd);
      this.appendDebugLog(`==/vpn_ext/tun_created/ fd=${this.tunFd}`);
      if (this.tunFd < 0) {
        throw new Error('VPN create returned an invalid tun fd (-1). Please check system VPN authorization state.');
      }
      let nativeError: string | undefined;
      if (this.filterMode === FILTER_MODE_FULL) {
        // Full mode: hand all filtering to the embedded AdGuardHome engine.
        // Generate its config from the current rules/upstream, then start it and
        // relay TUN DNS to its loopback listener.
        this.writeAghConfig();
        try {
          fileIo.mkdirSync(this.aghWorkDirPath, true);
        } catch (_) {
        }
        nativeError = vpnclientbridge.startFullDnsFilter(
          this.tunFd,
          DNS_SERVER_IP,
          this.aghConfigFilePath,
          this.aghWorkDirPath,
          this.aghLogFilePath,
          AGH_DNS_PORT,
          this.queryLogFilePath
        );
        hilog.info(
          DOMAIN,
          TAG,
          '==/vpn_ext/native_start_full/ fd=%{public}d dns4=%{public}s agh_cfg=%{public}s agh_dir=%{public}s agh_port=%{public}d query=%{public}s',
          this.tunFd,
          DNS_SERVER_IP,
          this.aghConfigFilePath,
          this.aghWorkDirPath,
          AGH_DNS_PORT,
          this.queryLogFilePath
        );
        this.appendDebugLog(`==/vpn_ext/native_start_full/ fd=${this.tunFd} dns4=${DNS_SERVER_IP} agh_cfg=${this.aghConfigFilePath} agh_dir=${this.aghWorkDirPath} agh_port=${AGH_DNS_PORT} query=${this.queryLogFilePath}`);
      } else {
        nativeError = vpnclientbridge.startDnsFilter(
          this.tunFd,
          DNS_SERVER_IP,
          this.upstreamDnsIp,
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
          this.upstreamDnsIp,
          this.rulesFilePath,
          this.queryLogFilePath,
          this.dnsCacheTtlSeconds
        );
        this.appendDebugLog(`==/vpn_ext/native_start/ fd=${this.tunFd} dns4=${DNS_SERVER_IP} upstream=${this.upstreamDnsIp} rules=${this.rulesFilePath} query=${this.queryLogFilePath} cache_ttl=${this.dnsCacheTtlSeconds}`);
      }
      if (nativeError !== undefined) {
        throw new Error(nativeError);
      }
    } catch (err) {
      throw new Error(this.errorMessage(err));
    }
  }

  // Tear down the running native filter and tun, then rebuild both with routes
  // computed from the current network. The status pump and the network listener
  // stay alive across this. Throws if the rebuild fails.
  private async reapplyVpnConfig(): Promise<void> {
    if (this.vpnConnection === undefined) {
      return;
    }
    this.appendDebugLog('==/vpn_ext/reapply_begin/');
    const nativeStopErr: string | undefined = vpnclientbridge.stopDnsFilter();
    if (nativeStopErr !== undefined) {
      this.appendDebugLog(`==/vpn_ext/reapply_native_stop_error/ ${nativeStopErr}`);
    }
    try {
      await this.vpnConnection.destroy();
    } catch (err) {
      this.appendDebugLog(`==/vpn_ext/reapply_destroy_error/ ${this.errorMessage(err)}`);
    }
    this.tunFd = -1;
    // Rebuild on a fresh VpnConnection instead of reusing the just-destroyed one,
    // so we never depend on create()-after-destroy being supported on the same
    // handle. createVpnConnection only allocates a lightweight JS handle; the
    // system VPN authorization for this extension persists across it.
    this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    await this.createTunAndStartFilter();
    // The native filter just reloaded rules/upstream from disk, so reseed the
    // watch baselines to avoid a redundant reload on the next tick.
    this.lastRulesSignature = this.rulesFileSignature();
    this.lastUpstreamSignature = this.upstreamFileSignature();
    this.writeStatus(
      'running',
      true,
      'DNS-only VPN is active. DNS requests are visible, rule-matched, and forwarded or blocked locally.'
    );
    this.appendDebugLog(`==/vpn_ext/reapply_done/ tun_fd=${this.tunFd}`);
  }

  // Subscribe to default-network changes so we can refresh the capture routes
  // when the underlying network (and thus its DNS) switches. Best effort:
  // failure to register just means no live refresh (a manual restart still
  // re-reads the network).
  private registerNetworkListener(): void {
    if (this.netListenerActive) {
      return;
    }
    try {
      this.netConn = connection.createNetConnection();
      this.netConn.register((err: BusinessError) => {
        if (err) {
          this.appendDebugLog(`==/vpn_ext/net_register_error/ ${this.errorMessage(err)}`);
        }
      });
      this.netConn.on('netAvailable', (_data: connection.NetHandle) => {
        this.scheduleNetworkReconfigure('netAvailable');
      });
      this.netConn.on('netConnectionPropertiesChange', (_data: connection.NetConnectionPropertyInfo) => {
        this.scheduleNetworkReconfigure('propertiesChange');
      });
      this.netConn.on('netLost', (_data: connection.NetHandle) => {
        this.scheduleNetworkReconfigure('netLost');
      });
      this.netListenerActive = true;
      this.appendDebugLog('==/vpn_ext/net_listener_registered/');
    } catch (err) {
      this.appendDebugLog(`==/vpn_ext/net_listener_register_exception/ ${this.errorMessage(err)}`);
    }
  }

  private unregisterNetworkListener(): void {
    if (this.netChangeDebounceTimer >= 0) {
      clearTimeout(this.netChangeDebounceTimer);
      this.netChangeDebounceTimer = -1;
    }
    if (this.netConn !== undefined) {
      try {
        this.netConn.unregister((err: BusinessError) => {
          if (err) {
            this.appendDebugLog(`==/vpn_ext/net_unregister_error/ ${this.errorMessage(err)}`);
          }
        });
      } catch (err) {
        this.appendDebugLog(`==/vpn_ext/net_unregister_exception/ ${this.errorMessage(err)}`);
      }
      this.netConn = undefined;
    }
    this.netListenerActive = false;
    this.netRecheckPending = false;
  }

  // Coalesce a burst of network callbacks into a single delayed re-evaluation.
  private scheduleNetworkReconfigure(reason: string): void {
    if (this.netChangeDebounceTimer >= 0) {
      clearTimeout(this.netChangeDebounceTimer);
    }
    this.netChangeDebounceTimer = setTimeout(() => {
      this.netChangeDebounceTimer = -1;
      this.onNetworkChanged(reason).catch((err: BusinessError) => {
        this.appendDebugLog(`==/vpn_ext/net_reconfigure_error/ ${this.errorMessage(err)}`);
        this.writeStatus('error', false, this.errorMessage(err));
      });
    }, NET_CHANGE_DEBOUNCE_MS);
  }

  // Re-read the underlying DNS and, if the captured resolver set changed, rebuild
  // the tun. Serialized via reconfiguring/netRecheckPending so overlapping bursts
  // don't run concurrent rebuilds but the final state is still applied.
  private async onNetworkChanged(reason: string): Promise<void> {
    if (this.reconfiguring) {
      this.netRecheckPending = true;
      return;
    }
    this.reconfiguring = true;
    try {
      for (;;) {
        this.netRecheckPending = false;
        if (this.tunFd < 0) {
          break;  // VPN not active; nothing to reconfigure
        }
        const underlyingDns: string[] = await this.queryUnderlyingDnsServers();
        if (underlyingDns.length === 0) {
          // No usable default network yet (transient loss / mid-switch). Keep the
          // current routes; a later netAvailable carrying real DNS reconfigures.
          this.appendDebugLog(`==/vpn_ext/net_change_skip_empty/ reason=${reason}`);
        } else {
          const signature: string = this.dnsCaptureRouteIps(underlyingDns).join(',');
          if (signature === this.lastDnsCaptureSignature) {
            this.appendDebugLog(`==/vpn_ext/net_change_noop/ reason=${reason} underlying=[${underlyingDns.join(',')}]`);
          } else {
            this.appendDebugLog(`==/vpn_ext/net_change_reconfigure/ reason=${reason} underlying=[${underlyingDns.join(',')}]`);
            await this.reapplyVpnConfig();
          }
        }
        if (!this.netRecheckPending) {
          break;
        }
      }
    } finally {
      this.reconfiguring = false;
    }
  }

  private startStatusPump(): void {
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
    }

    this.statusTimer = setInterval(() => {
      this.checkRulesReload();
      this.checkUpstreamReload();
      this.writeStatus(
        'running',
        true,
        'DNS-only VPN is active. DNS requests are visible, rule-matched, and forwarded or blocked locally.'
      );
    }, 1000);
  }

  private isLikelyIpAddress(value: string): boolean {
    const v: string = value.trim();
    if (v.length === 0) {
      return false;
    }
    if (v.includes(':')) {
      return /^[0-9a-fA-F:.]+$/.test(v);
    }
    const parts: string[] = v.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const part of parts) {
      if (!/^\d{1,3}$/.test(part)) {
        return false;
      }
      if (parseInt(part, 10) > 255) {
        return false;
      }
    }
    return true;
  }

  // Reads the upstream resolver from its file, falling back to the built-in
  // default when the file is missing, empty, or not a valid IP address.
  // Reads the upstream resolver list from its file (one or more IPs separated by
  // newlines/commas), keeping only valid, de-duplicated entries. Falls back to
  // the built-in default when nothing valid is found. The native layer applies
  // them in order with failover.
  private readUpstreamDnsFromFile(): string {
    const content: string = this.readTextFile(this.upstreamDnsFilePath);
    const valid: string[] = [];
    for (const raw of content.split(/[\s,;]+/)) {
      const ip: string = raw.trim();
      if (ip.length > 0 && this.isLikelyIpAddress(ip) && !valid.includes(ip)) {
        valid.push(ip);
      }
    }
    return valid.length > 0 ? valid.join('\n') : UPSTREAM_DNS_IP;
  }

  // Full mode: (re)generate AdGuardHome.yaml from the current upstream resolvers
  // and rule set. AdGuardHome unmarshals this onto its built-in defaults, so we
  // only emit the mobile-specific overrides (loopback binds, our upstreams, the
  // user rules, and no remote filter lists).
  private writeAghConfig(): void {
    const upstreams: string[] = [];
    for (const raw of this.upstreamDnsIp.split(/[\s,;\n]+/)) {
      const ip: string = raw.trim();
      if (ip.length > 0 && !upstreams.includes(ip)) {
        upstreams.push(ip);
      }
    }
    if (upstreams.length === 0) {
      upstreams.push(UPSTREAM_DNS_IP);
    }

    const rules: string[] = [];
    for (const rawLine of this.readTextFile(this.rulesFilePath).split('\n')) {
      const line: string = rawLine.trim();
      if (line.length > 0) {
        rules.push(line);
      }
    }

    const yaml: string = this.buildAghConfigYaml(upstreams, rules);
    this.writeTextFile(this.aghConfigFilePath, yaml);
    const filterCount: number = this.parseAghFilters().length;
    const rewriteCount: number = this.parseAghRewrites().length;
    const adv: AghAdvancedConfig = this.parseAghAdvanced();
    hilog.info(DOMAIN, TAG,
      '==/vpn_ext/agh_config_written/ upstreams=%{public}d rules=%{public}d filters=%{public}d rewrites=%{public}d blocking=%{public}s upstream_mode=%{public}s',
      upstreams.length, rules.length, filterCount, rewriteCount, this.normalizeBlockingMode(adv.blockingMode),
      this.normalizeUpstreamMode(adv.upstreamMode));
    this.appendDebugLog(`==/vpn_ext/agh_config_written/ upstreams=${upstreams.length} rules=${rules.length} filters=${filterCount} rewrites=${rewriteCount} blocking=${this.normalizeBlockingMode(adv.blockingMode)} upstream_mode=${this.normalizeUpstreamMode(adv.upstreamMode)} dnssec=${adv.enableDnssec} cache=${adv.cacheEnabled} ratelimit=${Math.max(0, Math.floor(adv.ratelimit))}`);
  }

  private yamlQuote(value: string): string {
    return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  }

  private buildAghConfigYaml(upstreams: string[], rules: string[]): string {
    const upstreamLines: string = upstreams.map((u: string) => `    - ${this.yamlQuote(u)}`).join('\n');
    const bootstrapLines: string = upstreams.map((u: string) => `    - ${this.yamlQuote(u)}`).join('\n');
    const userRulesBlock: string = rules.length > 0
      ? `user_rules:\n${rules.map((r: string) => `  - ${this.yamlQuote(r)}`).join('\n')}`
      : 'user_rules: []';

    const filters: AghFilterEntry[] = this.parseAghFilters();
    const rewrites: AghRewriteEntry[] = this.parseAghRewrites();
    const adv: AghAdvancedConfig = this.parseAghAdvanced();

    // Advanced DNS settings (inline into the dns: block). Ratelimit defaults to
    // 0 (unlimited): the C++ relay funnels every query through the single
    // 127.0.0.1 source, so AdGuardHome's per-client rate limit would otherwise
    // throttle the whole device.
    const upstreamMode: string = this.normalizeUpstreamMode(adv.upstreamMode);
    const cacheSize: number = adv.cacheEnabled ? Math.max(0, Math.floor(adv.cacheSizeMb)) * 1024 * 1024 : 0;
    const cacheOptimistic: boolean = adv.cacheEnabled && adv.cacheOptimistic;
    const ratelimit: number = Math.max(0, Math.floor(adv.ratelimit));

    // Online filter subscriptions -> AdGuardHome remote filter lists. Empty list
    // keeps the device on user_rules only; AdGuardHome downloads enabled lists a
    // few seconds after start (default filters_update_interval).
    let filtersBlock: string;
    if (filters.length === 0) {
      filtersBlock = 'filters: []';
    } else {
      const entries: string[] = [];
      filters.forEach((f: AghFilterEntry) => {
        entries.push(`  - enabled: ${f.enabled ? 'true' : 'false'}`);
        entries.push(`    url: ${this.yamlQuote(f.url)}`);
        entries.push(`    name: ${this.yamlQuote(f.name)}`);
        entries.push(`    id: ${Math.max(1, Math.floor(f.id))}`);
      });
      filtersBlock = `filters:\n${entries.join('\n')}`;
    }

    // filtering: block carries the blocking mode and the DNS rewrites. Only the
    // keys we emit override AdGuardHome's defaults; the rest stay default.
    const blockingMode: string = this.normalizeBlockingMode(adv.blockingMode);
    let rewritesBlock: string;
    if (rewrites.length === 0) {
      rewritesBlock = '  rewrites: []';
    } else {
      const rw: string[] = [];
      rewrites.forEach((r: AghRewriteEntry) => {
        rw.push(`    - domain: ${this.yamlQuote(r.domain)}`);
        rw.push(`      answer: ${this.yamlQuote(r.answer)}`);
      });
      rewritesBlock = `  rewrites:\n${rw.join('\n')}`;
    }
    const filteringBlock: string = `filtering:\n  blocking_mode: ${this.yamlQuote(blockingMode)}\n${rewritesBlock}`;

    const lines: string[] = [
      `schema_version: ${AGH_SCHEMA_VERSION}`,
      'http:',
      `  address: 127.0.0.1:${this.aghHttpPort}`,
      'dns:',
      '  bind_hosts:',
      '    - 127.0.0.1',
      `  port: ${AGH_DNS_PORT}`,
      '  upstream_dns:',
      upstreamLines,
      '  bootstrap_dns:',
      bootstrapLines,
      `  upstream_mode: ${this.yamlQuote(upstreamMode)}`,
      `  enable_dnssec: ${adv.enableDnssec ? 'true' : 'false'}`,
      `  cache_size: ${cacheSize}`,
      `  cache_optimistic: ${cacheOptimistic ? 'true' : 'false'}`,
      `  ratelimit: ${ratelimit}`,
      filtersBlock,
      filteringBlock,
      userRulesBlock,
      '',
    ];
    return lines.join('\n');
  }

  private normalizeUpstreamMode(mode: string): string {
    if (mode === 'parallel' || mode === 'fastest_addr' || mode === 'load_balance') {
      return mode;
    }
    return 'load_balance';
  }

  private normalizeBlockingMode(mode: string): string {
    if (mode === 'nxdomain' || mode === 'refused' || mode === 'null_ip' || mode === 'custom_ip'
      || mode === 'default') {
      return mode;
    }
    return 'default';
  }

  private parseAghFilters(): AghFilterEntry[] {
    const out: AghFilterEntry[] = [];
    try {
      const arr = JSON.parse(this.aghFiltersJson.length > 0 ? this.aghFiltersJson : '[]') as AghFilterEntry[];
      if (Array.isArray(arr)) {
        arr.forEach((f: AghFilterEntry) => {
          const url: string = typeof f?.url === 'string' ? f.url.trim() : '';
          if (url.length === 0) {
            return;
          }
          out.push({
            id: typeof f?.id === 'number' && f.id > 0 ? Math.floor(f.id) : out.length + 1,
            name: typeof f?.name === 'string' && f.name.length > 0 ? f.name : url,
            url: url,
            enabled: f?.enabled !== false,
          });
        });
      }
    } catch (_) {
    }
    return out;
  }

  private parseAghRewrites(): AghRewriteEntry[] {
    const out: AghRewriteEntry[] = [];
    try {
      const arr = JSON.parse(this.aghRewritesJson.length > 0 ? this.aghRewritesJson : '[]') as AghRewriteEntry[];
      if (Array.isArray(arr)) {
        arr.forEach((r: AghRewriteEntry) => {
          const domain: string = typeof r?.domain === 'string' ? r.domain.trim() : '';
          const answer: string = typeof r?.answer === 'string' ? r.answer.trim() : '';
          if (domain.length === 0 || answer.length === 0) {
            return;
          }
          out.push({ domain: domain, answer: answer });
        });
      }
    } catch (_) {
    }
    return out;
  }

  private parseAghAdvanced(): AghAdvancedConfig {
    const def: AghAdvancedConfig = {
      blockingMode: 'default',
      upstreamMode: 'load_balance',
      enableDnssec: false,
      cacheEnabled: true,
      cacheSizeMb: 4,
      cacheOptimistic: false,
      ratelimit: 0,
    };
    if (this.aghAdvancedJson.trim().length === 0) {
      return def;
    }
    try {
      const a = JSON.parse(this.aghAdvancedJson) as AghAdvancedConfig;
      return {
        blockingMode: typeof a?.blockingMode === 'string' ? a.blockingMode : def.blockingMode,
        upstreamMode: typeof a?.upstreamMode === 'string' ? a.upstreamMode : def.upstreamMode,
        enableDnssec: typeof a?.enableDnssec === 'boolean' ? a.enableDnssec : def.enableDnssec,
        cacheEnabled: typeof a?.cacheEnabled === 'boolean' ? a.cacheEnabled : def.cacheEnabled,
        cacheSizeMb: typeof a?.cacheSizeMb === 'number' && a.cacheSizeMb >= 0 ? a.cacheSizeMb : def.cacheSizeMb,
        cacheOptimistic: typeof a?.cacheOptimistic === 'boolean' ? a.cacheOptimistic : def.cacheOptimistic,
        ratelimit: typeof a?.ratelimit === 'number' && a.ratelimit >= 0 ? a.ratelimit : def.ratelimit,
      };
    } catch (_) {
      return def;
    }
  }

  private rulesFileSignature(): string {
    try {
      const stat = fileIo.statSync(this.rulesFilePath);
      return `${stat.mtime}:${stat.size}`;
    } catch (_) {
      return '';
    }
  }

  private upstreamFileSignature(): string {
    try {
      const stat = fileIo.statSync(this.upstreamDnsFilePath);
      return `${stat.mtime}:${stat.size}`;
    } catch (_) {
      return '';
    }
  }

  // Apply an upstream DNS change live: when the UI rewrites the upstream file,
  // switch the running filter's resolver (and flush its cache) without a
  // full VPN restart.
  private checkUpstreamReload(): void {
    // In full mode the embedded AdGuardHome owns the upstream; applying it to
    // the lightweight engine would corrupt the loopback relay. Upstream changes
    // take effect on the next filter restart.
    if (this.filterMode === FILTER_MODE_FULL) {
      return;
    }
    const signature: string = this.upstreamFileSignature();
    if (signature.length === 0 || signature === this.lastUpstreamSignature) {
      return;
    }
    this.lastUpstreamSignature = signature;

    const nextUpstream: string = this.readUpstreamDnsFromFile();
    if (nextUpstream === this.upstreamDnsIp) {
      return;
    }
    this.upstreamDnsIp = nextUpstream;

    try {
      const err: string | undefined = vpnclientbridge.setUpstreamDns(nextUpstream);
      if (err !== undefined) {
        hilog.error(DOMAIN, TAG, '==/vpn_ext/upstream_set_error/ %{public}s', err);
        this.appendDebugLog(`==/vpn_ext/upstream_set_error/ ${err}`);
      } else {
        hilog.info(DOMAIN, TAG, '==/vpn_ext/upstream_set/ upstream=%{public}s', nextUpstream);
        this.appendDebugLog(`==/vpn_ext/upstream_set/ upstream=${nextUpstream}`);
      }
    } catch (err) {
      this.appendDebugLog(`==/vpn_ext/upstream_set_exception/ ${this.errorMessage(err)}`);
    }
  }

  // Apply rule edits live: when the UI rewrites the rules file, hot-swap the
  // running filter's rule set instead of forcing a full VPN restart.
  private checkRulesReload(): void {
    // In full mode rules are baked into AdGuardHome.yaml at start; AdGuardHome
    // is not hot-reloaded here. Rule changes take effect on the next restart.
    if (this.filterMode === FILTER_MODE_FULL) {
      return;
    }
    const signature: string = this.rulesFileSignature();
    if (signature.length === 0 || signature === this.lastRulesSignature) {
      return;
    }
    this.lastRulesSignature = signature;

    try {
      const err: string | undefined = vpnclientbridge.reloadDnsRules(this.rulesFilePath);
      if (err !== undefined) {
        hilog.error(DOMAIN, TAG, '==/vpn_ext/rules_reload_error/ %{public}s', err);
        this.appendDebugLog(`==/vpn_ext/rules_reload_error/ ${err}`);
      } else {
        hilog.info(DOMAIN, TAG, '==/vpn_ext/rules_reloaded/ rules=%{public}s', this.rulesFilePath);
        this.appendDebugLog(`==/vpn_ext/rules_reloaded/ rules=${this.rulesFilePath}`);
      }
    } catch (err) {
      this.appendDebugLog(`==/vpn_ext/rules_reload_exception/ ${this.errorMessage(err)}`);
    }
  }

  private async destroyVpn(): Promise<void> {
    this.unregisterNetworkListener();
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
