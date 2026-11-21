import { common } from '@kit.AbilityKit';
import { distributedKVStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { distributedDeviceManager } from '@kit.DistributedServiceKit';

const STORE_ID = 'shieldConfigSync';
const MANUAL_PREFIX = 'manual/';
const CONTINUE_PREFIX = 'continue/';
const RECEIPT_PREFIX = 'receipt/';
const SYNC_TIMEOUT_MS = 12000;
const TRANSFER_RETENTION_MS = 60000;
const MANUAL_RETENTION_MS = 24 * 60 * 60 * 1000;
const CONTINUATION_RETRY_MS = 1000;
const RECEIPT_RETRY_MS = 1000;

export const CONFIG_CONTINUE_KEY = 'shieldConfigTransfer';
export const CONFIG_CONTINUE_SOURCE = 'shieldConfigSource';

interface ConfigSyncPayload {
  version: number;
  config: string;
  expiresAt: number;
  receiptDeviceId?: string;
}

function parseConfigSyncPayload(value: string): ConfigSyncPayload | undefined {
  try {
    const payload = JSON.parse(value) as ConfigSyncPayload;
    if (payload?.version === 1 && typeof payload.config === 'string' && payload.config.length > 0 &&
      Number.isSafeInteger(payload.expiresAt)) {
      return payload;
    }
  } catch (_) {}
  return undefined;
}

export interface ConfigSyncDevice {
  id: string;
  name: string;
}

export interface ConfigDelivery {
  key: string;
  payload: ConfigSyncPayload | undefined;
  continuation: boolean;
}

export interface ConfigSyncSendResult {
  key: string;
  confirmation: ConfigSyncConfirmation;
}

export enum ConfigSyncConfirmation {
  Unconfirmed,
  Sent,
  Delivered
}

export interface ConfigSyncSendOptions {
  continuation?: boolean;
  onSubmitted?: () => void;
}

class ConfigSync {
  private openPromise?: Promise<distributedKVStore.SingleKVStore>;
  private store?: distributedKVStore.SingleKVStore;
  private receiving = false;
  private sending = false;
  private available?: () => void;
  private snapshot?: () => string;
  private senderId = '';
  private continuationKey = '';
  private continuationSourceId = '';
  private continuationRetryTimer?: number;
  private nextContinuationPullAt = 0;
  private onReceipt?: (change: distributedKVStore.ChangeNotification) => void;
  private readonly onRemoteChange = (change: distributedKVStore.ChangeNotification): void => {
    this.onReceipt?.(change);
    this.available?.();
  };

  private async open(context: common.UIAbilityContext): Promise<distributedKVStore.SingleKVStore> {
    if (!this.openPromise) {
      const options: distributedKVStore.Options = {
        createIfMissing: true,
        encrypt: true,
        backup: false,
        autoSync: false,
        kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
        securityLevel: distributedKVStore.SecurityLevel.S4
      };
      const manager = distributedKVStore.createKVManager({ context, bundleName: context.abilityInfo.bundleName });
      this.openPromise = manager.getKVStore<distributedKVStore.SingleKVStore>(STORE_ID, options);
    }
    try {
      this.store = await this.openPromise;
      return this.store;
    } catch (err) {
      this.openPromise = undefined;
      throw err as Error;
    }
  }

  async enable(context: common.UIAbilityContext, senderId: string, snapshot: () => string,
    onAvailable: () => void): Promise<void> {
    this.senderId = senderId;
    this.snapshot = snapshot;
    this.available = onAvailable;
    const store = await this.open(context);
    if (this.available !== onAvailable) {
      return;
    }
    if (!this.receiving) {
      store.on('dataChange', distributedKVStore.SubscribeType.SUBSCRIBE_TYPE_REMOTE, this.onRemoteChange);
      this.receiving = true;
      void this.removeExpiredTransfers(store, CONTINUE_PREFIX).catch(() => {});
      void this.removeExpiredTransfers(store, MANUAL_PREFIX).catch(() => {});
      void this.removeExpiredReceipts(store).catch(() => {});
    }
    this.retryContinuation();
    onAvailable();
  }

  disable(): void {
    this.clearContinuation();
    this.stopReceiving();
  }

  detach(onAvailable: () => void): void {
    if (this.available === onAvailable) {
      this.stopReceiving();
    }
  }

  private stopReceiving(): void {
    this.available = undefined;
    this.snapshot = undefined;
    this.stopContinuationRetry();
    if (this.receiving) {
      this.receiving = false;
      try { this.store?.off('dataChange', this.onRemoteChange); } catch (_) {}
    }
  }

  isEnabled(onAvailable?: () => void): boolean {
    return this.receiving && (!onAvailable || this.available === onAvailable);
  }

  queueContinuation(key: string, sourceId: string): void {
    if (/^continue\/[0-9a-f-]{36}\/[0-9a-f-]{36}$/.test(key)) {
      this.continuationKey = key;
      this.continuationSourceId = sourceId.length <= 255 ? sourceId : '';
      // Give the push a chance to arrive before trying the same key from the source.
      this.nextContinuationPullAt = Date.now() + CONTINUATION_RETRY_MS;
      this.retryContinuation();
      this.available?.();
    }
  }

  private retryContinuation(): void {
    this.stopContinuationRetry();
    if (!this.receiving || !this.continuationKey) {
      return;
    }
    const deadline = Date.now() + SYNC_TIMEOUT_MS;
    this.continuationRetryTimer = setInterval(() => {
      if (Date.now() >= deadline) {
        this.stopContinuationRetry();
      }
      this.available?.();
    }, CONTINUATION_RETRY_MS);
  }

  private stopContinuationRetry(): void {
    if (this.continuationRetryTimer !== undefined) {
      clearInterval(this.continuationRetryTimer);
      this.continuationRetryTimer = undefined;
    }
  }

  private clearContinuation(): void {
    this.continuationKey = '';
    this.continuationSourceId = '';
    this.stopContinuationRetry();
  }

  private async removeExpiredTransfers(store: distributedKVStore.SingleKVStore, prefix: string): Promise<void> {
    const entries = await store.getEntries(prefix);
    const now = Date.now();
    for (const entry of entries) {
      if (entry.key !== this.continuationKey && typeof entry.value.value === 'string') {
        const expiry = parseConfigSyncPayload(entry.value.value)?.expiresAt;
        if (typeof expiry === 'number' && expiry <= now) {
          await store.delete(entry.key).catch(() => {});
        }
      }
    }
  }

  async inbox(): Promise<ConfigDelivery[]> {
    const store = this.store;
    if (!store || !this.available) {
      return [];
    }
    const entries = await store.getEntries(MANUAL_PREFIX);
    if (this.continuationKey) {
      const key = this.continuationKey;
      const continuation = await store.getEntries(key);
      const entry = continuation.find((item: distributedKVStore.Entry): boolean => item.key === key);
      if (this.continuationKey === key) {
        if (entry) {
          entries.push(entry);
        } else if (this.continuationSourceId && this.continuationRetryTimer !== undefined &&
          Date.now() >= this.nextContinuationPullAt) {
          this.nextContinuationPullAt = Date.now() + CONTINUATION_RETRY_MS;
          try {
            this.syncTransfer(store, this.continuationSourceId, key, distributedKVStore.SyncMode.PULL_ONLY);
          } catch (_) {
            // The next retry can run after the devices finish reconnecting.
          }
        }
      }
    }
    const ownPrefix = `${MANUAL_PREFIX}${this.senderId}/`;
    return entries.filter((entry: distributedKVStore.Entry): boolean => !entry.key.startsWith(ownPrefix))
      .map((entry: distributedKVStore.Entry): ConfigDelivery => {
        const payload = typeof entry.value.value === 'string' ? parseConfigSyncPayload(entry.value.value) : undefined;
        return {
          key: entry.key,
          payload: payload && payload.expiresAt > Date.now() ? payload : undefined,
          continuation: entry.key.startsWith(CONTINUE_PREFIX)
        };
      });
  }

  async finishDelivery(delivery: ConfigDelivery, applied: boolean): Promise<void> {
    const store = this.store;
    if (!store) {
      return;
    }
    const sourceId = applied ? delivery.payload?.receiptDeviceId : undefined;
    if (typeof sourceId === 'string' && sourceId.length > 0 && sourceId.length <= 255 &&
      /^manual\/[0-9a-f-]{36}\/[0-9a-f-]{36}$/.test(delivery.key)) {
      await this.sendReceipt(store, sourceId, delivery.key).catch(() => {});
    }
    await store.delete(delivery.key);
    if (this.continuationKey === delivery.key) {
      this.clearContinuation();
    }
  }

  private receiptKey(key: string): string {
    return RECEIPT_PREFIX + key.slice(MANUAL_PREFIX.length);
  }

  private async sendReceipt(store: distributedKVStore.SingleKVStore, sourceId: string, key: string): Promise<void> {
    const receipt = this.receiptKey(key);
    await store.put(receipt, String(Date.now() + TRANSFER_RETENTION_MS));
    setTimeout(() => { void store.delete(receipt).catch(() => {}); }, TRANSFER_RETENTION_MS);
    // The sender can still pull the stored receipt if this push fails.
    this.syncTransfer(store, sourceId, receipt, distributedKVStore.SyncMode.PUSH_ONLY);
  }

  private async removeExpiredReceipts(store: distributedKVStore.SingleKVStore): Promise<void> {
    const entries = await store.getEntries(RECEIPT_PREFIX);
    const now = Date.now();
    for (const entry of entries) {
      const expiry = Number(entry.value.value);
      if (Number.isSafeInteger(expiry) && expiry > 0 && expiry <= now) {
        await store.delete(entry.key).catch(() => {});
      }
    }
  }

  devices(context: common.UIAbilityContext): ConfigSyncDevice[] {
    const manager = distributedDeviceManager.createDeviceManager(context.abilityInfo.bundleName);
    try {
      const devices: ConfigSyncDevice[] = [];
      for (const device of manager.getAvailableDeviceListSync()) {
        if (device.networkId) {
          devices.push({ id: device.networkId, name: device.deviceName });
        }
      }
      return devices;
    } finally {
      distributedDeviceManager.releaseDeviceManager(manager);
    }
  }

  localNetworkId(context: common.UIAbilityContext): string {
    try {
      const manager = distributedDeviceManager.createDeviceManager(context.abilityInfo.bundleName);
      try {
        return manager.getLocalDeviceNetworkId();
      } finally {
        distributedDeviceManager.releaseDeviceManager(manager);
      }
    } catch (_) {
      return '';
    }
  }

  async send(context: common.UIAbilityContext, deviceId: string,
    options?: ConfigSyncSendOptions): Promise<ConfigSyncSendResult> {
    if (!this.receiving || !this.snapshot || this.sending) {
      throw new Error('Sync unavailable');
    }
    this.sending = true;
    try {
      const continuation = options?.continuation === true;
      const payload: ConfigSyncPayload = {
        version: 1,
        config: this.snapshot(),
        expiresAt: Date.now() + (continuation ? TRANSFER_RETENTION_MS : MANUAL_RETENTION_MS)
      };
      if (!continuation) {
        const sourceId = this.localNetworkId(context);
        if (sourceId && sourceId.length <= 255) {
          payload.receiptDeviceId = sourceId;
        }
      }
      const serialized = JSON.stringify(payload);
      if (new util.TextEncoder().encodeInto(serialized).byteLength >= 4 * 1024 * 1024 - 1) {
        throw new Error('Config data too large');
      }
      const store = await this.open(context);
      if (!this.receiving || !this.snapshot) {
        throw new Error('Sync unavailable');
      }
      const key = `${continuation ? CONTINUE_PREFIX : MANUAL_PREFIX}${this.senderId}/${util.generateRandomUUID()}`;
      await store.put(key, serialized);
      if (continuation) {
        try {
          this.syncTransfer(store, deviceId, key, distributedKVStore.SyncMode.PUSH_ONLY);
        } catch (err) {
          await store.delete(key).catch(() => {});
          throw err as Error;
        }
        // The system may start the target before the KV push finishes.
        setTimeout(() => { void store.delete(key).catch(() => {}); }, TRANSFER_RETENTION_MS);
        return { key, confirmation: ConfigSyncConfirmation.Unconfirmed };
      }
      try {
        if (payload.receiptDeviceId) {
          const delivered = await this.pushWithReceipt(store, deviceId, key, options?.onSubmitted);
          if (delivered) {
            await store.delete(this.receiptKey(key)).catch(() => {});
          }
          return { key, confirmation: delivered ? ConfigSyncConfirmation.Delivered : ConfigSyncConfirmation.Unconfirmed };
        }
        const confirmed = await this.push(store, deviceId, key, options?.onSubmitted);
        return { key, confirmation: confirmed ? ConfigSyncConfirmation.Sent : ConfigSyncConfirmation.Unconfirmed };
      } finally {
        // Sync only the selected key. Its local cleanup must not propagate to the receiver.
        await store.delete(key).catch(() => {});
      }
    } finally {
      this.sending = false;
    }
  }

  private pushWithReceipt(store: distributedKVStore.SingleKVStore, deviceId: string, key: string,
    onSubmitted?: () => void): Promise<boolean> {
    const receipt = this.receiptKey(key);
    return new Promise<boolean>((resolve, reject) => {
      let finished = false;
      let checking = false;
      const matchesReceipt = (entry: distributedKVStore.Entry): boolean => {
        const expiry = Number(entry.value.value);
        return entry.key === receipt && Number.isSafeInteger(expiry) && expiry > Date.now();
      };
      const stopListening = (): void => {
        finished = true;
        this.onReceipt = undefined;
        clearTimeout(timeout);
        clearInterval(retry);
      };
      const complete = (delivered: boolean): void => {
        if (!finished) {
          stopListening();
          resolve(delivered);
        }
      };
      const check = async (): Promise<void> => {
        if (finished || checking) {
          return;
        }
        checking = true;
        try {
          const entries = await store.getEntries(receipt);
          if (entries.some(matchesReceipt)) {
            complete(true);
          } else if (!finished) {
            this.syncTransfer(store, deviceId, receipt, distributedKVStore.SyncMode.PULL_ONLY);
          }
        } catch (_) {
          // A temporary connection failure can recover before the next check.
        } finally {
          checking = false;
        }
      };
      const retry = setInterval(() => { void check(); }, RECEIPT_RETRY_MS);
      const timeout = setTimeout(() => { complete(false); }, SYNC_TIMEOUT_MS);
      this.onReceipt = (change: distributedKVStore.ChangeNotification): void => {
        if (change.insertEntries.some(matchesReceipt) || change.updateEntries.some(matchesReceipt)) {
          complete(true);
        }
      };
      try {
        this.syncTransfer(store, deviceId, key, distributedKVStore.SyncMode.PUSH_ONLY);
      } catch (err) {
        stopListening();
        reject(err);
        return;
      }
      try { onSubmitted?.(); } catch (_) {}
    });
  }

  private push(store: distributedKVStore.SingleKVStore, deviceId: string, key: string,
    onSubmitted?: () => void): Promise<boolean> {
    return new Promise<boolean>((resolve, reject) => {
      const onComplete = (results: [string, number][]): void => {
        // This store sends to one device at a time. Some systems report its UUID instead of its network ID.
        const result = results.length === 1 ? results[0] : results.find(item => item[0] === deviceId);
        if (!result || !result[0]) {
          return;
        }
        stopListening();
        if (result[1] === 0) {
          resolve(true);
        } else {
          reject(new Error(`Device sync failed (${result[1]})`));
        }
      };
      const stopListening = (): void => {
        clearTimeout(timer);
        try { store.off('syncComplete', onComplete); } catch (_) {}
      };
      const timer = setTimeout(() => {
        stopListening();
        resolve(false);
      }, SYNC_TIMEOUT_MS);
      try {
        store.on('syncComplete', onComplete);
        this.syncTransfer(store, deviceId, key, distributedKVStore.SyncMode.PUSH_ONLY);
      } catch (err) {
        stopListening();
        reject(err);
        return;
      }
      try { onSubmitted?.(); } catch (_) {}
    });
  }

  private syncTransfer(store: distributedKVStore.SingleKVStore, deviceId: string, key: string,
    mode: distributedKVStore.SyncMode): void {
    store.sync([deviceId], new distributedKVStore.Query().prefixKey(key), mode);
  }
}

export const configSync = new ConfigSync();
