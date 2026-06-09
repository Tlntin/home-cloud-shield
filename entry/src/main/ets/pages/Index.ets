import { common, ConfigurationConstant, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { i18n, resourceManager } from '@kit.LocalizationKit';
import { vpnExtension, socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { hdsMaterial, HdsTabs } from '@kit.UIDesignKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';
import { geoLocationManager } from '@kit.LocationKit';
import { webview } from '@kit.ArkWeb';
import { BLOCKED_SERVICES, BlockedServiceDef } from '../data/BlockedServices';
import { dnsLogDb, DnsLogRow } from '../data/DnsLogDb';
import type { PromptAction } from '@ohos.arkui.UIContext';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import bundleManager from '@ohos.bundle.bundleManager';
import pasteboard from '@ohos.pasteboard';
import uri from '@ohos.uri';
import vpnclientbridge from 'libvpnclientbridge.so';

const DOMAIN = 0x0000;
const TAG = 'vpn_demo_ui';
const VPN_BUNDLE_NAME = 'com.tlntin.home_cloud_shield';
const VPN_MODULE_NAME = 'entry';
const VPN_ABILITY_NAME = 'MyVpnExtAbility';
const ENTRY_ABILITY_NAME = `${VPN_BUNDLE_NAME}.EntryAbility`;
const VPN_DIR_NAME = 'vpn';
// AdGuardHome (full mode) web admin panel — default port. The effective port is
// user-configurable (aghHttpPort) and passed to the VPN extension via the Want.
const AGH_HTTP_PORT = 3000;
// DNS server / coexist mode (experimental): the embedded AdGuardHome engine runs
// in THIS (main) process as a standalone loopback DNS server, with no VPN, so a
// separate VPN/proxy app can stay connected and use 127.0.0.1:AGH_DNS_PORT as its
// DNS upstream. AGH_DNS_PORT must match AGH_DNS_PORT in MyVpnExtAbility.
const AGH_DNS_PORT = 5354;
// Allowed range for the user-configurable DNS-proxy port. Unprivileged apps
// cannot bind ports below 1024.
const DNS_PROXY_PORT_MIN = 1024;
const DNS_PROXY_PORT_MAX = 65535;
const AGH_CONFIG_FILE_NAME = 'AdGuardHome.yaml';
const AGH_WORK_DIR_NAME = 'agh';
const AGH_LOG_FILE_NAME = 'agh.log';
const AGH_SCHEMA_VERSION = 29;
// DNS query log: cap how many recent entries are parsed/held in memory (the file
// can grow to tens of thousands of lines; parsing all every refresh tick and
// rendering them at once freezes the UI), and how many to show per page.
const MAX_QUERY_EVENTS = 2000;
const DNS_PAGE_SIZE = 100;
const STATUS_FILE_NAME = 'status.json';
const RULES_FILE_NAME = 'filters.txt';
const QUERY_LOG_FILE_NAME = 'dns_queries.jsonl';
const DEBUG_LOG_FILE_NAME = 'debug.log';
const UPSTREAM_DNS_FILE_NAME = 'upstream.txt';
const STATE_FILE_NAME = 'ui_state.json';
const WANT_STATUS_FILE_PATH = 'statusFilePath';
const WANT_RULES_FILE_PATH = 'rulesFilePath';
const WANT_QUERY_LOG_FILE_PATH = 'queryLogFilePath';
const WANT_DEBUG_LOG_FILE_PATH = 'debugLogFilePath';
const WANT_UPSTREAM_DNS_FILE_PATH = 'upstreamDnsFilePath';
const DEFAULT_UPSTREAM_DNS_IP = '119.29.29.29';
const WANT_DNS_CACHE_TTL_SECONDS = 'dnsCacheTtlSeconds';
const WANT_LOG_RETENTION_DAYS = 'logRetentionDays';
const WANT_LOG_MAX_SIZE_MB = 'logMaxSizeMb';
const WANT_CLEAR_DNS_LOG_ON_START = 'clearDnsLogOnStart';
const WANT_CLEAR_DEBUG_LOG_ON_START = 'clearDebugLogOnStart';
const DEFAULT_DNS_CACHE_TTL_SECONDS = 3600;
const DEFAULT_LOG_RETENTION_DAYS = 0;
const DEFAULT_LOG_MAX_SIZE_MB = 0;
const CUSTOM_BLOCK_RULE_PROFILE_ID = 'custom_block_rules';
const CUSTOM_ALLOW_RULE_PROFILE_ID = 'custom_allow_rules';
type LangCode = 'zhHans' | 'en' | 'zhHant';
type PreferredLangCode = 'zh-Hans' | 'en-Latn-US' | 'zh-Hant';
type LanguageKey =
  'appTitle' | 'homeTitle' | 'configTitle' | 'meTitle' | 'settingsTitle' | 'homeSubtitle' | 'configSubtitle' | 'meSubtitle' | 'settingsSubtitle'
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
  | 'editRule' | 'renameRule' | 'deleteRule' | 'exportRules' | 'rulesSavedSuccess' | 'rulesSavedApplied' | 'disabled' | 'defaultCustomRules'
  | 'moveUp' | 'moveDown' | 'closeEditor' | 'rulesFile' | 'myDevice' | 'myDeviceHint' | 'keepAliveOn' | 'keepAliveOff'
  | 'backgroundKeepAlive' | 'keepAliveSummary' | 'audioKeepAlive' | 'audioKeepAliveHint' | 'locationKeepAlive'
  | 'locationKeepAliveHint' | 'autoStartFilter' | 'autoStartFilterHint' | 'autoStartFilterPermissionDenied'
  | 'versionBuild' | 'appVersion' | 'bundle' | 'mode' | 'modeValue' | 'ipv6Dns' | 'enabled' | 'openSource'
  | 'openSourceHint' | 'openSourceNotices' | 'unsaved' | 'language' | 'theme' | 'themeAuto' | 'themeLight'
  | 'themeDark' | 'langZhHans' | 'langEn' | 'langZhHant' | 'configImported' | 'noConfigSelected' | 'importedEmpty'
  | 'saveRulesFailed' | 'audioMode' | 'locationMode' | 'keepAliveActivePrefix' | 'keepAliveArmedPrefix'
  | 'keepAliveErrorPrefix' | 'keepAliveOffStatus' | 'keepAliveWaitStatus' | 'keepAliveStartFailed'
  | 'locationPermissionRequired' | 'dnsFilterNotStarted' | 'startRequested' | 'stopping' | 'licenseTitle'
  | 'restartRequested'
  | 'licenseSubtitle' | 'back' | 'loadingLicense' | 'licenseUnavailable' | 'enabledRuleProfileSummary'
  | 'rulesImportedMessage' | 'exportSuccessMessage' | 'exportCanceledMessage' | 'noRulesToExportMessage'
  | 'confirmDeleteRuleProfile' | 'noDnsRequestsToCopy' | 'dnsRequestsCopied' | 'noDebugLogsToCopy' | 'debugLogsCopied'
  | 'allWithCount' | 'noDomainStatsToCopy' | 'domainStatsCopied' | 'noDomainStatsToExport'
  | 'domainStatsExportedStatus' | 'exportSuccessToast' | 'noDnsRequestsToExport' | 'dnsRequestsExportedStatus'
  | 'clearDnsRequestsFailed' | 'noDebugLogsToExport' | 'debugLogsExportedStatus' | 'copy' | 'export' | 'copyLog'
  | 'exportLog' | 'dnsSearchPlaceholder' | 'clickToExpand' | 'clickViewDebugAndCopy' | 'exportDebugLogsFailed'
  | 'exportRulesFailed' | 'exportFileFailed' | 'dnsCacheTitle' | 'dnsCacheHint' | 'dnsCacheTtlLabel'
  | 'upstreamDnsTitle' | 'upstreamDnsHint' | 'upstreamDnsApply' | 'upstreamDnsApplied' | 'upstreamDnsInvalid'
  | 'logRetentionTitle' | 'logRetentionHint' | 'clearDnsLogOnStart' | 'clearDnsLogOnStartHint'
  | 'clearDebugLogOnStart' | 'clearDebugLogOnStartHint' | 'logRetentionDaysLabel' | 'logRetentionDaysHint'
  | 'logMaxSizeMbLabel' | 'logMaxSizeMbHint' | 'settingsEntry' | 'settingsEntryHint'
  | 'cacheHits' | 'cacheMisses' | 'sourcePrefix' | 'sourceCache' | 'sourceUpstream' | 'sourceBlocked'
  | 'domainCacheHits' | 'domainUpstreamQueries'
  | 'importedRules'
  | 'customBlockRules' | 'customAllowRules' | 'builtInRuleProfileLocked' | 'addRuleActionTitle'
  | 'addAllowRuleAction' | 'addBlockRuleAction' | 'ruleAddedNeedsRestart' | 'ruleAlreadyExists'
  | 'tapDomainToCreateRule' | 'addRuleLine' | 'customBlockRulePlaceholder' | 'customAllowRulePlaceholder'
  | 'confirmDeleteRuleLine' | 'noCustomRulesHint' | 'swipeAgainToExit'
  | 'continueLabel' | 'keepAliveWarnTitle' | 'keepAliveWarnMessage'
  | 'dnsProxyTitle' | 'dnsProxyDesc' | 'dnsProxyCopied' | 'dnsProxyStart' | 'dnsProxyStop'
  | 'dnsProxyDashboard' | 'dnsProxyDashboardDesc' | 'dnsProxyRunningStatus' | 'dnsProxyStoppedStatus'
  | 'dnsProxyStopVpnFirst' | 'dnsProxyEngineLite' | 'dnsProxyEngineFull'
  | 'modeVpn' | 'modeDnsProxy' | 'dnsProxyPortTitle' | 'dnsProxyPortHint' | 'dnsProxyPortInvalid'
  | 'aghPanelPortTitle' | 'aghPanelPortHint' | 'aghPanelPortConflict' | 'dnsProxyPortBumped';

function resolveStringResource(key: LanguageKey): number {
  switch (key) {
    case 'appTitle': return $r('app.string.appTitle').id;
    case 'homeTitle': return $r('app.string.homeTitle').id;
    case 'configTitle': return $r('app.string.configTitle').id;
    case 'meTitle': return $r('app.string.meTitle').id;
    case 'settingsTitle': return $r('app.string.settingsTitle').id;
    case 'homeSubtitle': return $r('app.string.homeSubtitle').id;
    case 'configSubtitle': return $r('app.string.configSubtitle').id;
    case 'meSubtitle': return $r('app.string.meSubtitle').id;
    case 'settingsSubtitle': return $r('app.string.settingsSubtitle').id;
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
    case 'rulesSavedApplied': return $r('app.string.rulesSavedApplied').id;
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
    case 'restartRequested': return $r('app.string.restartRequested').id;
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
    case 'upstreamDnsTitle': return $r('app.string.upstreamDnsTitle').id;
    case 'upstreamDnsHint': return $r('app.string.upstreamDnsHint').id;
    case 'upstreamDnsApply': return $r('app.string.upstreamDnsApply').id;
    case 'upstreamDnsApplied': return $r('app.string.upstreamDnsApplied').id;
    case 'upstreamDnsInvalid': return $r('app.string.upstreamDnsInvalid').id;
    case 'dnsCacheTtlLabel': return $r('app.string.dnsCacheTtlLabel').id;
    case 'logRetentionTitle': return $r('app.string.logRetentionTitle').id;
    case 'logRetentionHint': return $r('app.string.logRetentionHint').id;
    case 'logRetentionDaysLabel': return $r('app.string.logRetentionDaysLabel').id;
    case 'logRetentionDaysHint': return $r('app.string.logRetentionDaysHint').id;
    case 'logMaxSizeMbLabel': return $r('app.string.logMaxSizeMbLabel').id;
    case 'logMaxSizeMbHint': return $r('app.string.logMaxSizeMbHint').id;
    case 'clearDnsLogOnStart': return $r('app.string.clearDnsLogOnStart').id;
    case 'clearDnsLogOnStartHint': return $r('app.string.clearDnsLogOnStartHint').id;
    case 'clearDebugLogOnStart': return $r('app.string.clearDebugLogOnStart').id;
    case 'clearDebugLogOnStartHint': return $r('app.string.clearDebugLogOnStartHint').id;
    case 'settingsEntry': return $r('app.string.settingsEntry').id;
    case 'settingsEntryHint': return $r('app.string.settingsEntryHint').id;
    case 'cacheHits': return $r('app.string.cacheHits').id;
    case 'cacheMisses': return $r('app.string.cacheMisses').id;
    case 'sourcePrefix': return $r('app.string.sourcePrefix').id;
    case 'sourceCache': return $r('app.string.sourceCache').id;
    case 'sourceUpstream': return $r('app.string.sourceUpstream').id;
    case 'sourceBlocked': return $r('app.string.sourceBlocked').id;
    case 'domainCacheHits': return $r('app.string.domainCacheHits').id;
    case 'domainUpstreamQueries': return $r('app.string.domainUpstreamQueries').id;
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
    case 'addRuleLine': return $r('app.string.addRuleLine').id;
    case 'customBlockRulePlaceholder': return $r('app.string.customBlockRulePlaceholder').id;
    case 'customAllowRulePlaceholder': return $r('app.string.customAllowRulePlaceholder').id;
    case 'confirmDeleteRuleLine': return $r('app.string.confirmDeleteRuleLine').id;
    case 'noCustomRulesHint': return $r('app.string.noCustomRulesHint').id;
    case 'swipeAgainToExit': return $r('app.string.swipeAgainToExit').id;
    case 'continueLabel': return $r('app.string.continueLabel').id;
    case 'keepAliveWarnTitle': return $r('app.string.keepAliveWarnTitle').id;
    case 'keepAliveWarnMessage': return $r('app.string.keepAliveWarnMessage').id;
    case 'dnsProxyTitle': return $r('app.string.dnsProxyTitle').id;
    case 'dnsProxyDesc': return $r('app.string.dnsProxyDesc').id;
    case 'dnsProxyCopied': return $r('app.string.dnsProxyCopied').id;
    case 'dnsProxyStart': return $r('app.string.dnsProxyStart').id;
    case 'dnsProxyStop': return $r('app.string.dnsProxyStop').id;
    case 'dnsProxyDashboard': return $r('app.string.dnsProxyDashboard').id;
    case 'dnsProxyDashboardDesc': return $r('app.string.dnsProxyDashboardDesc').id;
    case 'dnsProxyRunningStatus': return $r('app.string.dnsProxyRunningStatus').id;
    case 'dnsProxyStoppedStatus': return $r('app.string.dnsProxyStoppedStatus').id;
    case 'dnsProxyStopVpnFirst': return $r('app.string.dnsProxyStopVpnFirst').id;
    case 'dnsProxyEngineLite': return $r('app.string.dnsProxyEngineLite').id;
    case 'dnsProxyEngineFull': return $r('app.string.dnsProxyEngineFull').id;
    case 'modeVpn': return $r('app.string.modeVpn').id;
    case 'modeDnsProxy': return $r('app.string.modeDnsProxy').id;
    case 'dnsProxyPortTitle': return $r('app.string.dnsProxyPortTitle').id;
    case 'dnsProxyPortHint': return $r('app.string.dnsProxyPortHint').id;
    case 'dnsProxyPortInvalid': return $r('app.string.dnsProxyPortInvalid').id;
    case 'aghPanelPortTitle': return $r('app.string.aghPanelPortTitle').id;
    case 'aghPanelPortHint': return $r('app.string.aghPanelPortHint').id;
    case 'aghPanelPortConflict': return $r('app.string.aghPanelPortConflict').id;
    case 'dnsProxyPortBumped': return $r('app.string.dnsProxyPortBumped').id;
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

interface QueryLogEntry {
  ts: number;
  domain: string;
  qtype: string;
  action: string;
  rule: string;
  source?: string;
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

// Subset of AdGuardHome's querylog.json line shape we read in full DNS-proxy mode.
interface AghQueryLogRule {
  Text?: string;
}

interface AghQueryLogResult {
  IsFiltered?: boolean;
  Reason?: number;
  Rules?: AghQueryLogRule[];
}

interface AghQueryLogLine {
  T?: string;
  QH?: string;
  QT?: string;
  Answer?: string;
  Cached?: boolean;
  Result?: AghQueryLogResult;
}

interface DomainQueryStats {
  domain: string;
  total: number;
  allowed: number;
  blocked: number;
  cacheHits: number;
  upstreamQueries: number;
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

interface RuleLineItem {
  key: string;
  line: string;
  index: number;
}

type QueryActionFilter = 'all' | 'allowed' | 'blocked';
type QuickRuleState = 'none' | 'block' | 'allow';

interface QuickRuleDialogButton {
  value: string;
  action: () => void;
}

// A user-managed online filter list (full-mode AdGuardHome subscription).
interface FilterSubscription {
  id: number;
  name: string;
  url: string;
  enabled: boolean;
}

// Lightweight view of the native getStats() JSON. In the main app process this
// reflects only the in-process DNS-proxy server (AdGuardHome); the VPN modes run
// AdGuardHome in the extension process, so their state is not visible here.
interface AghProxyStats {
  running: boolean;
}

// A full-mode DNS rewrite: resolve `domain` to `answer` (IP, host, or A/AAAA).
interface DnsRewriteRule {
  domain: string;
  answer: string;
}

// Full-mode AdGuardHome advanced DNS settings.
interface AdvancedDnsConfig {
  blockingMode: string;   // default | nxdomain | refused | null_ip
  upstreamMode: string;   // load_balance | parallel | fastest_addr
  enableDnssec: boolean;
  cacheEnabled: boolean;
  cacheSizeMb: number;
  cacheOptimistic: boolean;
  ratelimit: number;      // 0 = unlimited
}

// A built-in preset offered as a one-tap online subscription.
interface SubscriptionPreset {
  name: string;
  url: string;
}

// Passed by reference to settings @Builder helpers so they re-render when the
// in-app language changes (ArkUI memoizes value-type @Builder params, so the
// translated strings must arrive inside a fresh object each render).
interface SettingsGroupTitleParam {
  text: string;
}

interface SettingsRowTextParam {
  glyph: string;
  iconBg: string;
  iconFg: string;
  title: string;
  desc: string;
}

interface ThemeSegButtonParam {
  label: string;
  mode: number;
}

interface OverviewStatParam {
  label: string;
  value: string;
  valueColor: string;
}

function defaultAdvancedDnsConfig(): AdvancedDnsConfig {
  return {
    blockingMode: 'default',
    upstreamMode: 'load_balance',
    enableDnssec: false,
    cacheEnabled: true,
    cacheSizeMb: 4,
    cacheOptimistic: false,
    ratelimit: 0,
  };
}

// Mainstream, public DNS filter lists. The first three are sensible defaults
// (the same ones AdGuardHome ships, plus anti-AD for China); the rest are
// widely-used community blocklists shown under "show more". All are open and
// free to subscribe to; users can also add their own custom URLs.
const SUBSCRIPTION_PRESETS: SubscriptionPreset[] = [
  { name: 'AdGuard DNS filter', url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt' },
  { name: 'AdAway Default Blocklist', url: 'https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt' },
  { name: 'anti-AD（国内广告）', url: 'https://anti-ad.net/easylist.txt' },
  { name: 'OISD Blocklist (Big)', url: 'https://big.oisd.nl' },
  { name: 'HaGeZi Multi PRO', url: 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt' },
  { name: "Peter Lowe's Ad/Tracking", url: 'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext' },
  { name: 'StevenBlack Unified Hosts', url: 'https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts' },
  { name: '1Hosts (Lite)', url: 'https://o0.pages.dev/Lite/adblock.txt' },
];

interface PersistState {
  keepAliveEnabled?: boolean;
  audioKeepAliveEnabled?: boolean;
  locationKeepAliveEnabled?: boolean;
  autoStartFilterEnabled?: boolean;
  language?: LangCode;
  themeMode?: number;
  ruleProfiles?: RuleProfile[];
  dnsCacheTtlSeconds?: number;
  upstreamDnsIp?: string;
  logRetentionDays?: number;
  logMaxSizeMb?: number;
  clearDnsLogOnStart?: boolean;
  clearDebugLogOnStart?: boolean;
  fullModeEnabled?: boolean;
  proxyModeEnabled?: boolean;
  dnsProxyPort?: string;
  aghHttpPort?: string;
  blockedServiceIds?: string[];
  filterSubscriptions?: FilterSubscription[];
  dnsRewrites?: DnsRewriteRule[];
  advancedDns?: AdvancedDnsConfig;
  disclaimerAccepted?: boolean;
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
    dnsCacheHits: 0,
    dnsCacheMisses: 0,
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
  @State stopping: boolean = false;
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
  @State upstreamDnsFilePath: string = '';
  @State stateFilePath: string = '';
  @State rulesText: string = '';
  @State ruleProfiles: RuleProfile[] = [];
  @State importedRuleCountBadge: number = 0;
  @State customBlockRuleCountBadge: number = 0;
  @State customAllowRuleCountBadge: number = 0;
  @State queryEvents: QueryLogEntry[] = [];
  // Current filter+search match count (full table, for pagination/labels) and a
  // recent-rows window (drives the domain leaderboard). Both filled by SQL.
  @State dnsFilteredCount: number = 0;
  @State recentRows: QueryLogEntry[] = [];
  @State querySummary: QuerySummary = defaultQuerySummary();
  @State debugLines: string[] = [];
  @State showDnsSheet: boolean = false;
  @State showDomainSheet: boolean = false;
  @State showDebugSheet: boolean = false;
  @State showRuleEditorSheet: boolean = false;
  @State editingRuleProfileId: string = '';
  @State editingRuleNameText: string = '';
  @State ruleLineInputText: string = '';
  @State domainSortDescending: boolean = true;
  @State domainActionFilter: QueryActionFilter = 'all';
  @State dnsSearchText: string = '';
  @State dnsActionFilter: QueryActionFilter = 'all';
  @State dnsPage: number = 0;
  @State configFeedbackText: string = '';
  @State dnsSheetFeedbackText: string = '';
  @State domainSheetFeedbackText: string = '';
  @State debugSheetFeedbackText: string = '';
  @State dnsCacheTtlInput: string = `${DEFAULT_DNS_CACHE_TTL_SECONDS}`;
  @State dnsCacheTtlSeconds: number = DEFAULT_DNS_CACHE_TTL_SECONDS;
  @State upstreamDnsInput: string = '';
  @State logRetentionDaysInput: string = `${DEFAULT_LOG_RETENTION_DAYS}`;
  @State logRetentionDays: number = DEFAULT_LOG_RETENTION_DAYS;
  @State logMaxSizeMbInput: string = `${DEFAULT_LOG_MAX_SIZE_MB}`;
  @State logMaxSizeMb: number = DEFAULT_LOG_MAX_SIZE_MB;
  @State clearDnsLogOnStart: boolean = false;
  @State clearDebugLogOnStart: boolean = false;
  @State fullModeEnabled: boolean = false;
  // Network mode (home two-axis selector): false = whole-device VPN, true = pure
  // DNS proxy / coexist (no VPN). Orthogonal to the engine (lightweight/full).
  @State proxyModeEnabled: boolean = false;
  // Experimental DNS server / coexist mode (no VPN). Tracked separately from
  // `status` (which mirrors the VPN extension's status.json); here AGH runs in
  // this process, so we own the lifecycle flag directly.
  @State dnsProxyRunning: boolean = false;
  @State dnsProxyStatusText: string = '';
  // Local TCP port the DNS proxy listens on (DNS-proxy mode only; VPN mode uses a
  // fixed internal loopback port). Stored as text for the input; validated to
  // 1024-65535 at use, falling back to the default.
  @State dnsProxyPort: string = `${AGH_DNS_PORT}`;
  @State dnsProxyPortFeedback: string = '';
  // AdGuardHome web admin panel port (full engine only). Same validation as the
  // DNS-proxy port; must differ from it. Applies to both full-mode VPN and
  // full-mode DNS proxy.
  @State aghHttpPort: string = `${AGH_HTTP_PORT}`;
  @State aghHttpPortFeedback: string = '';
  // Actual bound ports while the DNS proxy runs (may differ from the configured
  // values when those were busy and auto-incremented). 0 = use the configured.
  @State dnsProxyActivePort: number = 0;
  @State aghActiveHttpPort: number = 0;
  @State blockedServiceIds: string[] = [];
  @State showServicesSheet: boolean = false;
  @State servicesSearchText: string = '';
  @State detailServiceId: string = '';
  @State showAghWebSheet: boolean = false;
  // Full-mode AdGuardHome extras: online subscriptions, DNS rewrites, advanced DNS.
  @State filterSubscriptions: FilterSubscription[] = [];
  @State dnsRewrites: DnsRewriteRule[] = [];
  @State advancedDns: AdvancedDnsConfig = defaultAdvancedDnsConfig();
  @State showSubscriptionsSheet: boolean = false;
  @State subAddNameInput: string = '';
  @State subAddUrlInput: string = '';
  @State subFeedbackText: string = '';
  @State showRewritesSheet: boolean = false;
  @State rewriteAddDomainInput: string = '';
  @State rewriteAddAnswerInput: string = '';
  @State rewriteFeedbackText: string = '';
  @State showAdvancedDnsSheet: boolean = false;
  @State cacheSizeInput: string = '4';
  @State ratelimitInput: string = '0';
  private aghWebController: webview.WebviewController = new webview.WebviewController();
  @State showSettingsPage: boolean = false;
  @State showImportMenu: boolean = false;
  @State showRecommendedLibrary: boolean = false;
  @State showDisclaimerSheet: boolean = false;
  @State showFirstRunDisclaimer: boolean = false;
  private disclaimerAccepted: boolean = false;
  @State appVersionName: string = 'loading';
  @State appVersionCode: number = 0;
  @State avoidPaddingTop: number = 0;
  @State avoidPaddingBottom: number = 0;

  private refreshTimer: number = -1;
  // DNS query-log RDB ingestion state. The native layer keeps appending jsonl;
  // we incrementally ingest new lines into SQLite (DnsLogDb) and query it. Offsets
  // are character offsets into the (ASCII) log text; lastTs is the ingest
  // watermark used to skip already-stored rows on a full re-scan (launch/rotation).
  private dnsDbReady: boolean = false;
  private dnsDbInitStarted: boolean = false;
  private dnsRefreshing: boolean = false;
  private appLogOffset: number = 0;
  private appLogLastTs: number = 0;
  private aghLogOffset: number = 0;
  private aghLogLastTs: number = 0;
  // Locale-specific resource manager so t() reflects the in-app language choice
  // immediately, without waiting for an app restart.
  private overrideResManager?: resourceManager.ResourceManager;
  private overrideResManagerLocale: string = '';
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
  private lastBackPressAt: number = 0;

  onBackPress(): boolean {
    if (this.showSettingsPage) {
      this.showSettingsPage = false;
      return true;
    }
    const now: number = Date.now();
    if (now - this.lastBackPressAt < 2000) {
      return false;
    }
    this.lastBackPressAt = now;
    try {
      this.ensurePromptAction()?.showToast({ message: this.t('swipeAgainToExit') });
    } catch (_) {
    }
    return true;
  }

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
    const serviceRules: string = this.blockedServiceRulesText();
    if (serviceRules.length > 0) {
      chunks.push(serviceRules);
    }
    return chunks.join('\n\n');
  }

  // Rules contributed by the user-selected "blocked services". Appended to the
  // merged rules so they work in both engines (lightweight reads filters.txt;
  // full mode maps filters.txt to AdGuardHome user_rules).
  private blockedServiceRulesText(): string {
    if (this.blockedServiceIds.length === 0) {
      return '';
    }
    const out: string[] = [];
    BLOCKED_SERVICES.forEach((svc: BlockedServiceDef) => {
      if (this.blockedServiceIds.includes(svc.id)) {
        out.push(`! service: ${svc.name}`);
        svc.rules.forEach((r: string) => out.push(r));
      }
    });
    return out.join('\n');
  }

  private toggleBlockedService(id: string, enabled: boolean): void {
    if (enabled) {
      if (!this.blockedServiceIds.includes(id)) {
        this.blockedServiceIds = this.blockedServiceIds.concat([id]);
      }
    } else {
      this.blockedServiceIds = this.blockedServiceIds.filter((x: string) => x !== id);
    }
    // Persist + write the merged rules file; the VPN extension hot-reloads it in
    // lightweight mode, and full mode picks it up on the next filter restart.
    this.saveRules();
  }

  private filteredBlockedServices(): BlockedServiceDef[] {
    const kw: string = this.servicesSearchText.trim().toLowerCase();
    if (kw.length === 0) {
      return BLOCKED_SERVICES;
    }
    return BLOCKED_SERVICES.filter((svc: BlockedServiceDef) => {
      return svc.name.toLowerCase().includes(kw) || svc.id.toLowerCase().includes(kw);
    });
  }

  private serviceById(id: string): BlockedServiceDef | undefined {
    return BLOCKED_SERVICES.find((svc: BlockedServiceDef) => svc.id === id);
  }

  // Trilingual inline label helper (en / zhHans / zhHant).
  private tri(en: string, zhHans: string, zhHant: string): string {
    return this.language === 'en' ? en : (this.language === 'zhHant' ? zhHant : zhHans);
  }

  // Subscriptions, rewrites and advanced DNS only apply in full mode and only at
  // filter start. Persist them and, if the full engine is currently running,
  // restart it so the change takes effect now; lightweight mode just persists.
  private applyFullModeConfigChange(): void {
    this.savePersistState();
    if (!this.fullModeEnabled || this.busy) {
      return;
    }
    // Restart whichever full-engine mode is running so the change applies now.
    if (this.proxyModeEnabled) {
      if (this.dnsProxyRunning) {
        this.startDnsProxy();
      }
    } else if (this.status.running) {
      this.startVpn();
    }
  }

  private normalizeAdvancedDns(raw: AdvancedDnsConfig): AdvancedDnsConfig {
    const def: AdvancedDnsConfig = defaultAdvancedDnsConfig();
    const blockingOk: boolean = raw?.blockingMode === 'default' || raw?.blockingMode === 'nxdomain'
      || raw?.blockingMode === 'refused' || raw?.blockingMode === 'null_ip';
    const upstreamOk: boolean = raw?.upstreamMode === 'load_balance' || raw?.upstreamMode === 'parallel'
      || raw?.upstreamMode === 'fastest_addr';
    return {
      blockingMode: blockingOk ? raw.blockingMode : def.blockingMode,
      upstreamMode: upstreamOk ? raw.upstreamMode : def.upstreamMode,
      enableDnssec: typeof raw?.enableDnssec === 'boolean' ? raw.enableDnssec : def.enableDnssec,
      cacheEnabled: typeof raw?.cacheEnabled === 'boolean' ? raw.cacheEnabled : def.cacheEnabled,
      cacheSizeMb: typeof raw?.cacheSizeMb === 'number' && raw.cacheSizeMb >= 0
        ? Math.floor(raw.cacheSizeMb) : def.cacheSizeMb,
      cacheOptimistic: typeof raw?.cacheOptimistic === 'boolean' ? raw.cacheOptimistic : def.cacheOptimistic,
      ratelimit: typeof raw?.ratelimit === 'number' && raw.ratelimit >= 0 ? Math.floor(raw.ratelimit) : def.ratelimit,
    };
  }

  private cloneAdvancedDns(): AdvancedDnsConfig {
    return {
      blockingMode: this.advancedDns.blockingMode,
      upstreamMode: this.advancedDns.upstreamMode,
      enableDnssec: this.advancedDns.enableDnssec,
      cacheEnabled: this.advancedDns.cacheEnabled,
      cacheSizeMb: this.advancedDns.cacheSizeMb,
      cacheOptimistic: this.advancedDns.cacheOptimistic,
      ratelimit: this.advancedDns.ratelimit,
    };
  }

  // ----- Online filter subscriptions (full mode) -----

  private nextSubscriptionId(): number {
    let maxId: number = 0;
    this.filterSubscriptions.forEach((s: FilterSubscription) => {
      if (s.id > maxId) {
        maxId = s.id;
      }
    });
    return maxId + 1;
  }

  private enabledSubscriptionCount(): number {
    let n: number = 0;
    this.filterSubscriptions.forEach((s: FilterSubscription) => {
      if (s.enabled) {
        n += 1;
      }
    });
    return n;
  }

  private addFilterSubscription(name: string, url: string): void {
    const u: string = url.trim();
    if (u.length === 0) {
      this.subFeedbackText = this.tri('Enter a list URL', '请输入规则列表 URL', '請輸入規則列表 URL');
      return;
    }
    if (!(u.startsWith('http://') || u.startsWith('https://'))) {
      this.subFeedbackText = this.tri('URL must start with http:// or https://',
        'URL 需以 http:// 或 https:// 开头', 'URL 需以 http:// 或 https:// 開頭');
      return;
    }
    if (this.filterSubscriptions.some((s: FilterSubscription) => s.url === u)) {
      this.subFeedbackText = this.tri('Already added', '该订阅已存在', '該訂閱已存在');
      return;
    }
    const nm: string = name.trim().length > 0 ? name.trim() : u;
    this.filterSubscriptions = this.filterSubscriptions.concat([{
      id: this.nextSubscriptionId(),
      name: nm,
      url: u,
      enabled: true,
    }]);
    this.subAddNameInput = '';
    this.subAddUrlInput = '';
    this.subFeedbackText = this.tri('Added', '已添加', '已新增');
    this.applyFullModeConfigChange();
  }

  private addSubscriptionPreset(preset: SubscriptionPreset): void {
    this.addFilterSubscription(preset.name, preset.url);
  }

  private toggleFilterSubscription(id: number, enabled: boolean): void {
    this.filterSubscriptions = this.filterSubscriptions.map((s: FilterSubscription) => {
      if (s.id === id) {
        return { id: s.id, name: s.name, url: s.url, enabled: enabled } as FilterSubscription;
      }
      return s;
    });
    this.applyFullModeConfigChange();
  }

  private removeFilterSubscription(id: number): void {
    this.filterSubscriptions = this.filterSubscriptions.filter((s: FilterSubscription) => s.id !== id);
    this.subFeedbackText = this.tri('Removed', '已删除', '已刪除');
    this.applyFullModeConfigChange();
  }

  // ----- DNS rewrites (full mode) -----

  private addDnsRewrite(domain: string, answer: string): void {
    const d: string = domain.trim().toLowerCase();
    const a: string = answer.trim();
    if (d.length === 0 || a.length === 0) {
      this.rewriteFeedbackText = this.tri('Enter both domain and answer', '请填写域名和应答值', '請填寫網域與應答值');
      return;
    }
    if (this.dnsRewrites.some((r: DnsRewriteRule) => r.domain === d && r.answer === a)) {
      this.rewriteFeedbackText = this.tri('Already added', '该重写已存在', '該重寫已存在');
      return;
    }
    this.dnsRewrites = this.dnsRewrites.concat([{ domain: d, answer: a }]);
    this.rewriteAddDomainInput = '';
    this.rewriteAddAnswerInput = '';
    this.rewriteFeedbackText = this.tri('Added', '已添加', '已新增');
    this.applyFullModeConfigChange();
  }

  private removeDnsRewrite(index: number): void {
    this.dnsRewrites = this.dnsRewrites.filter((_r: DnsRewriteRule, i: number) => i !== index);
    this.rewriteFeedbackText = this.tri('Removed', '已删除', '已刪除');
    this.applyFullModeConfigChange();
  }

  // ----- Advanced DNS settings (full mode) -----

  private setBlockingMode(mode: string): void {
    const next: AdvancedDnsConfig = this.cloneAdvancedDns();
    next.blockingMode = mode;
    this.advancedDns = next;
    this.applyFullModeConfigChange();
  }

  private setUpstreamMode(mode: string): void {
    const next: AdvancedDnsConfig = this.cloneAdvancedDns();
    next.upstreamMode = mode;
    this.advancedDns = next;
    this.applyFullModeConfigChange();
  }

  private setEnableDnssec(value: boolean): void {
    const next: AdvancedDnsConfig = this.cloneAdvancedDns();
    next.enableDnssec = value;
    this.advancedDns = next;
    this.applyFullModeConfigChange();
  }

  private setCacheEnabled(value: boolean): void {
    const next: AdvancedDnsConfig = this.cloneAdvancedDns();
    next.cacheEnabled = value;
    this.advancedDns = next;
    this.applyFullModeConfigChange();
  }

  private setCacheOptimistic(value: boolean): void {
    const next: AdvancedDnsConfig = this.cloneAdvancedDns();
    next.cacheOptimistic = value;
    this.advancedDns = next;
    this.applyFullModeConfigChange();
  }

  private setCacheSizeMb(value: number): void {
    const v: number = Number.isFinite(value) && value >= 0 ? Math.floor(value) : 0;
    const next: AdvancedDnsConfig = this.cloneAdvancedDns();
    next.cacheSizeMb = v;
    this.advancedDns = next;
    this.applyFullModeConfigChange();
  }

  private setRatelimit(value: number): void {
    const v: number = Number.isFinite(value) && value >= 0 ? Math.floor(value) : 0;
    const next: AdvancedDnsConfig = this.cloneAdvancedDns();
    next.ratelimit = v;
    this.advancedDns = next;
    this.applyFullModeConfigChange();
  }

  private blockingModeLabel(mode: string): string {
    if (mode === 'nxdomain') {
      return 'NXDOMAIN';
    }
    if (mode === 'refused') {
      return 'REFUSED';
    }
    if (mode === 'null_ip') {
      return this.tri('Null IP (0.0.0.0)', '空 IP (0.0.0.0)', '空 IP (0.0.0.0)');
    }
    return this.tri('Default', '默认', '預設');
  }

  private upstreamModeLabel(mode: string): string {
    if (mode === 'parallel') {
      return this.tri('Parallel', '并行', '並行');
    }
    if (mode === 'fastest_addr') {
      return this.tri('Fastest address', '最快地址', '最快位址');
    }
    return this.tri('Load balance', '负载均衡', '負載平衡');
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
      return this.localeResourceManager().getStringSync(resolveStringResource(key), ...args);
    } catch (_) {
      return key;
    }
  }

  private toResourceLocale(lang: LangCode): string {
    if (lang === 'en') {
      return 'en-US';
    }
    if (lang === 'zhHant') {
      return 'zh-Hant-HK';
    }
    return 'zh-Hans-CN';
  }

  // Returns a resource manager bound to the user-selected language, so resource
  // strings update live when the in-app language changes (cached per locale).
  // Falls back to the host resource manager if override managers are unavailable.
  private localeResourceManager(): resourceManager.ResourceManager {
    const base: resourceManager.ResourceManager = this.getHostContext().resourceManager;
    const locale: string = this.toResourceLocale(this.language);
    if (this.overrideResManager !== undefined && this.overrideResManagerLocale === locale) {
      return this.overrideResManager;
    }
    try {
      const config: resourceManager.Configuration = base.getOverrideConfiguration();
      config.locale = locale;
      const override: resourceManager.ResourceManager = base.getOverrideResourceManager(config);
      this.overrideResManager = override;
      this.overrideResManagerLocale = locale;
      return override;
    } catch (_) {
      return base;
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
    this.ruleLineInputText = '';
    this.rulesText = profile.content;
    this.showRuleEditorSheet = true;
  }

  private closeRuleEditor(): void {
    this.showRuleEditorSheet = false;
    this.editingRuleProfileId = '';
    this.editingRuleNameText = '';
    this.ruleLineInputText = '';
    this.loadRulesText();
  }

  private editingRuleProfile(): RuleProfile | undefined {
    return this.ruleProfiles.find((item: RuleProfile) => item.id === this.editingRuleProfileId);
  }

  private builtInRuleEditorActive(): boolean {
    return this.isBuiltInRuleProfile(this.editingRuleProfileId);
  }

  private builtInRuleInputPlaceholder(): string {
    if (this.editingRuleProfileId === CUSTOM_ALLOW_RULE_PROFILE_ID) {
      return this.t('customAllowRulePlaceholder');
    }
    return this.t('customBlockRulePlaceholder');
  }

  private editingRuleLineItems(): RuleLineItem[] {
    return this.ruleProfileLines(this.rulesText).map((line: string, index: number) => {
      const item: RuleLineItem = {
        key: `${index}_${line}`,
        line,
        index,
      };
      return item;
    });
  }

  private formatBuiltInRuleLine(value: string): string {
    const trimmed: string = value.trim();
    if (trimmed.length === 0) {
      return '';
    }
    if (trimmed.startsWith('@@') || trimmed.startsWith('||') || trimmed.startsWith('!')) {
      return trimmed;
    }
    return this.buildRuleLineForDomain(trimmed, this.editingRuleProfileId === CUSTOM_ALLOW_RULE_PROFILE_ID);
  }

  private addRuleLineToEditor(): void {
    const currentLines: string[] = this.ruleProfileLines(this.rulesText);
    const pendingLines: string[] = this.normalizeRuleContent(this.ruleLineInputText)
      .split('\n')
      .map((line: string) => this.formatBuiltInRuleLine(line))
      .filter((line: string) => line.length > 0);
    if (pendingLines.length === 0) {
      return;
    }
    let changed = false;
    pendingLines.forEach((line: string) => {
      if (!currentLines.includes(line)) {
        currentLines.push(line);
        changed = true;
      }
    });
    if (!changed) {
      return;
    }
    this.rulesText = currentLines.join('\n');
    this.ruleLineInputText = '';
  }

  private confirmDeleteRuleLine(lineIndex: number): void {
    const lines: string[] = this.ruleProfileLines(this.rulesText);
    if (lineIndex < 0 || lineIndex >= lines.length) {
      return;
    }
    const lineText: string = lines[lineIndex];
    this.getUIContext().showAlertDialog({
      message: `${this.t('confirmDeleteRuleLine')}\n${lineText}`,
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
              const nextLines: string[] = this.ruleProfileLines(this.rulesText);
              nextLines.splice(lineIndex, 1);
              this.rulesText = nextLines.join('\n');
            } catch (err) {
              this.errorText = this.errorMessage(err);
            }
          }
        }
      ]
    });
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

  private isValidUpstreamIp(value: string): boolean {
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

  private splitUpstreamEntries(value: string): string[] {
    return value.split(/[\s,;]+/).map((s: string) => s.trim()).filter((s: string) => s.length > 0);
  }

  private onUpstreamDnsInputChange(value: string): void {
    this.upstreamDnsInput = value;
    this.savePersistState();
  }

  // Tap a preset to append it to the failover list (deduped), then apply.
  private addUpstreamPreset(ip: string): void {
    const entries: string[] = this.splitUpstreamEntries(this.upstreamDnsInput);
    if (!entries.includes(ip)) {
      entries.push(ip);
    }
    this.applyUpstreamDns(entries.join('\n'));
  }

  // Persist the upstream list and write the file the VPN extension watches.
  // The list is tried in order with failover. While running it hot-applies
  // within ~1s; otherwise it is read at next start. Empty restores the default.
  private applyUpstreamDns(value: string): void {
    const entries: string[] = this.splitUpstreamEntries(value);
    for (const entry of entries) {
      if (!this.isValidUpstreamIp(entry)) {
        this.errorText = this.t('upstreamDnsInvalid');
        return;
      }
    }
    const cleaned: string[] = [];
    for (const entry of entries) {
      if (!cleaned.includes(entry)) {
        cleaned.push(entry);
      }
    }
    const text: string = cleaned.join('\n');
    this.upstreamDnsInput = text;
    this.savePersistState();
    this.errorText = '';
    this.writeTextFile(this.upstreamDnsFilePath, text);
    this.appendDebugLog(`==/vpn_ui/upstream_set/ upstream=${text.length > 0 ? cleaned.join(',') : DEFAULT_UPSTREAM_DNS_IP}`);
    try {
      this.ensurePromptAction()?.showToast({ message: this.t('upstreamDnsApplied') });
    } catch (_) {
    }
  }

  private parseLogRetentionDaysInput(value: string): number {
    const trimmed: string = value.trim();
    if (trimmed.length === 0) {
      return DEFAULT_LOG_RETENTION_DAYS;
    }
    const parsed = parseInt(trimmed, 10);
    if (!Number.isFinite(parsed) || parsed < 0) {
      return DEFAULT_LOG_RETENTION_DAYS;
    }
    return parsed;
  }

  private updateLogRetentionDays(value: string): void {
    this.logRetentionDaysInput = value;
    this.logRetentionDays = this.parseLogRetentionDaysInput(value);
    this.savePersistState();
  }

  private parseLogMaxSizeMbInput(value: string): number {
    const trimmed: string = value.trim();
    if (trimmed.length === 0) {
      return DEFAULT_LOG_MAX_SIZE_MB;
    }
    const parsed = parseInt(trimmed, 10);
    if (!Number.isFinite(parsed) || parsed < 0) {
      return DEFAULT_LOG_MAX_SIZE_MB;
    }
    return parsed;
  }

  private updateLogMaxSizeMb(value: string): void {
    this.logMaxSizeMbInput = value;
    this.logMaxSizeMb = this.parseLogMaxSizeMbInput(value);
    this.savePersistState();
  }

  private updateClearDnsLogOnStart(value: boolean): void {
    this.clearDnsLogOnStart = value;
    this.savePersistState();
  }

  private updateClearDebugLogOnStart(value: boolean): void {
    this.clearDebugLogOnStart = value;
    this.savePersistState();
  }

  // Toggle between the lightweight C++ engine and the full embedded AdGuardHome
  // engine. The mode is read by the VPN extension at start. If the filter is
  // already running, restart it so the new mode applies immediately.
  private updateFullModeEnabled(value: boolean): void {
    this.fullModeEnabled = value;
    this.savePersistState();
    if (this.busy) {
      return;
    }
    // Restart the active mode so the new engine applies immediately.
    if (this.proxyModeEnabled) {
      if (this.dnsProxyRunning) {
        this.startDnsProxy();
      }
    } else if (this.status.running) {
      this.startVpn();
    }
  }

  // Quick engine switch surfaced on the home Hero dropdown. Sets the lightweight
  // or full (AdGuardHome) engine and shows a short confirmation toast.
  private setEngineFullMode(full: boolean): void {
    if (this.fullModeEnabled === full) {
      return;
    }
    this.updateFullModeEnabled(full);
    const message: string = full
      ? this.tri('Switched to full engine · powerful & fully compatible',
          '已切换为完整模式内核 · 功能强大，完全兼容',
          '已切換為完整模式核心 · 功能強大，完全相容')
      : this.tri('Switched to lightweight engine · power-saving & fast',
          '已切换为轻量级内核 · 优化省电，快速响应',
          '已切換為輕量級核心 · 優化省電，快速回應');
    try {
      this.ensurePromptAction()?.showToast({ message, duration: 2000 });
    } catch (_) {
    }
  }

  private engineModeLabel(): string {
    return this.fullModeEnabled
      ? this.tri('🔒 Full', '🔒 完整', '🔒 完整')
      : this.tri('⚡ Lite', '⚡ 轻量', '⚡ 輕量');
  }

  // Whether the currently selected network mode is running. VPN mode tracks the
  // extension's status.json; DNS-proxy mode tracks the in-process server flag.
  private activeRunning(): boolean {
    return this.proxyModeEnabled ? this.dnsProxyRunning : this.status.running;
  }

  // Switch the home network mode. Only allowed while nothing is running (the
  // segmented control is disabled otherwise), so the two modes never overlap.
  private setNetworkProxyMode(proxy: boolean): void {
    if (this.proxyModeEnabled === proxy) {
      return;
    }
    this.proxyModeEnabled = proxy;
    this.savePersistState();
  }

  // The validated DNS-proxy listen port (1024-65535). Falls back to the default
  // when the field is empty or out of range; the unprivileged app cannot bind
  // ports below 1024.
  private dnsProxyPortNumber(): number {
    const p: number = parseInt(this.dnsProxyPort.trim(), 10);
    if (Number.isFinite(p) && p >= DNS_PROXY_PORT_MIN && p <= DNS_PROXY_PORT_MAX) {
      return p;
    }
    return AGH_DNS_PORT;
  }

  // Persist an edited DNS-proxy port, with inline validation feedback.
  private onDnsProxyPortChange(value: string): void {
    this.dnsProxyPort = value;
    const trimmed: string = value.trim();
    const p: number = parseInt(trimmed, 10);
    if (trimmed.length === 0 || !Number.isFinite(p) || p < DNS_PROXY_PORT_MIN || p > DNS_PROXY_PORT_MAX) {
      this.dnsProxyPortFeedback = this.t('dnsProxyPortInvalid');
    } else {
      this.dnsProxyPortFeedback = '';
    }
    this.savePersistState();
  }

  // The validated AdGuardHome web panel port (full engine only). Falls back to
  // the default when empty/out of range. Conflicts with the DNS port are only a
  // UI warning; if ignored, AdGuardHome surfaces a bind error on start.
  private aghHttpPortNumber(): number {
    const p: number = parseInt(this.aghHttpPort.trim(), 10);
    if (Number.isFinite(p) && p >= DNS_PROXY_PORT_MIN && p <= DNS_PROXY_PORT_MAX) {
      return p;
    }
    return AGH_HTTP_PORT;
  }

  // The loopback port to display/use for the DNS proxy: the actual bound port
  // while running, otherwise the configured one.
  private displayedDnsPort(): number {
    return (this.dnsProxyRunning && this.dnsProxyActivePort > 0) ? this.dnsProxyActivePort : this.dnsProxyPortNumber();
  }

  // The effective AdGuardHome panel port for opening the dashboard.
  private effectiveHttpPort(): number {
    return (this.dnsProxyRunning && this.aghActiveHttpPort > 0) ? this.aghActiveHttpPort : this.aghHttpPortNumber();
  }

  // Probe whether a loopback TCP port is free by trying to listen on it, then
  // releasing it. Resolves true if free (or if probing is unavailable, so the
  // real bind makes the final call), false if the port is in use.
  private isTcpPortFree(port: number): Promise<boolean> {
    return new Promise<boolean>((resolve: (free: boolean) => void) => {
      try {
        const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
        const addr: socket.NetAddress = { address: '127.0.0.1', port: port, family: 1 };
        server.listen(addr).then(() => {
          server.close().then(() => {
            resolve(true);
          }).catch(() => {
            resolve(true);
          });
        }).catch(() => {
          resolve(false);
        });
      } catch (_) {
        resolve(true);
      }
    });
  }

  // Find the first free loopback TCP port at or above startPort (scanning up to
  // maxTries ports). Falls back to startPort when none is found in range — the
  // real start then surfaces the bind error normally.
  private async findFreeTcpPort(startPort: number, maxTries: number): Promise<number> {
    for (let i = 0; i < maxTries; i++) {
      const p: number = startPort + i;
      if (p > DNS_PROXY_PORT_MAX) {
        break;
      }
      const free: boolean = await this.isTcpPortFree(p);
      if (free) {
        return p;
      }
    }
    return startPort;
  }

  // Persist an edited panel port, with inline validation feedback (range + must
  // differ from the DNS-proxy port).
  private onAghHttpPortChange(value: string): void {
    this.aghHttpPort = value;
    const trimmed: string = value.trim();
    const p: number = parseInt(trimmed, 10);
    if (trimmed.length === 0 || !Number.isFinite(p) || p < DNS_PROXY_PORT_MIN || p > DNS_PROXY_PORT_MAX) {
      this.aghHttpPortFeedback = this.t('dnsProxyPortInvalid');
    } else if (p === this.dnsProxyPortNumber()) {
      this.aghHttpPortFeedback = this.t('aghPanelPortConflict');
    } else {
      this.aghHttpPortFeedback = '';
    }
    this.savePersistState();
  }

  // Whether a recommended preset list is already present in the subscriptions.
  private subscriptionPresetActive(url: string): boolean {
    return this.filterSubscriptions.some((s: FilterSubscription) => s.url === url);
  }

  // Shown when a user taps a full-engine-only settings row while the lightweight
  // engine is selected.
  private notifyFullEngineRequired(): void {
    try {
      this.ensurePromptAction()?.showToast({
        message: this.tri('Enable the full engine on Home first',
          '请先在首页切换为「完整」引擎', '請先在首頁切換為「完整」引擎')
      });
    } catch (_) {
    }
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
    let hasBlockRule: boolean = false;
    for (const profile of this.normalizeRuleProfiles(this.ruleProfiles)) {
      const lines: string[] = this.ruleProfileLines(profile.content);
      if (lines.includes(allowRule)) {
        return 'allow';
      }
      if (lines.includes(blockRule)) {
        hasBlockRule = true;
      }
    }
    return hasBlockRule ? 'block' : 'none';
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
      if (!profile.builtIn) {
        return profile;
      }
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
    if (this.builtInRuleEditorActive()) {
      this.addRuleLineToEditor();
    }
    const next: RuleProfile[] = [];
    let changed = false;
    this.ruleProfiles.forEach((profile: RuleProfile) => {
      if (profile.id === this.editingRuleProfileId) {
        const nextContent: string = this.normalizeRuleContent(this.rulesText);
        next.push({
          id: profile.id,
          name: profile.name,
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
    const content = await this.dnsExportTextAsync();
    if (content.trim().length === 0) {
      this.dnsSheetFeedbackText = this.t('noDnsRequestsToCopy');
      return;
    }
    await this.copyText(content);
    this.dnsSheetFeedbackText = this.t('dnsRequestsCopied', this.dnsFilteredCount);
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

  // Total number of pages for the current filter/search (at least 1). The count
  // comes from SQL over the whole table, so it's correct regardless of which page
  // is currently loaded.
  private dnsTotalPages(): number {
    return Math.max(1, Math.ceil(this.dnsFilteredCount / DNS_PAGE_SIZE));
  }

  // Current page index, clamped into range (the filtered set can shrink when a
  // filter/search is applied while on a later page).
  private clampedDnsPage(): number {
    return Math.min(Math.max(0, this.dnsPage), this.dnsTotalPages() - 1);
  }

  // The current page of events. queryEvents already holds exactly the SQL page for
  // the active filter/search (newest first), so just return it.
  private pagedQueryEvents(): QueryLogEntry[] {
    return this.queryEvents;
  }

  private queryEntryText(item: QueryLogEntry): string {
    const requestBytes: number = item.requestBytes ?? 0;
    const responseBytes: number = item.responseBytes ?? 0;
    const totalDnsBytes: number = item.totalDnsBytes ?? (requestBytes + responseBytes);
    const ruleText: string = item.rule && item.rule.trim().length > 0 ? item.rule : this.t('none');
    return `${item.domain}\t${item.qtype}\t${item.action}\t${this.querySourceText(item.source)}\t${ruleText}\t${requestBytes}/${responseBytes}/${totalDnsBytes}\t${item.ts}`;
  }

  private querySourceText(source?: string): string {
    switch ((source ?? '').trim().toLowerCase()) {
      case 'cache':
        return this.t('sourceCache');
      case 'blocked':
        return this.t('sourceBlocked');
      case 'upstream':
      default:
        return this.t('sourceUpstream');
    }
  }

  // Build export text from all rows matching the current filter/search (capped),
  // queried fresh from the DB rather than the loaded page.
  private async dnsExportTextAsync(): Promise<string> {
    if (!this.dnsDbReady) {
      return '';
    }
    const rows: DnsLogRow[] = await dnsLogDb.allFiltered(this.dnsActionFilter, this.dnsSearchText, 50000);
    return rows.map((r: DnsLogRow) => this.queryEntryText(this.rowToEntry(r))).join('\n');
  }

  private dnsSheetCountText(): string {
    return `${this.dnsFilteredCount} ${this.t('lines')}`;
  }

  private domainSheetCountText(): string {
    return `${this.orderedDomainStats().length} ${this.t('lines')}`;
  }

  private topDomainStats(limit: number = 5): DomainQueryStats[] {
    const map: Map<string, DomainQueryStats> = new Map<string, DomainQueryStats>();
    for (const item of this.recentRows) {
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
          cacheHits: 0,
          upstreamQueries: 0,
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
      const source: string = (item.source ?? '').trim().toLowerCase();
      if (source === 'cache') {
        stats.cacheHits += 1;
      } else if (source === 'upstream') {
        stats.upstreamQueries += 1;
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
    return `${item.domain}\t${item.total}\t${item.allowed}\t${item.blocked}\t${item.cacheHits}\t${item.upstreamQueries}\t${item.requestBytes}/${item.responseBytes}/${item.totalDnsBytes}\t${item.lastTs}`;
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
    const content = await this.dnsExportTextAsync();
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
    // Wipe the DB too. The app jsonl is now empty; for AGH (full-proxy) skip its
    // pre-existing history by parking the watermark/offset at the current file end
    // so only post-clear entries get re-ingested.
    dnsLogDb.clear().catch(() => {
    });
    this.appLogOffset = 0;
    this.appLogLastTs = 0;
    this.aghLogLastTs = Date.now();
    this.aghLogOffset = this.readTextFile(this.aghQueryLogPath()).length;
    this.queryEvents = [];
    this.recentRows = [];
    this.querySummary = defaultQuerySummary();
    this.dnsFilteredCount = 0;
    this.dnsSheetFeedbackText = this.t('dnsRequestsCleared');
    this.keepAliveStatusText = this.t('dnsRequestsCleared');
    this.dnsSearchText = '';
    this.dnsActionFilter = 'all';
    this.domainActionFilter = 'all';
    this.dnsPage = 0;
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
    const baseName: string = this.sanitizeExportBaseName(this.editingRuleProfile()?.name ?? this.editingRuleNameText,
      'filters');
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
    // First launch (or after data clear / reinstall): require accepting the
    // disclaimer before the app can be used; declining exits the app.
    if (!this.disclaimerAccepted) {
      this.showFirstRunDisclaimer = true;
    }
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
    this.syncDnsProxyRunning();
    this.initDnsDb().catch(() => {
    });
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
    this.upstreamDnsFilePath = `${vpnDir}/${UPSTREAM_DNS_FILE_NAME}`;
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
        upstreamDnsFilePath: this.upstreamDnsFilePath,
        dnsCacheTtlSeconds: this.dnsCacheTtlSeconds,
        logRetentionDays: this.logRetentionDays,
        logMaxSizeMb: this.logMaxSizeMb,
        clearDnsLogOnStart: this.clearDnsLogOnStart,
        clearDebugLogOnStart: this.clearDebugLogOnStart,
        filterMode: this.fullModeEnabled ? 'full' : 'lightweight',
        aghFiltersJson: JSON.stringify(this.filterSubscriptions),
        aghRewritesJson: JSON.stringify(this.dnsRewrites),
        aghAdvancedJson: JSON.stringify(this.advancedDns),
        aghHttpPort: this.aghHttpPortNumber(),
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
      if (typeof state.upstreamDnsIp === 'string') {
        this.upstreamDnsInput = state.upstreamDnsIp.trim();
      }
      if (typeof state.dnsCacheTtlSeconds === 'number' && Number.isFinite(state.dnsCacheTtlSeconds)
        && state.dnsCacheTtlSeconds >= 0) {
        this.dnsCacheTtlSeconds = Math.floor(state.dnsCacheTtlSeconds);
        this.dnsCacheTtlInput = `${this.dnsCacheTtlSeconds}`;
      } else {
        this.dnsCacheTtlSeconds = DEFAULT_DNS_CACHE_TTL_SECONDS;
        this.dnsCacheTtlInput = `${DEFAULT_DNS_CACHE_TTL_SECONDS}`;
      }
      if (typeof state.logRetentionDays === 'number' && Number.isFinite(state.logRetentionDays)
        && state.logRetentionDays >= 0) {
        this.logRetentionDays = Math.floor(state.logRetentionDays);
        this.logRetentionDaysInput = `${this.logRetentionDays}`;
      } else {
        this.logRetentionDays = DEFAULT_LOG_RETENTION_DAYS;
        this.logRetentionDaysInput = `${DEFAULT_LOG_RETENTION_DAYS}`;
      }
      if (typeof state.logMaxSizeMb === 'number' && Number.isFinite(state.logMaxSizeMb)
        && state.logMaxSizeMb >= 0) {
        this.logMaxSizeMb = Math.floor(state.logMaxSizeMb);
        this.logMaxSizeMbInput = `${this.logMaxSizeMb}`;
      } else {
        this.logMaxSizeMb = DEFAULT_LOG_MAX_SIZE_MB;
        this.logMaxSizeMbInput = `${DEFAULT_LOG_MAX_SIZE_MB}`;
      }
      if (typeof state.clearDnsLogOnStart === 'boolean') {
        this.clearDnsLogOnStart = state.clearDnsLogOnStart;
      }
      if (typeof state.clearDebugLogOnStart === 'boolean') {
        this.clearDebugLogOnStart = state.clearDebugLogOnStart;
      }
      if (typeof state.fullModeEnabled === 'boolean') {
        this.fullModeEnabled = state.fullModeEnabled;
      }
      if (typeof state.proxyModeEnabled === 'boolean') {
        this.proxyModeEnabled = state.proxyModeEnabled;
      }
      if (typeof state.dnsProxyPort === 'string' && state.dnsProxyPort.length > 0) {
        this.dnsProxyPort = state.dnsProxyPort;
      }
      if (typeof state.aghHttpPort === 'string' && state.aghHttpPort.length > 0) {
        this.aghHttpPort = state.aghHttpPort;
      }
      if (Array.isArray(state.blockedServiceIds)) {
        const ids: string[] = [];
        state.blockedServiceIds.forEach((x: string) => {
          if (typeof x === 'string' && x.length > 0 && !ids.includes(x)) {
            ids.push(x);
          }
        });
        this.blockedServiceIds = ids;
      }
      if (Array.isArray(state.filterSubscriptions)) {
        const subs: FilterSubscription[] = [];
        state.filterSubscriptions.forEach((s: FilterSubscription, index: number) => {
          const url: string = typeof s?.url === 'string' ? s.url.trim() : '';
          if (url.length === 0) {
            return;
          }
          subs.push({
            id: typeof s?.id === 'number' && s.id > 0 ? Math.floor(s.id) : index + 1,
            name: typeof s?.name === 'string' && s.name.trim().length > 0 ? s.name.trim() : url,
            url: url,
            enabled: s?.enabled !== false,
          });
        });
        this.filterSubscriptions = subs;
      }
      if (Array.isArray(state.dnsRewrites)) {
        const rws: DnsRewriteRule[] = [];
        state.dnsRewrites.forEach((r: DnsRewriteRule) => {
          const domain: string = typeof r?.domain === 'string' ? r.domain.trim() : '';
          const answer: string = typeof r?.answer === 'string' ? r.answer.trim() : '';
          if (domain.length === 0 || answer.length === 0) {
            return;
          }
          rws.push({ domain: domain, answer: answer });
        });
        this.dnsRewrites = rws;
      }
      if (state.advancedDns !== undefined && state.advancedDns !== null) {
        this.advancedDns = this.normalizeAdvancedDns(state.advancedDns);
      }
      if (typeof state.disclaimerAccepted === 'boolean') {
        this.disclaimerAccepted = state.disclaimerAccepted;
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
      upstreamDnsIp: this.upstreamDnsInput,
      logRetentionDays: this.logRetentionDays,
      logMaxSizeMb: this.logMaxSizeMb,
      clearDnsLogOnStart: this.clearDnsLogOnStart,
      clearDebugLogOnStart: this.clearDebugLogOnStart,
      fullModeEnabled: this.fullModeEnabled,
      proxyModeEnabled: this.proxyModeEnabled,
      dnsProxyPort: this.dnsProxyPort,
      aghHttpPort: this.aghHttpPort,
      blockedServiceIds: this.blockedServiceIds,
      filterSubscriptions: this.filterSubscriptions,
      dnsRewrites: this.dnsRewrites,
      advancedDns: this.advancedDns,
      disclaimerAccepted: this.disclaimerAccepted,
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
      this.stopping = false;
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
      if (!this.status.running) {
        this.stopping = false;
      }
      this.errorText = '';
    } catch (err) {
      this.errorText = this.errorMessage(err);
      hilog.error(DOMAIN, TAG, '==/vpn_ui/status_parse_error/ %{public}s', this.errorText);
    }
  }

  // Open the "recent DNS requests" sheet pre-filtered to a tab (used by the home
  // allowed/blocked stat cards so a tap jumps straight to that filter).
  private openDnsSheetWithFilter(filter: QueryActionFilter): void {
    this.dnsActionFilter = filter;
    this.dnsPage = 0;
    this.dnsSheetFeedbackText = '';
    this.showDnsSheet = true;
    this.refreshQueryLog();
  }

  // Kick off the async RDB-backed refresh (ingest new jsonl/AGH lines, then query
  // counts + the current page + the leaderboard window). Kept synchronous-named so
  // the refresh timer and filter/search/page handlers can call it fire-and-forget.
  private refreshQueryLog(): void {
    if (this.suppressRuntimeArtifacts) {
      this.queryEvents = [];
      this.recentRows = [];
      this.querySummary = defaultQuerySummary();
      this.dnsFilteredCount = 0;
      return;
    }
    this.refreshDnsLogAsync().catch(() => {
    });
  }

  // One-time RDB init: open the store and seed per-origin ingest watermarks from
  // what's already stored, so a relaunch re-scan re-inserts only new rows.
  private async initDnsDb(): Promise<void> {
    if (this.dnsDbReady || this.dnsDbInitStarted) {
      return;
    }
    this.dnsDbInitStarted = true;
    const ok: boolean = await dnsLogDb.init(this.getHostContext());
    if (!ok) {
      this.dnsDbInitStarted = false;
      return;
    }
    this.appLogLastTs = await dnsLogDb.maxTs('app');
    this.aghLogLastTs = await dnsLogDb.maxTs('agh');
    this.appLogOffset = 0;
    this.aghLogOffset = 0;
    // Apply the configured retention to the DB once at startup (the jsonl has its
    // own rotation; the DB keeps its own history bounded the same way).
    if (this.logRetentionDays > 0) {
      await dnsLogDb.pruneOlderThan(Date.now() - this.logRetentionDays * 24 * 60 * 60 * 1000);
    }
    this.dnsDbReady = true;
    this.refreshDnsLogAsync().catch(() => {
    });
  }

  private async refreshDnsLogAsync(): Promise<void> {
    if (this.suppressRuntimeArtifacts) {
      return;
    }
    if (!this.dnsDbReady) {
      await this.initDnsDb();
      if (!this.dnsDbReady) {
        return;
      }
    }
    if (this.dnsRefreshing) {
      return;
    }
    this.dnsRefreshing = true;
    try {
      // Pick the log source by engine, not by network mode. In full mode (VPN or
      // proxy) AdGuardHome does the filtering and records the accurate result
      // (incl. blocked) in its own querylog; the C++ relay's app jsonl would mark
      // every full-mode query "allowed". In lightweight mode the C++ engine writes
      // the accurate app jsonl itself. The AGH querylog path is shared by both the
      // VPN extension and the main process (same app filesDir).
      if (this.fullModeEnabled) {
        await this.ingestAghLog();
      } else {
        await this.ingestAppLog();
      }

      const filter: string = this.dnsActionFilter;
      const search: string = this.dnsSearchText;
      const summary = await dnsLogDb.summary();
      const count: number = await dnsLogDb.countFor(filter, search);
      const totalPages: number = Math.max(1, Math.ceil(count / DNS_PAGE_SIZE));
      const page: number = Math.min(Math.max(0, this.dnsPage), totalPages - 1);
      const rows: DnsLogRow[] = await dnsLogDb.page(filter, search, DNS_PAGE_SIZE, page * DNS_PAGE_SIZE);
      const recent: DnsLogRow[] = await dnsLogDb.recentRows(MAX_QUERY_EVENTS);

      this.querySummary = {
        total: summary.total,
        allowed: summary.allowed,
        blocked: summary.blocked,
        lastDomain: summary.lastDomain,
        lastRule: summary.lastRule,
        requestBytes: summary.requestBytes,
        responseBytes: summary.responseBytes,
        totalDnsBytes: summary.totalDnsBytes,
      };
      this.dnsFilteredCount = count;
      this.queryEvents = rows.map((r: DnsLogRow) => this.rowToEntry(r));
      this.recentRows = recent.map((r: DnsLogRow) => this.rowToEntry(r));
    } finally {
      this.dnsRefreshing = false;
    }
  }

  private rowToEntry(r: DnsLogRow): QueryLogEntry {
    return {
      ts: r.ts,
      domain: r.domain,
      qtype: r.qtype,
      action: r.action,
      rule: r.rule,
      source: r.source,
      requestBytes: r.requestBytes,
      responseBytes: r.responseBytes,
      totalDnsBytes: r.totalDnsBytes,
    };
  }

  private aghQueryLogPath(): string {
    const vpnDir: string = `${this.getHostContext().filesDir}/${VPN_DIR_NAME}`;
    return `${vpnDir}/${AGH_WORK_DIR_NAME}/data/querylog.json`;
  }

  // Read the appended tail of the app jsonl and insert new rows. On shrink (clear
  // / rotation) the whole file is re-scanned but the ts watermark skips rows
  // already stored, so no duplicates.
  private async ingestAppLog(): Promise<void> {
    const raw: string = this.readTextFile(this.queryLogFilePath);
    if (raw.length < this.appLogOffset) {
      this.appLogOffset = 0;  // file shrank: cleared or rotated
    }
    if (raw.length <= this.appLogOffset) {
      return;
    }
    const slice: string = raw.substring(this.appLogOffset);
    const lastNl: number = slice.lastIndexOf('\n');
    if (lastNl < 0) {
      return;  // no complete new line yet
    }
    const chunk: string = slice.substring(0, lastNl);
    const newOffset: number = this.appLogOffset + lastNl + 1;
    const rows: DnsLogRow[] = [];
    let maxTs: number = this.appLogLastTs;
    for (const line of chunk.split('\n')) {
      const t: string = line.trim();
      if (t.length === 0) {
        continue;
      }
      const row: DnsLogRow | undefined = this.parseAppLogLine(t);
      if (row === undefined || row.ts <= this.appLogLastTs) {
        continue;
      }
      rows.push(row);
      if (row.ts > maxTs) {
        maxTs = row.ts;
      }
    }
    this.appLogOffset = newOffset;
    if (rows.length > 0) {
      await dnsLogDb.insertRows(rows, 'app');
      this.appLogLastTs = maxTs;
    }
  }

  private async ingestAghLog(): Promise<void> {
    const raw: string = this.readTextFile(this.aghQueryLogPath());
    if (raw.length < this.aghLogOffset) {
      this.aghLogOffset = 0;
    }
    if (raw.length <= this.aghLogOffset) {
      return;
    }
    const slice: string = raw.substring(this.aghLogOffset);
    const lastNl: number = slice.lastIndexOf('\n');
    if (lastNl < 0) {
      return;
    }
    const chunk: string = slice.substring(0, lastNl);
    const newOffset: number = this.aghLogOffset + lastNl + 1;
    const rows: DnsLogRow[] = [];
    let maxTs: number = this.aghLogLastTs;
    for (const line of chunk.split('\n')) {
      const t: string = line.trim();
      if (t.length === 0) {
        continue;
      }
      const row: DnsLogRow | undefined = this.parseAghLogLine(t);
      if (row === undefined || row.ts <= this.aghLogLastTs) {
        continue;
      }
      rows.push(row);
      if (row.ts > maxTs) {
        maxTs = row.ts;
      }
    }
    this.aghLogOffset = newOffset;
    if (rows.length > 0) {
      await dnsLogDb.insertRows(rows, 'agh');
      this.aghLogLastTs = maxTs;
    }
  }

  private parseAppLogLine(line: string): DnsLogRow | undefined {
    try {
      const e = JSON.parse(line) as QueryLogEntry;
      const req: number = e.requestBytes ?? 0;
      const resp: number = e.responseBytes ?? 0;
      return {
        ts: e.ts,
        domain: e.domain,
        qtype: e.qtype,
        action: e.action,
        rule: e.rule,
        source: e.source ?? '',
        requestBytes: req,
        responseBytes: resp,
        totalDnsBytes: e.totalDnsBytes ?? (req + resp),
      };
    } catch (_) {
      return undefined;
    }
  }

  private parseAghLogLine(line: string): DnsLogRow | undefined {
    try {
      const e = JSON.parse(line) as AghQueryLogLine;
      const domain: string = (e.QH ?? '').trim();
      if (domain.length === 0) {
        return undefined;
      }
      const tsMs: number = e.T !== undefined ? Date.parse(e.T) : 0;
      // AdGuardHome marks a query blocked via the Reason code, not only IsFiltered
      // (which is omitted/false for e.g. blocked-services hits): FilteredBlockList(3)
      // .. FilteredBlockedService(8) count as blocked; Rewritten(9-11) and
      // NotFiltered(0-2) do not.
      const reason: number = e.Result?.Reason ?? 0;
      const blocked: boolean = (reason >= 3 && reason <= 8) || e.Result?.IsFiltered === true;
      // AdGuardHome marks cache hits with a top-level Cached flag (omitted/false
      // for upstream-resolved). Map it to our source so the cache-hit stat works
      // in full mode too.
      const cached: boolean = e.Cached === true;
      let rule: string = '';
      const rules: AghQueryLogRule[] | undefined = e.Result?.Rules;
      if (rules !== undefined && rules.length > 0 && typeof rules[0]?.Text === 'string') {
        rule = rules[0].Text as string;
      }
      // AGH stores the base64 response in Answer; approximate the response size
      // from it (it does not record the request size).
      const respBytes: number = typeof e.Answer === 'string' ? Math.floor(e.Answer.length * 3 / 4) : 0;
      return {
        ts: Number.isFinite(tsMs) ? tsMs : 0,
        domain: domain,
        qtype: e.QT ?? '',
        action: blocked ? 'blocked' : 'allowed',
        rule: rule,
        source: blocked ? 'blocked' : (cached ? 'cache' : 'upstream'),
        requestBytes: 0,
        responseBytes: respBytes,
        totalDnsBytes: respBytes,
      };
    } catch (_) {
      return undefined;
    }
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

    // Warn (and let the user decide) when no background keep-alive is enabled —
    // in either mode filtering can be killed once the app is backgrounded.
    if (!(await this.confirmStartWithoutKeepAlive())) {
      return;
    }

    // Free the loopback DNS port if the experimental DNS-proxy server is running
    // in this process, so the VPN extension can bind it.
    if (this.dnsProxyRunning) {
      await this.stopDnsProxy();
    }

    this.busy = true;
    this.errorText = '';
    const wasRunning: boolean = this.status.running;
    try {
      if (!this.writeTextFile(this.rulesFilePath, this.rulesText)) {
        throw new Error('Failed to write rules file');
      }
      this.writeTextFile(this.upstreamDnsFilePath, this.upstreamDnsInput.trim());
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
      const requestMessage: string = wasRunning ? this.t('restartRequested') : this.t('startRequested');
      this.status = this.updatedStatus(
        'starting',
        requestMessage
      );
      if (wasRunning) {
        try {
          this.ensurePromptAction()?.showToast({ message: requestMessage });
        } catch (_) {
        }
      }
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
    // DNS-proxy mode runs a local server with no VPN, so it needs no VPN
    // authorization probe — enabling auto-start is always allowed there.
    if (this.proxyModeEnabled) {
      return true;
    }
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
    // Resume whichever network mode was last selected (persisted), not always
    // VPN. activeRunning() is mode-aware so we don't re-start something already up.
    if (this.autoStartAttempted || !this.autoStartFilterEnabled || this.busy || this.activeRunning()) {
      return;
    }
    this.autoStartAttempted = true;
    if (this.proxyModeEnabled) {
      await this.startDnsProxy();
    } else {
      await this.startVpn();
    }
  }

  private async stopVpn(): Promise<void> {
    if (this.busy) {
      return;
    }

    this.busy = true;
    // Surface the teardown immediately: the system VPN takes a moment to close,
    // so flag `stopping` now and keep it until the status file reports not
    // running (cleared in refreshStatus). The button greys out and the restart
    // button hides while this is true, instead of briefly flipping back.
    this.stopping = true;
    this.errorText = '';
    try {
      this.ensurePromptAction()?.showToast({ message: this.t('stopping') });
    } catch (_) {
    }
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
      this.stopping = false;
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
    this.setConfigFeedback(this.status.running ? this.t('rulesSavedApplied') : this.t('rulesSavedSuccess'));
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

  // Open the embedded AdGuardHome dashboard in the system browser instead of the
  // in-app webview (easier to operate). The AGH HTTP server listens on device
  // loopback, which is reachable by the browser on the same device.
  private openAghInBrowser(): void {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: `http://127.0.0.1:${this.effectiveHttpPort()}`
    };
    this.getHostContext().startAbility(want).catch((err: BusinessError) => {
      this.errorText = this.errorMessage(err);
      this.appendDebugLog(`==/vpn_ui/open_agh_browser_error/ ${this.errorMessage(err)}`);
    });
  }

  // ---- Experimental DNS server / coexist mode (no VPN) ---------------------
  // Build a minimal AdGuardHome.yaml for the standalone DNS server. AdGuardHome
  // unmarshals this onto its built-in defaults, so we only emit the loopback
  // binds, our upstreams, enabled online subscriptions, and the user rules.
  // (Thin validation slice: DNS rewrites / advanced DNS are not wired here yet.)
  private buildAghProxyYaml(dnsPort: number, httpPort: number): string {
    const yamlQuote = (value: string): string => `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

    const upstreams: string[] = [];
    for (const raw of this.upstreamDnsInput.split(/[\s,;\n]+/)) {
      const ip: string = raw.trim();
      if (ip.length > 0 && !upstreams.includes(ip)) {
        upstreams.push(ip);
      }
    }
    if (upstreams.length === 0) {
      upstreams.push(DEFAULT_UPSTREAM_DNS_IP);
    }
    const upstreamLines: string = upstreams.map((u: string) => `    - ${yamlQuote(u)}`).join('\n');

    const rules: string[] = [];
    for (const rawLine of this.rulesText.split('\n')) {
      const line: string = rawLine.trim();
      if (line.length > 0) {
        rules.push(line);
      }
    }
    const userRulesBlock: string = rules.length > 0
      ? `user_rules:\n${rules.map((r: string) => `  - ${yamlQuote(r)}`).join('\n')}`
      : 'user_rules: []';

    const enabledSubs: FilterSubscription[] = this.filterSubscriptions.filter(
      (s: FilterSubscription) => s.enabled && typeof s.url === 'string' && s.url.trim().length > 0);
    let filtersBlock: string;
    if (enabledSubs.length === 0) {
      filtersBlock = 'filters: []';
    } else {
      const entries: string[] = [];
      enabledSubs.forEach((s: FilterSubscription, i: number) => {
        const url: string = s.url.trim();
        entries.push('  - enabled: true');
        entries.push(`    url: ${yamlQuote(url)}`);
        entries.push(`    name: ${yamlQuote(s.name.length > 0 ? s.name : url)}`);
        entries.push(`    id: ${i + 1}`);
      });
      filtersBlock = `filters:\n${entries.join('\n')}`;
    }

    const lines: string[] = [
      `schema_version: ${AGH_SCHEMA_VERSION}`,
      'http:',
      `  address: 127.0.0.1:${httpPort}`,
      'dns:',
      '  bind_hosts:',
      '    - 127.0.0.1',
      `  port: ${dnsPort}`,
      '  upstream_dns:',
      upstreamLines,
      '  bootstrap_dns:',
      upstreamLines,
      // The proxy app funnels every query through the single 127.0.0.1 source, so
      // AdGuardHome's per-client rate limit would otherwise throttle the device.
      '  ratelimit: 0',
      filtersBlock,
      userRulesBlock,
      '',
    ];
    return lines.join('\n');
  }

  // Shared pre-start gate for BOTH modes (VPN and DNS-proxy): if no background
  // keep-alive is enabled, filtering can be killed once the app is backgrounded,
  // so warn and let the user decide. Resolves true to proceed, false to abort.
  private confirmStartWithoutKeepAlive(): Promise<boolean> {
    if (this.keepAliveModeList().length > 0) {
      return Promise.resolve(true);
    }
    return new Promise<boolean>((resolve: (proceed: boolean) => void) => {
      try {
        this.getUIContext().showAlertDialog({
          title: this.t('keepAliveWarnTitle'),
          message: this.t('keepAliveWarnMessage'),
          autoCancel: true,
          buttons: [
            {
              value: this.t('cancel'),
              action: () => {
                resolve(false);
              }
            },
            {
              value: this.t('continueLabel'),
              action: () => {
                resolve(true);
              }
            }
          ],
          cancel: () => {
            resolve(false);
          }
        });
      } catch (_) {
        // If the dialog cannot be shown for any reason, don't block the user.
        resolve(true);
      }
    });
  }

  private async startDnsProxy(): Promise<void> {
    if (this.busy) {
      return;
    }
    // The VPN extension (full mode) already owns 127.0.0.1:AGH_DNS_PORT; refuse to
    // double-bind. Stop VPN filtering on the Home page first.
    if (this.status.running) {
      try {
        this.ensurePromptAction()?.showToast({
          message: this.t('dnsProxyStopVpnFirst')
        });
      } catch (_) {
      }
      return;
    }

    // No VPN extension keeps this process alive in DNS-proxy mode, so a
    // continuous task must. Warn (and let the user decide) when none is enabled.
    if (!(await this.confirmStartWithoutKeepAlive())) {
      return;
    }

    this.busy = true;
    this.errorText = '';
    try {
      this.writeTextFile(this.rulesFilePath, this.rulesText);
      this.writeTextFile(this.upstreamDnsFilePath, this.upstreamDnsInput.trim());
      const upstream: string = this.upstreamDnsInput.trim().length > 0
        ? this.upstreamDnsInput.trim()
        : DEFAULT_UPSTREAM_DNS_IP;
      // Auto-skip busy ports: probe from the configured port upward for a free
      // loopback TCP port, so a port conflict doesn't fail the start. Full mode
      // also needs a free panel port (distinct from the DNS port).
      const configuredPort: number = this.dnsProxyPortNumber();
      const port: number = await this.findFreeTcpPort(configuredPort, 20);
      let httpPort: number = 0;
      if (this.fullModeEnabled) {
        const configuredHttp: number = this.aghHttpPortNumber();
        const httpStart: number = (configuredHttp === port) ? configuredHttp + 1 : configuredHttp;
        httpPort = await this.findFreeTcpPort(httpStart, 20);
        if (httpPort === port) {
          httpPort = await this.findFreeTcpPort(port + 1, 20);
        }
      }

      let err: string | undefined;
      if (this.fullModeEnabled) {
        // Full engine: AdGuardHome as a standalone DNS server (serves UDP + TCP).
        const vpnDir: string = `${this.getHostContext().filesDir}/${VPN_DIR_NAME}`;
        const cfgPath: string = `${vpnDir}/${AGH_CONFIG_FILE_NAME}`;
        const workDir: string = `${vpnDir}/${AGH_WORK_DIR_NAME}`;
        const logPath: string = `${vpnDir}/${AGH_LOG_FILE_NAME}`;
        this.writeTextFile(cfgPath, this.buildAghProxyYaml(port, httpPort));
        try {
          fileIo.mkdirSync(workDir, true);
        } catch (_) {
        }
        this.appendDebugLog(`==/vpn_ui/dns_proxy_start_request/ engine=full cfg=${cfgPath} port=${port}`);
        err = vpnclientbridge.startAghServerOnly(cfgPath, workDir, logPath, port);
      } else {
        // Lightweight engine: a DNS server (TCP + UDP) backed by the local matcher.
        this.appendDebugLog(`==/vpn_ui/dns_proxy_start_request/ engine=lite port=${port} upstream=${upstream}`);
        err = vpnclientbridge.startLwDnsServer('127.0.0.1', port, upstream,
          this.rulesFilePath, this.queryLogFilePath, this.dnsCacheTtlSeconds);
      }
      if (err !== undefined) {
        throw new Error(err);
      }

      // No VPN extension keeps this process alive, so the continuous task must.
      if (this.keepAliveModeList().length > 0) {
        await this.startLongTaskKeepAlive();
      }
      this.dnsProxyActivePort = port;
      this.aghActiveHttpPort = this.fullModeEnabled ? httpPort : 0;
      this.dnsProxyRunning = true;
      this.dnsProxyStatusText = this.t('dnsProxyRunningStatus', `tcp://127.0.0.1:${port}`);
      this.appendDebugLog(`==/vpn_ui/dns_proxy_started/ engine=${this.fullModeEnabled ? 'full' : 'lite'} port=${port} http=${httpPort}`);
      if (port !== configuredPort) {
        try {
          this.ensurePromptAction()?.showToast({ message: this.t('dnsProxyPortBumped', `${port}`) });
        } catch (_) {
        }
      }
    } catch (err) {
      const message: string = this.errorMessage(err);
      this.errorText = message;
      this.dnsProxyRunning = false;
      this.dnsProxyStatusText = message;
      this.appendDebugLog(`==/vpn_ui/dns_proxy_error/ ${message}`);
    } finally {
      this.busy = false;
    }
  }

  // Re-sync the DNS-proxy toggle with reality on (re)entry: AdGuardHome can keep
  // running in this (persistent, keep-alive) process across UI re-creations,
  // while dnsProxyRunning (a @State) resets to false. Read the native running
  // flag so the button shows the true state and a redundant stop/restart isn't
  // triggered on the next tap.
  private syncDnsProxyRunning(): void {
    try {
      const stats = JSON.parse(vpnclientbridge.getStats()) as AghProxyStats;
      const running: boolean = stats.running === true;
      this.dnsProxyRunning = running;
      if (running && this.dnsProxyStatusText.length === 0) {
        this.dnsProxyStatusText = this.t('dnsProxyRunningStatus', `tcp://127.0.0.1:${this.displayedDnsPort()}`);
      }
    } catch (_) {
    }
  }

  private async stopDnsProxy(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const err: string | undefined = vpnclientbridge.stopDnsFilter();
      if (err !== undefined) {
        this.appendDebugLog(`==/vpn_ui/dns_proxy_stop_error/ ${err}`);
      }
      await this.stopLongTaskKeepAlive(true);
      this.dnsProxyRunning = false;
      this.dnsProxyActivePort = 0;
      this.aghActiveHttpPort = 0;
      this.dnsProxyStatusText = this.t('dnsProxyStoppedStatus');
      this.appendDebugLog('==/vpn_ui/dns_proxy_stopped/');
    } catch (err) {
      this.appendDebugLog(`==/vpn_ui/dns_proxy_stop_exception/ ${this.errorMessage(err)}`);
    } finally {
      this.busy = false;
    }
  }

  // One copyable "<scheme>://127.0.0.1:<port>" address row. Both engines listen
  // on TCP and UDP at the loopback address, so we surface both schemes.
  @Builder
  DnsProxyAddressRow(scheme: string) {
    Row({ space: 8 }) {
      Text(`${scheme}://127.0.0.1:${this.displayedDnsPort()}`)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
      Blank()
      Button(this.t('copy'))
        .fontSize(12)
        .height(28)
        .backgroundColor(Color.Transparent)
        .fontColor('#2B5B95')
        .onClick(() => {
          this.copyText(`${scheme}://127.0.0.1:${this.displayedDnsPort()}`);
          try {
            this.ensurePromptAction()?.showToast({ message: this.t('dnsProxyCopied') });
          } catch (_) {
          }
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  DnsProxyCard() {
    Column({ space: 8 }) {
      this.SettingsGroupTitle({ text: this.t('dnsProxyTitle') })
      Column({ space: 10 }) {
        Text(this.t('dnsProxyDesc'))
          .fontSize(12)
          .lineHeight(18)
          .fontColor(this.secondaryTextColor())
          .width('100%')

        Text(this.fullModeEnabled ? this.t('dnsProxyEngineFull') : this.t('dnsProxyEngineLite'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#2B5B95')
          .width('100%')

        this.DnsProxyAddressRow('tcp')
        this.DnsProxyAddressRow('udp')

        Button(this.dnsProxyRunning ? this.t('dnsProxyStop') : this.t('dnsProxyStart'))
          .width('100%')
          .height(44)
          .backgroundColor(this.dnsProxyRunning ? '#C0392B' : '#2B5B95')
          .fontColor(Color.White)
          .enabled(!this.busy)
          .onClick(() => {
            if (this.dnsProxyRunning) {
              this.stopDnsProxy().catch((err: BusinessError) => {
                this.appendDebugLog(`==/vpn_ui/dns_proxy_stop_click_error/ ${this.errorMessage(err)}`);
              });
            } else {
              this.startDnsProxy().catch((err: BusinessError) => {
                this.appendDebugLog(`==/vpn_ui/dns_proxy_start_click_error/ ${this.errorMessage(err)}`);
              });
            }
          })

        if (this.dnsProxyStatusText.length > 0) {
          Text(this.dnsProxyStatusText)
            .fontSize(12)
            .fontColor(this.mutedTextColor())
            .width('100%')
        }

        if (this.dnsProxyRunning && this.fullModeEnabled) {
          Row({ space: 12 }) {
            this.SettingsIconText({ glyph: '⌘', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA',
              iconFg: '#2B5B95',
              title: this.t('dnsProxyDashboard'),
              desc: this.t('dnsProxyDashboardDesc') })
            Text('↗')
              .fontSize(18)
              .fontColor(this.secondaryTextColor())
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openAghInBrowser();
          })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(this.elevatedSurfaceTone())
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
      .borderRadius(22)
      .border({ width: 1, color: this.cardBorderTone() })
      .shadow({ radius: 12, color: this.cardShadowTone() })
      .linearGradient({
        angle: 145,
        colors: this.isDarkModeActive()
          ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
          : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private disclaimerText(): string {
    return this.tri(
      'This app is an on-device DNS filtering tool.\n\n• The built-in "blocked services" list is derived from the AdGuardHome open-source project (servicelist.go). Online subscriptions and recommended lists are third-party open-source lists provided "as is", and may over- or under-block.\n\n• Whether to enable filtering, which services to block and which lists to subscribe to are entirely your own decisions and responsibility. Use it only on devices/networks you are authorized to manage, and never for any unlawful purpose.\n\n• The authors provide no warranty and are not liable for any service disruption, data loss or other damage arising from use of this app.\n\n• This app is open source under GPL-3.0.',
      '本应用是运行在本机的 DNS 过滤工具。\n\n• 内置「服务屏蔽」清单来自 AdGuardHome 开源项目（servicelist.go）；在线订阅与推荐规则库均为第三方开源列表，按「现状」提供，可能存在误拦截或漏拦截。\n\n• 是否启用过滤、屏蔽哪些服务、订阅哪些列表，均由你自行决定并承担相应后果。请仅在你有权管理的设备 / 网络上使用，请勿用于任何非法用途。\n\n• 作者不提供任何担保，且不对因使用本应用造成的服务不可用、数据丢失或其他损失承担责任。\n\n• 本应用基于 GPL-3.0 开源。',
      '本應用是執行在本機的 DNS 過濾工具。\n\n• 內建「服務屏蔽」清單來自 AdGuardHome 開源專案（servicelist.go）；線上訂閱與推薦規則庫均為第三方開源清單，按「現狀」提供，可能存在誤攔截或漏攔截。\n\n• 是否啟用過濾、屏蔽哪些服務、訂閱哪些清單，均由你自行決定並承擔相應後果。請僅在你有權管理的裝置 / 網路上使用，請勿用於任何非法用途。\n\n• 作者不提供任何擔保，且不對因使用本應用造成的服務不可用、資料遺失或其他損失承擔責任。\n\n• 本應用基於 GPL-3.0 開源。');
  }

  private acceptDisclaimer(): void {
    this.disclaimerAccepted = true;
    this.showFirstRunDisclaimer = false;
    this.savePersistState();
  }

  private declineDisclaimerAndExit(): void {
    try {
      this.getHostContext().terminateSelf();
    } catch (_) {
    }
  }

  // Mandatory first-launch disclaimer gate: must accept to continue, or exit.
  @Builder
  private FirstRunDisclaimer() {
    Column() {
      Column({ space: 14 }) {
        Text(this.tri('Disclaimer', '免责声明', '免責聲明'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .width('100%')
          .textAlign(TextAlign.Center)

        Scroll() {
          Text(this.disclaimerText())
            .fontSize(14)
            .lineHeight(23)
            .fontColor(this.secondaryTextColor())
            .textAlign(TextAlign.Start)
            .width('100%')
        }
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)

        Row({ space: 10 }) {
          Button(this.tri('Decline & exit', '不接受并退出', '不接受並退出'))
            .layoutWeight(1)
            .height(46)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .backgroundColor(this.softRedTone())
            .fontColor(this.isDarkModeActive() ? '#FF8A8A' : '#B42318')
            .borderRadius(14)
            .onClick(() => {
              this.declineDisclaimerAndExit();
            })
          Button(this.tri('Accept', '接受', '接受'))
            .layoutWeight(1)
            .height(46)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .backgroundColor(this.accentBlueTone())
            .fontColor('#FFFFFF')
            .borderRadius(14)
            .onClick(() => {
              this.acceptDisclaimer();
            })
        }
        .width('100%')
      }
      .width('88%')
      .height('70%')
      .alignItems(HorizontalAlign.Start)
      .padding(22)
      .backgroundColor(this.cardSurfaceTone())
      .borderRadius(22)
      .border({ width: 1, color: this.cardBorderTone() })
      .shadow({ radius: 24, color: this.cardShadowTone() })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#A6000000')
  }

  @Builder
  private DisclaimerSheet() {
    Column({ space: 14 }) {
      Text(this.tri('Disclaimer', '免责声明', '免責聲明'))
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
        .width('100%')
        .textAlign(TextAlign.Center)

      Scroll() {
        Text(this.disclaimerText())
          .fontSize(14)
          .lineHeight(23)
          .fontColor(this.secondaryTextColor())
          .textAlign(TextAlign.Start)
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)

      Button(this.tri('I understand', '我已知晓', '我已知曉'))
        .width('100%')
        .height(46)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.accentBlueTone())
        .fontColor('#FFFFFF')
        .borderRadius(14)
        .onClick(() => {
          this.showDisclaimerSheet = false;
        })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: 20,
      right: 20,
      top: 22,
      bottom: Math.max(20, this.avoidPaddingBottom + 12)
    })
    .backgroundColor(this.sheetSurfaceTone())
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

  // Allowed/blocked come from the SQLite summary (cumulative across restarts and
  // always consistent with the total = allowed + blocked). The native counters are
  // per-session (reset on each filter (re)start) and would otherwise make the home
  // numbers reset to ~0 after an app restart and not add up to the total.
  private displayAllowed(): number {
    return this.querySummary.allowed;
  }

  private displayBlocked(): number {
    return this.querySummary.blocked;
  }

  private displayCacheHits(): number {
    return this.status.nativeStats.dnsCacheHits;
  }

  private displayCacheMisses(): number {
    return this.status.nativeStats.dnsCacheMisses;
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
    return this.isDarkModeActive() ? '#F3F4F6' : '#161B26';
  }

  private secondaryTextColor(): string {
    return this.isDarkModeActive() ? '#A7B0BD' : '#5A6573';
  }

  private mutedTextColor(): string {
    return this.isDarkModeActive() ? '#7E8795' : '#97A0AD';
  }

  private canvasTone(): string {
    return this.isDarkModeActive() ? '#0E1320' : '#EDEFF3';
  }

  private cardSurfaceTone(): string {
    return this.isDarkModeActive() ? '#182234' : '#FFFFFF';
  }

  private cardBorderTone(): string {
    return this.isDarkModeActive() ? '#1FFFFFFF' : '#14101828';
  }

  private cardShadowTone(): string {
    return this.isDarkModeActive() ? '#55000000' : '#22101A2E';
  }

  private chipSurfaceTone(): string {
      return this.isDarkModeActive() ? '#222E42' : '#F1F3F7';
  }

  private floatingBarTone(): string {
      return this.isDarkModeActive() ? '#182235F2' : '#FFFFFFF2';
  }

  private elevatedSurfaceTone(): string {
      return this.isDarkModeActive() ? '#1B2638' : '#FFFFFF';
  }

  private softPanelTone(): string {
      return this.isDarkModeActive() ? '#212C40' : '#F2F4F8';
  }

  private selectedChipSurfaceTone(): string {
        return this.isDarkModeActive() ? '#2C436E' : '#E6EEFF';
  }

  private selectedChipTextTone(): string {
      return this.isDarkModeActive() ? '#9FC0FF' : '#255DFF';
  }

  private coolChipSurfaceTone(): string {
        return this.isDarkModeActive() ? '#25375A' : '#E9F0FF';
  }

  private coolNeutralChipSurfaceTone(): string {
        return this.isDarkModeActive() ? '#212C40' : '#F1F3F7';
    }

    private warmChipSurfaceTone(): string {
      return this.isDarkModeActive() ? '#3E2630' : '#FCEAEA';
    }

    private selectedOutlineTone(): string {
      return this.isDarkModeActive() ? '#9CC2FF' : '#5B8EFF';
    }

    private selectedShadowTone(): string {
      return this.isDarkModeActive() ? '#40000000' : '#1F255DFF';
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
      case 'settings':
        return '⚙';
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
      return this.isDarkModeActive() ? '#25375A' : '#E9F0FF';
  }

  private softGreenTone(): string {
      return this.isDarkModeActive() ? '#1E3A2E' : '#E7F5EE';
  }

  private softAmberTone(): string {
      return this.isDarkModeActive() ? '#212C40' : '#F2F4F8';
  }

  private softRedTone(): string {
      return this.isDarkModeActive() ? '#3E2630' : '#FCEDEC';
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
    return this.isDarkModeActive() ? '#172335' : '#FFFFFF';
  }

  private sheetSecondarySurfaceTone(): string {
    return this.isDarkModeActive() ? '#212C40' : '#F4F6F9';
  }

  private sheetInputSurfaceTone(): string {
    return this.isDarkModeActive() ? '#212C40' : '#F2F4F8';
  }

  private sheetBorderTone(): string {
    return this.isDarkModeActive() ? '#1FFFFFFF' : '#14101828';
  }

  private sheetShadowTone(): string {
    return this.isDarkModeActive() ? '#55000000' : '#22101A2E';
  }

  private sheetGlowTone(): string {
    return this.isDarkModeActive() ? '#224C8BCB' : '#14255DFF';
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

  @Builder
  private OverviewStatCell(p: OverviewStatParam) {
    Column({ space: 3 }) {
      Text(p.label)
        .fontSize(11)
        .fontColor(this.secondaryTextColor())
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(p.value)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(p.valueColor)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(this.softPanelTone())
    .borderRadius(12)
    .border({ width: 1, color: this.cardBorderTone() })
  }

  @Builder
  private SettingsGroupTitle(p: SettingsGroupTitleParam) {
    Text(p.text)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.primaryTextColor())
      .opacity(0.9)
      .margin({ left: 4, top: 8, bottom: 2 })
  }

  @Builder
  private ThemeSegButton(p: ThemeSegButtonParam) {
    Button(p.label)
      .type(ButtonType.Normal)
      .layoutWeight(1)
      .height(36)
      .fontSize(13)
      .fontWeight(this.themeMode === p.mode ? FontWeight.Bold : FontWeight.Medium)
      .backgroundColor(this.themeMode === p.mode ? this.cardSurfaceTone() : Color.Transparent)
      .fontColor(this.themeMode === p.mode ? this.accentBlueTone() : this.secondaryTextColor())
      .borderRadius(11)
      .shadow(this.themeMode === p.mode
        ? { radius: 8, color: this.cardShadowTone(), offsetX: 0, offsetY: 2 }
        : { radius: 0, color: '#00000000' })
      .onClick(() => {
        this.setTheme(p.mode);
      })
  }

  @Builder
  private LangSegButton(label: string, lang: LangCode) {
    Button(label)
      .type(ButtonType.Normal)
      .layoutWeight(1)
      .height(36)
      .fontSize(13)
      .fontWeight(this.language === lang ? FontWeight.Bold : FontWeight.Medium)
      .backgroundColor(this.language === lang ? this.cardSurfaceTone() : Color.Transparent)
      .fontColor(this.language === lang ? this.accentBlueTone() : this.secondaryTextColor())
      .borderRadius(11)
      .shadow(this.language === lang
        ? { radius: 8, color: this.cardShadowTone(), offsetX: 0, offsetY: 2 }
        : { radius: 0, color: '#00000000' })
      .onClick(() => {
        this.setLanguage(lang);
      })
  }

  // Leading icon + title + description block for a settings list row. The
  // trailing control (chevron / Toggle) is placed by the caller as a sibling.
  @Builder
  private SettingsIconText(p: SettingsRowTextParam) {
    Row({ space: 12 }) {
      this.IconBubble(p.glyph, p.iconBg, p.iconFg, 36, 16)
      Column({ space: 2 }) {
        Text(p.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
        Text(p.desc)
          .fontSize(12)
          .lineHeight(17)
          .fontColor(this.secondaryTextColor())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .alignItems(VerticalAlign.Center)
  }

  // One recommended online-list row with a Subscribe / Subscribed button.
  @Builder
  private RecommendedPresetRow(preset: SubscriptionPreset) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(preset.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(preset.url)
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button(this.subscriptionPresetActive(preset.url)
          ? this.tri('Subscribed', '已订阅', '已訂閱')
          : this.tri('Subscribe', '订阅', '訂閱'))
        .enabled(!this.subscriptionPresetActive(preset.url))
        .height(32)
        .padding({ left: 14, right: 14 })
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.subscriptionPresetActive(preset.url)
          ? this.coolNeutralChipSurfaceTone() : this.accentBlueTone())
        .fontColor(this.subscriptionPresetActive(preset.url)
          ? this.secondaryTextColor() : '#FFFFFF')
        .borderRadius(8)
        .onClick(() => {
          this.addSubscriptionPreset(preset);
        })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.cardSurfaceTone())
    .borderRadius(16)
    .shadow({ radius: 12, color: this.cardShadowTone() })
    .margin({ bottom: 10 })
  }

  // Preview of the most recent queries (independent of the list's active
  // filter/page), so it uses the recent-rows window rather than the loaded page.
  private visibleQueryEvents(): QueryLogEntry[] {
    if (this.recentRows.length <= 8) {
      return this.recentRows;
    }
    return this.recentRows.slice(0, 8);
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
          this.dnsPage = 0;
          // Re-query the page/count for the new search term.
          this.refreshQueryLog();
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
            this.dnsPage = 0;
            // Rebuild the list for the new filter now instead of waiting for the
            // next refresh tick (the list is filter-aware tail of matching lines).
            this.refreshQueryLog();
          })
        }, (filter: QueryActionFilter) => filter)
      }
      .width('100%')

      if (this.dnsFilteredCount === 0) {
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
          ForEach(this.pagedQueryEvents(), (item: QueryLogEntry) => {
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
                  Text(this.querySourceText(item.source))
                    .fontSize(10)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.selectedChipTextTone())
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .backgroundColor(this.coolNeutralChipSurfaceTone())
                    .border({ width: 1, color: this.sheetBorderTone() })
                    .borderRadius(10)
                }
                .width('100%')

                Text(`${this.t('rulePrefix')}: ${item.rule || this.t('none')}`)
                  .fontSize(12)
                  .fontColor(this.secondaryTextColor())
                  .width('100%')
                Text(`${this.t('sourcePrefix')}: ${this.querySourceText(item.source)}`)
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

        if (this.dnsTotalPages() > 1) {
          Row({ space: 12 }) {
            Button(this.language === 'en' ? 'Prev' : (this.language === 'zhHant' ? '上一頁' : '上一页'))
              .fontSize(13)
              .height(36)
              .layoutWeight(1)
              .enabled(this.clampedDnsPage() > 0)
              .opacity(this.clampedDnsPage() > 0 ? 1 : 0.4)
              .backgroundColor(this.coolChipSurfaceTone())
              .fontColor(this.primaryTextColor())
              .borderRadius(12)
              .onClick(() => {
                this.dnsPage = Math.max(0, this.clampedDnsPage() - 1);
                this.dnsListScroller.scrollEdge(Edge.Top);
                this.refreshQueryLog();
              })
            Text(`${this.clampedDnsPage() + 1} / ${this.dnsTotalPages()}`)
              .fontSize(13)
              .fontColor(this.secondaryTextColor())
              .textAlign(TextAlign.Center)
            Button(this.language === 'en' ? 'Next' : (this.language === 'zhHant' ? '下一頁' : '下一页'))
              .fontSize(13)
              .height(36)
              .layoutWeight(1)
              .enabled(this.clampedDnsPage() < this.dnsTotalPages() - 1)
              .opacity(this.clampedDnsPage() < this.dnsTotalPages() - 1 ? 1 : 0.4)
              .backgroundColor(this.coolChipSurfaceTone())
              .fontColor(this.primaryTextColor())
              .borderRadius(12)
              .onClick(() => {
                this.dnsPage = Math.min(this.dnsTotalPages() - 1, this.clampedDnsPage() + 1);
                this.dnsListScroller.scrollEdge(Edge.Top);
                this.refreshQueryLog();
              })
          }
          .width('100%')
          .padding({ top: 8 })
        }
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
                Text(`${this.t('allowed')}: ${item.allowed} · ${this.t('blocked')}: ${item.blocked}`)
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
  private ServicesSheet() {
    Column({ space: 12 }) {
      if (this.detailServiceId.length > 0) {
        // ===== Detail view: one service's full rule list =====
        Row({ space: 12 }) {
          Button(this.tri('← Back', '← 返回', '← 返回'))
            .fontSize(13)
            .height(36)
            .padding({ left: 14, right: 14 })
            .backgroundColor(this.coolNeutralChipSurfaceTone())
            .fontColor(this.primaryTextColor())
            .borderRadius(12)
            .border({ width: 1, color: this.cardBorderTone() })
            .onClick(() => {
              this.detailServiceId = '';
            })

          Column({ space: 2 }) {
            Text(this.serviceById(this.detailServiceId)?.name ?? this.detailServiceId)
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${this.serviceById(this.detailServiceId)?.rules.length ?? 0} ${this.language === 'en' ? 'rules' : '条规则'}`)
              .fontSize(12)
              .fontColor(this.mutedTextColor())
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Toggle({ type: ToggleType.Switch, isOn: this.blockedServiceIds.includes(this.detailServiceId) })
            .onChange((value: boolean) => {
              this.toggleBlockedService(this.detailServiceId, value);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.tri('Long-press a rule to copy. Lookups matching these domains are blocked.',
          '长按可复制。命中这些域名的解析会被拦截。', '長按可複製。命中這些網域的解析會被攔截。'))
          .fontSize(12)
          .lineHeight(17)
          .fontColor(this.secondaryTextColor())
          .width('100%')

        List() {
          ForEach(this.serviceById(this.detailServiceId)?.rules ?? [], (rule: string, idx: number) => {
            ListItem() {
              Text(rule)
                .fontSize(13)
                .fontColor(this.primaryTextColor())
                .copyOption(CopyOptions.LocalDevice)
                .width('100%')
                .padding({ left: 14, right: 14, top: 11, bottom: 11 })
                .backgroundColor(this.sheetSecondarySurfaceTone())
                .borderRadius(12)
                .border({ width: 1, color: this.sheetBorderTone() })
            }
          }, (rule: string, idx: number) => `${idx}_${rule}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .cachedCount(12)
        .divider({ strokeWidth: 8, color: Color.Transparent })
      } else {
        // ===== List view: all services =====
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text(this.language === 'en' ? 'Blocked services' : (this.language === 'zhHant' ? '服務屏蔽' : '服务屏蔽'))
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
            Text(this.language === 'en'
              ? `${this.blockedServiceIds.length} blocked`
              : (this.language === 'zhHant' ? `已屏蔽 ${this.blockedServiceIds.length} 個` : `已屏蔽 ${this.blockedServiceIds.length} 个`))
              .fontSize(12)
              .fontColor(this.mutedTextColor())
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Button(this.language === 'en' ? 'Close' : (this.language === 'zhHant' ? '關閉' : '关闭'))
            .fontSize(13)
            .height(36)
            .backgroundColor(this.coolChipSurfaceTone())
            .fontColor(this.primaryTextColor())
            .borderRadius(12)
            .onClick(() => {
              this.showServicesSheet = false;
            })
        }
        .width('100%')

        TextInput({ text: this.servicesSearchText, placeholder: this.language === 'en' ? 'Search services' : '搜索服务' })
          .width('100%')
          .height(44)
          .fontSize(15)
          .backgroundColor(this.sheetInputSurfaceTone())
          .borderRadius(16)
          .border({ width: 1, color: this.sheetBorderTone() })
          .padding({ left: 14, right: 14 })
          .onChange((value: string) => {
            this.servicesSearchText = value;
          })

        List() {
          ForEach(this.filteredBlockedServices(), (svc: BlockedServiceDef) => {
            ListItem() {
              Row() {
                Column({ space: 2 }) {
                  Text(svc.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.primaryTextColor())
                  Row({ space: 6 }) {
                    Text(`${svc.rules.length} ${this.language === 'en' ? 'rules' : '条规则'}`)
                      .fontSize(11)
                      .fontColor(this.mutedTextColor())
                    Text(this.tri('view ›', '查看 ›', '查看 ›'))
                      .fontSize(11)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.accentBlueTone())
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .onClick(() => {
                  this.detailServiceId = svc.id;
                })

                Toggle({ type: ToggleType.Switch, isOn: this.blockedServiceIds.includes(svc.id) })
                  .onChange((value: boolean) => {
                    this.toggleBlockedService(svc.id, value);
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding(14)
              .backgroundColor(this.sheetSecondarySurfaceTone())
              .borderRadius(14)
              .border({ width: 1, color: this.sheetBorderTone() })
            }
          }, (svc: BlockedServiceDef) => svc.id)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .cachedCount(10)
        .divider({ strokeWidth: 8, color: Color.Transparent })
      }
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 14,
      right: 14,
      top: Math.max(18, this.avoidPaddingTop + 12),
      bottom: Math.max(18, this.avoidPaddingBottom + 12)
    })
    .backgroundColor(this.sheetSurfaceTone())
  }

  @Builder
  private AghWebSheet() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.language === 'en'
            ? 'AdGuardHome dashboard'
            : (this.language === 'zhHant' ? 'AdGuardHome 管理面板' : 'AdGuardHome 管理面板'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          Text(`http://127.0.0.1:${this.effectiveHttpPort()}`)
            .fontSize(12)
            .fontColor(this.mutedTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.language === 'en' ? 'Refresh' : (this.language === 'zhHant' ? '重新整理' : '刷新'))
          .fontSize(13)
          .height(36)
          .backgroundColor(this.coolChipSurfaceTone())
          .fontColor(this.primaryTextColor())
          .borderRadius(12)
          .onClick(() => {
            try {
              this.aghWebController.refresh();
            } catch (_) {
            }
          })
        Button(this.language === 'en' ? 'Close' : (this.language === 'zhHant' ? '關閉' : '关闭'))
          .fontSize(13)
          .height(36)
          .backgroundColor(this.coolChipSurfaceTone())
          .fontColor(this.primaryTextColor())
          .borderRadius(12)
          .onClick(() => {
            this.showAghWebSheet = false;
          })
      }
      .width('100%')

      Web({ src: `http://127.0.0.1:${this.effectiveHttpPort()}`, controller: this.aghWebController })
        .width('100%')
        .layoutWeight(1)
        .borderRadius(14)
        .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 14,
      right: 14,
      top: Math.max(18, this.avoidPaddingTop + 12),
      bottom: Math.max(18, this.avoidPaddingBottom + 12)
    })
    .backgroundColor(this.sheetSurfaceTone())
  }

  @Builder
  private ModeChip(label: string, selected: boolean, onTap: () => void) {
    Button(label)
      .type(ButtonType.Normal)
      .fontSize(13)
      .height(38)
      .fontColor(selected ? this.selectedChipTextTone() : this.primaryTextColor())
      .backgroundColor(selected ? this.coolChipSurfaceTone() : this.sheetInputSurfaceTone())
      .borderRadius(12)
      .border({ width: selected ? 1.5 : 1, color: selected ? this.selectedOutlineTone() : this.sheetBorderTone() })
      .padding({ left: 14, right: 14 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        onTap();
      })
  }

  @Builder
  private SubscriptionsSheet() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.tri('Online subscriptions', '在线规则订阅', '線上規則訂閱'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          Text(this.tri(`${this.enabledSubscriptionCount()} enabled / ${this.filterSubscriptions.length} total`,
            `已启用 ${this.enabledSubscriptionCount()} / 共 ${this.filterSubscriptions.length}`,
            `已啟用 ${this.enabledSubscriptionCount()} / 共 ${this.filterSubscriptions.length}`))
            .fontSize(12)
            .fontColor(this.mutedTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.tri('Close', '关闭', '關閉'))
          .fontSize(13)
          .height(36)
          .backgroundColor(this.coolChipSurfaceTone())
          .fontColor(this.primaryTextColor())
          .borderRadius(12)
          .onClick(() => {
            this.showSubscriptionsSheet = false;
          })
      }
      .width('100%')

      Text(this.tri('Full engine only. Enabled lists download a few seconds after the filter starts; changes restart filtering while running.',
        '仅完整引擎有效。启用的列表会在过滤启动几秒后下载；运行中更改会重启过滤。',
        '僅完整引擎有效。啟用的列表會在過濾啟動幾秒後下載；執行中更改會重啟過濾。'))
        .fontSize(12)
        .lineHeight(18)
        .fontColor(this.secondaryTextColor())
        .width('100%')

      Column({ space: 10 }) {
        TextInput({ text: this.subAddNameInput, placeholder: this.tri('Name (optional)', '名称（可选）', '名稱（可選）') })
          .width('100%')
          .height(44)
          .fontSize(15)
          .backgroundColor(this.sheetInputSurfaceTone())
          .borderRadius(14)
          .border({ width: 1, color: this.sheetBorderTone() })
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.subAddNameInput = value;
          })
        TextInput({ text: this.subAddUrlInput, placeholder: 'https://example.com/list.txt' })
          .width('100%')
          .height(44)
          .fontSize(15)
          .backgroundColor(this.sheetInputSurfaceTone())
          .borderRadius(14)
          .border({ width: 1, color: this.sheetBorderTone() })
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.subAddUrlInput = value;
          })
        Button(this.tri('Add', '添加', '新增'))
          .type(ButtonType.Normal)
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor('#2B5B95')
          .borderRadius(14)
          .onClick(() => {
            this.addFilterSubscription(this.subAddNameInput, this.subAddUrlInput);
          })

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(SUBSCRIPTION_PRESETS, (p: SubscriptionPreset) => {
            Button(p.name)
              .type(ButtonType.Normal)
              .fontSize(12)
              .fontColor(this.primaryTextColor())
              .backgroundColor(this.sheetInputSurfaceTone())
              .borderRadius(12)
              .border({ width: 1, color: this.sheetBorderTone() })
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin({ right: 8, bottom: 8 })
              .onClick(() => {
                this.addSubscriptionPreset(p);
              })
          }, (p: SubscriptionPreset) => p.url)
        }
        .width('100%')
      }
      .width('100%')
      .padding(14)
      .backgroundColor(this.sheetSecondarySurfaceTone())
      .borderRadius(18)
      .border({ width: 1, color: this.sheetBorderTone() })

      if (this.subFeedbackText.length > 0) {
        Text(this.subFeedbackText)
          .fontSize(12)
          .fontColor(this.accentBlueTone())
          .fontWeight(FontWeight.Medium)
          .width('100%')
      }

      if (this.filterSubscriptions.length === 0) {
        Text(this.tri('No subscriptions yet.', '暂无订阅。', '尚無訂閱。'))
          .fontSize(13)
          .fontColor(this.secondaryTextColor())
          .width('100%')
      }

      List() {
        ForEach(this.filterSubscriptions, (s: FilterSubscription) => {
          ListItem() {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text(s.name)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.primaryTextColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(s.url)
                  .fontSize(11)
                  .fontColor(this.mutedTextColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: s.enabled })
                .onChange((value: boolean) => {
                  this.toggleFilterSubscription(s.id, value);
                })
              Button(this.tri('Delete', '删除', '刪除'))
                .fontSize(12)
                .height(34)
                .backgroundColor(this.coolChipSurfaceTone())
                .fontColor(this.primaryTextColor())
                .borderRadius(10)
                .onClick(() => {
                  this.removeFilterSubscription(s.id);
                })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(this.sheetSecondarySurfaceTone())
            .borderRadius(14)
            .border({ width: 1, color: this.sheetBorderTone() })
          }
        }, (s: FilterSubscription) => `${s.id}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .cachedCount(8)
      .divider({ strokeWidth: 8, color: Color.Transparent })
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 14,
      right: 14,
      top: Math.max(18, this.avoidPaddingTop + 12),
      bottom: Math.max(18, this.avoidPaddingBottom + 12)
    })
    .backgroundColor(this.sheetSurfaceTone())
  }

  @Builder
  private RewritesSheet() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.tri('DNS rewrites', 'DNS 重写', 'DNS 重寫'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          Text(this.tri(`${this.dnsRewrites.length} rewrites`,
            `共 ${this.dnsRewrites.length} 条`, `共 ${this.dnsRewrites.length} 條`))
            .fontSize(12)
            .fontColor(this.mutedTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.tri('Close', '关闭', '關閉'))
          .fontSize(13)
          .height(36)
          .backgroundColor(this.coolChipSurfaceTone())
          .fontColor(this.primaryTextColor())
          .borderRadius(12)
          .onClick(() => {
            this.showRewritesSheet = false;
          })
      }
      .width('100%')

      Text(this.tri('Full engine only. Answer can be an IP (A/AAAA), a hostname (CNAME), or A/AAAA to clear. Changes restart filtering while running.',
        '仅完整引擎有效。应答值可填 IP（A/AAAA）、主机名（CNAME），或填 A/AAAA 清空。运行中更改会重启过滤。',
        '僅完整引擎有效。應答值可填 IP（A/AAAA）、主機名（CNAME），或填 A/AAAA 清空。執行中更改會重啟過濾。'))
        .fontSize(12)
        .lineHeight(18)
        .fontColor(this.secondaryTextColor())
        .width('100%')

      Column({ space: 10 }) {
        TextInput({ text: this.rewriteAddDomainInput, placeholder: this.tri('Domain, e.g. example.com', '域名，如 example.com', '網域，如 example.com') })
          .width('100%')
          .height(44)
          .fontSize(15)
          .backgroundColor(this.sheetInputSurfaceTone())
          .borderRadius(14)
          .border({ width: 1, color: this.sheetBorderTone() })
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.rewriteAddDomainInput = value;
          })
        TextInput({ text: this.rewriteAddAnswerInput, placeholder: this.tri('Answer, e.g. 1.2.3.4', '应答，如 1.2.3.4', '應答，如 1.2.3.4') })
          .width('100%')
          .height(44)
          .fontSize(15)
          .backgroundColor(this.sheetInputSurfaceTone())
          .borderRadius(14)
          .border({ width: 1, color: this.sheetBorderTone() })
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.rewriteAddAnswerInput = value;
          })
        Button(this.tri('Add', '添加', '新增'))
          .type(ButtonType.Normal)
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor('#2B5B95')
          .borderRadius(14)
          .onClick(() => {
            this.addDnsRewrite(this.rewriteAddDomainInput, this.rewriteAddAnswerInput);
          })
      }
      .width('100%')
      .padding(14)
      .backgroundColor(this.sheetSecondarySurfaceTone())
      .borderRadius(18)
      .border({ width: 1, color: this.sheetBorderTone() })

      if (this.rewriteFeedbackText.length > 0) {
        Text(this.rewriteFeedbackText)
          .fontSize(12)
          .fontColor(this.accentBlueTone())
          .fontWeight(FontWeight.Medium)
          .width('100%')
      }

      if (this.dnsRewrites.length === 0) {
        Text(this.tri('No rewrites yet.', '暂无重写。', '尚無重寫。'))
          .fontSize(13)
          .fontColor(this.secondaryTextColor())
          .width('100%')
      }

      List() {
        ForEach(this.dnsRewrites, (r: DnsRewriteRule, index: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text(r.domain)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.primaryTextColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`→ ${r.answer}`)
                  .fontSize(12)
                  .fontColor(this.mutedTextColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Button(this.tri('Delete', '删除', '刪除'))
                .fontSize(12)
                .height(34)
                .backgroundColor(this.coolChipSurfaceTone())
                .fontColor(this.primaryTextColor())
                .borderRadius(10)
                .onClick(() => {
                  this.removeDnsRewrite(index);
                })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(this.sheetSecondarySurfaceTone())
            .borderRadius(14)
            .border({ width: 1, color: this.sheetBorderTone() })
          }
        }, (r: DnsRewriteRule, index: number) => `${index}:${r.domain}:${r.answer}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .cachedCount(8)
      .divider({ strokeWidth: 8, color: Color.Transparent })
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 14,
      right: 14,
      top: Math.max(18, this.avoidPaddingTop + 12),
      bottom: Math.max(18, this.avoidPaddingBottom + 12)
    })
    .backgroundColor(this.sheetSurfaceTone())
  }

  @Builder
  private AdvancedDnsSheet() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.tri('Advanced DNS', 'DNS 高级设置', 'DNS 進階設定'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
          Text(this.tri('Full engine only', '仅完整引擎有效', '僅完整引擎有效'))
            .fontSize(12)
            .fontColor(this.mutedTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button(this.tri('Close', '关闭', '關閉'))
          .fontSize(13)
          .height(36)
          .backgroundColor(this.coolChipSurfaceTone())
          .fontColor(this.primaryTextColor())
          .borderRadius(12)
          .onClick(() => {
            this.showAdvancedDnsSheet = false;
          })
      }
      .width('100%')

      Scroll() {
        Column({ space: 16 }) {
          Text(this.tri('Changes restart filtering while running.',
            '运行中更改会重启过滤以生效。', '執行中更改會重啟過濾以生效。'))
            .fontSize(12)
            .lineHeight(18)
            .fontColor(this.secondaryTextColor())
            .width('100%')

          // Blocking mode
          Column({ space: 8 }) {
            Text(this.tri('Blocking mode', '拦截方式', '攔截方式'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
            Text(this.tri('How blocked answers are returned.', '被拦截的应答如何返回。', '被攔截的應答如何返回。'))
              .fontSize(12)
              .fontColor(this.secondaryTextColor())
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              this.ModeChip(this.blockingModeLabel('default'), this.advancedDns.blockingMode === 'default', () => {
                this.setBlockingMode('default');
              })
              this.ModeChip(this.blockingModeLabel('nxdomain'), this.advancedDns.blockingMode === 'nxdomain', () => {
                this.setBlockingMode('nxdomain');
              })
              this.ModeChip(this.blockingModeLabel('refused'), this.advancedDns.blockingMode === 'refused', () => {
                this.setBlockingMode('refused');
              })
              this.ModeChip(this.blockingModeLabel('null_ip'), this.advancedDns.blockingMode === 'null_ip', () => {
                this.setBlockingMode('null_ip');
              })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .backgroundColor(this.sheetSecondarySurfaceTone())
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })

          // Upstream mode
          Column({ space: 8 }) {
            Text(this.tri('Upstream mode', '上游模式', '上游模式'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
            Text(this.tri('How queries are sent to upstream resolvers.', '如何向上游解析器发送查询。', '如何向上游解析器發送查詢。'))
              .fontSize(12)
              .fontColor(this.secondaryTextColor())
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              this.ModeChip(this.upstreamModeLabel('load_balance'), this.advancedDns.upstreamMode === 'load_balance', () => {
                this.setUpstreamMode('load_balance');
              })
              this.ModeChip(this.upstreamModeLabel('parallel'), this.advancedDns.upstreamMode === 'parallel', () => {
                this.setUpstreamMode('parallel');
              })
              this.ModeChip(this.upstreamModeLabel('fastest_addr'), this.advancedDns.upstreamMode === 'fastest_addr', () => {
                this.setUpstreamMode('fastest_addr');
              })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .backgroundColor(this.sheetSecondarySurfaceTone())
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })

          // DNSSEC
          Row() {
            Column({ space: 2 }) {
              Text('DNSSEC')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.primaryTextColor())
              Text(this.tri('Request and verify DNSSEC signatures.', '请求并校验 DNSSEC 签名。', '請求並驗證 DNSSEC 簽章。'))
                .fontSize(12)
                .fontColor(this.secondaryTextColor())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.advancedDns.enableDnssec })
              .onChange((value: boolean) => {
                this.setEnableDnssec(value);
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.sheetSecondarySurfaceTone())
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })

          // Cache
          Column({ space: 12 }) {
            Row() {
              Column({ space: 2 }) {
                Text(this.tri('DNS cache', 'DNS 缓存', 'DNS 快取'))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.primaryTextColor())
                Text(this.tri('Cache resolved answers for faster repeats.', '缓存解析结果以加速重复查询。', '快取解析結果以加速重複查詢。'))
                  .fontSize(12)
                  .fontColor(this.secondaryTextColor())
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.advancedDns.cacheEnabled })
                .onChange((value: boolean) => {
                  this.setCacheEnabled(value);
                })
            }
            .width('100%')

            if (this.advancedDns.cacheEnabled) {
              Row({ space: 10 }) {
                Text(this.tri('Size (MB)', '大小（MB）', '大小（MB）'))
                  .fontSize(14)
                  .fontColor(this.primaryTextColor())
                  .layoutWeight(1)
                TextInput({ text: this.cacheSizeInput })
                  .type(InputType.Number)
                  .width(96)
                  .height(40)
                  .fontSize(15)
                  .backgroundColor(this.sheetInputSurfaceTone())
                  .borderRadius(12)
                  .border({ width: 1, color: this.sheetBorderTone() })
                  .padding({ left: 12, right: 12 })
                  .onChange((value: string) => {
                    this.cacheSizeInput = value;
                  })
                Button(this.tri('Apply', '应用', '套用'))
                  .fontSize(13)
                  .height(40)
                  .backgroundColor(this.coolChipSurfaceTone())
                  .fontColor(this.primaryTextColor())
                  .borderRadius(12)
                  .onClick(() => {
                    const n: number = parseInt(this.cacheSizeInput, 10);
                    this.setCacheSizeMb(Number.isFinite(n) && n >= 0 ? n : 0);
                  })
              }
              .width('100%')

              Row() {
                Column({ space: 2 }) {
                  Text(this.tri('Optimistic cache', '乐观缓存', '樂觀快取'))
                    .fontSize(14)
                    .fontColor(this.primaryTextColor())
                  Text(this.tri('Serve stale answers while refreshing.', '过期时先返回旧结果再刷新。', '過期時先返回舊結果再刷新。'))
                    .fontSize(12)
                    .fontColor(this.secondaryTextColor())
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Toggle({ type: ToggleType.Switch, isOn: this.advancedDns.cacheOptimistic })
                  .onChange((value: boolean) => {
                    this.setCacheOptimistic(value);
                  })
              }
              .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .backgroundColor(this.sheetSecondarySurfaceTone())
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })

          // Rate limit
          Column({ space: 8 }) {
            Text(this.tri('Rate limit (qps)', '限速（每秒查询数）', '限速（每秒查詢數）'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
            Text(this.tri('0 = unlimited. Recommended for this app since all queries share one loopback source.',
              '0 = 不限。本应用建议设 0，因为所有查询来自同一回环来源。',
              '0 = 不限。本應用建議設 0，因為所有查詢來自同一回環來源。'))
              .fontSize(12)
              .lineHeight(18)
              .fontColor(this.secondaryTextColor())
              .width('100%')
            Row({ space: 10 }) {
              TextInput({ text: this.ratelimitInput })
                .type(InputType.Number)
                .layoutWeight(1)
                .height(40)
                .fontSize(15)
                .backgroundColor(this.sheetInputSurfaceTone())
                .borderRadius(12)
                .border({ width: 1, color: this.sheetBorderTone() })
                .padding({ left: 12, right: 12 })
                .onChange((value: string) => {
                  this.ratelimitInput = value;
                })
              Button(this.tri('Apply', '应用', '套用'))
                .fontSize(13)
                .height(40)
                .backgroundColor(this.coolChipSurfaceTone())
                .fontColor(this.primaryTextColor())
                .borderRadius(12)
                .onClick(() => {
                  const n: number = parseInt(this.ratelimitInput, 10);
                  this.setRatelimit(Number.isFinite(n) && n >= 0 ? n : 0);
                })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .backgroundColor(this.sheetSecondarySurfaceTone())
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 14,
      right: 14,
      top: Math.max(18, this.avoidPaddingTop + 12),
      bottom: Math.max(18, this.avoidPaddingBottom + 12)
    })
    .backgroundColor(this.sheetSurfaceTone())
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
      this.showSettingsPage = false;
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
        // ===== Brand Hero: status at a glance + one primary action =====
        Column({ space: 18 }) {
          Row() {
            Text(this.t('appTitle'))
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
            Blank()
            Row({ space: 10 }) {
              Button(this.engineModeLabel() + ' ▾')
                .enabled(!this.busy && !this.stopping)
                .opacity((this.busy || this.stopping) ? 0.5 : 1)
                .height(30)
                .padding({ left: 11, right: 11 })
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.selectedChipTextTone())
                .backgroundColor(this.coolNeutralChipSurfaceTone())
                .borderRadius(8)
                .border({ width: 1, color: this.cardBorderTone() })
                .bindMenu([
                  {
                    value: this.tri('⚡ Lite', '⚡ 轻量', '⚡ 輕量'),
                    action: () => {
                      this.setEngineFullMode(false);
                    }
                  },
                  {
                    value: this.tri('🔒 Full', '🔒 完整', '🔒 完整'),
                    action: () => {
                      this.setEngineFullMode(true);
                    }
                  }
                ])
              Row({ space: 6 }) {
                Column() {}
                  .width(7)
                  .height(7)
                  .borderRadius(4)
                  .backgroundColor(this.activeRunning() ? this.accentGreenTone() : this.mutedTextColor())
                Text(this.activeRunning() ? this.t('active') : this.t('idle'))
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.activeRunning() ? this.accentGreenTone() : this.secondaryTextColor())
              }
              .padding({ left: 9, right: 12, top: 5, bottom: 5 })
              .backgroundColor(this.activeRunning() ? this.softGreenTone() : this.coolNeutralChipSurfaceTone())
              .border({ width: 1, color: this.cardBorderTone() })
              .borderRadius(12)
              .alignItems(VerticalAlign.Center)
            }
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // Network mode (two-axis with the engine dropdown above): whole-device
          // VPN, or pure DNS proxy that coexists with another VPN. Locked while
          // running so the two modes never overlap.
          Row() {
            Button(this.t('modeVpn'))
              .layoutWeight(1)
              .height(34)
              .fontSize(13)
              .fontWeight(this.proxyModeEnabled ? FontWeight.Normal : FontWeight.Bold)
              .fontColor(this.proxyModeEnabled ? this.secondaryTextColor() : '#FFFFFF')
              .backgroundColor(this.proxyModeEnabled ? Color.Transparent : '#0099CC')
              .borderRadius(9)
              .enabled(!this.status.running && !this.dnsProxyRunning && !this.busy && !this.stopping)
              .onClick(() => {
                this.setNetworkProxyMode(false);
              })
            Button(this.t('modeDnsProxy'))
              .layoutWeight(1)
              .height(34)
              .fontSize(13)
              .fontWeight(this.proxyModeEnabled ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.proxyModeEnabled ? '#FFFFFF' : this.secondaryTextColor())
              .backgroundColor(this.proxyModeEnabled ? '#0099CC' : Color.Transparent)
              .borderRadius(9)
              .enabled(!this.status.running && !this.dnsProxyRunning && !this.busy && !this.stopping)
              .onClick(() => {
                this.setNetworkProxyMode(true);
              })
          }
          .width('100%')
          .padding(3)
          .backgroundColor(this.coolNeutralChipSurfaceTone())
          .borderRadius(12)
          .border({ width: 1, color: this.cardBorderTone() })

          Column({ space: 10 }) {
            Stack() {
              Text(this.activeRunning() ? '✓' : '◈')
                .fontSize(40)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
            }
            .width(86)
            .height(86)
            .borderRadius(43)
            .shadow({ radius: 18, color: this.activeRunning() ? '#5910B981' : '#590099CC', offsetX: 0, offsetY: 6 })
            .linearGradient({
              angle: 135,
              colors: this.activeRunning()
                ? (this.isDarkModeActive()
                    ? [['#10997D', 0.0], ['#047D5F', 1.0]]
                    : [['#34D399', 0.0], ['#10B981', 1.0]])
                : (this.isDarkModeActive()
                    ? [['#06B6D4', 0.0], ['#0891B2', 1.0]]
                    : [['#00D9FF', 0.0], ['#0099CC', 1.0]])
            })

            Text(this.activeRunning() ? this.t('running') : this.t('stopped'))
              .fontSize(23)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
            Text(this.activeRunning() ? this.t('runningHint') : this.t('stoppedHint'))
              .fontSize(13)
              .lineHeight(19)
              .fontColor(this.secondaryTextColor())
              .textAlign(TextAlign.Center)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .margin({ top: 4, bottom: 4 })

          Button(this.stopping
            ? this.tri('Stopping…', '停止中…', '停止中…')
            : (this.busy ? this.t('working')
              : (this.proxyModeEnabled
                ? (this.dnsProxyRunning ? this.t('dnsProxyStop') : this.t('dnsProxyStart'))
                : (this.status.running ? this.t('stopFilter') : this.t('startFilter')))))
            .enabled(!this.busy && !this.stopping)
            .width('100%')
            .height(50)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .backgroundColor((this.busy || this.stopping)
              ? this.chipSurfaceTone()
              : (this.activeRunning() ? '#10B981' : '#0099CC'))
            .fontColor((this.busy || this.stopping) ? this.secondaryTextColor() : '#FFFFFF')
            .borderRadius(16)
            .shadow({ radius: 12, color: this.activeRunning() ? '#3310B981' : '#330099CC' })
            .onClick(() => {
              if (this.proxyModeEnabled) {
                if (this.dnsProxyRunning) {
                  this.stopDnsProxy().catch((err: BusinessError) => {
                    this.errorText = this.errorMessage(err);
                  });
                } else {
                  this.startDnsProxy().catch((err: BusinessError) => {
                    this.errorText = this.errorMessage(err);
                  });
                }
              } else {
                if (this.status.running) {
                  this.stopVpn().catch((err: BusinessError) => {
                    this.errorText = this.errorMessage(err);
                  });
                } else {
                  this.startVpn().catch((err: BusinessError) => {
                    this.errorText = this.errorMessage(err);
                  });
                }
              }
            })

          if (this.activeRunning() && !this.busy && !this.stopping) {
            Button(this.t('restartFilter'))
              .width('100%')
              .height(44)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(this.softGreenTone())
              .fontColor(this.accentGreenTone())
              .borderRadius(14)
              .border({ width: 1, color: this.cardBorderTone() })
              .onClick(() => {
                if (this.proxyModeEnabled) {
                  this.startDnsProxy().catch((err: BusinessError) => {
                    this.errorText = this.errorMessage(err);
                  });
                } else {
                  this.startVpn().catch((err: BusinessError) => {
                    this.errorText = this.errorMessage(err);
                  });
                }
              })
          }

          // DNS-proxy mode: show the local DNS address (TCP + UDP) + active engine
          // so the user can point their proxy app's DNS upstream at it.
          if (this.proxyModeEnabled) {
            Column({ space: 8 }) {
              Text(this.fullModeEnabled ? this.t('dnsProxyEngineFull') : this.t('dnsProxyEngineLite'))
                .fontSize(12)
                .fontColor(this.secondaryTextColor())
                .width('100%')
              this.DnsProxyAddressRow('tcp')
              this.DnsProxyAddressRow('udp')
              // The AdGuardHome dashboard entry lives on the Settings page (it
              // works for full-engine VPN and DNS-proxy alike), so it isn't
              // duplicated here.
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(22)
        .backgroundColor(this.cardSurfaceTone())
        .borderRadius(26)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 18, color: this.cardShadowTone() })

        // ===== Quick stats: allowed / blocked =====
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text(`${this.displayAllowed()}`)
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.accentGreenTone())
              .width('100%')
            Text(this.t('allowed'))
              .fontSize(13)
              .fontColor(this.secondaryTextColor())
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .padding({ left: 18, right: 18, top: 16, bottom: 16 })
          .backgroundColor(this.cardSurfaceTone())
          .borderRadius(18)
          .shadow({ radius: 14, color: this.cardShadowTone() })
          .onClick(() => {
            this.openDnsSheetWithFilter('allowed');
          })

          Column({ space: 4 }) {
            Text(`${this.displayBlocked()}`)
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.isDarkModeActive() ? '#FF8A8A' : '#D14343')
              .width('100%')
            Text(this.t('blocked'))
              .fontSize(13)
              .fontColor(this.secondaryTextColor())
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .padding({ left: 18, right: 18, top: 16, bottom: 16 })
          .backgroundColor(this.cardSurfaceTone())
          .borderRadius(18)
          .shadow({ radius: 14, color: this.cardShadowTone() })
          .onClick(() => {
            this.openDnsSheetWithFilter('blocked');
          })
        }
        .width('100%')

        Column({ space: 10 }) {
          Row() {
            Text(this.t('recentDnsRequests'))
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
            Blank()
            Text(this.t('clickToExpand'))
              .fontSize(13)
              .fontColor(this.accentBlueTone())
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: 6 }) {
            Text(`${this.querySummary.total}`)
              .fontSize(34)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
            Text(this.t('lines'))
              .fontSize(14)
              .fontColor(this.secondaryTextColor())
              .padding({ bottom: 6 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)

          Text(`${this.t('dnsTraffic')}: ${this.formatBytes(this.querySummary.totalDnsBytes)} (${this.t('requestBytes')} ${this.formatBytes(this.querySummary.requestBytes)} / ${this.t('responseBytes')} ${this.formatBytes(this.querySummary.responseBytes)})`)
            .fontSize(12)
            .fontColor(this.mutedTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.cardSurfaceTone())
        .borderRadius(20)
        .shadow({ radius: 14, color: this.cardShadowTone() })
        .onClick(() => {
          // Expanding from the "recent DNS requests" card always lands on the
          // "All" tab (the Allowed/Blocked cards above jump to their own tab).
          this.openDnsSheetWithFilter('all');
        })

        Column({ space: 12 }) {
          Row() {
            Text(this.t('domainLeaderboard'))
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
            Blank()
            Text(this.t('clickToExpand'))
              .fontSize(13)
              .fontColor(this.accentBlueTone())
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

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
                  Text(`${this.t('allowed')}: ${item.allowed} · ${this.t('blocked')}: ${item.blocked}`)
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
                .borderRadius(14)
              }, (item: DomainQueryStats) => `${item.domain}_${item.total}_${item.totalDnsBytes}`)
            }
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.cardSurfaceTone())
        .borderRadius(20)
        .shadow({ radius: 14, color: this.cardShadowTone() })
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
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 0 })
      .padding({ bottom: this.contentBottomInset() })
      // Bound on the shared parent (ancestor of the Allowed/Blocked cards and the
      // recent-requests card) so any of them opens it reliably — a cross-component
      // bindSheet anchored on one sibling card was flaky when triggered from another.
      .bindSheet(this.showDnsSheet, this.DnsRequestsSheet(), {
        height: '92%',
        backgroundColor: this.sheetSurfaceTone(),
        showClose: false,
        onDisappear: () => {
          this.showDnsSheet = false;
        }
      })
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
            Column({ space: 2 }) {
              Text(this.tri('RULE MANAGEMENT', '规则管理', '規則管理'))
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .letterSpacing(1.5)
                .fontColor(this.selectedChipTextTone())
              Text(this.t('configTitle'))
                .fontSize(26)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.primaryTextColor())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .justifyContent(FlexAlign.Center)

            Stack() {
              Text('+')
                .fontSize(26)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
            }
            .width(46)
            .height(46)
            .borderRadius(23)
            .backgroundColor(this.accentBlueTone())
            .shadow({ radius: 10, color: '#33255DFF' })
            .rotate({ angle: this.showImportMenu ? 45 : 0 })
            .animation({ duration: 200, curve: Curve.EaseInOut })
            .onClick(() => {
              this.showImportMenu = !this.showImportMenu;
            })
          }
          .alignItems(VerticalAlign.Center)

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
        .backgroundColor(this.cardSurfaceTone())
        .borderRadius(22)
        .shadow({ radius: 16, color: this.cardShadowTone() })

        // ===== Quick import menu (toggled by the + button) =====
        if (this.showImportMenu) {
          Column({ space: 10 }) {
            Row() {
              Text(this.tri('📥 Quick import', '📥 快速导入', '📥 快速匯入'))
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.primaryTextColor())
              Blank()
              Button('✕')
                .type(ButtonType.Circle)
                .width(28)
                .height(28)
                .fontSize(13)
                .backgroundColor(this.softPanelTone())
                .fontColor(this.secondaryTextColor())
                .onClick(() => {
                  this.showImportMenu = false;
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Button(this.tri('📁 Import from file', '📁 从文件导入', '📁 從檔案匯入'))
              .type(ButtonType.Normal)
              .width('100%')
              .height(42)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(this.softGreenTone())
              .fontColor(this.accentGreenTone())
              .borderRadius(12)
              .onClick(() => {
                this.showImportMenu = false;
                this.importRulesFile().catch((err: BusinessError) => {
                  this.errorText = this.errorMessage(err);
                });
              })

            Row({ space: 8 }) {
              TextInput({ text: this.subAddUrlInput, placeholder: 'https://example.com/list.txt' })
                .layoutWeight(1)
                .height(42)
                .fontSize(14)
                .backgroundColor(this.softPanelTone())
                .borderRadius(12)
                .border({ width: 1, color: this.cardBorderTone() })
                .padding({ left: 12, right: 12 })
                .onChange((value: string) => {
                  this.subAddUrlInput = value;
                })
              Button(this.tri('🔗 Add', '🔗 导入', '🔗 匯入'))
                .type(ButtonType.Normal)
                .height(42)
                .padding({ left: 14, right: 14 })
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .backgroundColor(this.accentBlueTone())
                .fontColor('#FFFFFF')
                .borderRadius(12)
                .onClick(() => {
                  this.addFilterSubscription('', this.subAddUrlInput);
                })
            }
            .width('100%')

            if (this.subFeedbackText.length > 0) {
              Text(this.subFeedbackText)
                .fontSize(12)
                .fontColor(this.accentBlueTone())
                .fontWeight(FontWeight.Medium)
                .width('100%')
            }

            Text(this.tri('📚 Browse online library — see Recommended lists below',
              '📚 浏览在线库：见下方「推荐规则库」', '📚 瀏覽線上庫：見下方「推薦規則庫」'))
              .fontSize(12)
              .fontColor(this.mutedTextColor())
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .backgroundColor(this.cardSurfaceTone())
          .borderRadius(20)
          .shadow({ radius: 14, color: this.cardShadowTone() })
        }

        // ===== Overview stats =====
        Column({ space: 10 }) {
          Text(this.tri('OVERVIEW', '概览统计', '概覽統計'))
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(1.5)
            .fontColor(this.selectedChipTextTone())
            .width('100%')
          Row({ space: 10 }) {
            this.OverviewStatCell({ label: this.tri('Enabled rules', '已启用规则', '已啟用規則'),
              value: `${this.enabledRuleProfileCount() + this.enabledSubscriptionCount()}`, valueColor: this.accentGreenTone() })
            this.OverviewStatCell({ label: this.tri('Local · Subs', '本地 · 订阅', '本地 · 訂閱'),
              value: `${this.ruleProfiles.length} · ${this.filterSubscriptions.length}`, valueColor: this.primaryTextColor() })
          }
          .width('100%')
          Row({ space: 10 }) {
            this.OverviewStatCell({ label: this.tri('Blocked', '已拦截', '已攔截'),
              value: `${this.displayBlocked()}`, valueColor: this.isDarkModeActive() ? '#FF8A8A' : '#D14343' })
            this.OverviewStatCell({ label: this.tri('Allowed', '已放行', '已放行'),
              value: `${this.displayAllowed()}`, valueColor: this.accentGreenTone() })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(this.cardSurfaceTone())
        .borderRadius(20)
        .shadow({ radius: 14, color: this.cardShadowTone() })

        if (this.ruleProfiles.length === 0) {
          Column({ space: 14 }) {
            Stack() {
              Text('⚙')
                .fontSize(30)
                .fontColor(this.accentBlueTone())
            }
            .width(64)
            .height(64)
            .borderRadius(32)
            .backgroundColor(this.softBlueTone())

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
              .height(46)
              .margin({ top: 4 })
              .padding({ left: 28, right: 28 })
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .backgroundColor(this.accentBlueTone())
              .fontColor('#FFFFFF')
              .borderRadius(14)
              .shadow({ radius: 12, color: '#33255DFF' })
              .onClick(() => {
                this.importRulesFile().catch((err: BusinessError) => {
                  this.errorText = this.errorMessage(err);
                });
              })
          }
          .width('100%')
          .margin({ top: 4 })
          .padding({ left: 24, right: 24, top: 40, bottom: 40 })
          .alignItems(HorizontalAlign.Center)
          .backgroundColor(this.cardSurfaceTone())
          .borderRadius(20)
          .shadow({ radius: 14, color: this.cardShadowTone() })
        } else {
          Text(this.tri('MY RULES', '我的规则', '我的規則'))
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .letterSpacing(1.5)
            .fontColor(this.selectedChipTextTone())
            .width('100%')
            .margin({ top: 4, bottom: 2 })

          Column({ space: 12 }) {
            ForEach(this.ruleProfiles, (profile: RuleProfile, index: number) => {
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
                  Button(this.t('editRule'))
                    .height(36)
                    .layoutWeight(1)
                    .fontSize(14)
                    .backgroundColor(this.softBlueTone())
                    .fontColor(this.selectedChipTextTone())
                    .borderRadius(12)
                    .onClick(() => {
                      this.openRuleEditor(profile.id);
                    })
                  Button(this.t('deleteRule'))
                    .enabled(!profile.builtIn)
                    .height(36)
                    .layoutWeight(1)
                    .fontSize(14)
                    .backgroundColor(this.softRedTone())
                    .fontColor(this.isDarkModeActive() ? '#FF8A8A' : '#B42318')
                    .borderRadius(12)
                    .onClick(() => {
                      this.confirmDeleteRuleProfile(profile.id);
                    })
                }
                .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 16, right: 16, top: 18, bottom: 18 })
              .backgroundColor(this.cardSurfaceTone())
              .borderRadius(18)
              .shadow({ radius: 14, color: this.cardShadowTone() })
            }, (profile: RuleProfile) => this.ruleProfileRenderKey(profile))
          }
          .width('100%')
          .margin({ top: 4 })
        }

        // ===== Recommended rule libraries (collapsible, wired to real subscriptions) =====
        Column({ space: 10 }) {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(this.tri('📚 Recommended lists', '📚 推荐规则库', '📚 推薦規則庫'))
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .letterSpacing(1.5)
                .fontColor(this.selectedChipTextTone())
              Text(this.tri('Full engine only · applied when filtering starts',
                '仅完整引擎有效 · 启动过滤时生效', '僅完整引擎有效 · 啟動過濾時生效'))
                .fontSize(11)
                .fontColor(this.mutedTextColor())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            if (SUBSCRIPTION_PRESETS.length > 3) {
              Text(this.showRecommendedLibrary
                  ? this.tri('Collapse ▲', '收起 ▲', '收起 ▲')
                  : this.tri(`Show more (${SUBSCRIPTION_PRESETS.length - 3}) ▼`,
                      `查看更多 (${SUBSCRIPTION_PRESETS.length - 3}) ▼`,
                      `查看更多 (${SUBSCRIPTION_PRESETS.length - 3}) ▼`))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.selectedChipTextTone())
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.coolNeutralChipSurfaceTone())
                .borderRadius(10)
                .border({ width: 1, color: this.cardBorderTone() })
                .onClick(() => {
                  this.showRecommendedLibrary = !this.showRecommendedLibrary;
                })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          ForEach(SUBSCRIPTION_PRESETS.slice(0, 3), (preset: SubscriptionPreset) => {
            this.RecommendedPresetRow(preset)
          }, (preset: SubscriptionPreset) => preset.url)

          if (this.showRecommendedLibrary) {
            ForEach(SUBSCRIPTION_PRESETS.slice(3), (preset: SubscriptionPreset) => {
              this.RecommendedPresetRow(preset)
            }, (preset: SubscriptionPreset) => preset.url)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })
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
    if (this.showSettingsPage) {
      this.SettingsSubPage();
    } else {
      Scroll() {
        Column({ space: 16 }) {
        Text(this.t('tabMe'))
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .width('100%')
          .margin({ left: 4, bottom: 2 })

        // 🎨 外观
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.tri('🎨 Appearance', '🎨 外观', '🎨 外觀') })
          Column({ space: 12 }) {
            Text(this.tri('Theme', '主题', '主題'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
              .width('100%')
            Row({ space: 5 }) {
              this.ThemeSegButton({ label: this.t('themeAuto'), mode: ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET })
              this.ThemeSegButton({ label: this.t('themeLight'), mode: ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT })
              this.ThemeSegButton({ label: this.t('themeDark'), mode: ConfigurationConstant.ColorMode.COLOR_MODE_DARK })
            }
            .width('100%')
            .padding(5)
            .backgroundColor(this.softPanelTone())
            .borderRadius(14)
            .border({ width: 1, color: this.cardBorderTone() })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ⚙️ 功能
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.tri('⚙️ Features', '⚙️ 功能', '⚙️ 功能') })
          Column() {
            Row({ space: 12 }) {
              this.SettingsIconText({ glyph: this.sectionGlyph('settings'), iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
                title: this.t('settingsTitle'), desc: this.t('settingsEntryHint') })
              Text('›')
                .fontSize(20)
                .fontColor(this.secondaryTextColor())
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.showSettingsPage = true;
            })

            Divider().strokeWidth(1).color(this.cardBorderTone())

            Row({ space: 12 }) {
              this.SettingsIconText({ glyph: '⚡', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
                title: this.t('autoStartFilter'), desc: this.t('autoStartFilterHint') })
              Toggle({ type: ToggleType.Switch, isOn: this.autoStartFilterEnabled })
                .onChange((value: boolean) => {
                  this.onAutoStartFilterChange(value).catch((err: BusinessError) => {
                    this.errorText = this.errorMessage(err);
                  });
                })
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 🔋 后台保活
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.tri('🔋 Background', '🔋 后台保活', '🔋 背景保活') })
          Column() {
            Row({ space: 12 }) {
              this.SettingsIconText({ glyph: '♪', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF8F2', iconFg: '#179160',
                title: this.t('audioKeepAlive'), desc: this.t('audioKeepAliveHint') })
              Toggle({ type: ToggleType.Switch, isOn: this.audioKeepAliveEnabled })
                .selectedColor(this.accentGreenTone())
                .onChange((value: boolean) => {
                  this.toggleAudioKeepAlive(value).catch((err: BusinessError) => {
                    this.errorText = this.errorMessage(err);
                  });
                })
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)

            Divider().strokeWidth(1).color(this.cardBorderTone())

            Row({ space: 12 }) {
              this.SettingsIconText({ glyph: '◉', iconBg: this.isDarkModeActive() ? '#3A2E12' : '#FBEFD7', iconFg: '#C77E12',
                title: this.t('locationKeepAlive'), desc: this.t('locationKeepAliveHint') })
              Toggle({ type: ToggleType.Switch, isOn: this.locationKeepAliveEnabled })
                .onChange((value: boolean) => {
                  this.onLocationKeepAliveChange(value).catch((err: BusinessError) => {
                    this.errorText = this.errorMessage(err);
                  });
                })
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)

            if (this.keepAliveStatusText.length > 0) {
              Text(this.keepAliveStatusText)
                .fontSize(12)
                .fontColor(this.keepAliveRunning ? this.accentGreenTone() : this.secondaryTextColor())
                .width('100%')
                .margin({ top: 4, bottom: 4 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ℹ️ 关于
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.tri('ℹ️ About', 'ℹ️ 关于', 'ℹ️ 關於') })
          Column() {
            Row() {
              Text(this.tri('Version', '版本', '版本'))
                .fontSize(14)
                .fontColor(this.secondaryTextColor())
              Blank()
              Text(`${this.appVersionName} (${this.appVersionCode})`)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.primaryTextColor())
            }
            .width('100%')
            .padding({ top: 11, bottom: 11 })
            .alignItems(VerticalAlign.Center)

            Divider().strokeWidth(1).color(this.cardBorderTone())

            Row() {
              Text(this.tri('Mode', '模式', '模式'))
                .fontSize(14)
                .fontColor(this.secondaryTextColor())
              Blank()
              Text(this.t('modeValue'))
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.primaryTextColor())
            }
            .width('100%')
            .padding({ top: 11, bottom: 11 })
            .alignItems(VerticalAlign.Center)

            Divider().strokeWidth(1).color(this.cardBorderTone())

            Row() {
              Text('IPv6 DNS')
                .fontSize(14)
                .fontColor(this.secondaryTextColor())
              Blank()
              Text(this.t('enabled'))
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.primaryTextColor())
            }
            .width('100%')
            .padding({ top: 11, bottom: 11 })
            .alignItems(VerticalAlign.Center)

            Divider().strokeWidth(1).color(this.cardBorderTone())

            Row() {
              Text(this.tri('License', '许可证', '授權'))
                .fontSize(14)
                .fontColor(this.secondaryTextColor())
              Blank()
              Text('GPL-3.0  ›')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.accentBlueTone())
            }
            .width('100%')
            .padding({ top: 11, bottom: 11 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.openLicensePage();
            })

            Divider().strokeWidth(1).color(this.cardBorderTone())

            Row() {
              Text(this.tri('Disclaimer', '免责声明', '免責聲明'))
                .fontSize(14)
                .fontColor(this.secondaryTextColor())
              Blank()
              Text(this.tri('View ›', '查看 ›', '查看 ›'))
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.accentBlueTone())
            }
            .width('100%')
            .padding({ top: 11, bottom: 11 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.showDisclaimerSheet = true;
            })
            .bindSheet(this.showDisclaimerSheet, this.DisclaimerSheet(), {
              height: '60%',
              backgroundColor: this.sheetSurfaceTone(),
              showClose: false,
              onDisappear: () => {
                this.showDisclaimerSheet = false;
              }
            })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
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
  }

  @Builder
  private SettingsSubPage() {
    Scroll() {
      Column({ space: 14 }) {
        // ===== Slim header =====
        Row({ space: 12 }) {
          Button(this.t('back'))
            .height(38)
            .padding({ left: 14, right: 14 })
            .fontSize(14)
            .backgroundColor(this.coolNeutralChipSurfaceTone())
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
            .fontColor(this.primaryTextColor())
            .borderRadius(12)
            .border({ width: 1, color: this.cardBorderTone() })
            .onClick(() => {
              this.showSettingsPage = false;
            })

          Column({ space: 2 }) {
            Text(this.t('settingsTitle'))
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
            Text(this.t('settingsSubtitle'))
              .fontSize(13)
              .fontColor(this.secondaryTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 4, right: 4, top: 4, bottom: 2 })

        // ===== 🌍 语言 =====
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.tri('🌍 Language', '🌍 语言', '🌍 語言') })
          Column() {
            Row({ space: 5 }) {
              this.LangSegButton(this.t('langZhHans'), 'zhHans')
              this.LangSegButton(this.t('langEn'), 'en')
              this.LangSegButton(this.t('langZhHant'), 'zhHant')
            }
            .width('100%')
            .padding(5)
            .backgroundColor(this.softPanelTone())
            .borderRadius(14)
            .border({ width: 1, color: this.cardBorderTone() })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(12)
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ===== 🛡️ 过滤规则 =====
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.tri('🛡️ Filtering', '🛡️ 过滤规则', '🛡️ 過濾規則') })
          Column() {
            // Blocked services — works in both engines, always enabled.
            Row({ space: 12 }) {
              this.SettingsIconText({ glyph: '✕', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
                title: this.tri('Blocked services', '服务屏蔽', '服務屏蔽'),
                desc: this.tri(`${this.blockedServiceIds.length} blocked`,
                  `已屏蔽 ${this.blockedServiceIds.length} 个`, `已屏蔽 ${this.blockedServiceIds.length} 個`) })
              Text('›')
                .fontSize(20)
                .fontColor(this.secondaryTextColor())
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.servicesSearchText = '';
              this.detailServiceId = '';
              this.showServicesSheet = true;
            })
            .bindContentCover(this.showServicesSheet, this.ServicesSheet(), {
              modalTransition: ModalTransition.DEFAULT,
              onDisappear: () => {
                this.showServicesSheet = false;
                this.detailServiceId = '';
              }
            })

            Divider().strokeWidth(1).color(this.cardBorderTone())

            // Online subscriptions — full engine only.
            Row({ space: 12 }) {
              this.SettingsIconText({ glyph: '≋', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
                title: this.tri('Online subscriptions', '在线规则订阅', '線上規則訂閱'),
                desc: this.tri(`${this.enabledSubscriptionCount()} on / ${this.filterSubscriptions.length} total`,
                  `已启用 ${this.enabledSubscriptionCount()} / 共 ${this.filterSubscriptions.length}`,
                  `已啟用 ${this.enabledSubscriptionCount()} / 共 ${this.filterSubscriptions.length}`) })
              Text('›')
                .fontSize(20)
                .fontColor(this.secondaryTextColor())
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
            .opacity(this.fullModeEnabled ? 1 : 0.4)
            .onClick(() => {
              if (!this.fullModeEnabled) {
                this.notifyFullEngineRequired();
                return;
              }
              this.subFeedbackText = '';
              this.subAddNameInput = '';
              this.subAddUrlInput = '';
              this.showSubscriptionsSheet = true;
            })
            .bindContentCover(this.showSubscriptionsSheet, this.SubscriptionsSheet(), {
              modalTransition: ModalTransition.DEFAULT,
              onDisappear: () => {
                this.showSubscriptionsSheet = false;
              }
            })

            Divider().strokeWidth(1).color(this.cardBorderTone())

            // DNS rewrites — full engine only.
            Row({ space: 12 }) {
              this.SettingsIconText({ glyph: '◎', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
                title: this.tri('DNS rewrites', 'DNS 重写', 'DNS 重寫'),
                desc: this.tri(`${this.dnsRewrites.length} rewrites`,
                  `共 ${this.dnsRewrites.length} 条`, `共 ${this.dnsRewrites.length} 條`) })
              Text('›')
                .fontSize(20)
                .fontColor(this.secondaryTextColor())
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
            .opacity(this.fullModeEnabled ? 1 : 0.4)
            .onClick(() => {
              if (!this.fullModeEnabled) {
                this.notifyFullEngineRequired();
                return;
              }
              this.rewriteFeedbackText = '';
              this.rewriteAddDomainInput = '';
              this.rewriteAddAnswerInput = '';
              this.showRewritesSheet = true;
            })
            .bindContentCover(this.showRewritesSheet, this.RewritesSheet(), {
              modalTransition: ModalTransition.DEFAULT,
              onDisappear: () => {
                this.showRewritesSheet = false;
              }
            })

            Divider().strokeWidth(1).color(this.cardBorderTone())

            // Advanced DNS — full engine only.
            Row({ space: 12 }) {
              this.SettingsIconText({ glyph: '⚙', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
                title: this.tri('Advanced DNS', 'DNS 高级设置', 'DNS 進階設定'),
                desc: `${this.blockingModeLabel(this.advancedDns.blockingMode)} · ${this.upstreamModeLabel(this.advancedDns.upstreamMode)}` })
              Text('›')
                .fontSize(20)
                .fontColor(this.secondaryTextColor())
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
            .opacity(this.fullModeEnabled ? 1 : 0.4)
            .onClick(() => {
              if (!this.fullModeEnabled) {
                this.notifyFullEngineRequired();
                return;
              }
              this.cacheSizeInput = `${this.advancedDns.cacheSizeMb}`;
              this.ratelimitInput = `${this.advancedDns.ratelimit}`;
              this.showAdvancedDnsSheet = true;
            })
            .bindContentCover(this.showAdvancedDnsSheet, this.AdvancedDnsSheet(), {
              modalTransition: ModalTransition.DEFAULT,
              onDisappear: () => {
                this.showAdvancedDnsSheet = false;
              }
            })

            Divider().strokeWidth(1).color(this.cardBorderTone())

            // AdGuardHome dashboard — full engine + running.
            Row({ space: 12 }) {
              this.SettingsIconText({ glyph: '⌘', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
                title: this.tri('AdGuardHome dashboard', 'AdGuardHome 管理面板', 'AdGuardHome 管理面板'),
                desc: this.tri('Opens in browser · needs full engine running', '浏览器打开 · 需完整引擎并正在运行', '瀏覽器開啟 · 需完整引擎並正在執行') })
              Text('↗')
                .fontSize(18)
                .fontColor(this.secondaryTextColor())
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
            // Enabled whenever the full engine is running, in either VPN or
            // DNS-proxy mode (activeRunning tracks whichever is active).
            .opacity(this.fullModeEnabled && this.activeRunning() ? 1 : 0.4)
            .onClick(() => {
              if (!this.fullModeEnabled) {
                this.notifyFullEngineRequired();
                return;
              }
              if (!this.activeRunning()) {
                try {
                  this.ensurePromptAction()?.showToast({
                    message: this.tri('Start filtering first', '请先启动过滤', '請先啟動過濾')
                  });
                } catch (_) {
                }
                return;
              }
              this.openAghInBrowser();
            })

            if (!this.fullModeEnabled) {
              Text(this.tri('Subscriptions / rewrites / advanced DNS / dashboard need the full engine — switch it on the Home page.',
                '订阅 / 重写 / 高级 DNS / 管理面板 需完整引擎，请在首页切换。',
                '訂閱 / 重寫 / 進階 DNS / 管理面板 需完整引擎，請在首頁切換。'))
                .fontSize(11)
                .lineHeight(16)
                .fontColor(this.mutedTextColor())
                .width('100%')
                .margin({ top: 8, bottom: 4 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 6, bottom: 6 })
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ===== 🔗 上游 DNS =====
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.tri('🔗 Upstream DNS', '🔗 上游 DNS', '🔗 上游 DNS') })
          Column({ space: 10 }) {
            Text(this.t('upstreamDnsHint'))
              .fontSize(12)
              .lineHeight(18)
              .fontColor(this.secondaryTextColor())
              .width('100%')

            TextArea({ text: this.upstreamDnsInput, placeholder: DEFAULT_UPSTREAM_DNS_IP })
              .width('100%')
              .height(80)
              .fontSize(15)
              .backgroundColor(this.sheetInputSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .borderRadius(14)
              .border({ width: 1, color: this.sheetBorderTone() })
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .onChange((value: string) => {
                this.onUpstreamDnsInputChange(value);
              })

            Flex({ wrap: FlexWrap.Wrap }) {
              Button('AliDNS')
                .type(ButtonType.Normal)
                .fontSize(13)
                .fontColor(this.primaryTextColor())
                .backgroundColor(this.softPanelTone())
                .borderRadius(10)
                .border({ width: 1, color: this.cardBorderTone() })
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .margin({ right: 8, bottom: 8 })
                .onClick(() => {
                  this.addUpstreamPreset('223.5.5.5');
                })
              Button('DNSPod')
                .type(ButtonType.Normal)
                .fontSize(13)
                .fontColor(this.primaryTextColor())
                .backgroundColor(this.softPanelTone())
                .borderRadius(10)
                .border({ width: 1, color: this.cardBorderTone() })
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .margin({ right: 8, bottom: 8 })
                .onClick(() => {
                  this.addUpstreamPreset('119.29.29.29');
                })
              Button('Baidu')
                .type(ButtonType.Normal)
                .fontSize(13)
                .fontColor(this.primaryTextColor())
                .backgroundColor(this.softPanelTone())
                .borderRadius(10)
                .border({ width: 1, color: this.cardBorderTone() })
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .margin({ right: 8, bottom: 8 })
                .onClick(() => {
                  this.addUpstreamPreset('180.76.76.76');
                })
              Button('AdGuard')
                .type(ButtonType.Normal)
                .fontSize(13)
                .fontColor(this.primaryTextColor())
                .backgroundColor(this.softPanelTone())
                .borderRadius(10)
                .border({ width: 1, color: this.cardBorderTone() })
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .margin({ right: 8, bottom: 8 })
                .onClick(() => {
                  this.addUpstreamPreset('94.140.14.14');
                })
            }
            .width('100%')

            Button(this.t('upstreamDnsApply'))
              .type(ButtonType.Normal)
              .width('100%')
              .height(42)
              .fontSize(15)
              .fontColor(Color.White)
              .backgroundColor(this.accentBlueTone())
              .borderRadius(12)
              .onClick(() => {
                this.applyUpstreamDns(this.upstreamDnsInput);
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ===== 🧩 DNS 代理端口 =====
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.t('dnsProxyPortTitle') })
          Column({ space: 10 }) {
            Text(this.t('dnsProxyPortHint'))
              .fontSize(12)
              .lineHeight(18)
              .fontColor(this.secondaryTextColor())
              .width('100%')

            TextInput({ text: this.dnsProxyPort, placeholder: `${AGH_DNS_PORT}` })
              .type(InputType.Number)
              .width('100%')
              .height(44)
              .fontSize(15)
              .enabled(!this.dnsProxyRunning)
              .opacity(this.dnsProxyRunning ? 0.5 : 1)
              .backgroundColor(this.sheetInputSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .borderRadius(14)
              .border({ width: 1, color: this.sheetBorderTone() })
              .padding({ left: 12, right: 12 })
              .onChange((value: string) => {
                this.onDnsProxyPortChange(value);
              })

            if (this.dnsProxyPortFeedback.length > 0) {
              Text(this.dnsProxyPortFeedback)
                .fontSize(12)
                .fontColor('#C0392B')
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ===== 🖥️ AdGuardHome 面板端口 =====
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.t('aghPanelPortTitle') })
          Column({ space: 10 }) {
            Text(this.t('aghPanelPortHint'))
              .fontSize(12)
              .lineHeight(18)
              .fontColor(this.secondaryTextColor())
              .width('100%')

            TextInput({ text: this.aghHttpPort, placeholder: `${AGH_HTTP_PORT}` })
              .type(InputType.Number)
              .width('100%')
              .height(44)
              .fontSize(15)
              .enabled(!this.dnsProxyRunning && !this.status.running)
              .opacity((this.dnsProxyRunning || this.status.running) ? 0.5 : 1)
              .backgroundColor(this.sheetInputSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .borderRadius(14)
              .border({ width: 1, color: this.sheetBorderTone() })
              .padding({ left: 12, right: 12 })
              .onChange((value: string) => {
                this.onAghHttpPortChange(value);
              })

            if (this.aghHttpPortFeedback.length > 0) {
              Text(this.aghHttpPortFeedback)
                .fontSize(12)
                .fontColor('#C0392B')
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ===== 💾 缓存 =====
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.tri('💾 Cache', '💾 缓存', '💾 快取') })
          Column() {
            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text(this.language === 'en' ? `${this.t('dnsCacheTtlLabel')} (s)` : `${this.t('dnsCacheTtlLabel')}（秒）`)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.primaryTextColor())
                Text(this.t('dnsCacheHint'))
                  .fontSize(12)
                  .lineHeight(17)
                  .fontColor(this.secondaryTextColor())
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              TextInput({ text: this.dnsCacheTtlInput, placeholder: `${DEFAULT_DNS_CACHE_TTL_SECONDS}` })
                .width(96)
                .height(40)
                .fontSize(15)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.sheetInputSurfaceTone())
                .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                .borderRadius(12)
                .border({ width: 1, color: this.sheetBorderTone() })
                .padding({ left: 10, right: 10 })
                .onChange((value: string) => {
                  this.updateDnsCacheTtl(value);
                })
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ===== 📊 日志 =====
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.tri('📊 Logs', '📊 日志', '📊 日誌') })
          Column() {
            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text(this.t('logRetentionDaysLabel'))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.primaryTextColor())
                Text(this.t('logRetentionDaysHint'))
                  .fontSize(12)
                  .lineHeight(17)
                  .fontColor(this.secondaryTextColor())
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Row({ space: 6 }) {
                TextInput({ text: this.logRetentionDaysInput, placeholder: `${DEFAULT_LOG_RETENTION_DAYS}` })
                  .width(72)
                  .height(40)
                  .fontSize(15)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.sheetInputSurfaceTone())
                  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                  .borderRadius(12)
                  .border({ width: 1, color: this.sheetBorderTone() })
                  .padding({ left: 8, right: 8 })
                  .onChange((value: string) => {
                    this.updateLogRetentionDays(value);
                  })
                Text(this.language === 'en' ? 'd' : '天')
                  .fontSize(12)
                  .fontColor(this.secondaryTextColor())
              }
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)

            Divider().strokeWidth(1).color(this.cardBorderTone())

            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text(this.t('logMaxSizeMbLabel'))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.primaryTextColor())
                Text(this.t('logMaxSizeMbHint'))
                  .fontSize(12)
                  .lineHeight(17)
                  .fontColor(this.secondaryTextColor())
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Row({ space: 6 }) {
                TextInput({ text: this.logMaxSizeMbInput, placeholder: `${DEFAULT_LOG_MAX_SIZE_MB}` })
                  .width(72)
                  .height(40)
                  .fontSize(15)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.sheetInputSurfaceTone())
                  .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                  .borderRadius(12)
                  .border({ width: 1, color: this.sheetBorderTone() })
                  .padding({ left: 8, right: 8 })
                  .onChange((value: string) => {
                    this.updateLogMaxSizeMb(value);
                  })
                Text('MB')
                  .fontSize(12)
                  .fontColor(this.secondaryTextColor())
              }
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)

            Divider().strokeWidth(1).color(this.cardBorderTone())

            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text(this.t('clearDnsLogOnStart'))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.primaryTextColor())
                Text(this.t('clearDnsLogOnStartHint'))
                  .fontSize(12)
                  .lineHeight(17)
                  .fontColor(this.secondaryTextColor())
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.clearDnsLogOnStart })
                .onChange((value: boolean) => {
                  this.updateClearDnsLogOnStart(value);
                })
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)

            Divider().strokeWidth(1).color(this.cardBorderTone())

            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text(this.t('clearDebugLogOnStart'))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.primaryTextColor())
                Text(this.t('clearDebugLogOnStartHint'))
                  .fontSize(12)
                  .lineHeight(17)
                  .fontColor(this.secondaryTextColor())
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.clearDebugLogOnStart })
                .onChange((value: boolean) => {
                  this.updateClearDebugLogOnStart(value);
                })
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
          })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // ===== 🐛 调试 =====
        Column({ space: 8 }) {
          this.SettingsGroupTitle({ text: this.tri('🐛 Debug', '🐛 调试', '🐛 偵錯') })
          Row({ space: 12 }) {
            this.SettingsIconText({ glyph: '⋯', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
              title: this.t('debugLog'),
              desc: this.debugLines.length === 0
                ? this.t('noDebugLogs')
                : this.tri(`${this.debugLines.length} lines · tap to view`,
                    `${this.debugLines.length} 条 · 点击查看`, `${this.debugLines.length} 條 · 點擊查看`) })
            Text('›')
              .fontSize(20)
              .fontColor(this.secondaryTextColor())
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .backgroundColor(this.elevatedSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(22)
          .border({ width: 1, color: this.cardBorderTone() })
          .shadow({ radius: 12, color: this.cardShadowTone() })
          .linearGradient({
            angle: 145,
            colors: this.isDarkModeActive()
              ? [['#1C283BDB', 0.0], ['#22324ADB', 1.0]]
              : [['#FFFFFF', 0.0], ['#F6F8FB', 1.0]]
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
        .alignItems(HorizontalAlign.Start)
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

      Row() {
        Text(this.editingRuleProfile()?.name ?? this.editingRuleNameText)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
        .width('100%')
        .height(44)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.sheetInputSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
        .borderRadius(14)
        .border({ width: 1, color: this.sheetBorderTone() })
        .padding({ left: 12, right: 12 })

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

      if (this.builtInRuleEditorActive()) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            TextInput({ text: this.ruleLineInputText, placeholder: this.builtInRuleInputPlaceholder() })
              .layoutWeight(1)
              .height(44)
              .fontSize(14)
              .backgroundColor(this.sheetInputSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .borderRadius(14)
              .border({ width: 1, color: this.sheetBorderTone() })
              .padding({ left: 12, right: 12 })
              .onChange((value: string) => {
                this.ruleLineInputText = value;
              })
            Button(this.t('addRuleLine'))
              .height(44)
              .padding({ left: 16, right: 16 })
              .backgroundColor(this.coolChipSurfaceTone())
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
              .fontColor(this.selectedChipTextTone())
              .borderRadius(14)
              .border({ width: 1, color: this.cardBorderTone() })
              .onClick(() => {
                this.addRuleLineToEditor();
              })
          }
          .width('100%')

          Column() {
            if (this.editingRuleLineItems().length === 0) {
              Text(this.t('noCustomRulesHint'))
                .fontSize(13)
                .lineHeight(20)
                .textAlign(TextAlign.Center)
                .fontColor(this.secondaryTextColor())
            } else {
              List({ space: 8 }) {
                ForEach(this.editingRuleLineItems(), (item: RuleLineItem) => {
                  ListItem() {
                    Row({ space: 10 }) {
                      Text(item.line)
                        .layoutWeight(1)
                        .fontSize(14)
                        .fontColor(this.primaryTextColor())
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })

                      Button() {
                        Text('×')
                          .fontSize(18)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#B42318')
                      }
                      .width(32)
                      .height(32)
                      .backgroundColor(this.warmChipSurfaceTone())
                      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                      .borderRadius(16)
                      .border({ width: 1, color: this.cardBorderTone() })
                      .onClick(() => {
                        this.confirmDeleteRuleLine(item.index);
                      })
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)
                    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                    .backgroundColor(this.softPanelTone())
                    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
                    .borderRadius(14)
                    .border({ width: 1, color: this.cardBorderTone() })
                  }
                }, (item: RuleLineItem) => item.key)
              }
              .width('100%')
              .height('100%')
              .scrollBar(BarState.Auto)
            }
          }
          .width('100%')
          .height(306)
          .justifyContent(FlexAlign.Center)
          .padding(12)
          .backgroundColor(this.sheetInputSurfaceTone())
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .borderRadius(18)
          .border({ width: 1, color: this.sheetBorderTone() })
          .shadow({ radius: 10, color: this.sheetShadowTone() })
        }
        .width('100%')
      } else {
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
      }

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
            angle: 180,
            colors: this.isDarkModeActive()
              ? [['#0E1320', 0.0], ['#0C111C', 1.0]]
              : [['#F3F5F8', 0.0], ['#EDEFF3', 1.0]]
          })
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

      // First-launch disclaimer gate sits on top of everything.
      if (this.showFirstRunDisclaimer) {
        this.FirstRunDisclaimer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.canvasTone())
  }
}
