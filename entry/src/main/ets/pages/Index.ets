import { common, ConfigurationConstant, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { i18n } from '@kit.LocalizationKit';
import { vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { hdsMaterial, HdsTabs } from '@kit.UIDesignKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';
import { geoLocationManager } from '@kit.LocationKit';
import type { PromptAction } from '@ohos.arkui.UIContext';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import bundleManager from '@ohos.bundle.bundleManager';
import pasteboard from '@ohos.pasteboard';
import uri from '@ohos.uri';

const DOMAIN = 0x0000;
const TAG = 'vpn_demo_ui';
const VPN_BUNDLE_NAME = 'com.tlntin.home_cloud_shield';
const VPN_MODULE_NAME = 'entry';
const VPN_ABILITY_NAME = 'MyVpnExtAbility';
const ENTRY_ABILITY_NAME = `${VPN_BUNDLE_NAME}.EntryAbility`;
const VPN_DIR_NAME = 'vpn';
const STATUS_FILE_NAME = 'status.json';
const RULES_FILE_NAME = 'filters.txt';
const QUERY_LOG_FILE_NAME = 'dns_queries.jsonl';
const DEBUG_LOG_FILE_NAME = 'debug.log';
const STATE_FILE_NAME = 'ui_state.json';
const WANT_STATUS_FILE_PATH = 'statusFilePath';
const WANT_RULES_FILE_PATH = 'rulesFilePath';
const WANT_QUERY_LOG_FILE_PATH = 'queryLogFilePath';
const WANT_DEBUG_LOG_FILE_PATH = 'debugLogFilePath';
const WANT_DNS_CACHE_TTL_SECONDS = 'dnsCacheTtlSeconds';
const DEFAULT_DNS_CACHE_TTL_SECONDS = 3600;
const CUSTOM_BLOCK_RULE_PROFILE_ID = 'custom_block_rules';
const CUSTOM_ALLOW_RULE_PROFILE_ID = 'custom_allow_rules';
type LangCode = 'zhHans' | 'en' | 'zhHant';
type PreferredLangCode = 'zh-Hans' | 'en-Latn-US' | 'zh-Hant';
type LanguageKey =
  'appTitle' | 'homeTitle' | 'configTitle' | 'meTitle' | 'homeSubtitle' | 'configSubtitle' | 'meSubtitle'
  | 'protected' | 'standby' | 'tabHome' | 'tabHomeSub' | 'tabConfig' | 'tabConfigSub' | 'tabMe' | 'tabMeSub'
  | 'localVpn' | 'dnsFilter' | 'ipv6Ready' | 'controlCenter' | 'running' | 'readyToStart' | 'active' | 'idle'
  | 'lastDomain' | 'updated' | 'notAvailable' | 'filterStatus' | 'stopped' | 'startFilter' | 'restartFilter'
  | 'stopFilter' | 'working' | 'runningHint' | 'stoppedHint' | 'liveSnapshot' | 'requestsLogged' | 'matchedRule'
  | 'none' | 'trafficClass' | 'dnsOnlyVpn' | 'nativeBridge' | 'bridgeReady' | 'bridgeStandby' | 'dnsPackets'
  | 'allowed' | 'blocked' | 'tunFd' | 'recentDnsRequests' | 'domainLeaderboard' | 'dnsTraffic' | 'queryCount'
  | 'requestBytes' | 'responseBytes' | 'totalBytesLabel' | 'clearLogs' | 'cancel' | 'confirm' | 'ascendingOrder'
  | 'descendingOrder' | 'clearDnsRequests' | 'clearDnsRequestsConfirm' | 'operationCanceled' | 'dnsRequestsCleared'
  | 'lines' | 'noDnsLogs' | 'noDnsLogsHint' | 'blockedTag' | 'allowedTag' | 'rulePrefix' | 'timePrefix'
  | 'debugLog' | 'debugHint' | 'noDebugLogs' | 'configStudio' | 'configCardHint' | 'activeFile' | 'importFile'
  | 'resetDefaults' | 'rulesEditor' | 'saveRules' | 'reloadFile' | 'writeRulesHere' | 'ruleFiles' | 'ruleFilesHint'
  | 'noRuleProfiles' | 'noRuleProfilesHint'
  | 'editRule' | 'renameRule' | 'deleteRule' | 'exportRules' | 'rulesSavedSuccess' | 'disabled' | 'defaultCustomRules'
  | 'moveUp' | 'moveDown' | 'closeEditor' | 'rulesFile' | 'myDevice' | 'myDeviceHint' | 'keepAliveOn' | 'keepAliveOff'
  | 'backgroundKeepAlive' | 'keepAliveSummary' | 'audioKeepAlive' | 'audioKeepAliveHint' | 'locationKeepAlive'
  | 'locationKeepAliveHint' | 'autoStartFilter' | 'autoStartFilterHint' | 'autoStartFilterPermissionDenied'
  | 'versionBuild' | 'appVersion' | 'bundle' | 'mode' | 'modeValue' | 'ipv6Dns' | 'enabled' | 'openSource'
  | 'openSourceHint' | 'openSourceNotices' | 'unsaved' | 'language' | 'theme' | 'themeAuto' | 'themeLight'
  | 'themeDark' | 'langZhHans' | 'langEn' | 'langZhHant' | 'configImported' | 'noConfigSelected' | 'importedEmpty'
  | 'saveRulesFailed' | 'audioMode' | 'locationMode' | 'keepAliveActivePrefix' | 'keepAliveArmedPrefix'
  | 'keepAliveErrorPrefix' | 'keepAliveOffStatus' | 'keepAliveWaitStatus' | 'keepAliveStartFailed'
  | 'locationPermissionRequired' | 'dnsFilterNotStarted' | 'startRequested' | 'stopping' | 'licenseTitle'
  | 'licenseSubtitle' | 'back' | 'loadingLicense' | 'licenseUnavailable' | 'enabledRuleProfileSummary'
  | 'rulesImportedMessage' | 'exportSuccessMessage' | 'exportCanceledMessage' | 'noRulesToExportMessage'
  | 'confirmDeleteRuleProfile' | 'noDnsRequestsToCopy' | 'dnsRequestsCopied' | 'noDebugLogsToCopy' | 'debugLogsCopied'
  | 'allWithCount' | 'noDomainStatsToCopy' | 'domainStatsCopied' | 'noDomainStatsToExport'
  | 'domainStatsExportedStatus' | 'exportSuccessToast' | 'noDnsRequestsToExport' | 'dnsRequestsExportedStatus'
  | 'clearDnsRequestsFailed' | 'noDebugLogsToExport' | 'debugLogsExportedStatus' | 'copy' | 'export' | 'copyLog'
  | 'exportLog' | 'dnsSearchPlaceholder' | 'clickToExpand' | 'clickViewDebugAndCopy' | 'exportDebugLogsFailed'
  | 'exportRulesFailed' | 'exportFileFailed' | 'dnsCacheTitle' | 'dnsCacheHint' | 'dnsCacheTtlLabel'
  | 'importedRules'
  | 'customBlockRules' | 'customAllowRules' | 'builtInRuleProfileLocked' | 'addRuleActionTitle'
  | 'addAllowRuleAction' | 'addBlockRuleAction' | 'ruleAddedNeedsRestart' | 'ruleAlreadyExists'
  | 'tapDomainToCreateRule';

function resolveStringResource(key: LanguageKey): number {
  switch (key) {
    case 'appTitle': return $r('app.string.appTitle').id;
    case 'homeTitle': return $r('app.string.homeTitle').id;
    case 'configTitle': return $r('app.string.configTitle').id;
    case 'meTitle': return $r('app.string.meTitle').id;
    case 'homeSubtitle': return $r('app.string.homeSubtitle').id;
    case 'configSubtitle': return $r('app.string.configSubtitle').id;
    case 'meSubtitle': return $r('app.string.meSubtitle').id;
    case 'protected': return $r('app.string.protected').id;
    case 'standby': return $r('app.string.standby').id;
    case 'tabHome': return $r('app.string.tabHome').id;
    case 'tabHomeSub': return $r('app.string.tabHomeSub').id;
    case 'tabConfig': return $r('app.string.tabConfig').id;
    case 'tabConfigSub': return $r('app.string.tabConfigSub').id;
    case 'tabMe': return $r('app.string.tabMe').id;
    case 'tabMeSub': return $r('app.string.tabMeSub').id;
    case 'localVpn': return $r('app.string.localVpn').id;
    case 'dnsFilter': return $r('app.string.dnsFilter').id;
    case 'ipv6Ready': return $r('app.string.ipv6Ready').id;
    case 'controlCenter': return $r('app.string.controlCenter').id;
    case 'running': return $r('app.string.running').id;
    case 'readyToStart': return $r('app.string.readyToStart').id;
    case 'active': return $r('app.string.active').id;
    case 'idle': return $r('app.string.idle').id;
    case 'lastDomain': return $r('app.string.lastDomain').id;
    case 'updated': return $r('app.string.updated').id;
    case 'notAvailable': return $r('app.string.notAvailable').id;
    case 'filterStatus': return $r('app.string.filterStatus').id;
    case 'stopped': return $r('app.string.stopped').id;
    case 'startFilter': return $r('app.string.startFilter').id;
    case 'restartFilter': return $r('app.string.restartFilter').id;
    case 'stopFilter': return $r('app.string.stopFilter').id;
    case 'working': return $r('app.string.working').id;
    case 'runningHint': return $r('app.string.runningHint').id;
    case 'stoppedHint': return $r('app.string.stoppedHint').id;
    case 'liveSnapshot': return $r('app.string.liveSnapshot').id;
    case 'requestsLogged': return $r('app.string.requestsLogged').id;
    case 'matchedRule': return $r('app.string.matchedRule').id;
    case 'none': return $r('app.string.none').id;
    case 'trafficClass': return $r('app.string.trafficClass').id;
    case 'dnsOnlyVpn': return $r('app.string.dnsOnlyVpn').id;
    case 'nativeBridge': return $r('app.string.nativeBridge').id;
    case 'bridgeReady': return $r('app.string.bridgeReady').id;
    case 'bridgeStandby': return $r('app.string.bridgeStandby').id;
    case 'dnsPackets': return $r('app.string.dnsPackets').id;
    case 'allowed': return $r('app.string.allowed').id;
    case 'blocked': return $r('app.string.blocked').id;
    case 'tunFd': return $r('app.string.tunFd').id;
    case 'recentDnsRequests': return $r('app.string.recentDnsRequests').id;
    case 'domainLeaderboard': return $r('app.string.domainLeaderboard').id;
    case 'dnsTraffic': return $r('app.string.dnsTraffic').id;
    case 'queryCount': return $r('app.string.queryCount').id;
    case 'requestBytes': return $r('app.string.requestBytes').id;
    case 'responseBytes': return $r('app.string.responseBytes').id;
    case 'totalBytesLabel': return $r('app.string.totalBytesLabel').id;
    case 'clearLogs': return $r('app.string.clearLogs').id;
    case 'cancel': return $r('app.string.cancel').id;
    case 'confirm': return $r('app.string.confirm').id;
    case 'ascendingOrder': return $r('app.string.ascendingOrder').id;
    case 'descendingOrder': return $r('app.string.descendingOrder').id;
    case 'clearDnsRequests': return $r('app.string.clearDnsRequests').id;
    case 'clearDnsRequestsConfirm': return $r('app.string.clearDnsRequestsConfirm').id;
    case 'operationCanceled': return $r('app.string.operationCanceled').id;
    case 'dnsRequestsCleared': return $r('app.string.dnsRequestsCleared').id;
    case 'lines': return $r('app.string.lines').id;
    case 'noDnsLogs': return $r('app.string.noDnsLogs').id;
    case 'noDnsLogsHint': return $r('app.string.noDnsLogsHint').id;
    case 'blockedTag': return $r('app.string.blockedTag').id;
    case 'allowedTag': return $r('app.string.allowedTag').id;
    case 'rulePrefix': return $r('app.string.rulePrefix').id;
    case 'timePrefix': return $r('app.string.timePrefix').id;
    case 'debugLog': return $r('app.string.debugLog').id;
    case 'debugHint': return $r('app.string.debugHint').id;
    case 'noDebugLogs': return $r('app.string.noDebugLogs').id;
    case 'configStudio': return $r('app.string.configStudio').id;
    case 'configCardHint': return $r('app.string.configCardHint').id;
    case 'activeFile': return $r('app.string.activeFile').id;
    case 'importFile': return $r('app.string.importFile').id;
    case 'resetDefaults': return $r('app.string.resetDefaults').id;
    case 'rulesEditor': return $r('app.string.rulesEditor').id;
    case 'saveRules': return $r('app.string.saveRules').id;
    case 'reloadFile': return $r('app.string.reloadFile').id;
    case 'writeRulesHere': return $r('app.string.writeRulesHere').id;
    case 'ruleFiles': return $r('app.string.ruleFiles').id;
    case 'ruleFilesHint': return $r('app.string.ruleFilesHint').id;
    case 'noRuleProfiles': return $r('app.string.noRuleProfiles').id;
    case 'noRuleProfilesHint': return $r('app.string.noRuleProfilesHint').id;
    case 'editRule': return $r('app.string.editRule').id;
    case 'renameRule': return $r('app.string.renameRule').id;
    case 'deleteRule': return $r('app.string.deleteRule').id;
    case 'exportRules': return $r('app.string.exportRules').id;
    case 'rulesSavedSuccess': return $r('app.string.rulesSavedSuccess').id;
    case 'disabled': return $r('app.string.disabled').id;
    case 'defaultCustomRules': return $r('app.string.defaultCustomRules').id;
    case 'moveUp': return $r('app.string.moveUp').id;
    case 'moveDown': return $r('app.string.moveDown').id;
    case 'closeEditor': return $r('app.string.closeEditor').id;
    case 'rulesFile': return $r('app.string.rulesFile').id;
    case 'myDevice': return $r('app.string.myDevice').id;
    case 'myDeviceHint': return $r('app.string.myDeviceHint').id;
    case 'keepAliveOn': return $r('app.string.keepAliveOn').id;
    case 'keepAliveOff': return $r('app.string.keepAliveOff').id;
    case 'backgroundKeepAlive': return $r('app.string.backgroundKeepAlive').id;
    case 'keepAliveSummary': return $r('app.string.keepAliveSummary').id;
    case 'audioKeepAlive': return $r('app.string.audioKeepAlive').id;
    case 'audioKeepAliveHint': return $r('app.string.audioKeepAliveHint').id;
    case 'locationKeepAlive': return $r('app.string.locationKeepAlive').id;
    case 'locationKeepAliveHint': return $r('app.string.locationKeepAliveHint').id;
    case 'autoStartFilter': return $r('app.string.autoStartFilter').id;
    case 'autoStartFilterHint': return $r('app.string.autoStartFilterHint').id;
    case 'autoStartFilterPermissionDenied': return $r('app.string.autoStartFilterPermissionDenied').id;
    case 'versionBuild': return $r('app.string.versionBuild').id;
    case 'appVersion': return $r('app.string.appVersion').id;
    case 'bundle': return $r('app.string.bundle').id;
    case 'mode': return $r('app.string.mode').id;
    case 'modeValue': return $r('app.string.modeValue').id;
    case 'ipv6Dns': return $r('app.string.ipv6Dns').id;
    case 'enabled': return $r('app.string.enabled').id;
    case 'openSource': return $r('app.string.openSource').id;
    case 'openSourceHint': return $r('app.string.openSourceHint').id;
    case 'openSourceNotices': return $r('app.string.openSourceNotices').id;
    case 'unsaved': return $r('app.string.unsaved').id;
    case 'language': return $r('app.string.language').id;
    case 'theme': return $r('app.string.theme').id;
    case 'themeAuto': return $r('app.string.themeAuto').id;
    case 'themeLight': return $r('app.string.themeLight').id;
    case 'themeDark': return $r('app.string.themeDark').id;
    case 'langZhHans': return $r('app.string.langZhHans').id;
    case 'langEn': return $r('app.string.langEn').id;
    case 'langZhHant': return $r('app.string.langZhHant').id;
    case 'configImported': return $r('app.string.configImported').id;
    case 'noConfigSelected': return $r('app.string.noConfigSelected').id;
    case 'importedEmpty': return $r('app.string.importedEmpty').id;
    case 'saveRulesFailed': return $r('app.string.saveRulesFailed').id;
    case 'audioMode': return $r('app.string.audioMode').id;
    case 'locationMode': return $r('app.string.locationMode').id;
    case 'keepAliveActivePrefix': return $r('app.string.keepAliveActivePrefix').id;
    case 'keepAliveArmedPrefix': return $r('app.string.keepAliveArmedPrefix').id;
    case 'keepAliveErrorPrefix': return $r('app.string.keepAliveErrorPrefix').id;
    case 'keepAliveOffStatus': return $r('app.string.keepAliveOffStatus').id;
    case 'keepAliveWaitStatus': return $r('app.string.keepAliveWaitStatus').id;
    case 'keepAliveStartFailed': return $r('app.string.keepAliveStartFailed').id;
    case 'locationPermissionRequired': return $r('app.string.locationPermissionRequired').id;
    case 'dnsFilterNotStarted': return $r('app.string.dnsFilterNotStarted').id;
    case 'startRequested': return $r('app.string.startRequested').id;
    case 'stopping': return $r('app.string.stopping').id;
    case 'licenseTitle': return $r('app.string.licenseTitle').id;
    case 'licenseSubtitle': return $r('app.string.licenseSubtitle').id;
    case 'back': return $r('app.string.back').id;
    case 'loadingLicense': return $r('app.string.loadingLicense').id;
    case 'licenseUnavailable': return $r('app.string.licenseUnavailable').id;
    case 'enabledRuleProfileSummary': return $r('app.string.enabledRuleProfileSummary').id;
    case 'rulesImportedMessage': return $r('app.string.rulesImportedMessage').id;
    case 'exportSuccessMessage': return $r('app.string.exportSuccessMessage').id;
    case 'exportCanceledMessage': return $r('app.string.exportCanceledMessage').id;
    case 'noRulesToExportMessage': return $r('app.string.noRulesToExportMessage').id;
    case 'confirmDeleteRuleProfile': return $r('app.string.confirmDeleteRuleProfile').id;
    case 'noDnsRequestsToCopy': return $r('app.string.noDnsRequestsToCopy').id;
    case 'dnsRequestsCopied': return $r('app.string.dnsRequestsCopied').id;
    case 'noDebugLogsToCopy': return $r('app.string.noDebugLogsToCopy').id;
    case 'debugLogsCopied': return $r('app.string.debugLogsCopied').id;
    case 'allWithCount': return $r('app.string.allWithCount').id;
    case 'noDomainStatsToCopy': return $r('app.string.noDomainStatsToCopy').id;
    case 'domainStatsCopied': return $r('app.string.domainStatsCopied').id;
    case 'noDomainStatsToExport': return $r('app.string.noDomainStatsToExport').id;
    case 'domainStatsExportedStatus': return $r('app.string.domainStatsExportedStatus').id;
    case 'exportSuccessToast': return $r('app.string.exportSuccessToast').id;
    case 'noDnsRequestsToExport': return $r('app.string.noDnsRequestsToExport').id;
    case 'dnsRequestsExportedStatus': return $r('app.string.dnsRequestsExportedStatus').id;
    case 'clearDnsRequestsFailed': return $r('app.string.clearDnsRequestsFailed').id;
    case 'noDebugLogsToExport': return $r('app.string.noDebugLogsToExport').id;
    case 'debugLogsExportedStatus': return $r('app.string.debugLogsExportedStatus').id;
    case 'copy': return $r('app.string.copy').id;
    case 'export': return $r('app.string.export').id;
    case 'copyLog': return $r('app.string.copyLog').id;
    case 'exportLog': return $r('app.string.exportLog').id;
    case 'dnsSearchPlaceholder': return $r('app.string.dnsSearchPlaceholder').id;
    case 'clickToExpand': return $r('app.string.clickToExpand').id;
    case 'clickViewDebugAndCopy': return $r('app.string.clickViewDebugAndCopy').id;
    case 'exportDebugLogsFailed': return $r('app.string.exportDebugLogsFailed').id;
    case 'exportRulesFailed': return $r('app.string.exportRulesFailed').id;
    case 'exportFileFailed': return $r('app.string.exportFileFailed').id;
    case 'dnsCacheTitle': return $r('app.string.dnsCacheTitle').id;
    case 'dnsCacheHint': return $r('app.string.dnsCacheHint').id;
    case 'dnsCacheTtlLabel': return $r('app.string.dnsCacheTtlLabel').id;
    case 'importedRules': return $r('app.string.importedRules').id;
    case 'customBlockRules': return $r('app.string.customBlockRules').id;
    case 'customAllowRules': return $r('app.string.customAllowRules').id;
    case 'builtInRuleProfileLocked': return $r('app.string.builtInRuleProfileLocked').id;
    case 'addRuleActionTitle': return $r('app.string.addRuleActionTitle').id;
    case 'addAllowRuleAction': return $r('app.string.addAllowRuleAction').id;
    case 'addBlockRuleAction': return $r('app.string.addBlockRuleAction').id;
    case 'ruleAddedNeedsRestart': return $r('app.string.ruleAddedNeedsRestart').id;
    case 'ruleAlreadyExists': return $r('app.string.ruleAlreadyExists').id;
    case 'tapDomainToCreateRule': return $r('app.string.tapDomainToCreateRule').id;
  }
}

const LEGACY_DEFAULT_RULES_TEXT = [
  '! AdGuard-compatible DNS rule subset',
  '! Supported:',
  '!   ||ads.example.com^',
  '!   @@||allowed.example.com^',
  '!   tracker.example.org',
  '||doubleclick.net^',
  '||googleadservices.com^',
  '||googlesyndication.com^'
].join('\n');

const STATUS_STALE_TIMEOUT_MS = 4000;

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

interface QueryLogEntry {
  ts: number;
  domain: string;
  qtype: string;
  action: string;
  rule: string;
  requestBytes?: number;
  responseBytes?: number;
  totalDnsBytes?: number;
}

interface QuerySummary {
  total: number;
  allowed: number;
  blocked: number;
  lastDomain: string;
  lastRule: string;
  requestBytes: number;
  responseBytes: number;
  totalDnsBytes: number;
}

interface DomainQueryStats {
  domain: string;
  total: number;
  allowed: number;
  blocked: number;
  lastAction: string;
  lastRule: string;
  requestBytes: number;
  responseBytes: number;
  totalDnsBytes: number;
  lastTs: number;
}

interface RuleProfile {
  id: string;
  name: string;
  content: string;
  enabled: boolean;
  updatedAt: number;
  builtIn?: boolean;
}

type QueryActionFilter = 'all' | 'allowed' | 'blocked';
type QuickRuleState = 'none' | 'block' | 'allow';

interface QuickRuleDialogButton {
  value: string;
  action: () => void;
}

interface PersistState {
  keepAliveEnabled?: boolean;
  audioKeepAliveEnabled?: boolean;
  locationKeepAliveEnabled?: boolean;
  autoStartFilterEnabled?: boolean;
  language?: LangCode;
  themeMode?: number;
  ruleProfiles?: RuleProfile[];
  dnsCacheTtlSeconds?: number;
  currentTab: number;
}

function defaultStats(): NativeStats {
  return {
    running: false,
    tunFd: -1,
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
    lastQueryDomain: '',
    lastMatchedRule: '',
    lastError: '',
  };
}

function defaultStatus(): StatusSnapshot {
  return {
    phase: 'idle',
    running: false,
    note: 'DNS filter has not been started yet.',
    updatedAt: '',
    tunFd: -1,
    nativeStats: defaultStats(),
  };
}

function defaultQuerySummary(): QuerySummary {
  return {
    total: 0,
    allowed: 0,
    blocked: 0,
    lastDomain: '',
    lastRule: '',
    requestBytes: 0,
    responseBytes: 0,
    totalDnsBytes: 0,
  };
}

@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @State busy: boolean = false;
  @State rulesDirty: boolean = false;
  @State language: LangCode = 'zhHans';
  @State themeMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  @State keepAliveEnabled: boolean = false;
  @State audioKeepAliveEnabled: boolean = true;
  @State locationKeepAliveEnabled: boolean = false;
  @State autoStartFilterEnabled: boolean = false;
  @State keepAliveRunning: boolean = false;
  @State keepAliveStatusText: string = '';
  @State status: StatusSnapshot = defaultStatus();
  @State errorText: string = '';
  @State statusFilePath: string = '';
  @State rulesFilePath: string = '';
  @State queryLogFilePath: string = '';
  @State debugLogFilePath: string = '';
  @State stateFilePath: string = '';
  @State rulesText: string = '';
  @State ruleProfiles: RuleProfile[] = [];
  @State importedRuleCountBadge: number = 0;
  @State customBlockRuleCountBadge: number = 0;
  @State customAllowRuleCountBadge: number = 0;
  @State queryEvents: QueryLogEntry[] = [];
  @State querySummary: QuerySummary = defaultQuerySummary();
  @State debugLines: string[] = [];
  @State showDnsSheet: boolean = false;
  @State showDomainSheet: boolean = false;
  @State showDebugSheet: boolean = false;
  @State showRuleEditorSheet: boolean = false;
  @State editingRuleProfileId: string = '';
  @State editingRuleNameText: string = '';
  @State domainSortDescending: boolean = true;
  @State domainActionFilter: QueryActionFilter = 'all';
  @State dnsSearchText: string = '';
  @State dnsActionFilter: QueryActionFilter = 'all';
  @State configFeedbackText: string = '';
  @State dnsSheetFeedbackText: string = '';
  @State domainSheetFeedbackText: string = '';
  @State debugSheetFeedbackText: string = '';
  @State dnsCacheTtlInput: string = `${DEFAULT_DNS_CACHE_TTL_SECONDS}`;
  @State dnsCacheTtlSeconds: number = DEFAULT_DNS_CACHE_TTL_SECONDS;
  @State appVersionName: string = 'loading';
  @State appVersionCode: number = 0;
  @State avoidPaddingTop: number = 0;
  @State avoidPaddingBottom: number = 0;

  private refreshTimer: number = -1;
  private dnsListScroller: Scroller = new Scroller();
  private domainListScroller: Scroller = new Scroller();
  private continuousTaskId: number = -1;
  private accessTokenId: number = -1;
  private avPlayer?: media.AVPlayer;
  private audioSessionManager?: audio.AudioSessionManager;
  private locationListening: boolean = false;
  private mainWindow?: window.Window;
  private hasBoundWindowAvoidAreaListeners: boolean = false;
  private suppressRuntimeArtifacts: boolean = false;
  private promptAction?: PromptAction;
  private autoStartAttempted: boolean = false;

  private async copyText(text: string): Promise<void> {
    if (text.trim().length === 0) {
      return;
    }
    try {
      const board = pasteboard.getSystemPasteboard();
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await board.setData(data);
    } catch (_) {
    }
  }

  private normalizeRuleContent(content: string): string {
    return content.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  }

  private isLegacyDefaultRulesText(content: string): boolean {
    return this.normalizeRuleContent(content).trim() === LEGACY_DEFAULT_RULES_TEXT;
  }

  private defaultCustomRuleName(): string {
    return this.t('defaultCustomRules');
  }

  private customBlockRuleName(): string {
    return this.t('customBlockRules');
  }

  private customAllowRuleName(): string {
    return this.t('customAllowRules');
  }

  private createRuleProfile(name: string, content: string, enabled: boolean = true, id?: string,
    builtIn: boolean = false): RuleProfile {
    return {
      id: id ?? `rule_${Date.now()}_${Math.floor(Math.random() * 100000)}`,
      name,
      content: this.normalizeRuleContent(content),
      enabled,
      updatedAt: Date.now(),
      builtIn,
    };
  }

  private createBuiltInRuleProfile(id: string, name: string): RuleProfile {
    return this.createRuleProfile(name, '', true, id, true);
  }

  private isBuiltInRuleProfile(profileId: string): boolean {
    return profileId === CUSTOM_BLOCK_RULE_PROFILE_ID || profileId === CUSTOM_ALLOW_RULE_PROFILE_ID;
  }

  private normalizeRuleProfiles(profiles: RuleProfile[]): RuleProfile[] {
    const importedProfiles: RuleProfile[] = [];
    let customBlockProfile: RuleProfile | undefined = undefined;
    let customAllowProfile: RuleProfile | undefined = undefined;

    profiles.forEach((profile: RuleProfile, index: number) => {
      const normalizedProfile: RuleProfile = {
        id: typeof profile.id === 'string' && profile.id.length > 0 ? profile.id : `rule_${index}_${Date.now()}`,
        name: typeof profile.name === 'string' && profile.name.trim().length > 0
          ? profile.name.trim()
          : `${this.defaultCustomRuleName()} ${index + 1}`,
        content: this.normalizeRuleContent(profile.content ?? ''),
        enabled: profile.enabled !== false,
        updatedAt: typeof profile.updatedAt === 'number' ? profile.updatedAt : Date.now(),
        builtIn: this.isBuiltInRuleProfile(profile.id),
      };
      if (normalizedProfile.id === CUSTOM_BLOCK_RULE_PROFILE_ID) {
        customBlockProfile = {
          id: normalizedProfile.id,
          name: this.customBlockRuleName(),
          content: normalizedProfile.content,
          enabled: normalizedProfile.enabled,
          updatedAt: normalizedProfile.updatedAt,
          builtIn: true,
        };
        return;
      }
      if (normalizedProfile.id === CUSTOM_ALLOW_RULE_PROFILE_ID) {
        customAllowProfile = {
          id: normalizedProfile.id,
          name: this.customAllowRuleName(),
          content: normalizedProfile.content,
          enabled: normalizedProfile.enabled,
          updatedAt: normalizedProfile.updatedAt,
          builtIn: true,
        };
        return;
      }
      importedProfiles.push({
        id: normalizedProfile.id,
        name: normalizedProfile.name,
        content: normalizedProfile.content,
        enabled: normalizedProfile.enabled,
        updatedAt: normalizedProfile.updatedAt,
        builtIn: false,
      });
    });

    if (customBlockProfile === undefined) {
      customBlockProfile = this.createBuiltInRuleProfile(CUSTOM_BLOCK_RULE_PROFILE_ID, this.customBlockRuleName());
    }
    if (customAllowProfile === undefined) {
      customAllowProfile = this.createBuiltInRuleProfile(CUSTOM_ALLOW_RULE_PROFILE_ID, this.customAllowRuleName());
    }

    return importedProfiles.concat([customBlockProfile, customAllowProfile]);
  }

  private ensureRuleProfilesInitialized(): void {
    if (this.ruleProfiles.length > 0) {
      this.ruleProfiles = this.normalizeRuleProfiles(this.ruleProfiles);
      this.syncRuleCountBadges();
      return;
    }
    const currentRules: string = this.normalizeRuleContent(this.readTextFile(this.rulesFilePath));
    if (currentRules.trim().length === 0 || this.isLegacyDefaultRulesText(currentRules)) {
      this.ruleProfiles = this.normalizeRuleProfiles([]);
    } else {
      this.ruleProfiles = this.normalizeRuleProfiles([
        this.createRuleProfile(this.defaultCustomRuleName(), currentRules, true)
      ]);
    }
    this.syncRuleCountBadges();
    this.rulesDirty = false;
    this.savePersistState();
  }

  private buildMergedRulesText(): string {
    const chunks: string[] = [];
    this.ruleProfiles.forEach((profile: RuleProfile) => {
      if (!profile.enabled) {
        return;
      }
      const normalized: string = this.normalizeRuleContent(profile.content).trim();
      if (normalized.length > 0) {
        chunks.push(normalized);
      }
    });
    return chunks.join('\n\n');
  }

  private enabledRuleProfileCount(): number {
    let count = 0;
    this.ruleProfiles.forEach((profile: RuleProfile) => {
      if (profile.enabled) {
        count += 1;
      }
    });
    return count;
  }

  private enabledRuleProfileSummary(): string {
    const enabledCount: number = this.enabledRuleProfileCount();
    const totalCount: number = this.ruleProfiles.length;
    return this.t('enabledRuleProfileSummary', enabledCount, totalCount);
  }

  private importedRuleLineCount(): number {
    let count = 0;
    this.ruleProfiles.forEach((profile: RuleProfile) => {
      if (!profile.builtIn) {
        count += this.ruleProfileLineCount(profile);
      }
    });
    return count;
  }

  private builtInRuleLineCount(profileId: string): number {
    const profile = this.ruleProfiles.find((item: RuleProfile) => item.id === profileId);
    if (profile === undefined) {
      return 0;
    }
    return this.ruleProfileLineCount(profile);
  }

  private syncRuleCountBadges(): void {
    this.importedRuleCountBadge = this.importedRuleLineCount();
    this.customBlockRuleCountBadge = this.builtInRuleLineCount(CUSTOM_BLOCK_RULE_PROFILE_ID);
    this.customAllowRuleCountBadge = this.builtInRuleLineCount(CUSTOM_ALLOW_RULE_PROFILE_ID);
  }

  private rulesImportedMessage(count: number): string {
    return this.t('rulesImportedMessage', count);
  }

  private exportSuccessMessage(fileName: string): string {
    return this.t('exportSuccessMessage', fileName);
  }

  private exportCanceledMessage(): string {
    return this.t('exportCanceledMessage');
  }

  private noRulesToExportMessage(): string {
    return this.t('noRulesToExportMessage');
  }

  private ensurePromptAction(): PromptAction | undefined {
    if (this.promptAction !== undefined) {
      return this.promptAction;
    }
    try {
      this.promptAction = this.getUIContext().getPromptAction();
    } catch (_) {
    }
    return this.promptAction;
  }

  private setConfigFeedback(message: string, showToast: boolean = true): void {
    this.configFeedbackText = message;
    if (showToast) {
      try {
        this.ensurePromptAction()?.showToast({ message });
      } catch (_) {
      }
    }
  }

  private ruleProfileLineCount(profile: RuleProfile): number {
    const normalized: string = this.normalizeRuleContent(profile.content).trim();
    if (normalized.length === 0) {
      return 0;
    }
    return normalized.split('\n').length;
  }

  private t(key: LanguageKey, ...args: Array<string | number>): string {
    try {
      return this.getHostContext().resourceManager.getStringSync(resolveStringResource(key), ...args);
    } catch (_) {
      return key;
    }
  }

  private ruleProfileMetaText(profile: RuleProfile): string {
    let lineCount: number = this.ruleProfileLineCount(profile);
    if (profile.id === CUSTOM_BLOCK_RULE_PROFILE_ID) {
      lineCount = this.customBlockRuleCountBadge;
    } else if (profile.id === CUSTOM_ALLOW_RULE_PROFILE_ID) {
      lineCount = this.customAllowRuleCountBadge;
    }
    const lockedText: string = profile.builtIn ? ` · ${this.t('builtInRuleProfileLocked')}` : '';
    return `${lineCount} ${this.t('lines')} · ${profile.enabled ? this.t('enabled') : this.t('disabled')}${lockedText}`;
  }

  private ruleProfileRenderKey(profile: RuleProfile): string {
    return `${profile.id}_${profile.updatedAt}_${profile.enabled ? '1' : '0'}_${this.ruleProfileLineCount(profile)}`;
  }

  private ruleProfileIndex(profileId: string): number {
    return this.ruleProfiles.findIndex((profile: RuleProfile) => profile.id === profileId);
  }

  private canMoveRuleProfileUp(profileId: string): boolean {
    if (this.isBuiltInRuleProfile(profileId)) {
      return false;
    }
    return this.ruleProfileIndex(profileId) > 0;
  }

  private canMoveRuleProfileDown(profileId: string): boolean {
    if (this.isBuiltInRuleProfile(profileId)) {
      return false;
    }
    const index: number = this.ruleProfileIndex(profileId);
    const customBlockIndex: number = this.ruleProfileIndex(CUSTOM_BLOCK_RULE_PROFILE_ID);
    if (customBlockIndex >= 0) {
      return index >= 0 && index < customBlockIndex - 1;
    }
    return index >= 0 && index < this.ruleProfiles.length - 1;
  }

  private moveRuleProfileUp(profileId: string): void {
    const index: number = this.ruleProfileIndex(profileId);
    if (index <= 0) {
      return;
    }
    this.moveRuleProfile(index, index - 1);
  }

  private moveRuleProfileDown(profileId: string): void {
    const index: number = this.ruleProfileIndex(profileId);
    if (index < 0 || index >= this.ruleProfiles.length - 1) {
      return;
    }
    this.moveRuleProfile(index, index + 1);
  }

  private moveRuleProfile(from: number, to: number): void {
    if (from < 0 || to < 0 || from >= this.ruleProfiles.length || to >= this.ruleProfiles.length || from === to) {
      return;
    }
    const next: RuleProfile[] = this.ruleProfiles.slice();
    const moved: RuleProfile[] = next.splice(from, 1);
    if (moved.length === 0) {
      return;
    }
    next.splice(to, 0, moved[0]);
    this.ruleProfiles = next;
    this.syncRuleCountBadges();
    this.rulesText = this.buildMergedRulesText();
    this.rulesDirty = true;
    this.savePersistState();
  }

  private toggleRuleProfileEnabled(profileId: string, enabled: boolean): void {
    const next: RuleProfile[] = [];
    this.ruleProfiles.forEach((profile: RuleProfile) => {
      if (profile.id === profileId) {
        next.push({
          id: profile.id,
          name: profile.name,
          content: profile.content,
          enabled,
          updatedAt: Date.now(),
          builtIn: profile.builtIn,
        });
      } else {
        next.push(profile);
      }
    });
    this.ruleProfiles = next;
    this.syncRuleCountBadges();
    this.rulesText = this.buildMergedRulesText();
    this.rulesDirty = true;
    this.savePersistState();
  }

  private openRuleEditor(profileId: string): void {
    const profile = this.ruleProfiles.find((item: RuleProfile) => item.id === profileId);
    if (profile === undefined) {
      return;
    }
    this.editingRuleProfileId = profileId;
    this.editingRuleNameText = profile.name;
    this.rulesText = profile.content;
    this.showRuleEditorSheet = true;
  }

  private closeRuleEditor(): void {
    this.showRuleEditorSheet = false;
    this.editingRuleProfileId = '';
    this.editingRuleNameText = '';
    this.loadRulesText();
  }

  private parseDnsCacheTtlInput(value: string): number {
    const trimmed: string = value.trim();
    if (trimmed.length === 0) {
      return DEFAULT_DNS_CACHE_TTL_SECONDS;
    }
    const parsed = parseInt(trimmed, 10);
    if (!Number.isFinite(parsed) || parsed < 0) {
      return DEFAULT_DNS_CACHE_TTL_SECONDS;
    }
    return parsed;
  }

  private updateDnsCacheTtl(value: string): void {
    this.dnsCacheTtlInput = value;
    this.dnsCacheTtlSeconds = this.parseDnsCacheTtlInput(value);
    this.savePersistState();
  }

  private buildRuleLineForDomain(domain: string, allow: boolean): string {
    return allow ? `@@||${domain}^` : `||${domain}^`;
  }

  private ruleProfileLines(profileContent: string): string[] {
    return this.normalizeRuleContent(profileContent)
      .split('\n')
      .map((line: string) => line.trim())
      .filter((line: string) => line.length > 0);
  }

  private quickRuleState(domain: string): QuickRuleState {
    const normalizedDomain: string = domain.trim().toLowerCase();
    if (normalizedDomain.length === 0) {
      return 'none';
    }
    const allowRule: string = this.buildRuleLineForDomain(normalizedDomain, true);
    const blockRule: string = this.buildRuleLineForDomain(normalizedDomain, false);
    for (const profile of this.normalizeRuleProfiles(this.ruleProfiles)) {
      const lines: string[] = this.ruleProfileLines(profile.content);
      if (profile.id === CUSTOM_ALLOW_RULE_PROFILE_ID && lines.includes(allowRule)) {
        return 'allow';
      }
      if (profile.id === CUSTOM_BLOCK_RULE_PROFILE_ID && lines.includes(blockRule)) {
        return 'block';
      }
    }
    return 'none';
  }

  private updateRuleProfileContent(profile: RuleProfile, nextLines: string[], originalLines: string[]): RuleProfile {
    return {
      id: profile.id,
      name: profile.name,
      content: nextLines.join('\n'),
      enabled: profile.enabled,
      updatedAt: nextLines.join('\n') === originalLines.join('\n') ? profile.updatedAt : Date.now(),
      builtIn: profile.builtIn,
    };
  }

  private quickRuleActionButton(label: string, domain: string, allow: boolean): QuickRuleDialogButton {
    return {
      value: label,
      action: () => {
        try {
          this.upsertQuickRule(domain, allow);
        } catch (err) {
          this.errorText = this.errorMessage(err);
        }
      }
    };
  }

  private upsertQuickRule(domain: string, allow: boolean): void {
    const normalizedDomain: string = domain.trim().toLowerCase();
    if (normalizedDomain.length === 0) {
      return;
    }
    const targetRule: string = this.buildRuleLineForDomain(normalizedDomain, allow);
    const oppositeRule: string = this.buildRuleLineForDomain(normalizedDomain, !allow);
    const targetProfileId: string = allow ? CUSTOM_ALLOW_RULE_PROFILE_ID : CUSTOM_BLOCK_RULE_PROFILE_ID;
    const oppositeProfileId: string = allow ? CUSTOM_BLOCK_RULE_PROFILE_ID : CUSTOM_ALLOW_RULE_PROFILE_ID;
    let targetExistsBefore: boolean = false;
    let oppositeExistsBefore: boolean = false;
    const nextProfiles: RuleProfile[] = this.normalizeRuleProfiles(this.ruleProfiles).map((profile: RuleProfile) => {
      const originalLines: string[] = this.ruleProfileLines(profile.content);
      let nextLines: string[] = originalLines.slice();
      if (profile.id === oppositeProfileId) {
        if (nextLines.includes(oppositeRule)) {
          oppositeExistsBefore = true;
          nextLines = nextLines.filter((line: string) => line !== oppositeRule);
        }
      }
      if (profile.id === targetProfileId) {
        if (nextLines.includes(targetRule)) {
          targetExistsBefore = true;
        } else {
          nextLines.push(targetRule);
        }
      }
      return this.updateRuleProfileContent(profile, nextLines, originalLines);
    });
    this.ruleProfiles = nextProfiles;
    this.syncRuleCountBadges();
    this.rulesText = this.buildMergedRulesText();
    this.rulesDirty = true;
    this.currentTab = 1;
    this.showDnsSheet = false;
    this.showDomainSheet = false;
    this.savePersistState();
    this.setConfigFeedback(targetExistsBefore && !oppositeExistsBefore
      ? this.t('ruleAlreadyExists', normalizedDomain)
      : this.t('ruleAddedNeedsRestart', normalizedDomain));
  }

  private confirmAddRuleForDomain(domain: string): void {
    const normalizedDomain: string = domain.trim().toLowerCase();
    if (normalizedDomain.length === 0) {
      return;
    }
    const currentState: QuickRuleState = this.quickRuleState(normalizedDomain);
    const blockButtonText: string = currentState === 'block'
      ? `${this.t('addBlockRuleAction')} ✓`
      : this.t('addBlockRuleAction');
    const allowButtonText: string = currentState === 'allow'
      ? `${this.t('addAllowRuleAction')} ✓`
      : this.t('addAllowRuleAction');
    const actionButtons: QuickRuleDialogButton[] = currentState === 'allow'
      ? [
          this.quickRuleActionButton(allowButtonText, normalizedDomain, true),
          this.quickRuleActionButton(blockButtonText, normalizedDomain, false)
        ]
      : [
          this.quickRuleActionButton(blockButtonText, normalizedDomain, false),
          this.quickRuleActionButton(allowButtonText, normalizedDomain, true)
        ];
    this.getUIContext().showAlertDialog({
      title: this.t('addRuleActionTitle'),
      message: normalizedDomain,
      buttons: [
        {
          value: this.t('cancel'),
          action: () => {
            try {
              this.promptAction?.showToast({ message: this.t('operationCanceled') });
            } catch (_) {
            }
          }
        },
        actionButtons[0],
        actionButtons[1]
      ]
    });
  }

  private applyRuleEditorChanges(): void {
    const next: RuleProfile[] = [];
    let changed = false;
    this.ruleProfiles.forEach((profile: RuleProfile) => {
      if (profile.id === this.editingRuleProfileId) {
        const trimmedName: string = this.editingRuleNameText.trim();
        const nextName: string = trimmedName.length > 0 ? trimmedName : profile.name;
        const nextContent: string = this.normalizeRuleContent(this.rulesText);
        next.push({
          id: profile.id,
          name: nextName,
          content: nextContent,
          enabled: profile.enabled,
          updatedAt: Date.now(),
          builtIn: profile.builtIn,
        });
        changed = true;
      } else {
        next.push(profile);
      }
    });
    if (!changed) {
      return;
    }
    this.ruleProfiles = next;
    this.syncRuleCountBadges();
    this.rulesText = this.buildMergedRulesText();
    this.rulesDirty = true;
    this.savePersistState();
    this.closeRuleEditor();
  }

  private confirmDeleteRuleProfile(profileId: string): void {
    if (this.isBuiltInRuleProfile(profileId)) {
      return;
    }
    const profile = this.ruleProfiles.find((item: RuleProfile) => item.id === profileId);
    if (profile === undefined) {
      return;
    }
    this.getUIContext().showAlertDialog({
      message: `${this.t('confirmDeleteRuleProfile')}\n${profile.name}`,
      buttons: [
        {
          value: this.t('cancel'),
          action: () => {
            try {
              this.promptAction?.showToast({ message: this.t('operationCanceled') });
            } catch (_) {
            }
          }
        },
        {
          value: this.t('confirm'),
          action: () => {
            try {
              this.ruleProfiles = this.ruleProfiles.filter((item: RuleProfile) => item.id !== profileId);
              this.syncRuleCountBadges();
              this.rulesText = this.buildMergedRulesText();
              this.rulesDirty = true;
              this.savePersistState();
              if (this.editingRuleProfileId === profileId) {
                this.closeRuleEditor();
              }
            } catch (err) {
              this.errorText = this.errorMessage(err);
            }
          }
        }
      ]
    });
  }

  private ruleProfileNameFromUri(fileUri: string, fallbackIndex: number): string {
    try {
      const parsedUri = new uri.URI(fileUri);
      const encodedPath: string = parsedUri.encodedPath;
      if (encodedPath.length > 0) {
        const decodedPath: string = decodeURIComponent(encodedPath);
        const parts: string[] = decodedPath.split(/[/\\]/);
        const lastPart: string = parts[parts.length - 1];
        if (lastPart.length > 0) {
          return lastPart;
        }
      }
    } catch (_) {
    }
    return `${this.defaultCustomRuleName()} ${fallbackIndex}`;
  }

  private async copyDnsRequests(): Promise<void> {
    const content = this.dnsExportText();
    if (content.trim().length === 0) {
      this.dnsSheetFeedbackText = this.t('noDnsRequestsToCopy');
      return;
    }
    await this.copyText(content);
    this.dnsSheetFeedbackText = this.t('dnsRequestsCopied', this.filteredQueryEvents().length);
  }

  private async copyDebugLogs(): Promise<void> {
    const content = this.debugLogText();
    if (content.trim().length === 0) {
      this.debugSheetFeedbackText = this.t('noDebugLogsToCopy');
      return;
    }
    await this.copyText(content);
    this.debugSheetFeedbackText = this.t('debugLogsCopied', this.debugLines.length);
  }

  private debugLogText(): string {
    return this.debugLines.slice().reverse().join('\n');
  }

  private filteredQueryEvents(): QueryLogEntry[] {
    let items: QueryLogEntry[] = this.queryEvents;
    if (this.dnsActionFilter !== 'all') {
      items = items.filter((item: QueryLogEntry) => item.action.trim().toLowerCase() === this.dnsActionFilter);
    }
    const keyword = this.dnsSearchText.trim().toLowerCase();
    if (keyword.length === 0) {
      return items;
    }
    return items.filter((item: QueryLogEntry) => {
      return item.domain.toLowerCase().includes(keyword)
        || item.qtype.toLowerCase().includes(keyword)
        || item.action.toLowerCase().includes(keyword)
        || item.rule.toLowerCase().includes(keyword);
    });
  }

  private queryEntryText(item: QueryLogEntry): string {
    const requestBytes: number = item.requestBytes ?? 0;
    const responseBytes: number = item.responseBytes ?? 0;
    const totalDnsBytes: number = item.totalDnsBytes ?? (requestBytes + responseBytes);
    const ruleText: string = item.rule && item.rule.trim().length > 0 ? item.rule : this.t('none');
    return `${item.domain}\t${item.qtype}\t${item.action}\t${ruleText}\t${requestBytes}/${responseBytes}/${totalDnsBytes}\t${item.ts}`;
  }

  private dnsExportText(): string {
    const lines: string[] = this.filteredQueryEvents().map((item: QueryLogEntry) => this.queryEntryText(item));
    return lines.join('\n');
  }

  private dnsSheetCountText(): string {
    return `${this.filteredQueryEvents().length} ${this.t('lines')}`;
  }

  private domainSheetCountText(): string {
    return `${this.orderedDomainStats().length} ${this.t('lines')}`;
  }

  private topDomainStats(limit: number = 5): DomainQueryStats[] {
    const map: Map<string, DomainQueryStats> = new Map<string, DomainQueryStats>();
    for (const item of this.queryEvents) {
      const key: string = item.domain.trim().toLowerCase();
      if (key.length === 0) {
        continue;
      }
      const requestBytes: number = item.requestBytes ?? 0;
      const responseBytes: number = item.responseBytes ?? 0;
      const totalDnsBytes: number = item.totalDnsBytes ?? (requestBytes + responseBytes);
      let stats: DomainQueryStats | undefined = map.get(key);
      if (stats === undefined) {
        stats = {
          domain: item.domain,
          total: 0,
          allowed: 0,
          blocked: 0,
          lastAction: item.action.trim().toLowerCase(),
          lastRule: item.rule,
          requestBytes: 0,
          responseBytes: 0,
          totalDnsBytes: 0,
          lastTs: item.ts,
        };
        map.set(key, stats);
      }
      stats.total += 1;
      if (item.action.trim().toLowerCase() === 'blocked') {
        stats.blocked += 1;
      } else {
        stats.allowed += 1;
      }
      stats.lastAction = item.action.trim().toLowerCase();
      stats.lastRule = item.rule;
      stats.requestBytes += requestBytes;
      stats.responseBytes += responseBytes;
      stats.totalDnsBytes += totalDnsBytes;
      stats.lastTs = Math.max(stats.lastTs, item.ts);
    }
    const ordered: DomainQueryStats[] = Array.from(map.values()).sort((a: DomainQueryStats, b: DomainQueryStats) => {
      if (b.total !== a.total) {
        return b.total - a.total;
      }
      return b.lastTs - a.lastTs;
    });
    return ordered.slice(0, limit);
  }

  private orderedDomainStats(limit?: number): DomainQueryStats[] {
    const allItems: DomainQueryStats[] = this.topDomainStats(Number.MAX_SAFE_INTEGER);
    let filteredItems: DomainQueryStats[] = allItems;
    if (this.domainActionFilter !== 'all') {
      filteredItems = allItems.filter((item: DomainQueryStats) => item.lastAction === this.domainActionFilter);
    }
    const orderedItems: DomainQueryStats[] = this.domainSortDescending ? filteredItems : filteredItems.slice().reverse();
    if (limit === undefined) {
      return orderedItems;
    }
    return orderedItems.slice(0, limit);
  }

  private domainPreviewStats(): DomainQueryStats[] {
    return this.orderedDomainStats(3);
  }

  private domainSortButtonText(): string {
    return this.domainSortDescending ? this.t('descendingOrder') : this.t('ascendingOrder');
  }

  private domainCountForFilter(filter: QueryActionFilter): number {
    const allItems: DomainQueryStats[] = this.topDomainStats(Number.MAX_SAFE_INTEGER);
    switch (filter) {
      case 'allowed':
        return allItems.filter((item: DomainQueryStats) => item.lastAction === 'allowed').length;
      case 'blocked':
        return allItems.filter((item: DomainQueryStats) => item.lastAction === 'blocked').length;
      default:
        return allItems.length;
    }
  }

  private domainFilterLabel(filter: QueryActionFilter): string {
    switch (filter) {
      case 'allowed':
        return `${this.t('allowedTag')} ${this.domainCountForFilter(filter)}`;
      case 'blocked':
        return `${this.t('blockedTag')} ${this.domainCountForFilter(filter)}`;
      default:
        return this.t('allWithCount', this.domainCountForFilter(filter));
    }
  }

  private domainStatsEntryText(item: DomainQueryStats): string {
    return `${item.domain}\t${item.total}\t${item.allowed}\t${item.blocked}\t${item.requestBytes}/${item.responseBytes}/${item.totalDnsBytes}\t${item.lastTs}`;
  }

  private domainStatsExportText(): string {
    return this.orderedDomainStats()
      .map((item: DomainQueryStats) => this.domainStatsEntryText(item))
      .join('\n');
  }

  private async copyDomainStats(): Promise<void> {
    const content = this.domainStatsExportText();
    if (content.trim().length === 0) {
      this.domainSheetFeedbackText = this.t('noDomainStatsToCopy');
      return;
    }
    await this.copyText(content);
    this.domainSheetFeedbackText = this.t('domainStatsCopied', this.orderedDomainStats().length);
  }

  private async exportDomainStats(): Promise<void> {
    const content = this.domainStatsExportText();
    if (content.trim().length === 0) {
      this.domainSheetFeedbackText = this.t('noDomainStatsToExport');
      return;
    }
    const fileName = await this.exportTextToDownloadDirectory('domain_leaderboard', 'txt', content);
    if (fileName === undefined) {
      this.domainSheetFeedbackText = this.exportCanceledMessage();
      return;
    }
    this.domainSheetFeedbackText = this.exportSuccessMessage(fileName);
    this.keepAliveStatusText = this.t('domainStatsExportedStatus', fileName);
    try {
      this.promptAction?.showToast({ message: this.t('exportSuccessToast', fileName) });
    } catch (_) {
    }
  }

  private clearDomainStatsData(): void {
    this.clearDnsRequestData();
    this.domainSheetFeedbackText = this.t('dnsRequestsCleared');
  }

  private confirmClearDomainStats(): void {
    this.getUIContext().showAlertDialog({
      message: this.t('clearDnsRequestsConfirm'),
      buttons: [
        {
          value: this.t('cancel'),
          action: () => {
            try {
              this.promptAction?.showToast({ message: this.t('operationCanceled') });
            } catch (_) {
            }
          }
        },
        {
          value: this.t('confirm'),
          action: () => {
            try {
              this.clearDomainStatsData();
              this.promptAction?.showToast({ message: this.t('dnsRequestsCleared') });
            } catch (err) {
              this.errorText = this.errorMessage(err);
            }
          }
        }
      ]
    });
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  private dnsCountForFilter(filter: QueryActionFilter): number {
    switch (filter) {
      case 'allowed':
        return this.querySummary.allowed;
      case 'blocked':
        return this.querySummary.blocked;
      default:
        return this.querySummary.total;
    }
  }

  private dnsFilterLabel(filter: QueryActionFilter): string {
    switch (filter) {
      case 'allowed':
        return `${this.t('allowedTag')} ${this.dnsCountForFilter(filter)}`;
      case 'blocked':
        return `${this.t('blockedTag')} ${this.dnsCountForFilter(filter)}`;
      default:
        return this.t('allWithCount', this.dnsCountForFilter(filter));
    }
  }

  private exportFileTimestamp(): string {
    const now = new Date();
    const year = `${now.getFullYear()}`;
    const month = `${now.getMonth() + 1}`.padStart(2, '0');
    const day = `${now.getDate()}`.padStart(2, '0');
    const hours = `${now.getHours()}`.padStart(2, '0');
    const minutes = `${now.getMinutes()}`.padStart(2, '0');
    const seconds = `${now.getSeconds()}`.padStart(2, '0');
    return `${year}-${month}-${day}_${hours}-${minutes}-${seconds}`;
  }

  private sanitizeExportBaseName(name: string, fallback: string): string {
    const trimmed: string = name.trim();
    const normalized: string = (trimmed.length > 0 ? trimmed : fallback)
      .replace(/[\\/:*?"<>|]/g, '_')
      .replace(/\s+/g, ' ')
      .trim();
    return normalized.length > 0 ? normalized : fallback;
  }

  private async exportTextToDownloadDirectory(baseName: string, extension: string, content: string, customFileName?: string): Promise<string | undefined> {
    const pickerOptions = new picker.DocumentSaveOptions();
    pickerOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const savePicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.getHostContext());
    const uris: string[] = await savePicker.save(pickerOptions);
    if (!uris || uris.length === 0) {
      return undefined;
    }
    const downloadPath: string = decodeURIComponent(new uri.URI(uris[0]).encodedPath);
    const fileName: string = customFileName ?? `${baseName}_${this.exportFileTimestamp()}.${extension}`;
    const exportPath = `${downloadPath}/${fileName}`;
    if (!this.writeTextFile(exportPath, content)) {
      throw new Error(this.t('exportFileFailed', fileName));
    }
    return fileName;
  }

  private async exportDnsRequests(): Promise<void> {
    const content = this.dnsExportText();
    if (content.trim().length === 0) {
      this.dnsSheetFeedbackText = this.t('noDnsRequestsToExport');
      return;
    }
    const fileName = await this.exportTextToDownloadDirectory('dns_requests', 'txt', content);
    if (fileName === undefined) {
      this.dnsSheetFeedbackText = this.exportCanceledMessage();
      return;
    }
    this.dnsSheetFeedbackText = this.exportSuccessMessage(fileName);
    this.keepAliveStatusText = this.t('dnsRequestsExportedStatus', fileName);
    try {
      this.promptAction?.showToast({ message: this.t('exportSuccessToast', fileName) });
    } catch (_) {
    }
  }

  private clearDnsRequestData(): void {
    if (!this.writeTextFile(this.queryLogFilePath, '')) {
      throw new Error(this.t('clearDnsRequestsFailed'));
    }
    this.queryEvents = [];
    this.querySummary = defaultQuerySummary();
    this.dnsSheetFeedbackText = this.t('dnsRequestsCleared');
    this.keepAliveStatusText = this.t('dnsRequestsCleared');
    this.dnsSearchText = '';
    this.dnsActionFilter = 'all';
    this.domainActionFilter = 'all';
  }

  private confirmClearDnsRequests(): void {
    this.getUIContext().showAlertDialog({
      message: this.t('clearDnsRequestsConfirm'),
      buttons: [
        {
          value: this.t('cancel'),
          action: () => {
            try {
              this.promptAction?.showToast({ message: this.t('operationCanceled') });
            } catch (_) {
            }
          }
        },
        {
          value: this.t('confirm'),
          action: () => {
            try {
              this.clearDnsRequestData();
              this.promptAction?.showToast({ message: this.t('dnsRequestsCleared') });
            } catch (err) {
              this.errorText = this.errorMessage(err);
            }
          }
        }
      ]
    });
  }

  private async exportDebugLogs(): Promise<void> {
    const content = this.debugLogText();
    if (content.trim().length === 0) {
      this.debugSheetFeedbackText = this.t('noDebugLogsToExport');
      return;
    }
    const fileName = await this.exportTextToDownloadDirectory('debug_log', 'txt', content);
    if (fileName === undefined) {
      this.debugSheetFeedbackText = this.exportCanceledMessage();
      return;
    }
    this.debugSheetFeedbackText = this.exportSuccessMessage(fileName);
    this.keepAliveStatusText = this.t('debugLogsExportedStatus', fileName);
    try {
      this.promptAction?.showToast({ message: this.t('exportSuccessToast', fileName) });
    } catch (_) {
    }
  }

  private async exportRulesFile(): Promise<void> {
    const content = this.buildMergedRulesText();
    if (content.trim().length === 0) {
      this.setConfigFeedback(this.t('importedEmpty'));
      return;
    }
    const fileName = await this.exportTextToDownloadDirectory('filters', 'txt', content);
    if (fileName === undefined) {
      this.setConfigFeedback(this.exportCanceledMessage());
      return;
    }
    this.setConfigFeedback(this.exportSuccessMessage(fileName));
  }

  private async exportRuleEditorContent(): Promise<void> {
    const content = this.normalizeRuleContent(this.rulesText).trim();
    if (content.length === 0) {
      this.setConfigFeedback(this.noRulesToExportMessage());
      return;
    }
    const baseName: string = this.sanitizeExportBaseName(this.editingRuleNameText, 'filters');
    const fileName = await this.exportTextToDownloadDirectory(baseName, 'txt', content, `${baseName}.txt`);
    if (fileName === undefined) {
      this.setConfigFeedback(this.exportCanceledMessage());
      return;
    }
    this.setConfigFeedback(this.exportSuccessMessage(fileName));
  }

  private getHostContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async initWindowAvoidPadding(): Promise<void> {
    try {
      this.mainWindow = await window.getLastWindow(this.getHostContext());
      this.updateWindowAvoidPadding();
      if (!this.hasBoundWindowAvoidAreaListeners && this.mainWindow !== undefined) {
        this.mainWindow.on('avoidAreaChange', () => {
          this.updateWindowAvoidPadding();
        });
        this.mainWindow.on('windowSizeChange', () => {
          this.updateWindowAvoidPadding();
          this.promptAction = this.getUIContext().getPromptAction();
        });
        this.hasBoundWindowAvoidAreaListeners = true;
      }
    } catch (_) {
      this.avoidPaddingTop = 0;
      this.avoidPaddingBottom = 0;
    }
  }

  private updateWindowAvoidPadding(): void {
    if (this.mainWindow === undefined) {
      this.avoidPaddingTop = 0;
      this.avoidPaddingBottom = 0;
      return;
    }
    try {
      const uiContext = this.getUIContext();
      let topInsetVp = 0;
      let bottomInsetVp = 0;
      try {
        const systemArea: window.AvoidArea = this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        topInsetVp = Math.max(topInsetVp, uiContext.px2vp(systemArea.topRect.height));
        bottomInsetVp = Math.max(bottomInsetVp, uiContext.px2vp(systemArea.bottomRect.height));
      } catch (_) {
      }
      try {
        const navArea: window.AvoidArea =
          this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        bottomInsetVp = Math.max(bottomInsetVp, uiContext.px2vp(navArea.bottomRect.height));
      } catch (_) {
      }
      this.avoidPaddingTop = Math.max(0, Math.round(topInsetVp));
      this.avoidPaddingBottom = Math.max(0, Math.round(bottomInsetVp));
    } catch (_) {
      this.avoidPaddingTop = 0;
      this.avoidPaddingBottom = 0;
    }
  }

  private contentTopInset(): number {
    if (this.avoidPaddingTop > 0) {
      return this.avoidPaddingTop;
    }
    return 12;
  }

  private detectSystemLang(): LangCode {
    try {
      const systemLang: string = i18n.System.getSystemLanguage();
      if (systemLang.startsWith('zh-Hant')) {
        return 'zhHant';
      }
      if (systemLang.startsWith('en')) {
        return 'en';
      }
      return 'zhHans';
    } catch (_) {
      return 'zhHans';
    }
  }

  private toPreferredLanguage(lang: LangCode): PreferredLangCode {
    if (lang === 'en') {
      return 'en-Latn-US';
    }
    if (lang === 'zhHant') {
      return 'zh-Hant';
    }
    return 'zh-Hans';
  }

  private applyPreferredLanguage(lang: LangCode): void {
    this.language = lang;
    try {
      i18n.System.setAppPreferredLanguage(this.toPreferredLanguage(lang));
    } catch (_) {
    }
  }

  private applyTheme(mode: number): void {
    this.themeMode = mode;
    try {
      this.getHostContext().getApplicationContext().setColorMode(mode);
    } catch (_) {
    }
  }

  private setLanguage(lang: LangCode): void {
    this.applyPreferredLanguage(lang);
    this.savePersistState();
  }

  private setTheme(mode: number): void {
    this.applyTheme(mode);
    this.savePersistState();
  }

  private isDarkModeActive(): boolean {
    if (this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      return true;
    }
    if (this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      return false;
    }
    try {
      return this.getHostContext().config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (_) {
      return false;
    }
  }

  aboutToAppear(): void {
    this.ensurePromptAction();
    this.ensureRuntimeFiles();
    this.loadPersistState();
    this.applyPreferredLanguage(this.language);
    this.ensureRuleProfilesInitialized();
    this.autoStartAttempted = false;
    this.applyTheme(this.themeMode);
    this.initWindowAvoidPadding();
    if (this.keepAliveStatusText.length === 0) {
      this.keepAliveStatusText = this.t('keepAliveOffStatus');
    }
    if (this.status.note === 'DNS filter has not been started yet.') {
      this.status = {
        phase: this.status.phase,
        running: this.status.running,
        note: this.t('dnsFilterNotStarted'),
        updatedAt: this.status.updatedAt,
        tunFd: this.status.tunFd,
        nativeStats: this.status.nativeStats,
      };
    }
    this.loadRulesText();
    this.loadAppVersion();
    this.refreshAll();
    void this.tryAutoStartFilterOnLaunch();
    this.refreshTimer = setInterval(() => {
      this.refreshAll();
    }, 1200);
  }

  aboutToDisappear(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private ensureRuntimeFiles(): void {
    const ctx = this.getHostContext();
    const vpnDir = `${ctx.filesDir}/${VPN_DIR_NAME}`;
    this.statusFilePath = `${vpnDir}/${STATUS_FILE_NAME}`;
    this.rulesFilePath = `${vpnDir}/${RULES_FILE_NAME}`;
    this.queryLogFilePath = `${vpnDir}/${QUERY_LOG_FILE_NAME}`;
    this.debugLogFilePath = `${vpnDir}/${DEBUG_LOG_FILE_NAME}`;
    this.stateFilePath = `${vpnDir}/${STATE_FILE_NAME}`;
    try {
      fileIo.mkdirSync(vpnDir, true);
    } catch (_) {
    }

    const currentRules: string = this.readTextFile(this.rulesFilePath);
    if (this.isLegacyDefaultRulesText(currentRules)) {
      this.writeTextFile(this.rulesFilePath, '');
    }
    this.rulesText = this.isLegacyDefaultRulesText(currentRules) ? '' : currentRules;

    hilog.info(
      DOMAIN,
      TAG,
      '==/vpn_ui/runtime_files/ status=%{public}s rules=%{public}s query=%{public}s',
      this.statusFilePath,
      this.rulesFilePath,
      this.queryLogFilePath
    );
    this.appendDebugLog(
      `==/vpn_ui/runtime_files/ status=${this.statusFilePath} rules=${this.rulesFilePath} query=${this.queryLogFilePath}`
    );
  }

  private buildVpnWant(): Want {
    return {
      deviceId: '',
      bundleName: VPN_BUNDLE_NAME,
      moduleName: VPN_MODULE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        statusFilePath: this.statusFilePath,
        rulesFilePath: this.rulesFilePath,
        queryLogFilePath: this.queryLogFilePath,
        debugLogFilePath: this.debugLogFilePath,
        dnsCacheTtlSeconds: this.dnsCacheTtlSeconds,
      },
    };
  }

  private buildKeepAliveWantAgentInfo(): wantAgent.WantAgentInfo {
    return {
      wants: [{
        bundleName: VPN_BUNDLE_NAME,
        abilityName: ENTRY_ABILITY_NAME,
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
  }

  private loadPersistState(): void {
    try {
      const raw: string = this.readTextFile(this.stateFilePath);
      if (raw.trim().length === 0) {
        this.language = this.detectSystemLang();
        return;
      }
      const state: PersistState = JSON.parse(raw) as PersistState;
      if (state.language === 'zhHans' || state.language === 'en' || state.language === 'zhHant') {
        this.language = state.language;
      } else {
        this.language = this.detectSystemLang();
      }
      if (typeof state.themeMode === 'number') {
        this.themeMode = state.themeMode;
      }
      if (typeof state.audioKeepAliveEnabled === 'boolean') {
        this.audioKeepAliveEnabled = state.audioKeepAliveEnabled;
      } else if (typeof state.keepAliveEnabled === 'boolean') {
        this.audioKeepAliveEnabled = state.keepAliveEnabled;
      }
      if (typeof state.locationKeepAliveEnabled === 'boolean') {
        this.locationKeepAliveEnabled = state.locationKeepAliveEnabled;
      }
      if (typeof state.autoStartFilterEnabled === 'boolean') {
        this.autoStartFilterEnabled = state.autoStartFilterEnabled;
      }
      if (typeof state.currentTab === 'number' && state.currentTab >= 0 && state.currentTab <= 2) {
        this.currentTab = state.currentTab;
      }
      if (typeof state.dnsCacheTtlSeconds === 'number' && Number.isFinite(state.dnsCacheTtlSeconds)
        && state.dnsCacheTtlSeconds >= 0) {
        this.dnsCacheTtlSeconds = Math.floor(state.dnsCacheTtlSeconds);
        this.dnsCacheTtlInput = `${this.dnsCacheTtlSeconds}`;
      } else {
        this.dnsCacheTtlSeconds = DEFAULT_DNS_CACHE_TTL_SECONDS;
        this.dnsCacheTtlInput = `${DEFAULT_DNS_CACHE_TTL_SECONDS}`;
      }
      if (Array.isArray(state.ruleProfiles)) {
        const nextProfiles: RuleProfile[] = [];
        state.ruleProfiles.forEach((item: RuleProfile, index: number) => {
          if (typeof item?.content !== 'string') {
            return;
          }
          nextProfiles.push({
            id: typeof item.id === 'string' && item.id.length > 0 ? item.id : `rule_${index}_${Date.now()}`,
            name: typeof item.name === 'string' && item.name.trim().length > 0
              ? item.name.trim()
              : `${this.defaultCustomRuleName()} ${index + 1}`,
            content: this.normalizeRuleContent(item.content),
            enabled: item.enabled !== false,
            updatedAt: typeof item.updatedAt === 'number' ? item.updatedAt : Date.now(),
            builtIn: this.isBuiltInRuleProfile(item.id),
          });
        });
        if (nextProfiles.length === 1 && this.isLegacyDefaultRulesText(nextProfiles[0].content)) {
          this.ruleProfiles = this.normalizeRuleProfiles([]);
        } else if (nextProfiles.length > 0) {
          this.ruleProfiles = this.normalizeRuleProfiles(nextProfiles);
        }
        this.syncRuleCountBadges();
      }
      this.syncKeepAliveEnabledFlag();
      if (this.keepAliveEnabled) {
        this.keepAliveStatusText = this.keepAliveModeSummary(false);
      }
    } catch (_) {
    }
  }

  private savePersistState(): void {
    this.syncKeepAliveEnabledFlag();
    const state: PersistState = {
      keepAliveEnabled: this.keepAliveEnabled,
      audioKeepAliveEnabled: this.audioKeepAliveEnabled,
      locationKeepAliveEnabled: this.locationKeepAliveEnabled,
      autoStartFilterEnabled: this.autoStartFilterEnabled,
      language: this.language,
      themeMode: this.themeMode,
      ruleProfiles: this.ruleProfiles,
      dnsCacheTtlSeconds: this.dnsCacheTtlSeconds,
      currentTab: this.currentTab,
    };
    this.writeTextFile(this.stateFilePath, JSON.stringify(state));
  }

  private async loadAppVersion(): Promise<void> {
    try {
      const bundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      this.appVersionName = bundleInfo.versionName;
      this.appVersionCode = bundleInfo.versionCode;
    } catch (_) {
      this.appVersionName = 'unknown';
      this.appVersionCode = 0;
    }
  }

  private readTextFile(path: string): string {
    try {
      return fileIo.readTextSync(path);
    } catch (_) {
      return '';
    }
  }

  private writeTextFile(path: string, content: string): boolean {
    let f: fileIo.File | undefined = undefined;
    try {
      f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, content);
      return true;
    } catch (_) {
      return false;
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
      f = fileIo.openSync(
        this.debugLogFilePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND
      );
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

  private refreshAll(): void {
    this.refreshStatus();
    this.refreshQueryLog();
    this.refreshDebugLog();
  }

  private refreshStatus(): void {
    const raw = this.readTextFile(this.statusFilePath);
    if (raw.trim().length === 0) {
      this.suppressRuntimeArtifacts = true;
      this.status = this.buildInactiveStatus();
      return;
    }

    try {
      const snapshot = JSON.parse(raw) as StatusSnapshot;
      if (this.isStaleRunningSnapshot(snapshot)) {
        this.suppressRuntimeArtifacts = true;
        this.status = this.buildInactiveStatus();
        this.writeTextFile(this.statusFilePath, JSON.stringify(defaultStatus()));
      } else {
        this.suppressRuntimeArtifacts = false;
        this.status = this.normalizeStatusSnapshot(snapshot);
      }
      this.errorText = '';
    } catch (err) {
      this.errorText = this.errorMessage(err);
      hilog.error(DOMAIN, TAG, '==/vpn_ui/status_parse_error/ %{public}s', this.errorText);
    }
  }

  private refreshQueryLog(): void {
    if (this.suppressRuntimeArtifacts) {
      this.queryEvents = [];
      this.querySummary = defaultQuerySummary();
      return;
    }

    const raw = this.readTextFile(this.queryLogFilePath);
    if (raw.trim().length === 0) {
      this.queryEvents = [];
      this.querySummary = defaultQuerySummary();
      return;
    }

    const lines: string[] = raw.split('\n');
    const parsedEntries: QueryLogEntry[] = [];
    let total: number = 0;
    let allowed: number = 0;
    let blocked: number = 0;
    let lastDomain: string = '';
    let lastRule: string = '';
    let requestBytes: number = 0;
    let responseBytes: number = 0;
    let totalDnsBytes: number = 0;

    for (const rawLine of lines) {
      const line: string = rawLine.trim();
      if (line.length === 0) {
        continue;
      }
      try {
        const entry = JSON.parse(line) as QueryLogEntry;
        parsedEntries.push(entry);
        total += 1;
        if (entry.action.trim().toLowerCase() === 'blocked') {
          blocked += 1;
        } else {
          allowed += 1;
        }
        requestBytes += entry.requestBytes ?? 0;
        responseBytes += entry.responseBytes ?? 0;
        totalDnsBytes += entry.totalDnsBytes ?? ((entry.requestBytes ?? 0) + (entry.responseBytes ?? 0));
        lastDomain = entry.domain;
        lastRule = entry.rule;
      } catch (_) {
      }
    }

    this.queryEvents = parsedEntries.reverse();
    this.querySummary = {
      total: total,
      allowed: allowed,
      blocked: blocked,
      lastDomain: lastDomain,
      lastRule: lastRule,
      requestBytes: requestBytes,
      responseBytes: responseBytes,
      totalDnsBytes: totalDnsBytes,
    };
  }

  private refreshDebugLog(): void {
    const raw = this.readTextFile(this.debugLogFilePath);
    if (raw.trim().length === 0) {
      this.debugLines = [];
      return;
    }

    const lines: string[] = raw.split('\n');
    const items: string[] = [];
    let index: number = lines.length - 1;
    while (index >= 0 && items.length < 20) {
      const line: string = lines[index].trim();
      if (line.length > 0) {
        items.push(line);
      }
      index -= 1;
    }
    this.debugLines = items;
  }

  private loadRulesText(): void {
    if (this.rulesDirty) {
      return;
    }
    this.ensureRuleProfilesInitialized();
    const mergedRules: string = this.buildMergedRulesText();
    this.rulesText = mergedRules;
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

  private async startVpn(): Promise<void> {
    if (this.busy) {
      return;
    }

    this.busy = true;
    this.errorText = '';
    try {
      if (!this.writeTextFile(this.rulesFilePath, this.rulesText)) {
        throw new Error('Failed to write rules file');
      }
      this.rulesDirty = false;
      hilog.info(
        DOMAIN,
        TAG,
        '==/vpn_ui/start_request/ rules=%{public}s query=%{public}s',
        this.rulesFilePath,
        this.queryLogFilePath
      );
      this.appendDebugLog(`==/vpn_ui/start_request/ rules=${this.rulesFilePath} query=${this.queryLogFilePath}`);
      await vpnExtension.startVpnExtensionAbility(this.buildVpnWant());
      hilog.info(DOMAIN, TAG, '%{public}s', '==/vpn_ui/start_resolved/');
      this.appendDebugLog('==/vpn_ui/start_resolved/');
      this.status = this.updatedStatus(
        'starting',
        this.t('startRequested')
      );
      if (this.keepAliveModeList().length > 0) {
        await this.startLongTaskKeepAlive();
      }
    } catch (err) {
      const message = this.errorMessage(err);
      this.errorText = message;
      hilog.error(DOMAIN, TAG, '==/vpn_ui/start_error/ %{public}s', message);
      this.appendDebugLog(`==/vpn_ui/start_error/ ${message}`);
    } finally {
      this.busy = false;
      this.refreshAll();
    }
  }

  private async canEnableAutoStartFilter(): Promise<boolean> {
    try {
      await vpnExtension.startVpnExtensionAbility(this.buildVpnWant());
      this.appendDebugLog('==/vpn_ui/auto_start_permission_granted/');
      await vpnExtension.stopVpnExtensionAbility(this.buildVpnWant());
      this.refreshAll();
      return true;
    } catch (err) {
      const message = this.errorMessage(err);
      this.appendDebugLog(`==/vpn_ui/auto_start_permission_denied/ ${message}`);
      this.keepAliveStatusText = this.t('autoStartFilterPermissionDenied');
      this.errorText = message;
      this.autoStartFilterEnabled = false;
      this.savePersistState();
      this.refreshAll();
      return false;
    }
  }

  private async onAutoStartFilterChange(enabled: boolean): Promise<void> {
    if (!enabled) {
      this.autoStartFilterEnabled = false;
      this.savePersistState();
      return;
    }
    const granted: boolean = await this.canEnableAutoStartFilter();
    this.autoStartFilterEnabled = granted;
    this.savePersistState();
  }

  private async tryAutoStartFilterOnLaunch(): Promise<void> {
    if (this.autoStartAttempted || !this.autoStartFilterEnabled || this.busy || this.status.running) {
      return;
    }
    this.autoStartAttempted = true;
    await this.startVpn();
  }

  private async stopVpn(): Promise<void> {
    if (this.busy) {
      return;
    }

    this.busy = true;
    this.errorText = '';
    try {
      hilog.info(DOMAIN, TAG, '%{public}s', '==/vpn_ui/stop_request/');
      this.appendDebugLog('==/vpn_ui/stop_request/');
      await this.stopLongTaskKeepAlive(false);
      await vpnExtension.stopVpnExtensionAbility(this.buildVpnWant());
      hilog.info(DOMAIN, TAG, '%{public}s', '==/vpn_ui/stop_resolved/');
      this.appendDebugLog('==/vpn_ui/stop_resolved/');
      this.status = this.updatedStatus('stopping', this.t('stopping'));
    } catch (err) {
      const message = this.errorMessage(err);
      this.errorText = message;
      hilog.error(DOMAIN, TAG, '==/vpn_ui/stop_error/ %{public}s', message);
      this.appendDebugLog(`==/vpn_ui/stop_error/ ${message}`);
    } finally {
      this.busy = false;
      this.refreshAll();
    }
  }

  private async importRulesFile(): Promise<void> {
    try {
      const p: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.getHostContext());
      const uris: string[] = await p.select({
        maxSelectNumber: 20,
        fileSuffixFilters: ['.txt', '.conf', '.yaml', '.yml', '.json']
      });
      if (!uris || uris.length === 0) {
        this.keepAliveStatusText = this.t('noConfigSelected');
        return;
      }

      const importedProfiles: RuleProfile[] = [];
      for (let index = 0; index < uris.length; index += 1) {
        const currentUri: string = uris[index];
        const importedPath: string = `${this.getHostContext().filesDir}/${VPN_DIR_NAME}/imported_rules_${index}.txt`;
        try {
          try {
            await fileIo.copyFile(currentUri, importedPath);
          } catch (_) {
            const srcPath: string = decodeURIComponent(new uri.URI(currentUri).encodedPath);
            await fileIo.copyFile(srcPath, importedPath);
          }
          const importedText: string = this.readTextFile(importedPath);
          if (importedText.trim().length === 0) {
            continue;
          }
          importedProfiles.push(this.createRuleProfile(this.ruleProfileNameFromUri(currentUri, index + 1), importedText, true));
        } catch (_) {
        }
      }

      if (importedProfiles.length === 0) {
        this.errorText = this.t('importedEmpty');
        return;
      }

      this.ensureRuleProfilesInitialized();
        const importedOnlyProfiles: RuleProfile[] = this.ruleProfiles.filter((profile: RuleProfile) => !profile.builtIn);
        const builtInProfiles: RuleProfile[] = this.ruleProfiles.filter((profile: RuleProfile) => profile.builtIn);
        this.ruleProfiles = importedOnlyProfiles.concat(importedProfiles).concat(builtInProfiles);
        this.syncRuleCountBadges();
      this.rulesText = this.buildMergedRulesText();
      this.rulesDirty = true;
      this.currentTab = 1;
      this.savePersistState();
      this.errorText = '';
      this.setConfigFeedback(this.rulesImportedMessage(importedProfiles.length));
      this.appendDebugLog(`==/vpn_ui/import_rules/ count=${importedProfiles.length}`);
    } catch (err) {
      this.errorText = this.errorMessage(err);
      this.appendDebugLog(`==/vpn_ui/import_rules_error/ ${this.errorText}`);
    }
  }

  private saveRules(): void {
    if (this.busy) {
      return;
    }

    this.ensureRuleProfilesInitialized();
    const mergedRules: string = this.buildMergedRulesText();
    if (!this.writeTextFile(this.rulesFilePath, mergedRules)) {
      this.errorText = this.t('saveRulesFailed');
      return;
    }

    this.rulesText = mergedRules;
    this.rulesDirty = false;
    this.errorText = '';
    this.savePersistState();
    hilog.info(DOMAIN, TAG, '==/vpn_ui/rules_saved/ path=%{public}s bytes=%{public}d', this.rulesFilePath,
      this.rulesText.length);
    this.appendDebugLog(`==/vpn_ui/rules_saved/ path=${this.rulesFilePath} bytes=${this.rulesText.length}`);
    this.setConfigFeedback(this.t('ruleAddedNeedsRestart', this.t('rulesSavedSuccess')));
  }

  private resetRulesToDefault(): void {
    this.ruleProfiles = this.normalizeRuleProfiles([]);
    this.syncRuleCountBadges();
    this.rulesText = '';
    this.rulesDirty = true;
    this.errorText = '';
    this.savePersistState();
  }

  private syncKeepAliveEnabledFlag(): void {
    this.keepAliveEnabled = this.audioKeepAliveEnabled || this.locationKeepAliveEnabled;
  }

  private keepAliveModeList(): Array<string> {
    const list: Array<string> = [];
    if (this.audioKeepAliveEnabled) {
      list.push('audioPlayback');
    }
    if (this.locationKeepAliveEnabled) {
      list.push('location');
    }
    return list;
  }

  private keepAliveModeSummary(active: boolean): string {
    const modes: Array<string> = [];
    if (this.audioKeepAliveEnabled) {
      modes.push(this.t('audioMode'));
    }
    if (this.locationKeepAliveEnabled) {
      modes.push(this.t('locationMode'));
    }
    if (modes.length === 0) {
      return this.t('keepAliveOffStatus');
    }
    const label: string = modes.join(' + ');
    return active ? `${this.t('keepAliveActivePrefix')}: ${label}` : `${this.t('keepAliveArmedPrefix')}: ${label}`;
  }

  private activateAudioMixMode(): void {
    try {
      if (this.audioSessionManager === undefined) {
        const audioManager = audio.getAudioManager();
        this.audioSessionManager = audioManager.getSessionManager();
      }
      const sessionManager: audio.AudioSessionManager | undefined = this.audioSessionManager;
      if (sessionManager === undefined) {
        return;
      }
      const strategy: audio.AudioSessionStrategy = {
        concurrencyMode: audio.AudioConcurrencyMode.CONCURRENCY_MIX_WITH_OTHERS
      };
      sessionManager.activateAudioSession(strategy).catch(() => {
      });
    } catch (_) {
    }
  }

  private deactivateAudioSession(): void {
    try {
      const sessionManager: audio.AudioSessionManager | undefined = this.audioSessionManager;
      if (sessionManager !== undefined) {
        sessionManager.deactivateAudioSession();
      }
    } catch (_) {
    }
  }

  private async toggleAudioKeepAlive(enabled: boolean): Promise<void> {
    this.audioKeepAliveEnabled = enabled;
    this.syncKeepAliveEnabledFlag();
    this.savePersistState();
    await this.syncLongTaskKeepAlive();
  }

  private async startLocationPolling(): Promise<void> {
    if (this.locationListening) {
      return;
    }
    try {
      const request: geoLocationManager.LocationRequest = {
        priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
        scenario: geoLocationManager.LocationRequestScenario.UNSET,
        timeInterval: 30,
        distanceInterval: 0,
        maxAccuracy: 0
      };
      geoLocationManager.on('locationChange', request, (_location: geoLocationManager.Location) => {
        this.appendDebugLog('==/vpn_ui/location_tick/');
      });
      this.locationListening = true;
      this.appendDebugLog('==/vpn_ui/location_keepalive_started/');
    } catch (err) {
      this.appendDebugLog(`==/vpn_ui/location_keepalive_error/ ${this.errorMessage(err)}`);
    }
  }

  private stopLocationPolling(): void {
    if (!this.locationListening) {
      return;
    }
    try {
      geoLocationManager.off('locationChange');
    } catch (_) {
    }
    this.locationListening = false;
    this.appendDebugLog('==/vpn_ui/location_keepalive_stopped/');
  }

  private async getSelfAccessTokenId(): Promise<number> {
    if (this.accessTokenId > 0) {
      return this.accessTokenId;
    }
    const bundleInfo = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    this.accessTokenId = bundleInfo.appInfo.accessTokenId;
    return this.accessTokenId;
  }

  private async hasPermission(permission: Permissions): Promise<boolean> {
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const grant: abilityAccessCtrl.GrantStatus =
        await atManager.checkAccessToken(await this.getSelfAccessTokenId(), permission);
      return grant === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (_) {
      return false;
    }
  }

  private async requestLocationPermissionForKeepAlive(): Promise<boolean> {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    try {
      const foregroundPermission: Permissions = 'ohos.permission.APPROXIMATELY_LOCATION';
      if (!(await this.hasPermission(foregroundPermission))) {
        await atManager.requestPermissionsFromUser(this.getHostContext(), [foregroundPermission]);
      }

      if (!(await this.hasPermission(foregroundPermission))) {
        this.keepAliveStatusText = this.t('locationPermissionRequired');
        return false;
      }

      const backgroundPermission: Permissions = 'ohos.permission.LOCATION_IN_BACKGROUND';
      if (!(await this.hasPermission(backgroundPermission))) {
        await atManager.requestPermissionsFromUser(this.getHostContext(), [backgroundPermission]);
      }
      return true;
    } catch (_) {
      this.keepAliveStatusText = this.t('locationPermissionRequired');
      return false;
    }
  }

  private async onLocationKeepAliveChange(enabled: boolean): Promise<void> {
    if (!enabled) {
      this.locationKeepAliveEnabled = false;
      this.syncKeepAliveEnabledFlag();
      this.savePersistState();
      await this.syncLongTaskKeepAlive();
      return;
    }
    const granted: boolean = await this.requestLocationPermissionForKeepAlive();
    this.locationKeepAliveEnabled = granted;
    this.syncKeepAliveEnabledFlag();
    this.savePersistState();
    await this.syncLongTaskKeepAlive();
  }

  private async startLongTaskKeepAlive(): Promise<void> {
    if (this.continuousTaskId >= 0) {
      this.keepAliveRunning = true;
      this.keepAliveStatusText = this.keepAliveModeSummary(true);
      return;
    }

    const modeList: Array<string> = this.keepAliveModeList();
    if (modeList.length === 0) {
      this.keepAliveRunning = false;
      this.keepAliveStatusText = this.t('keepAliveOffStatus');
      return;
    }

    try {
      const wantAgentObj: WantAgent = await wantAgent.getWantAgent(this.buildKeepAliveWantAgentInfo());
      const taskInfo: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(this.getHostContext(), modeList, wantAgentObj);
      if (taskInfo.continuousTaskId === undefined) {
        this.keepAliveRunning = false;
        this.keepAliveStatusText = this.t('keepAliveStartFailed');
        return;
      }
      this.continuousTaskId = taskInfo.continuousTaskId;
      if (this.audioKeepAliveEnabled) {
        await this.startSilentAudioPlayback();
      }
      if (this.locationKeepAliveEnabled) {
        await this.startLocationPolling();
      }
      this.keepAliveRunning = true;
      this.keepAliveStatusText = this.keepAliveModeSummary(true);
      this.appendDebugLog(`==/vpn_ui/keepalive_started/ id=${this.continuousTaskId}`);
    } catch (err) {
      this.keepAliveRunning = false;
      this.keepAliveStatusText = `${this.t('keepAliveErrorPrefix')}: ${this.errorMessage(err)}`;
      this.appendDebugLog(`==/vpn_ui/keepalive_error/ ${this.keepAliveStatusText}`);
    }
  }

  private async stopLongTaskKeepAlive(notify: boolean): Promise<void> {
    await this.stopSilentAudioPlayback();
    this.stopLocationPolling();
    if (this.continuousTaskId < 0) {
      this.keepAliveRunning = false;
      if (notify) {
        this.keepAliveStatusText = this.t('keepAliveOffStatus');
      }
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.getHostContext());
    } catch (_) {
    }
    this.continuousTaskId = -1;
    this.keepAliveRunning = false;
    if (notify) {
      this.keepAliveStatusText = this.t('keepAliveOffStatus');
    }
    this.appendDebugLog('==/vpn_ui/keepalive_stopped/');
  }

  private async startSilentAudioPlayback(): Promise<void> {
    try {
      if (this.avPlayer !== undefined) {
        await this.stopSilentAudioPlayback();
      }
      this.activateAudioMixMode();
      const player: media.AVPlayer = await media.createAVPlayer();
      player.on('stateChange', (state: string) => {
        if (state === 'initialized') {
          player.audioRendererInfo = {
            usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
            rendererFlags: 0
          };
          player.prepare();
        } else if (state === 'prepared') {
          player.loop = true;
          player.setVolume(0);
          player.play();
        } else if (state === 'paused') {
          player.play();
        } else if (state === 'error') {
          this.appendDebugLog('==/vpn_ui/audio_restart/');
          void this.restartSilentAudio();
        }
      });
      const context = this.getHostContext();
      const rawFd = context.resourceManager.getRawFdSync('silence.wav');
      player.fdSrc = { fd: rawFd.fd, offset: rawFd.offset, length: rawFd.length };
      this.avPlayer = player;
    } catch (err) {
      this.keepAliveStatusText = `Silent audio failed: ${this.errorMessage(err)}`;
    }
  }

  private async restartSilentAudio(): Promise<void> {
    await this.stopSilentAudioPlayback();
    if (this.keepAliveRunning && this.audioKeepAliveEnabled) {
      await this.startSilentAudioPlayback();
    }
  }

  private async stopSilentAudioPlayback(): Promise<void> {
    if (this.avPlayer === undefined) {
      this.deactivateAudioSession();
      return;
    }
    try {
      this.avPlayer.off('stateChange');
      await this.avPlayer.release();
    } catch (_) {
    }
    this.avPlayer = undefined;
    this.deactivateAudioSession();
  }

  private async syncLongTaskKeepAlive(): Promise<void> {
    this.syncKeepAliveEnabledFlag();
    this.savePersistState();
    const modeList: Array<string> = this.keepAliveModeList();
    if (modeList.length === 0) {
      await this.stopLongTaskKeepAlive(false);
      this.keepAliveStatusText = this.t('keepAliveOffStatus');
      return;
    }
    if (!this.status.running) {
      await this.stopLongTaskKeepAlive(false);
      this.keepAliveStatusText = this.keepAliveModeSummary(false);
      return;
    }
    await this.stopLongTaskKeepAlive(false);
    await this.startLongTaskKeepAlive();
  }

  private openLicensePage(): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/OpenSourceLicense'
    }).catch((err: BusinessError) => {
      this.errorText = this.errorMessage(err);
    });
  }

  private updatedStatus(phase: string, note: string): StatusSnapshot {
    return {
      phase: phase,
      running: this.status.running,
      note: note,
      updatedAt: this.status.updatedAt,
      tunFd: this.status.tunFd,
      nativeStats: this.status.nativeStats,
    };
  }

  private buildInactiveStatus(): StatusSnapshot {
    return {
      phase: 'idle',
      running: false,
      note: this.t('dnsFilterNotStarted'),
      updatedAt: '',
      tunFd: -1,
      nativeStats: defaultStats(),
    };
  }

  private normalizeStatusSnapshot(snapshot: StatusSnapshot): StatusSnapshot {
    const localizedNote = snapshot.note === 'DNS filter has not been started yet.'
      ? this.t('dnsFilterNotStarted')
      : snapshot.note;
    const normalizedTunFd = snapshot.tunFd >= 0
      ? snapshot.tunFd
      : snapshot.nativeStats.tunFd;
    const nativeRunning = snapshot.nativeStats.running || normalizedTunFd >= 0;

    if (snapshot.phase === 'running' && !nativeRunning) {
      return this.buildInactiveStatus();
    }

    return {
      phase: snapshot.phase,
      running: snapshot.phase === 'running' ? nativeRunning : snapshot.running,
      note: localizedNote,
      updatedAt: snapshot.updatedAt,
      tunFd: normalizedTunFd,
      nativeStats: snapshot.nativeStats,
    };
  }

  private isStaleRunningSnapshot(snapshot: StatusSnapshot): boolean {
    if (!snapshot.running) {
      return false;
    }
    const updatedAtMs = Date.parse(snapshot.updatedAt);
    if (!Number.isFinite(updatedAtMs)) {
      return true;
    }
    return Date.now() - updatedAtMs > STATUS_STALE_TIMEOUT_MS;
  }

  private displayAllowed(): number {
    if (this.status.nativeStats.allowedQueries > 0) {
      return this.status.nativeStats.allowedQueries;
    }
    return this.querySummary.allowed;
  }

  private displayBlocked(): number {
    if (this.status.nativeStats.blockedQueries > 0) {
      return this.status.nativeStats.blockedQueries;
    }
    return this.querySummary.blocked;
  }

  private displayLastDomain(): string {
    if (this.status.nativeStats.lastQueryDomain.length > 0) {
      return this.status.nativeStats.lastQueryDomain;
    }
    return this.querySummary.lastDomain;
  }

  private displayLastRule(): string {
    if (this.status.nativeStats.lastMatchedRule.length > 0) {
      return this.status.nativeStats.lastMatchedRule;
    }
    return this.querySummary.lastRule;
  }

  private displayPhaseText(): string {
    const phase: string = this.status.phase;
    if (phase === 'idle') {
      return this.t('idle');
    }
    if (phase === 'running') {
      return this.t('running');
    }
    if (phase === 'stopping') {
      return this.t('stopping');
    }
    if (phase === 'starting') {
      return this.t('working');
    }
    return phase;
  }

  private primaryTextColor(): string {
    return this.isDarkModeActive() ? '#F3F4F6' : '#162235';
  }

  private secondaryTextColor(): string {
    return this.isDarkModeActive() ? '#A7B0BD' : '#5B6675';
  }

  private mutedTextColor(): string {
    return this.isDarkModeActive() ? '#7E8795' : '#8B94A2';
  }

  private canvasTone(): string {
    return this.isDarkModeActive() ? '#0F1724' : '#F2F8FF';
  }

  private cardSurfaceTone(): string {
    return this.isDarkModeActive() ? '#1A2435D8' : '#F4FAFFFA';
  }

  private cardBorderTone(): string {
    return this.isDarkModeActive() ? '#26FFFFFF' : '#C7E8F7FF';
  }

  private cardShadowTone(): string {
    return this.isDarkModeActive() ? '#44040B14' : '#140E2238';
  }

  private chipSurfaceTone(): string {
      return this.isDarkModeActive() ? '#243248B8' : '#F7FBFFFA';
  }

  private floatingBarTone(): string {
      return this.isDarkModeActive() ? '#182235E0' : '#F4F9FFFA';
  }

  private elevatedSurfaceTone(): string {
      return this.isDarkModeActive() ? '#1C283BDB' : '#F5FAFFFA';
  }

  private softPanelTone(): string {
      return this.isDarkModeActive() ? '#223147BA' : '#EEF7FFEE';
  }

  private selectedChipSurfaceTone(): string {
        return this.isDarkModeActive() ? '#3A67B6E6' : '#E1F0FFFA';
  }

  private selectedChipTextTone(): string {
      return this.isDarkModeActive() ? '#F7FBFF' : '#255DFF';
  }

  private coolChipSurfaceTone(): string {
        return this.isDarkModeActive() ? '#325EA8DE' : '#E8F3FFFA';
  }

  private coolNeutralChipSurfaceTone(): string {
        return this.isDarkModeActive() ? '#202B3ABF' : '#F3F9FFFA';
    }

    private warmChipSurfaceTone(): string {
      return this.isDarkModeActive() ? '#4C2A2ABF' : '#FDECEC';
    }

    private selectedOutlineTone(): string {
      return this.isDarkModeActive() ? '#9CC2FF' : '#5B8EFF';
    }

    private selectedShadowTone(): string {
      return this.isDarkModeActive() ? '#4D78D8A8' : '#1497C8E8';
  }

  private accentBlueTone(): string {
    return this.isDarkModeActive() ? '#8CB3FF' : '#255DFF';
  }

  private accentGreenTone(): string {
    return this.isDarkModeActive() ? '#52D19E' : '#179160';
  }

  private accentAmberTone(): string {
    return this.isDarkModeActive() ? '#B6C4D8' : '#5E7088';
  }

  private sectionGlyph(section: string): string {
    switch (section) {
      case 'dnsPackets':
        return '◎';
      case 'allowed':
        return '↗';
      case 'blocked':
        return '✕';
      case 'tunFd':
        return '◌';
      case 'requests':
        return '≋';
      case 'debug':
        return '⋯';
      case 'rules':
        return '⚙';
      case 'keepAlive':
        return '◈';
      case 'language':
        return '文';
      case 'theme':
        return '☼';
      case 'version':
        return '⌘';
      case 'license':
        return '☰';
      default:
        return '•';
    }
  }

  private softBlueTone(): string {
      return this.isDarkModeActive() ? '#233247B5' : '#E8F3FFF0';
  }

  private softGreenTone(): string {
      return this.isDarkModeActive() ? '#233247B5' : '#E9F8F1F0';
  }

  private softAmberTone(): string {
      return this.isDarkModeActive() ? '#233247B5' : '#EDF4FFF0';
  }

  private softRedTone(): string {
      return this.isDarkModeActive() ? '#2D3142C7' : '#FBEFF5F0';
  }

  private queryActionBadgeTextTone(action: string): string {
    if (action === 'blocked') {
      return this.isDarkModeActive() ? '#FFF8FA' : '#1F1315';
    }
    return this.isDarkModeActive() ? '#F8FFFC' : '#162016';
  }

  private queryActionBadgeSurfaceTone(action: string): string {
    if (action === 'blocked') {
      return this.isDarkModeActive() ? '#FF7D96' : '#FFD6D6';
    }
    return this.isDarkModeActive() ? '#49D89B' : '#C8F3D3';
  }

  private queryActionBadgeBorderTone(action: string): string {
    if (action === 'blocked') {
      return this.isDarkModeActive() ? '#FFD7E540' : '#F4B7C1';
    }
    return this.isDarkModeActive() ? '#D6FFE966' : '#A7E2BD';
  }

  private queryActionBadgeShadowTone(action: string): string {
    if (action === 'blocked') {
      return this.isDarkModeActive() ? '#C63F8A3D' : '#F0A8B766';
    }
    return this.isDarkModeActive() ? '#21B97852' : '#8ED8AE66';
  }

  private formatQueryTimestamp(ts: number): string {
    let value: number = ts;
    if (!Number.isFinite(value)) {
      return `${ts}`;
    }
    if (Math.abs(value) < 1000000000000) {
      value = value * 1000;
    }
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return `${ts}`;
    }
    const year = `${date.getFullYear()}`;
    const month = `${date.getMonth() + 1}`.padStart(2, '0');
    const day = `${date.getDate()}`.padStart(2, '0');
    const hours = `${date.getHours()}`.padStart(2, '0');
    const minutes = `${date.getMinutes()}`.padStart(2, '0');
    const seconds = `${date.getSeconds()}`.padStart(2, '0');
    return `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
  }

  private sheetSurfaceTone(): string {
    return this.isDarkModeActive() ? '#172437F2' : '#ECF7FFFE';
  }

  private sheetSecondarySurfaceTone(): string {
    return this.isDarkModeActive() ? '#23364FBE' : '#F7FBFFF2';
  }

  private sheetInputSurfaceTone(): string {
    return this.isDarkModeActive() ? '#24354BBA' : '#F1F8FFFA';
  }

  private sheetBorderTone(): string {
    return this.isDarkModeActive() ? '#30F2FAFF' : '#B7E6F7FF';
  }

  private sheetShadowTone(): string {
    return this.isDarkModeActive() ? '#42030B16' : '#180C2340';
  }

  private sheetGlowTone(): string {
    return this.isDarkModeActive() ? '#224C8BCB' : '#249FD4FF';
  }

  private getBottomTabOverlayHeight(): number {
    const tabHeight: number = 50;
    const floatingBottomMargin: number = 24;
    return tabHeight + floatingBottomMargin;
  }

  private contentBottomInset(): number {
    return Math.max(0, this.avoidPaddingBottom) + this.getBottomTabOverlayHeight();
  }

  @Builder
  private IconBubble(glyph: string, backgroundColor: string, foregroundColor: string, size: number = 24, fontSize: number = 12) {
    Stack() {
      Stack() {
        Text(glyph)
          .fontSize(fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(foregroundColor)
      }
      .width(size - 8)
      .height(size - 8)
      .borderRadius((size - 8) / 2)
      .backgroundColor(this.isDarkModeActive() ? backgroundColor : '#F8FCFF')
      .border({ width: 1, color: this.isDarkModeActive() ? '#28FFFFFF' : '#E1ECF8FF' })
      .shadow({
        radius: this.isDarkModeActive() ? 6 : 8,
        color: this.isDarkModeActive() ? '#22030B16' : '#100E2238',
        offsetX: 0,
        offsetY: 2
      })
    }
    .width(size)
    .height(size)
    .borderRadius(size / 2)
    .backgroundColor(this.isDarkModeActive() ? '#162236D6' : backgroundColor)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .border({ width: 1, color: this.isDarkModeActive() ? '#36FFFFFF' : '#CFE2F2FF' })
    .shadow({
      radius: this.isDarkModeActive() ? 10 : 12,
      color: this.isDarkModeActive() ? '#28030B16' : '#140E2238',
      offsetX: 0,
      offsetY: 4
    })
    .linearGradient({
      angle: 135,
      colors: this.isDarkModeActive()
        ? [['#1B2A3ED4', 0.0], ['#20314AD8', 1.0]]
        : [[backgroundColor, 0.0], ['#FFFFFFF2', 1.0]]
    })
  }

  @Builder
  private RuleCountBadge(label: string, count: number, backgroundColor: string, textColor: string) {
    Row({ space: 6 }) {
      Text(label)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(textColor)
      Text(`${count}`)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(textColor)
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor(backgroundColor)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .border({ width: 1, color: this.cardBorderTone() })
    .borderRadius(12)
    .margin({ right: 8, bottom: 8 })
  }

  private visibleQueryEvents(): QueryLogEntry[] {
    if (this.queryEvents.length <= 8) {
      return this.queryEvents;
    }
    return this.queryEvents.slice(0, 8);
  }

  private visibleDebugLines(): string[] {
    if (this.debugLines.length <= 10) {
      return this.debugLines;
    }
    return this.debugLines.slice(0, 10);
  }

  @Builder
  private SectionActionButton(label: string, foregroundColor: string, backgroundColor: string, onTap: () => void) {
    Button(label)
      .height(36)
      .padding({ left: 14, right: 14 })
      .backgroundColor(backgroundColor)
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .fontColor(foregroundColor)
      .fontSize(12)
      .borderRadius(14)
      .border({ width: 1, color: this.sheetBorderTone() })
      .shadow({ radius: 10, color: this.isDarkModeActive() ? '#12000000' : '#1497C8E8' })
      .onClick(() => {
        onTap();
      })
  }

  @Builder
  private DnsRequestsSheet() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.t('recentDnsRequests'))
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          Text(this.dnsSheetCountText())
            .fontSize(12)
            .fontColor(this.mutedTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.SectionActionButton(this.t('copy'), this.selectedChipTextTone(), this.coolChipSurfaceTone(), () => {
          this.copyDnsRequests().catch((err: BusinessError) => {
            this.errorText = this.errorMessage(err);
          });
        })
        this.SectionActionButton(this.t('export'), this.selectedChipTextTone(), this.coolChipSurfaceTone(), () => {
          this.exportDnsRequests().catch((err: BusinessError) => {
            this.errorText = this.errorMessage(err);
          });
        })
        this.SectionActionButton(this.t('clearLogs'), '#B42318', this.warmChipSurfaceTone(), () => {
          this.confirmClearDnsRequests();
        })
      }
      .width('100%')

      if (this.dnsSheetFeedbackText.length > 0) {
        Text(this.dnsSheetFeedbackText)
          .fontSize(12)
          .fontColor(this.accentBlueTone())
          .fontWeight(FontWeight.Medium)
          .width('100%')
      }

      Text(this.t('tapDomainToCreateRule'))
        .fontSize(12)
        .fontColor(this.mutedTextColor())
        .width('100%')

      TextInput({ placeholder: this.t('dnsSearchPlaceholder'), text: this.dnsSearchText })
        .width('100%')
        .height(44)
        .fontSize(14)
        .backgroundColor(this.sheetInputSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .border({ width: 1, color: this.sheetBorderTone() })
        .borderRadius(16)
        .padding({ left: 14, right: 14 })
        .onChange((value: string) => {
          this.dnsSearchText = value;
        })

      Row({ space: 8 }) {
        ForEach(['all', 'allowed', 'blocked'] as QueryActionFilter[], (filter: QueryActionFilter) => {
          Row() {
            Text(this.dnsFilterLabel(filter))
              .fontSize(12)
              .fontWeight(this.dnsActionFilter === filter ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.dnsActionFilter === filter ? this.accentBlueTone() : this.secondaryTextColor())
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .height(40)
          .padding({ left: 16, right: 16 })
          .backgroundColor(this.dnsActionFilter === filter ? this.selectedChipSurfaceTone() : this.sheetInputSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .borderRadius(20)
          .border({ width: this.dnsActionFilter === filter ? 1.5 : 1, color: this.dnsActionFilter === filter ? this.selectedOutlineTone() : this.sheetBorderTone() })
          .shadow(this.dnsActionFilter === filter ? { radius: 16, color: this.selectedShadowTone(), offsetX: 0, offsetY: 4 } : { radius: 6, color: '#0A97C8E8', offsetX: 0, offsetY: 2 })
          .onClick(() => {
            this.dnsActionFilter = filter;
          })
        }, (filter: QueryActionFilter) => filter)
      }
      .width('100%')

      if (this.filteredQueryEvents().length === 0) {
        Column() {
          Text(this.t('noDnsLogs'))
            .fontSize(13)
            .fontColor(this.secondaryTextColor())
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ scroller: this.dnsListScroller }) {
          ForEach(this.filteredQueryEvents(), (item: QueryLogEntry) => {
            ListItem() {
              Column({ space: 6 }) {
                Row() {
                  Text(`${item.domain}  ${item.qtype}`)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.primaryTextColor())
                    .layoutWeight(1)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.action === 'blocked' ? this.t('blockedTag') : this.t('allowedTag'))
                    .fontSize(10)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.queryActionBadgeTextTone(item.action))
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .backgroundColor(this.queryActionBadgeSurfaceTone(item.action))
                    .border({ width: 1, color: this.queryActionBadgeBorderTone(item.action) })
                    .borderRadius(10)
                    .shadow({ radius: 10, color: this.queryActionBadgeShadowTone(item.action), offsetX: 0, offsetY: 3 })
                }
                .width('100%')

                Text(`${this.t('rulePrefix')}: ${item.rule || this.t('none')}`)
                  .fontSize(12)
                  .fontColor(this.secondaryTextColor())
                  .width('100%')
                Text(`${this.t('dnsTraffic')}: ${this.formatBytes(item.totalDnsBytes ?? ((item.requestBytes ?? 0) + (item.responseBytes ?? 0)))} (${this.t('requestBytes')} ${this.formatBytes(item.requestBytes ?? 0)} / ${this.t('responseBytes')} ${this.formatBytes(item.responseBytes ?? 0)})`)
                  .fontSize(12)
                  .fontColor(this.secondaryTextColor())
                  .width('100%')
                Text(`${this.t('timePrefix')}: ${this.formatQueryTimestamp(item.ts)}`)
                  .fontSize(12)
                  .fontColor(this.mutedTextColor())
                  .width('100%')
              }
              .width('100%')
              .padding(14)
              .backgroundColor(this.sheetSecondarySurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
              .borderRadius(18)
              .border({ width: 1, color: this.sheetBorderTone() })
              .shadow({ radius: 10, color: this.sheetShadowTone(), offsetX: 0, offsetY: 4 })
            }
            .onClick(() => {
              this.confirmAddRuleForDomain(item.domain);
            })
          }, (item: QueryLogEntry) => `${item.ts}_${item.domain}_${item.qtype}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .cachedCount(8)
        .divider({ strokeWidth: 10, color: Color.Transparent })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: Math.max(12, this.avoidPaddingBottom + 6) })
    .linearGradient({
      angle: 145,
      colors: this.isDarkModeActive()
        ? [['#142030', 0.0], ['#18273B', 0.45], ['#1A2E46', 1.0]]
        : [['#EAF7FF', 0.0], ['#DFF1FF', 0.45], ['#EDF8FF', 1.0]]
    })
    .backgroundColor(this.sheetSurfaceTone())
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
    .border({ width: 1, color: this.sheetBorderTone() })
    .shadow({ radius: 18, color: this.sheetShadowTone(), offsetX: 0, offsetY: -4 })
  }

  @Builder
  private DomainLeaderboardSheet() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.t('domainLeaderboard'))
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          Text(this.domainSheetCountText())
            .fontSize(12)
            .fontColor(this.mutedTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.domainSortButtonText())
          .height(36)
          .padding({ left: 14, right: 14 })
          .backgroundColor(this.coolNeutralChipSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .fontColor(this.primaryTextColor())
          .fontSize(12)
          .borderRadius(14)
          .border({ width: 1, color: this.sheetBorderTone() })
          .shadow({ radius: 10, color: this.isDarkModeActive() ? '#12000000' : '#1497C8E8' })
          .onClick(() => {
            this.domainSortDescending = !this.domainSortDescending;
          })
        this.SectionActionButton(this.t('copy'), this.selectedChipTextTone(), this.coolChipSurfaceTone(), () => {
          this.copyDomainStats().catch((err: BusinessError) => {
            this.errorText = this.errorMessage(err);
          });
        })
        this.SectionActionButton(this.t('export'), this.selectedChipTextTone(), this.coolChipSurfaceTone(), () => {
          this.exportDomainStats().catch((err: BusinessError) => {
            this.errorText = this.errorMessage(err);
          });
        })
        this.SectionActionButton(this.t('clearLogs'), '#B42318', this.warmChipSurfaceTone(), () => {
          this.confirmClearDomainStats();
        })
      }
      .width('100%')

      if (this.domainSheetFeedbackText.length > 0) {
        Text(this.domainSheetFeedbackText)
          .fontSize(12)
          .fontColor(this.accentBlueTone())
          .fontWeight(FontWeight.Medium)
          .width('100%')
      }

      Text(this.t('tapDomainToCreateRule'))
        .fontSize(12)
        .fontColor(this.mutedTextColor())
        .width('100%')

      Row({ space: 10 }) {
        ForEach(['all', 'allowed', 'blocked'] as QueryActionFilter[], (filter: QueryActionFilter) => {
          Row() {
            Text(this.domainFilterLabel(filter))
              .fontSize(12)
              .fontWeight(this.domainActionFilter === filter ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.domainActionFilter === filter ? this.accentBlueTone() : this.secondaryTextColor())
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .height(40)
          .padding({ left: 16, right: 16 })
          .backgroundColor(this.domainActionFilter === filter ? this.selectedChipSurfaceTone() : this.sheetInputSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .borderRadius(20)
          .border({ width: this.domainActionFilter === filter ? 1.5 : 1, color: this.domainActionFilter === filter ? this.selectedOutlineTone() : this.sheetBorderTone() })
          .shadow(this.domainActionFilter === filter ? { radius: 16, color: this.selectedShadowTone(), offsetX: 0, offsetY: 4 } : { radius: 6, color: '#0A97C8E8', offsetX: 0, offsetY: 2 })
          .onClick(() => {
            this.domainActionFilter = filter;
          })
        }, (filter: QueryActionFilter) => filter)
      }
      .width('100%')

      if (this.orderedDomainStats().length === 0) {
        Column() {
          Text(this.t('noDnsLogs'))
            .fontSize(13)
            .fontColor(this.secondaryTextColor())
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ scroller: this.domainListScroller }) {
          ForEach(this.orderedDomainStats(), (item: DomainQueryStats, index: number) => {
            ListItem() {
              Column({ space: 6 }) {
                Row({ space: 10 }) {
                  Text(`${index + 1}. ${item.domain}`)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.primaryTextColor())
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.lastAction === 'blocked' ? this.t('blockedTag') : this.t('allowedTag'))
                    .fontSize(10)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.queryActionBadgeTextTone(item.lastAction))
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .backgroundColor(this.queryActionBadgeSurfaceTone(item.lastAction))
                    .border({ width: 1, color: this.queryActionBadgeBorderTone(item.lastAction) })
                    .borderRadius(10)
                    .shadow({ radius: 10, color: this.queryActionBadgeShadowTone(item.lastAction), offsetX: 0, offsetY: 3 })
                }
                .width('100%')

                Text(`${this.t('queryCount')}: ${item.total}`)
                  .fontSize(12)
                  .fontColor(this.secondaryTextColor())
                  .width('100%')
                if (item.lastAction === 'blocked') {
                  Text(`${this.t('rulePrefix')}: ${item.lastRule || this.t('none')}`)
                    .fontSize(12)
                    .fontColor(this.secondaryTextColor())
                    .width('100%')
                }
              }
              .width('100%')
              .padding(14)
              .backgroundColor(this.sheetSecondarySurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
              .borderRadius(18)
              .border({ width: 1, color: this.sheetBorderTone() })
              .shadow({ radius: 10, color: this.sheetShadowTone(), offsetX: 0, offsetY: 4 })
            }
            .onClick(() => {
              this.confirmAddRuleForDomain(item.domain);
            })
          }, (item: DomainQueryStats) => `${item.domain}_${item.total}_${item.totalDnsBytes}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .cachedCount(8)
        .divider({ strokeWidth: 10, color: Color.Transparent })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: Math.max(12, this.avoidPaddingBottom + 6) })
    .linearGradient({
      angle: 145,
      colors: this.isDarkModeActive()
        ? [['#142030', 0.0], ['#18273B', 0.45], ['#1A2E46', 1.0]]
        : [['#EAF7FF', 0.0], ['#DFF1FF', 0.45], ['#EDF8FF', 1.0]]
    })
    .backgroundColor(this.sheetSurfaceTone())
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
    .border({ width: 1, color: this.sheetBorderTone() })
    .shadow({ radius: 18, color: this.sheetShadowTone(), offsetX: 0, offsetY: -4 })
  }

  @Builder
  private DebugLogSheet() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.t('debugLog'))
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          Text(`${this.debugLines.length} ${this.t('lines')}`)
            .fontSize(12)
            .fontColor(this.mutedTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.SectionActionButton(this.t('copyLog'), this.selectedChipTextTone(), this.coolChipSurfaceTone(), () => {
          this.copyDebugLogs().catch((err: BusinessError) => {
            this.errorText = this.errorMessage(err);
          });
        })
        this.SectionActionButton(this.t('exportLog'), this.selectedChipTextTone(), this.coolChipSurfaceTone(), () => {
          this.exportDebugLogs().catch((err: BusinessError) => {
            this.errorText = this.errorMessage(err);
            this.promptAction?.showToast({ message: this.t('exportDebugLogsFailed') });
          });
        })
      }
      .width('100%')

      if (this.debugSheetFeedbackText.length > 0) {
        Text(this.debugSheetFeedbackText)
          .fontSize(12)
          .fontColor(this.accentBlueTone())
          .fontWeight(FontWeight.Medium)
          .width('100%')
      }

      Scroll() {
        Column({ space: 10 }) {
          if (this.debugLines.length === 0) {
            Text(this.t('noDebugLogs'))
              .fontSize(13)
              .fontColor(this.secondaryTextColor())
              .width('100%')
          }
          ForEach(this.debugLines, (item: string, index: number) => {
            Text(item)
              .fontSize(12)
              .fontColor(this.secondaryTextColor())
              .width('100%')
              .padding(12)
              .backgroundColor(this.sheetSecondarySurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
              .borderRadius(14)
              .border({ width: 1, color: this.sheetBorderTone() })
              .shadow({ radius: 8, color: this.sheetShadowTone(), offsetX: 0, offsetY: 3 })
          }, (_item: string, index: number) => `${index}`)
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: Math.max(18, this.avoidPaddingBottom + 12) })
    .linearGradient({
      angle: 145,
      colors: this.isDarkModeActive()
        ? [['#142030', 0.0], ['#18273B', 0.45], ['#1A2E46', 1.0]]
        : [['#EAF7FF', 0.0], ['#DFF1FF', 0.45], ['#EDF8FF', 1.0]]
    })
    .backgroundColor(this.sheetSurfaceTone())
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
    .border({ width: 1, color: this.sheetBorderTone() })
    .shadow({ radius: 18, color: this.sheetShadowTone(), offsetX: 0, offsetY: -4 })
  }

  @Builder
  private CurrentTabPage() {
    Column() {
      if (this.currentTab === 0) {
        this.HomeTab();
      } else if (this.currentTab === 1) {
        this.ConfigTab();
      } else {
        this.MeTab();
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .backgroundColor('#00000000')
  }

  @Builder
  private BottomNavItem(index: number, activeIcon: Resource, inactiveIcon: Resource, label: string) {
    Column({ space: 4 }) {
      SymbolGlyph(this.currentTab === index ? activeIcon : inactiveIcon)
        .fontSize(16)
        .fontColor([this.currentTab === index ? this.selectedChipTextTone() : this.secondaryTextColor()])
      Text(label)
        .fontSize(10)
        .fontWeight(this.currentTab === index ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.currentTab === index ? this.selectedChipTextTone() : this.secondaryTextColor())
    }
    .layoutWeight(1)
    .padding({ top: 6, bottom: 6, left: 8, right: 8 })
    .borderRadius(14)
    .backgroundColor(this.currentTab === index ? this.selectedChipSurfaceTone() : '#00000000')
    .onClick(() => {
      if (this.currentTab === index) {
        return;
      }
      this.currentTab = index;
      this.savePersistState();
    })
  }

  @Builder
  private ClassicTabHost() {
    Row({ space: 4 }) {
      this.BottomNavItem(0, $r('sys.symbol.house_fill'), $r('sys.symbol.house'), this.t('tabHome'));
      this.BottomNavItem(1, $r('sys.symbol.gearshape_fill'), $r('sys.symbol.gearshape'), this.t('tabConfig'));
      this.BottomNavItem(2, $r('sys.symbol.person_fill'), $r('sys.symbol.person'), this.t('tabMe'));
    }
    .width('82%')
    .padding({ left: 4, right: 4, top: 5, bottom: 5 })
    .margin({ bottom: 24 })
    .backgroundColor(this.floatingBarTone())
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
    .borderRadius(20)
    .border({ width: 1, color: this.cardBorderTone() })
    .shadow({ radius: 8, color: this.cardShadowTone() })
  }

  @Builder
  private HomeTab() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 14 }) {
          Row({ space: 12 }) {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                this.IconBubble('◈', this.softPanelTone(), this.accentBlueTone(), 24, 11)
                Text(this.t('localVpn'))
                  .fontSize(11)
                  .fontColor(this.selectedChipTextTone())
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .backgroundColor(this.coolChipSurfaceTone())
                  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                  .border({ width: 1, color: this.cardBorderTone() })
                  .borderRadius(12)
                Text(this.t('dnsFilter'))
                  .fontSize(11)
                  .fontColor(this.secondaryTextColor())
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .backgroundColor(this.coolNeutralChipSurfaceTone())
                  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                  .border({ width: 1, color: this.cardBorderTone() })
                  .borderRadius(12)
                Text(this.t('ipv6Ready'))
                  .fontSize(11)
                  .fontColor(this.selectedChipTextTone())
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .backgroundColor(this.coolChipSurfaceTone())
                  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                  .border({ width: 1, color: this.cardBorderTone() })
                  .borderRadius(12)
              }
              .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Column({ space: 10 }) {
              Text(this.status.running ? this.t('active') : this.t('idle'))
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.status.running ? this.accentGreenTone() : this.accentAmberTone())
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(this.coolNeutralChipSurfaceTone())
                .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                .border({ width: 1, color: this.cardBorderTone() })
                .borderRadius(12)
            }
            .alignItems(HorizontalAlign.End)
          }
          .width('100%')

          Row({ space: 10 }) {
            Column({ space: 4 }) {
              Text(this.t('trafficClass'))
                .fontSize(12)
                .fontColor(this.secondaryTextColor())
              Text(this.t('dnsOnlyVpn'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.primaryTextColor())
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Column({ space: 4 }) {
              Text(this.t('nativeBridge'))
                .fontSize(12)
                .fontColor(this.secondaryTextColor())
              Text(this.status.running ? this.t('bridgeReady') : this.t('bridgeStandby'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.status.running ? '#179160' : this.primaryTextColor())
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.softPanelTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .borderRadius(20)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 10, color: this.cardShadowTone() })

          Row({ space: 10 }) {
            Button(this.busy ? this.t('working') : (this.status.running ? this.t('restartFilter') : this.t('startFilter')))
              .enabled(!this.busy)
              .height(42)
              .layoutWeight(1)
              .backgroundColor(this.coolChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .fontColor(this.selectedChipTextTone())
              .borderRadius(16)
              .border({ width: 1, color: this.cardBorderTone() })
              .shadow({ radius: 8, color: this.softBlueTone() })
              .onClick(() => {
                this.startVpn().catch((err: BusinessError) => {
                  this.errorText = this.errorMessage(err);
                });
              })
            Button(this.busy ? this.t('working') : this.t('stopFilter'))
              .enabled(!this.busy)
              .height(42)
              .layoutWeight(1)
              .backgroundColor(this.coolNeutralChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .fontColor(this.primaryTextColor())
              .borderRadius(16)
              .border({ width: 1, color: this.cardBorderTone() })
              .shadow({ radius: 8, color: this.cardShadowTone() })
              .onClick(() => {
                this.stopVpn().catch((err: BusinessError) => {
                  this.errorText = this.errorMessage(err);
                });
              })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(20)
        .backgroundColor(this.cardSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(30)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 20, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1A2435D8', 0.0], ['#1D2A3EDC', 0.5], ['#22334AD8', 1.0]]
            : [['#F8FCFF', 0.0], ['#EFF7FF', 0.52], ['#EAF4FF', 1.0]]
        })

        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text(this.t('filterStatus'))
              .fontSize(12)
              .fontColor(this.secondaryTextColor())
              .width('100%')
            Text(this.status.running ? this.t('running') : this.t('stopped'))
              .fontSize(20)
              .minFontSize(14)
              .maxLines(2)
              .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.status.running ? '#179160' : '#5E7088')
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Center)
          .layoutWeight(1)
          .height(96)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#202B3EDB', 0.0], ['#223149DB', 1.0]]
              : [['#F9FCFF', 0.0], ['#EEF7FF', 1.0]]
          })

          Column({ space: 4 }) {
            Text(this.t('tunFd'))
              .fontSize(12)
              .fontColor(this.secondaryTextColor())
              .width('100%')
            Text(`${this.status.tunFd}`)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Center)
          .layoutWeight(1)
          .height(96)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#202B3EDB', 0.0], ['#223149DB', 1.0]]
              : [['#F9FCFF', 0.0], ['#EEF7FF', 1.0]]
          })
        }
        .width('100%')

        Column({ space: 12 }) {
          Row() {
            Text(this.t('recentDnsRequests'))
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
            Blank()
            Text(this.t('clickToExpand'))
              .fontSize(12)
              .fontColor(this.mutedTextColor())
          }
          .width('100%')

          Column({ space: 8 }) {
            Text(`${this.querySummary.total} ${this.t('lines')}`)
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .width('100%')
            Text(`${this.t('allowed')}: ${this.displayAllowed()}   ${this.t('blocked')}: ${this.displayBlocked()}`)
              .fontSize(13)
              .fontColor(this.secondaryTextColor())
              .width('100%')
            Text(`${this.t('matchedRule')}: ${this.displayLastRule() || this.t('none')}`)
              .fontSize(13)
              .fontColor(this.mutedTextColor())
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              Text(`${this.t('dnsTraffic')}: ${this.formatBytes(this.querySummary.totalDnsBytes)} (${this.t('requestBytes')} ${this.formatBytes(this.querySummary.requestBytes)} / ${this.t('responseBytes')} ${this.formatBytes(this.querySummary.responseBytes)})`)
                .fontSize(13)
                .fontColor(this.mutedTextColor())
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .backgroundColor(this.sheetSecondarySurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })
          .shadow({ radius: 10, color: this.sheetShadowTone() })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(24)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
            : [['#F8FCFF', 0.0], ['#EBF5FF', 1.0]]
        })
        .onClick(() => {
          this.dnsSheetFeedbackText = '';
          this.showDnsSheet = true;
        })
        .bindSheet(this.showDnsSheet, this.DnsRequestsSheet(), {
          height: '92%',
          backgroundColor: this.sheetSurfaceTone(),
          showClose: false,
          onDisappear: () => {
            this.showDnsSheet = false;
          }
        })

        Column({ space: 12 }) {
          Row() {
            Text(this.t('domainLeaderboard'))
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
            Blank()
            Text(this.t('clickToExpand'))
              .fontSize(12)
              .fontColor(this.mutedTextColor())
          }
          .width('100%')

          Column({ space: 10 }) {
            if (this.domainPreviewStats().length === 0) {
              Text(this.t('noDnsLogsHint'))
                .fontSize(13)
                .fontColor(this.secondaryTextColor())
                .width('100%')
            } else {
              ForEach(this.domainPreviewStats(), (item: DomainQueryStats, index: number) => {
                Column({ space: 6 }) {
                  Row({ space: 10 }) {
                    Text(`${index + 1}. ${item.domain}`)
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.primaryTextColor())
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(item.lastAction === 'blocked' ? this.t('blockedTag') : this.t('allowedTag'))
                      .fontSize(10)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.queryActionBadgeTextTone(item.lastAction))
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                      .backgroundColor(this.queryActionBadgeSurfaceTone(item.lastAction))
                      .border({ width: 1, color: this.queryActionBadgeBorderTone(item.lastAction) })
                      .borderRadius(10)
                      .shadow({ radius: 10, color: this.queryActionBadgeShadowTone(item.lastAction), offsetX: 0, offsetY: 3 })
                  }
                  .width('100%')

                  Text(`${this.t('queryCount')}: ${item.total}`)
                    .fontSize(12)
                    .fontColor(this.secondaryTextColor())
                    .width('100%')
                  if (item.lastAction === 'blocked') {
                    Text(`${this.t('rulePrefix')}: ${item.lastRule || this.t('none')}`)
                      .fontSize(12)
                      .fontColor(this.secondaryTextColor())
                      .width('100%')
                  }
                }
                .width('100%')
                .padding(14)
                .backgroundColor(this.sheetSecondarySurfaceTone())
                .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
                .borderRadius(18)
                .border({ width: 1, color: this.sheetBorderTone() })
                .shadow({ radius: 10, color: this.sheetShadowTone(), offsetX: 0, offsetY: 4 })
              }, (item: DomainQueryStats) => `${item.domain}_${item.total}_${item.totalDnsBytes}`)
            }
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(24)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
            : [['#F8FCFF', 0.0], ['#EBF5FF', 1.0]]
        })
        .onClick(() => {
          this.domainSheetFeedbackText = '';
          this.showDomainSheet = true;
        })
        .bindSheet(this.showDomainSheet, this.DomainLeaderboardSheet(), {
          height: '92%',
          backgroundColor: this.sheetSurfaceTone(),
          showClose: false,
          onDisappear: () => {
            this.showDomainSheet = false;
          }
        })

        Column({ space: 12 }) {
          Row() {
            Text(this.t('debugLog'))
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
            Blank()
            Text(this.t('clickToExpand'))
              .fontSize(12)
              .fontColor(this.mutedTextColor())
          }
          .width('100%')

          Column({ space: 8 }) {
            Text(`${this.debugLines.length} ${this.t('lines')}`)
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
              .width('100%')
            if (this.debugLines.length === 0) {
              Text(this.t('noDebugLogs'))
                .fontSize(13)
                .fontColor(this.secondaryTextColor())
                .width('100%')
            } else {
              Text(this.t('clickViewDebugAndCopy'))
                .fontSize(12)
                .fontColor(this.mutedTextColor())
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .backgroundColor(this.sheetSecondarySurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })
          .shadow({ radius: 10, color: this.sheetShadowTone() })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(24)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
            : [['#F8FCFF', 0.0], ['#EBF5FF', 1.0]]
        })
        .onClick(() => {
          this.debugSheetFeedbackText = '';
          this.showDebugSheet = true;
        })
        .bindSheet(this.showDebugSheet, this.DebugLogSheet(), {
          height: '82%',
          backgroundColor: this.sheetSurfaceTone(),
          showClose: false,
          onDisappear: () => {
            this.showDebugSheet = false;
          }
        })
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 0 })
      .padding({ bottom: this.contentBottomInset() })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  private ConfigTab() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 16 }) {
          Row({ space: 12 }) {
            this.IconBubble(this.sectionGlyph('rules'), this.isDarkModeActive() ? '#22324A' : '#EEF3FA', '#2B5B95', 26, 12)
            Column() {
              Text(this.t('configTitle'))
                .fontSize(24)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.primaryTextColor())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .justifyContent(FlexAlign.Center)

            Stack() {
              Text('+')
                .fontSize(26)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.selectedChipTextTone())
            }
            .width(46)
            .height(46)
            .borderRadius(23)
            .backgroundColor(this.coolChipSurfaceTone())
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
            .border({ width: 1, color: this.cardBorderTone() })
            .shadow({ radius: 8, color: this.softBlueTone() })
            .onClick(() => {
              this.importRulesFile().catch((err: BusinessError) => {
                this.errorText = this.errorMessage(err);
              });
            })
          }
          .alignItems(VerticalAlign.Center)

          Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Center }) {
            Text(this.enabledRuleProfileSummary())
              .fontSize(12)
              .fontColor(this.selectedChipTextTone())
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(this.coolChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .border({ width: 1, color: this.cardBorderTone() })
              .borderRadius(12)
              .margin({ right: 8, bottom: 8 })
            this.RuleCountBadge(
              this.t('importedRules'),
              this.importedRuleCountBadge,
              this.coolNeutralChipSurfaceTone(),
              this.primaryTextColor()
            )
            this.RuleCountBadge(
              this.t('customBlockRules'),
              this.customBlockRuleCountBadge,
              this.coolNeutralChipSurfaceTone(),
              '#B42318'
            )
            this.RuleCountBadge(
              this.t('customAllowRules'),
              this.customAllowRuleCountBadge,
              this.softGreenTone(),
              '#185B45'
            )
          }
          .width('100%')

          if (this.configFeedbackText.length > 0) {
            Text(this.configFeedbackText)
              .fontSize(12)
              .fontColor(this.accentBlueTone())
              .fontWeight(FontWeight.Medium)
              .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 20, right: 20, top: 22, bottom: 24 })
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(24)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
            : [['#F8FCFF', 0.0], ['#EBF5FF', 1.0]]
        })

        Column({ space: 12 }) {
          Row({ space: 8 }) {
            this.IconBubble(this.sectionGlyph('dnsPackets'), this.isDarkModeActive() ? '#22324A' : '#EEF3FA', '#2B5B95', 26, 12)
            Text(this.t('dnsCacheTitle'))
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
          }
          Text(this.t('dnsCacheHint'))
            .fontSize(13)
            .lineHeight(20)
            .fontColor(this.secondaryTextColor())
            .width('100%')

          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text(this.t('dnsCacheTtlLabel'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.primaryTextColor())
              Text('s')
                .fontSize(12)
                .fontColor(this.secondaryTextColor())
            }
            .alignItems(HorizontalAlign.Start)

            TextInput({ text: this.dnsCacheTtlInput, placeholder: `${DEFAULT_DNS_CACHE_TTL_SECONDS}` })
              .layoutWeight(1)
              .height(44)
              .fontSize(15)
              .backgroundColor(this.sheetInputSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .borderRadius(14)
              .border({ width: 1, color: this.sheetBorderTone() })
              .padding({ left: 12, right: 12 })
              .onChange((value: string) => {
                this.updateDnsCacheTtl(value);
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.sheetSecondarySurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(24)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
            : [['#F8FCFF', 0.0], ['#EBF5FF', 1.0]]
        })

        if (this.ruleProfiles.length === 0) {
          Column({ space: 12 }) {
            Text(this.t('noRuleProfiles'))
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
            Text(this.t('noRuleProfilesHint'))
              .fontSize(13)
              .lineHeight(20)
              .textAlign(TextAlign.Center)
              .fontColor(this.secondaryTextColor())
            Button(this.t('importFile'))
              .height(40)
              .padding({ left: 18, right: 18 })
              .backgroundColor(this.coolChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .fontColor(this.selectedChipTextTone())
              .borderRadius(14)
              .border({ width: 1, color: this.cardBorderTone() })
              .onClick(() => {
                this.importRulesFile().catch((err: BusinessError) => {
                  this.errorText = this.errorMessage(err);
                });
              })
          }
          .width('100%')
          .margin({ top: 4 })
          .padding({ left: 24, right: 24, top: 32, bottom: 32 })
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.sheetInputSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.sheetBorderTone() })
          .shadow({ radius: 10, color: this.sheetShadowTone() })
        } else {
          List({ space: 12 }) {
            ForEach(this.ruleProfiles, (profile: RuleProfile, index: number) => {
              ListItem() {
                Column({ space: 10 }) {
                  Row({ space: 10 }) {
                    Column({ space: 4 }) {
                      Text(profile.name)
                        .fontSize(17)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.primaryTextColor())
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.ruleProfileMetaText(profile))
                        .fontSize(12)
                        .fontColor(this.secondaryTextColor())
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    Toggle({ type: ToggleType.Switch, isOn: profile.enabled })
                      .selectedColor(this.accentBlueTone())
                      .onChange((value: boolean) => {
                        this.toggleRuleProfileEnabled(profile.id, value);
                      })
                  }
                  .width('100%')

                  Row({ space: 8 }) {
                    Button(this.t('moveUp'))
                      .enabled(this.canMoveRuleProfileUp(profile.id))
                      .height(34)
                      .layoutWeight(1)
                      .backgroundColor(this.coolNeutralChipSurfaceTone())
                      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                      .fontColor(this.primaryTextColor())
                      .borderRadius(12)
                      .border({ width: 1, color: this.cardBorderTone() })
                      .onClick(() => {
                        this.moveRuleProfileUp(profile.id);
                      })
                    Button(this.t('moveDown'))
                      .enabled(this.canMoveRuleProfileDown(profile.id))
                      .height(34)
                      .layoutWeight(1)
                      .backgroundColor(this.coolNeutralChipSurfaceTone())
                      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                      .fontColor(this.primaryTextColor())
                      .borderRadius(12)
                      .border({ width: 1, color: this.cardBorderTone() })
                      .onClick(() => {
                        this.moveRuleProfileDown(profile.id);
                      })
                  }
                  .width('100%')

                  Row({ space: 8 }) {
                    Button(this.t('editRule'))
                      .height(34)
                      .layoutWeight(1)
                      .backgroundColor(this.coolChipSurfaceTone())
                      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                      .fontColor(this.selectedChipTextTone())
                      .borderRadius(12)
                      .border({ width: 1, color: this.cardBorderTone() })
                      .onClick(() => {
                        this.openRuleEditor(profile.id);
                      })
                    Button(this.t('deleteRule'))
                      .enabled(!profile.builtIn)
                      .height(34)
                      .layoutWeight(1)
                      .backgroundColor(this.coolNeutralChipSurfaceTone())
                      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                      .fontColor('#B42318')
                      .borderRadius(12)
                      .border({ width: 1, color: this.cardBorderTone() })
                      .onClick(() => {
                        this.confirmDeleteRuleProfile(profile.id);
                      })
                  }
                  .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ left: 16, right: 16, top: 18, bottom: 18 })
                .backgroundColor(this.sheetInputSurfaceTone())
                .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
                .borderRadius(18)
                .border({ width: 1, color: this.sheetBorderTone() })
                .shadow({ radius: 10, color: this.sheetShadowTone() })
              }
            }, (profile: RuleProfile) => this.ruleProfileRenderKey(profile))
          }
          .width('100%')
          .height('100%')
          .margin({ top: 4 })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 0 })
      .padding({ bottom: this.contentBottomInset() })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  private MeTab() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 12 }) {
          Row({ space: 8 }) {
            this.IconBubble(this.sectionGlyph('keepAlive'), this.isDarkModeActive() ? '#22324A' : '#EEF8F2', '#179160', 24, 12)
            Text(this.t('tabMe'))
              .fontSize(11)
              .fontColor(this.selectedChipTextTone())
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(this.coolNeutralChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .border({ width: 1, color: this.cardBorderTone() })
              .borderRadius(12)
            Text(this.keepAliveRunning ? this.t('keepAliveOn') : this.t('keepAliveOff'))
              .fontSize(11)
              .fontColor(this.keepAliveRunning ? this.accentGreenTone() : this.accentAmberTone())
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(this.keepAliveRunning ? this.softGreenTone() : this.coolNeutralChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .border({ width: 1, color: this.cardBorderTone() })
              .borderRadius(12)
          }
          .width('100%')

          Text(this.t('myDevice'))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.primaryTextColor())
          Text(this.t('myDeviceHint'))
            .fontSize(14)
            .lineHeight(22)
            .fontColor(this.secondaryTextColor())
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(20)
        .backgroundColor(this.cardSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(26)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 14, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1A2435D8', 0.0], ['#1D2A3EDC', 0.5], ['#22334AD8', 1.0]]
            : [['#F8FCFF', 0.0], ['#EFF7FF', 0.52], ['#EAF4FF', 1.0]]
        })

        Column({ space: 12 }) {
          Row({ space: 8 }) {
            this.IconBubble(this.sectionGlyph('keepAlive'), this.isDarkModeActive() ? '#22324A' : '#EEF8F2', '#179160', 26, 12)
          Text(this.t('backgroundKeepAlive'))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
            .width('100%')
          }
          Text(this.t('keepAliveSummary'))
            .fontSize(13)
            .lineHeight(20)
            .fontColor(this.secondaryTextColor())
            .width('100%')

          Row() {
            Column({ space: 4 }) {
              Text(this.t('audioKeepAlive'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.primaryTextColor())
              Text(this.t('audioKeepAliveHint'))
                .fontSize(12)
                .lineHeight(18)
                .fontColor(this.secondaryTextColor())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.audioKeepAliveEnabled })
              .onChange((value: boolean) => {
                this.toggleAudioKeepAlive(value).catch((err: BusinessError) => {
                  this.errorText = this.errorMessage(err);
                });
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.sheetSecondarySurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })

          Row() {
            Column({ space: 4 }) {
              Text(this.t('locationKeepAlive'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.primaryTextColor())
              Text(this.t('locationKeepAliveHint'))
                .fontSize(12)
                .lineHeight(18)
                .fontColor(this.secondaryTextColor())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.locationKeepAliveEnabled })
              .onChange((value: boolean) => {
                this.onLocationKeepAliveChange(value).catch((err: BusinessError) => {
                  this.errorText = this.errorMessage(err);
                });
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.sheetSecondarySurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })

          Text(this.keepAliveStatusText)
            .fontSize(13)
            .fontColor(this.keepAliveRunning ? '#179160' : this.secondaryTextColor())
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(24)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
            : [['#F8FCFF', 0.0], ['#EBF5FF', 1.0]]
        })

        Column({ space: 12 }) {
          Row({ space: 8 }) {
            this.IconBubble(this.sectionGlyph('dnsPackets'), this.isDarkModeActive() ? '#22324A' : '#EEF3FA', '#2B5B95', 26, 12)
          Text(this.t('autoStartFilter'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          }
          Row() {
            Column({ space: 4 }) {
              Text(this.t('autoStartFilter'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.primaryTextColor())
              Text(this.t('autoStartFilterHint'))
                .fontSize(12)
                .lineHeight(18)
                .fontColor(this.secondaryTextColor())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.autoStartFilterEnabled })
              .onChange((value: boolean) => {
                this.onAutoStartFilterChange(value).catch((err: BusinessError) => {
                  this.errorText = this.errorMessage(err);
                });
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.sheetSecondarySurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(24)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
            : [['#F8FCFF', 0.0], ['#EBF5FF', 1.0]]
        })

        Column({ space: 10 }) {
          Row({ space: 8 }) {
            this.IconBubble(this.sectionGlyph('language'), this.isDarkModeActive() ? '#22324A' : '#EEF3FA', '#4B63D1', 26, 12)
          Text(this.t('language'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          }
          Row({ space: 8 }) {
            Button(this.t('langZhHans'))
              .layoutWeight(1)
              .backgroundColor(this.language === 'zhHans' ? this.coolChipSurfaceTone() : this.coolNeutralChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .fontColor(this.language === 'zhHans' ? this.selectedChipTextTone() : this.primaryTextColor())
              .borderRadius(14)
              .border({ width: this.language === 'zhHans' ? 1.5 : 1, color: this.language === 'zhHans' ? this.selectedOutlineTone() : this.cardBorderTone() })
              .shadow(this.language === 'zhHans'
                ? { radius: 16, color: this.selectedShadowTone(), offsetX: 0, offsetY: 4 }
                : { radius: 8, color: this.cardShadowTone(), offsetX: 0, offsetY: 2 })
              .onClick(() => {
                this.setLanguage('zhHans');
              })
            Button(this.t('langEn'))
              .layoutWeight(1)
              .backgroundColor(this.language === 'en' ? this.coolChipSurfaceTone() : this.coolNeutralChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .fontColor(this.language === 'en' ? this.selectedChipTextTone() : this.primaryTextColor())
              .borderRadius(14)
              .border({ width: this.language === 'en' ? 1.5 : 1, color: this.language === 'en' ? this.selectedOutlineTone() : this.cardBorderTone() })
              .shadow(this.language === 'en'
                ? { radius: 16, color: this.selectedShadowTone(), offsetX: 0, offsetY: 4 }
                : { radius: 8, color: this.cardShadowTone(), offsetX: 0, offsetY: 2 })
              .onClick(() => {
                this.setLanguage('en');
              })
            Button(this.t('langZhHant'))
              .layoutWeight(1)
              .backgroundColor(this.language === 'zhHant' ? this.coolChipSurfaceTone() : this.coolNeutralChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .fontColor(this.language === 'zhHant' ? this.selectedChipTextTone() : this.primaryTextColor())
              .borderRadius(14)
              .border({ width: this.language === 'zhHant' ? 1.5 : 1, color: this.language === 'zhHant' ? this.selectedOutlineTone() : this.cardBorderTone() })
              .shadow(this.language === 'zhHant'
                ? { radius: 16, color: this.selectedShadowTone(), offsetX: 0, offsetY: 4 }
                : { radius: 8, color: this.cardShadowTone(), offsetX: 0, offsetY: 2 })
              .onClick(() => {
                this.setLanguage('zhHant');
              })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(24)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
            : [['#F8FCFF', 0.0], ['#EBF5FF', 1.0]]
        })

        Column({ space: 10 }) {
          Row({ space: 8 }) {
            this.IconBubble(this.sectionGlyph('theme'), this.isDarkModeActive() ? '#22324A' : '#EEF3FA', '#6B7FA3', 26, 12)
          Text(this.t('theme'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          }
          Row({ space: 8 }) {
            Button(this.t('themeAuto'))
              .layoutWeight(1)
              .backgroundColor(this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
                ? this.coolChipSurfaceTone() : this.coolNeutralChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .fontColor(this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
                ? this.selectedChipTextTone() : this.primaryTextColor())
              .borderRadius(14)
              .border({ width: this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET ? 1.5 : 1, color: this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET ? this.selectedOutlineTone() : this.cardBorderTone() })
              .shadow(this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
                ? { radius: 16, color: this.selectedShadowTone(), offsetX: 0, offsetY: 4 }
                : { radius: 8, color: this.cardShadowTone(), offsetX: 0, offsetY: 2 })
              .onClick(() => {
                this.setTheme(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
              })
            Button(this.t('themeLight'))
              .layoutWeight(1)
              .backgroundColor(this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
                ? this.coolChipSurfaceTone() : this.coolNeutralChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .fontColor(this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
                ? this.selectedChipTextTone() : this.primaryTextColor())
              .borderRadius(14)
              .border({ width: this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT ? 1.5 : 1, color: this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT ? this.selectedOutlineTone() : this.cardBorderTone() })
              .shadow(this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
                ? { radius: 16, color: this.selectedShadowTone(), offsetX: 0, offsetY: 4 }
                : { radius: 8, color: this.cardShadowTone(), offsetX: 0, offsetY: 2 })
              .onClick(() => {
                this.setTheme(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
              })
            Button(this.t('themeDark'))
              .layoutWeight(1)
              .backgroundColor(this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
                ? this.coolChipSurfaceTone() : this.coolNeutralChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .fontColor(this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
                ? this.selectedChipTextTone() : this.primaryTextColor())
              .borderRadius(14)
              .border({ width: this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? 1.5 : 1, color: this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? this.selectedOutlineTone() : this.cardBorderTone() })
              .shadow(this.themeMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
                ? { radius: 16, color: this.selectedShadowTone(), offsetX: 0, offsetY: 4 }
                : { radius: 8, color: this.cardShadowTone(), offsetX: 0, offsetY: 2 })
              .onClick(() => {
                this.setTheme(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
              })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(24)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
            : [['#F8FCFF', 0.0], ['#EBF5FF', 1.0]]
        })

        Column({ space: 10 }) {
          Row({ space: 8 }) {
            this.IconBubble(this.sectionGlyph('version'), this.isDarkModeActive() ? '#22324A' : '#EEF3FA', '#2B5B95', 26, 12)
          Text(this.t('versionBuild'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          }
          Text(`${this.t('appVersion')}: ${this.appVersionName} (${this.appVersionCode})`)
            .fontSize(14)
            .fontColor(this.secondaryTextColor())
          Text(`${this.t('mode')}: ${this.t('modeValue')}`)
            .fontSize(14)
            .fontColor(this.secondaryTextColor())
          Text(`${this.t('ipv6Dns')}: ${this.t('enabled')}`)
            .fontSize(14)
            .fontColor(this.secondaryTextColor())
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(24)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
            : [['#F8FCFF', 0.0], ['#EBF5FF', 1.0]]
        })

        Column({ space: 12 }) {
          Row({ space: 8 }) {
            this.IconBubble(this.sectionGlyph('license'), this.isDarkModeActive() ? '#22324A' : '#EEF3FA', '#6B7FA3', 26, 12)
          Text(this.t('openSource'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          }
          Text(this.t('openSourceHint'))
            .fontSize(13)
            .lineHeight(20)
            .fontColor(this.secondaryTextColor())
          Button(this.t('openSourceNotices'))
            .height(42)
            .backgroundColor(this.coolChipSurfaceTone())
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
            .fontColor(this.selectedChipTextTone())
            .borderRadius(14)
            .border({ width: 1, color: this.cardBorderTone() })
            .shadow({ radius: 8, color: this.softBlueTone() })
            .onClick(() => {
              this.openLicensePage();
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(24)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })
        .linearGradient({
          angle: 145,
          colors: this.isDarkModeActive()
            ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
            : [['#F8FCFF', 0.0], ['#EBF5FF', 1.0]]
        })
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 0 })
      .padding({ bottom: this.contentBottomInset() })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  private RuleEditorSheet() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        this.IconBubble(this.sectionGlyph('rules'), this.isDarkModeActive() ? '#22324A' : '#EEF3FA', '#2B5B95', 24, 12)
        Column({ space: 2 }) {
          Text(this.t('rulesEditor'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      TextInput({ text: this.editingRuleNameText, placeholder: this.t('defaultCustomRules') })
        .width('100%')
        .height(44)
        .fontSize(15)
        .backgroundColor(this.sheetInputSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .borderRadius(14)
        .border({ width: 1, color: this.sheetBorderTone() })
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.editingRuleNameText = value;
        })

      Row({ space: 8 }) {
        Text('||domain^')
          .fontSize(11)
          .fontColor('#185B45')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.softGreenTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .border({ width: 1, color: this.cardBorderTone() })
          .borderRadius(12)
        Text('@@ whitelist')
          .fontSize(11)
          .fontColor('#2B5B95')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.softBlueTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .border({ width: 1, color: this.cardBorderTone() })
          .borderRadius(12)
        Text('IPv6')
          .fontSize(11)
          .fontColor(this.accentAmberTone())
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.coolNeutralChipSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .border({ width: 1, color: this.cardBorderTone() })
          .borderRadius(12)
      }
      .width('100%')

      TextArea({ text: this.rulesText, placeholder: this.t('writeRulesHere') })
        .width('100%')
        .height(360)
        .backgroundColor(this.sheetInputSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(18)
        .border({ width: 1, color: this.sheetBorderTone() })
        .fontSize(13)
        .padding(12)
        .shadow({ radius: 10, color: this.sheetShadowTone() })
        .onChange((value: string) => {
          this.rulesText = value;
        })

      Row({ space: 12 }) {
        Button(this.t('closeEditor'))
          .height(42)
          .layoutWeight(1)
          .backgroundColor(this.coolNeutralChipSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .fontColor(this.primaryTextColor())
          .borderRadius(14)
          .border({ width: 1, color: this.cardBorderTone() })
          .onClick(() => {
            this.closeRuleEditor();
          })
        Button(this.t('exportRules'))
          .height(42)
          .layoutWeight(1)
          .backgroundColor(this.coolNeutralChipSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .fontColor(this.primaryTextColor())
          .borderRadius(14)
          .border({ width: 1, color: this.cardBorderTone() })
          .onClick(() => {
            this.exportRuleEditorContent().catch((err: BusinessError) => {
              this.errorText = this.errorMessage(err);
              this.promptAction?.showToast({ message: this.t('exportRulesFailed') });
            });
          })
        Button(this.t('saveRules'))
          .height(42)
          .layoutWeight(1)
          .backgroundColor(this.coolChipSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
          .fontColor(this.selectedChipTextTone())
          .borderRadius(14)
          .border({ width: 1, color: this.cardBorderTone() })
          .onClick(() => {
            this.applyRuleEditorChanges();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: Math.max(18, this.avoidPaddingBottom + 12) })
    .backgroundColor(this.sheetSurfaceTone())
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
    .border({ width: 1, color: this.sheetBorderTone() })
    .shadow({ radius: 18, color: this.sheetShadowTone(), offsetX: 0, offsetY: -4 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Stack() {
        Column() {}
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 135,
            colors: this.isDarkModeActive()
              ? [['#0A0F1A', 0.0], ['#0F172A', 0.46], ['#111827', 1.0]]
              : [['#F7FAFF', 0.0], ['#EEF4FC', 0.46], ['#F5F9FF', 1.0]]
          })

        Column() {}
          .width(220)
          .height(220)
          .borderRadius(110)
          .backgroundColor(this.isDarkModeActive() ? '#22355370' : '#33DCE7F8')
          .position({ x: -50, y: 90 })

        Column() {}
          .width(180)
          .height(180)
          .borderRadius(90)
          .backgroundColor(this.isDarkModeActive() ? '#223A3A55' : '#33F4DFC3')
          .position({ x: 250, y: 420 })

        Column() {}
          .width(160)
          .height(160)
          .borderRadius(80)
          .backgroundColor(this.isDarkModeActive() ? '#1F3C6A55' : '#33C9D8FF')
          .position({ x: 210, y: 110 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)

      Stack({ alignContent: Alignment.TopStart }) {
        Column({ space: 16 }) {
          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(13)
              .fontColor('#B42318')
              .padding(12)
              .backgroundColor(this.softRedTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .borderRadius(14)
              .width('100%')
          }

          if (deviceInfo.sdkApiVersion >= 23) {
            HdsTabs({ barPosition: BarPosition.End, index: this.currentTab }) {
              TabContent() {
                Column() {
                  this.HomeTab();
                }
                .width('100%')
                .height('100%')
                .layoutWeight(1)
                .justifyContent(FlexAlign.Start)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .height('100%')
              .backgroundColor('#00000000')
              .tabBar(new BottomTabBarStyle(
                { normal: new SymbolGlyphModifier($r('sys.symbol.house')), selected: new SymbolGlyphModifier($r('sys.symbol.house_fill')) },
                this.t('tabHome')
              ))

              TabContent() {
                Column() {
                  this.ConfigTab();
                }
                .width('100%')
                .height('100%')
                .layoutWeight(1)
                .justifyContent(FlexAlign.Start)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .height('100%')
              .backgroundColor('#00000000')
              .tabBar(new BottomTabBarStyle(
                { normal: new SymbolGlyphModifier($r('sys.symbol.gearshape')), selected: new SymbolGlyphModifier($r('sys.symbol.gearshape_fill')) },
                this.t('tabConfig')
              ))

              TabContent() {
                Column() {
                  this.MeTab();
                }
                .width('100%')
                .height('100%')
                .layoutWeight(1)
                .justifyContent(FlexAlign.Start)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .height('100%')
              .backgroundColor('#00000000')
              .tabBar(new BottomTabBarStyle(
                { normal: new SymbolGlyphModifier($r('sys.symbol.person')), selected: new SymbolGlyphModifier($r('sys.symbol.person_fill')) },
                this.t('tabMe')
              ))
            }
            .backgroundColor('#00000000')
            .barOverlap(true)
            .vertical(false)
            .scrollable(false)
            .width('100%')
            .height('100%')
            .barFloatingStyle({
              barBottomMargin: 24,
              systemMaterialEffect: {
                materialType: hdsMaterial.MaterialType.ADAPTIVE,
                materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
              }
            })
            .onChange((index: number) => {
              this.currentTab = index;
              this.savePersistState();
            })
          } else {
            this.CurrentTabPage()
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16, top: this.contentTopInset(), bottom: 0 })
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
        .align(Alignment.TopStart)
        .bindSheet(this.showRuleEditorSheet, this.RuleEditorSheet(), {
          height: SheetSize.FIT_CONTENT,
          backgroundColor: Color.Transparent,
          onDisappear: () => {
            this.showRuleEditorSheet = false;
            this.editingRuleProfileId = '';
          }
        })
      }
      .width('100%')
      .height('100%')
      if (deviceInfo.sdkApiVersion < 23) {
        this.ClassicTabHost()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.canvasTone())
  }
}
