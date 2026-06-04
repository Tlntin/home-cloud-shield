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
  export function startFullDnsFilter(
    fd: number,
    dnsServerIp: string,
    aghConfigPath: string,
    aghWorkDir: string,
    aghLogPath: string,
    aghDnsPort: number,
    queryLogPath: string
  ): string | undefined;
  export function stopDnsFilter(): string | undefined;
  export function reloadDnsRules(rulesPath: string): string | undefined;
  export function setUpstreamDns(upstreamDnsIp: string): string | undefined;
  export function getStats(): string;
  // Smoke test for the full-mode engine: returns the linked AdGuardHome
  // version string (proves the prebuilt .so loads inside the native module).
  export function aghVersion(): string;
}
