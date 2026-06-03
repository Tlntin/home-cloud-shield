declare module 'libvpnclientbridge.so' {
  export function startDnsFilter(
    fd: number,
    dnsServerIp: string,
    upstreamDnsIp: string,
    rulesPath: string,
    queryLogPath: string,
    dnsCacheTtlSeconds: number
  ): string | undefined;
  export function stopDnsFilter(): string | undefined;
  export function reloadDnsRules(rulesPath: string): string | undefined;
  export function setUpstreamDns(upstreamDnsIp: string): string | undefined;
  export function getStats(): string;
}
