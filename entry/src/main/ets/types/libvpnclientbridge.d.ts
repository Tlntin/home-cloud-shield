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
  export function getStats(): string;
}
