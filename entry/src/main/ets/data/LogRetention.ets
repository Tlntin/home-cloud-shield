import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export const DEFAULT_LOG_RETENTION_DAYS = 7;
export const DEFAULT_LOG_MAX_SIZE_MB = 20;
export const LOG_MAINTENANCE_INTERVAL_MS = 30000;
const DAY_MS = 86400000;
const READ_BYTES = 256 * 1024;
const ARCHIVE_SUFFIX = '.retained-';

interface LogFile {
  path: string;
  size: number;
  modifiedAt: number;
}

interface LogCursor {
  offset: number;
  skipping: boolean;
  watermark: number;
}

export interface LogBatch {
  chunk: string;
  inode: bigint;
  next: LogCursor;
}

export function logCutoff(days: number): number {
  return days > 0 ? Date.now() - days * DAY_MS : 0;
}

function logFile(path: string): LogFile | undefined {
  try {
    const stat = fileIo.statSync(path);
    return { path: path, size: stat.size, modifiedAt: stat.mtime * 1000 };
  } catch (_) {
    return undefined;
  }
}

function logArchives(path: string): LogFile[] {
  const slash = path.lastIndexOf('/');
  const dir = path.slice(0, slash);
  const name = path.slice(slash + 1);
  const archives: LogFile[] = [];
  try {
    for (const entry of fileIo.listFileSync(dir)) {
      if (entry === `${name}.1` || (entry.startsWith(name + ARCHIVE_SUFFIX) && /^\d+$/.test(entry.slice(name.length + ARCHIVE_SUFFIX.length)))) {
        const archive = logFile(`${dir}/${entry}`);
        if (archive !== undefined) {
          archives.push(archive);
        }
      }
    }
  } catch (_) {
  }
  return archives.sort((a: LogFile, b: LogFile) => a.modifiedAt - b.modifiedAt || a.path.localeCompare(b.path));
}

export function archivedLogPaths(path: string): string[] {
  return logArchives(path).map((archive: LogFile) => archive.path);
}

function unlinkLog(path: string): boolean {
  try {
    fileIo.unlinkSync(path);
    return true;
  } catch (_) {
    return false;
  }
}

export function clearLogFile(path: string): boolean {
  let success = true;
  for (const archive of logArchives(path)) {
    success = unlinkLog(archive.path) && success;
  }
  try {
    if (logFile(path) !== undefined) {
      fileIo.truncateSync(path, 0);
    }
  } catch (_) {
    return false;
  }
  return success;
}

function oldestLogTime(file: LogFile): number {
  try {
    const head = fileIo.readTextSync(file.path, { length: 1024 });
    const line = head.split('\n', 1)[0];
    const app = /"ts"\s*:\s*(\d+)/.exec(line);
    if (app !== null) {
      return Number(app[1]);
    }
    const agh = /"T"\s*:\s*"([^"]+)"/.exec(line);
    const time = Date.parse(agh === null ? line.split(/\s/, 1)[0] : agh[1]);
    return Number.isFinite(time) ? time : file.modifiedAt;
  } catch (_) {
    return file.modifiedAt;
  }
}

