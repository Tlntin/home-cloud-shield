declare module 'libvpnclientbridge.so' {
  export function startDnsFilter(
    fd: number,
    dnsServerIp: string,
    upstreamDnsIp: string,
    rulesPath: string,
    queryLogPath: string,
    dnsCacheTtlSeconds: number
  ): string | undefined;
  // Full mode: boot the embedded AdGuardHome engine on 127.0.0.1:aghDnsPort and
  // relay every TUN DNS query to it (AGH does all filtering/upstream/caching).
  // aghWebEnabled serves the web admin dashboard; omitted/false skips it
  // entirely (no HTTP listener / server goroutines — saves battery).
  export function startFullDnsFilter(
    fd: number,
    dnsServerIp: string,
    aghConfigPath: string,
    aghWorkDir: string,
    aghLogPath: string,
    aghDnsPort: number,
    queryLogPath: string,
    aghWebEnabled?: boolean
  ): string | undefined;
  // DNS server / coexist mode: boot the embedded AdGuardHome engine as a
  // standalone loopback DNS server on 127.0.0.1:aghDnsPort, with NO VPN/TUN.
  // Another app can point its DNS upstream at this port. Tear down with
  // stopDnsFilter(). Hosted in the main app process (kept alive by the
  // continuous task), since there is no VPN extension to keep it alive.
  export function startAghServerOnly(
    aghConfigPath: string,
    aghWorkDir: string,
    aghLogPath: string,
    aghDnsPort: number,
    aghWebEnabled?: boolean
  ): string | undefined;
  // DNS server / coexist mode with the lightweight engine: bind matching DNS
  // listeners on bindIp:port over both TCP and UDP (no VPN/TUN) and resolve each
  // query through the local matcher + UDP upstream. A separate proxy app points
  // its DNS upstream at tcp:// or udp://bindIp:port. The UDP listener is best
  // effort (TCP still works if UDP can't bind). Tear down with stopDnsFilter().
  export function startLwDnsServer(
    bindIp: string,
    port: number,
    upstreamDnsIp: string,
    rulesPath: string,
    queryLogPath: string,
    dnsCacheTtlSeconds: number
  ): string | undefined;
  export function stopDnsFilter(): string | undefined;
  export function reloadDnsRules(rulesPath: string): string | undefined;
  export function setUpstreamDns(upstreamDnsIp: string): string | undefined;
  export function getStats(): string;
  // Toggles the native per-query / packet-counter hilog lines. Default off:
  // one hilog call per DNS query is a measurable battery cost. Turn on only
  // for debugging sessions.
  export function setNativeVerboseLog(enabled: boolean): void;
  // Smoke test for the full-mode engine: returns the linked AdGuardHome
  // version string (proves the prebuilt .so loads inside the native module).
  export function aghVersion(): string;
}
