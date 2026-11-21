import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export function subscriptionCacheName(url: string): string {
  let hash = 5381;
  for (let i = 0; i < url.length; i++) {
    hash = (hash * 33 + url.charCodeAt(i)) | 0;
  }
  return `${(hash >>> 0).toString(16)}.txt`;
}

export function aghSubscriptionId(url: string): number {
  const digest = cryptoFramework.createMd('SHA256');
  digest.updateSync({ data: new util.TextEncoder().encodeInto(url) });
  const hash = digest.digestSync().data;
  let id = 0;
  for (let i = 0; i < 6; i++) {
    id = id * 256 + hash[i];
  }
  // Keep URL-based IDs out of the namespace of the old sequential cache files.
  return 0x1000000000000 + id;
}

function exists(path: string): boolean {
  try {
    return fileIo.accessSync(path);
  } catch (_) {
    return false;
  }
}

export function seedAghSubscriptionCache(vpnDir: string, workDir: string, url: string, id: number): void {
  const source = `${vpnDir}/subs/${subscriptionCacheName(url)}`;
  const directory = `${workDir}/data/filters`;
  const destination = `${directory}/${id}.txt`;
  const staged = `${destination}.seed`;
  try {
    if (!exists(source) || exists(destination)) {
      return;
    }
    if (!exists(directory)) {
      fileIo.mkdirSync(directory, true);
    }
    // The app's own cache is keyed by URL, so an existing list keeps its
    // offline rules across migration. The old AGH files have no such mapping.
    fileIo.copyFileSync(source, staged);
    fileIo.renameSync(staged, destination);
  } catch (_) {
    try { fileIo.unlinkSync(staged); } catch (_) {}
  }
}