// A large file left over from before rotation can exceed the entire budget.
// Copy its newest complete lines into a replacement using bounded buffers.
async function trimArchive(file: LogFile, keepBytes: number): Promise<void> {
  const staged = `${file.path}.trim`;
  let input: fileIo.File | undefined;
  let output: fileIo.File | undefined;
  try {
    input = fileIo.openSync(file.path, fileIo.OpenMode.READ_ONLY);
    output = fileIo.openSync(staged, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    const buffer = new ArrayBuffer(READ_BYTES);
    let offset = Math.max(0, file.size - keepBytes - 1);
    let startOnNewline = offset > 0;
    fileIo.lseek(input.fd, offset);
    while (offset < file.size) {
      const got = await fileIo.read(input.fd, buffer, { length: Math.min(READ_BYTES, file.size - offset) });
      if (got <= 0) {
        return;
      }
      offset += got;
      let start = 0;
      if (startOnNewline) {
        const newline = new Uint8Array(buffer, 0, got).indexOf(10);
        if (newline < 0) {
          continue;
        }
        start = newline + 1;
        startOnNewline = false;
      }
      if (start < got) {
        const contents = buffer.slice(start, got);
        if (await fileIo.write(output.fd, contents) !== contents.byteLength) {
          return;
        }
      }
    }
    // A concurrent clear or engine rotation invalidates this snapshot.
    const opened = fileIo.statSync(input.fd);
    fileIo.closeSync(input);
    input = undefined;
    fileIo.closeSync(output);
    output = undefined;
    const latest = fileIo.statSync(file.path);
    if (latest.ino === opened.ino && latest.size === file.size) {
      fileIo.utimes(staged, file.modifiedAt);
      fileIo.renameSync(staged, file.path);
    }
  } catch (_) {
  } finally {
    if (input !== undefined) {
      fileIo.closeSync(input);
    }
    if (output !== undefined) {
      fileIo.closeSync(output);
    }
    unlinkLog(staged);
  }
}

// Writers of these logs reopen the path for each append. Rename keeps their
// in-flight file descriptors valid and makes later writes open a fresh file.
export async function maintainLogFiles(paths: string[], days: number, maxMb: number,
  fixedPath: string = ''): Promise<void> {
  if (days <= 0 && maxMb <= 0) {
    return;
  }
  const cutoff = logCutoff(days);
  const maxBytes = maxMb * 1024 * 1024;
  const now = Date.now();
  let activeBytes = 0;
  let archives: LogFile[] = [];
  for (const path of paths) {
    const active = logFile(path);
    if (active !== undefined && active.size > 0) {
      const rotateForSize = maxBytes > 0 && active.size >= maxBytes / 4;
      const rotateForAge = days > 0 && oldestLogTime(active) <= now - DAY_MS;
      if (!rotateForSize && !rotateForAge) {
        activeBytes += active.size;
      } else {
        try {
          fileIo.renameSync(path, `${path}${ARCHIVE_SUFFIX}${now}`);
        } catch (_) {
          activeBytes += active.size;
        }
      }
    }
    archives = archives.concat(logArchives(path));
  }
  // The tunnel writer holds its active descriptor and already caps it at 256 KiB.
  const fixed = fixedPath.length > 0 ? logFile(fixedPath) : undefined;
  if (fixed !== undefined) {
    if (fixed.modifiedAt < cutoff) {
      try {
        fileIo.truncateSync(fixed.path, 0);
      } catch (_) {
      }
    } else {
      activeBytes += fixed.size;
    }
  }
  archives.sort((a: LogFile, b: LogFile) => a.modifiedAt - b.modifiedAt || a.path.localeCompare(b.path));
  let bytes = activeBytes + archives.reduce((sum: number, file: LogFile) => sum + file.size, 0);
  for (const archive of archives) {
    if (archive.modifiedAt < cutoff ||
      (maxBytes > 0 && bytes > maxBytes && (bytes - archive.size >= maxBytes || archive.size <= maxBytes / 2))) {
      if (unlinkLog(archive.path)) {
        bytes -= archive.size;
      }
    } else if (maxBytes > 0 && bytes > maxBytes) {
      await trimArchive(archive, archive.size - (bytes - maxBytes));
      break;
    }
  }
}

export class LogReader {
  private readonly decoder = new util.TextDecoder('utf-8');
  private cursors: Map<bigint, LogCursor> = new Map();

  reset(): void {
    this.cursors.clear();
  }

  advance(batch: LogBatch): void {
    this.cursors.set(batch.inode, batch.next);
  }

  read(path: string, watermark: number): LogBatch | undefined {
    const archives = archivedLogPaths(path);
    const paths = archives.concat([path]);
    const present: Set<bigint> = new Set();
    let batch: LogBatch | undefined;
    for (const name of paths) {
      let file: fileIo.File | undefined;
      try {
        if (batch !== undefined) {
          present.add(fileIo.statSync(name).ino);
          continue;
        }
        file = fileIo.openSync(name, fileIo.OpenMode.READ_ONLY);
        const stat = fileIo.statSync(file.fd);
        present.add(stat.ino);
        const cursor = this.cursors.get(stat.ino);
        const resumed = cursor !== undefined && cursor.offset <= stat.size;
        const offset = resumed && cursor !== undefined ? cursor.offset : 0;
        const startWatermark = resumed && cursor !== undefined ? cursor.watermark : watermark;
        if (offset >= stat.size) {
          continue;
        }
        const buffer = new ArrayBuffer(Math.min(READ_BYTES, stat.size - offset));
        const got = fileIo.readSync(file.fd, buffer, { offset: offset });
        if (got <= 0) {
          continue;
        }
        const raw = new Uint8Array(buffer, 0, got);
        const last = raw.lastIndexOf(10);
        if (last < 0) {
          if (got === READ_BYTES) {
            // An oversized or corrupt row cannot trap the reader at this offset.
            batch = { chunk: '', inode: stat.ino,
              next: { offset: offset + got, skipping: true, watermark: startWatermark } };
          }
          continue;
        }
        const start = offset > 0 && cursor?.skipping === true ? raw.indexOf(10) + 1 : 0;
        const chunk = start <= last ? this.decoder.decodeToString(raw.subarray(start, last)) : '';
        batch = { chunk: chunk, inode: stat.ino,
          next: { offset: offset + last + 1, skipping: false, watermark: startWatermark } };
      } catch (_) {
      } finally {
        if (file !== undefined) {
          fileIo.closeSync(file);
        }
      }
    }
    for (const inode of this.cursors.keys()) {
      if (!present.has(inode)) {
        this.cursors.delete(inode);
      }
    }
    return batch;
  }
}
