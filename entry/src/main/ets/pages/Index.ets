import { AbilityConstant, common, ConfigurationConstant, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { i18n, resourceManager } from '@kit.LocalizationKit';
import { connection, vpnExtension, socket, http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import {
  hdsMaterial, HdsNavDestination, HdsNavDestinationTitleMode, HdsNavigation, HdsNavigationMenuItemOptions,
  HdsNavigationTitleBarOptions, HdsNavigationTitleMode, HdsTabs
} from '@kit.UIDesignKit';
import { LengthMetrics, SymbolGlyphModifier, window } from '@kit.ArkUI';
import { geoLocationManager } from '@kit.LocationKit';
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { dnsLogDb, DnsLogRow, DnsLogSummary } from '../data/DnsLogDb';
import { dnsStats } from '../data/DnsStats';
import {
  archivedLogPaths, clearLogFile, DEFAULT_LOG_MAX_SIZE_MB, DEFAULT_LOG_RETENTION_DAYS, logCutoff,
  LOG_MAINTENANCE_INTERVAL_MS, LogReader, maintainLogFiles
} from '../data/LogRetention';
import { ConfigSyncConfirmation, ConfigSyncDevice, configSync } from '../data/ConfigSync';
import { formatVisualDnsRule, normalizeRuleDomain, parseVisualDnsRule, RuleQueryType,
  VisualDnsRule } from '../data/DnsRuleComposer';
import { aghSubscriptionId, seedAghSubscriptionCache, subscriptionCacheName } from '../data/SubscriptionCache';
import { blurTitleBar } from '../components/BlurTitleBar';
import { DEFAULT_SHIELD_PALETTE, paletteAlpha, SHIELD_PALETTES, ShieldColors, ShieldPalette,
  shieldPalette } from '../theme/ShieldPalette';
import {
  APP_SPLIT_MAX_BUNDLES, APP_TUNNEL_LOG_FILE, APP_TUNNEL_RULES_MAX_LENGTH,
  AppSplitEntry, AppSplitFile, AppSplitMode, isValidBundleName,
  normalizeAppSplitList, normalizeAppSplitMode, parseAppSplitDnsAllowlist
} from '../data/AppSplit';
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
// Stage-model ability name = the bare "name" from module.json5 ("EntryAbility"),
// NOT the bundle-prefixed form. A prefixed name still packages into a WantAgent
// (creation isn't validated), so keep-alive worked, but it FAILS to resolve when the
// notification's WantAgent is actually tapped — that's why tapping the persistent
// notification didn't open the app.
const ENTRY_ABILITY_NAME = 'EntryAbility';
const VPN_DIR_NAME = 'vpn';
const CONFIG_SYNC_PERMISSION: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC';
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
// The recent-rows window (leaderboard source) is only re-queried when new rows
// were ingested AND at least this long has passed since the last fetch — pulling
// 2000 rows out of SQLite every 1.2s tick is what froze the UI on big tables.
const RECENT_REFRESH_MIN_MS = 5000;
// Auto-restart of a dropped filter service: minimum gap between attempts
// (doubles per consecutive failure) and the give-up threshold.
const AUTO_RESTART_BASE_DELAY_MS = 5000;
const AUTO_RESTART_MAX_DELAY_MS = 60000;
const AUTO_RESTART_MAX_ATTEMPTS = 5;
// The debug-log preview only shows the last ~20 lines; read at most this many
// trailing bytes instead of the whole (potentially multi-MB) file every tick.
const DEBUG_LOG_TAIL_BYTES = 16384;
// How long after launch a "running" status stamped BEFORE launch may stay
// unconfirmed: the extension's pump may be idling at its slow heartbeat and
// only returns to the 1s cadence after noticing our ui_watch touch (≤1s) and
// stamping a write on its next tick; past this grace with no post-launch write
// the snapshot is a leftover of a killed session and declared dead.
const LAUNCH_STATUS_GRACE_MS = 5000;
// After a start request the extension takes a while to come up and transiently
// reports intermediate phases ('creating', even 'stopped' during a restart).
// Within this window the watchdog must not declare the service dead (it fired a
// duplicate start one tick after the first), and the home banner keeps showing
// "starting" instead of flashing "stopped".
const START_SETTLE_GRACE_MS = 15000;
const STATUS_FILE_NAME = 'status.json';
const RULES_FILE_NAME = 'filters.txt';
const QUERY_LOG_FILE_NAME = 'dns_queries.jsonl';
const DEBUG_LOG_FILE_NAME = 'debug.log';
const UPSTREAM_DNS_FILE_NAME = 'upstream.txt';
const STATE_FILE_NAME = 'ui_state.json';
// Touched (mtime refreshed) while this page is visible so the VPN extension's
// status pump knows someone is reading status.json and keeps its 1s cadence;
// when the marker goes stale the pump drops to IDLE_STATUS_HEARTBEAT_MS to
// save battery. Must match UI_WATCH_FILE_NAME in MyVpnExtAbility.
const UI_WATCH_FILE_NAME = 'ui_watch';
const UI_WATCH_TOUCH_INTERVAL_MS = 4000;
// Persistent stats-notification config consumed by the VPN extension. Must match
// NOTIFY_CONFIG_FILE_NAME in MyVpnExtAbility. The UI rewrites it on every settings
// change so the extension can apply toggle/interval/language live.
const NOTIFY_CONFIG_FILE_NAME = 'notify.json';
// Live cumulative baseline for the notification (see MyVpnExtAbility). Holds the
// home-page cumulative counts + the native session counts at capture time, so
// the VPN extension can show cumulative numbers that keep ticking in background.
const NOTIFY_COUNTS_FILE_NAME = 'notify_counts.json';
// Per-app routing settings mirrored for the running VPN extension, which
// watches the file and rebuilds the tun on change (must match MyVpnExtAbility).
const APP_SPLIT_FILE_NAME = 'app_split.json';
// Must match STATS_NOTIFICATION_ID in MyVpnExtAbility so proxy-mode (UI) and
// VPN-mode (extension) publish/cancel the same notification.
const STATS_NOTIFICATION_ID = 10010;
const DEFAULT_NOTIFICATION_REFRESH_SECONDS = 2;
const NOTIFICATION_REFRESH_MIN_SECONDS = 1;
const NOTIFICATION_REFRESH_MAX_SECONDS = 5;
// DATA_TRANSFER keep-alive progress refresh. The system cancels the task if the
// progress isn't updated for 10 minutes; once a minute leaves ample margin.
const DATA_TRANSFER_PROGRESS_INTERVAL_MS = 60000;
// Sub page names on the "Me" tab's navigation stack.
const ME_PAGE_PROTECTION = 'protection';
const ME_PAGE_PREFERENCES = 'preferences';
const ME_PAGE_BACKGROUND = 'background';
const ME_PAGE_DIAGNOSTICS = 'diagnostics';
const ME_PAGE_SYNC = 'sync';
const ME_PAGE_ABOUT = 'about';
const ME_PAGE_NETWORK = 'network';
const ME_PAGE_DNS = 'dns';
const ME_PAGE_WEB = 'web';
const ME_PAGE_APP_SPLIT = 'appSplit';
// Mirror of the extension's idle heartbeat. While the extension may still be
// idling (right after this page becomes visible, before it notices ui_watch),
// a "running" snapshot is allowed to be up to a heartbeat old; only once the
// fast cadence has had time to resume does the tight staleness limit apply.
const IDLE_STATUS_HEARTBEAT_MS = 30000;
const STATUS_IDLE_STALE_TIMEOUT_MS = IDLE_STATUS_HEARTBEAT_MS + 5000;
// How long after the page becomes visible the extension is expected to be back
// on the 1s cadence (ui_watch noticed ≤1s + a pump tick + our read tick).
const UI_WATCH_RESUME_GRACE_MS = 10000;
const WANT_STATUS_FILE_PATH = 'statusFilePath';
const WANT_RULES_FILE_PATH = 'rulesFilePath';
const WANT_QUERY_LOG_FILE_PATH = 'queryLogFilePath';
const WANT_DEBUG_LOG_FILE_PATH = 'debugLogFilePath';
const WANT_UPSTREAM_DNS_FILE_PATH = 'upstreamDnsFilePath';
const DEFAULT_UPSTREAM_DNS_IP = '119.29.29.29';
// Sentinel first line of upstream.txt that turns on auto upstream (follow the
// system/router DNS). Must match UPSTREAM_AUTO_MARKER in MyVpnExtAbility.
const UPSTREAM_AUTO_MARKER = '__AUTO__';
const WANT_DNS_CACHE_TTL_SECONDS = 'dnsCacheTtlSeconds';
const WANT_LOG_RETENTION_DAYS = 'logRetentionDays';
const WANT_LOG_MAX_SIZE_MB = 'logMaxSizeMb';
const WANT_CLEAR_DNS_LOG_ON_START = 'clearDnsLogOnStart';
const WANT_CLEAR_DEBUG_LOG_ON_START = 'clearDebugLogOnStart';
const DEFAULT_DNS_CACHE_TTL_SECONDS = 3600;
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
  | 'upstreamDnsEncryptedLabel' | 'upstreamDnsLiteOnlyIp'
  | 'logRetentionTitle' | 'logRetentionHint' | 'clearDnsLogOnStart' | 'clearDnsLogOnStartHint'
  | 'clearDebugLogOnStart' | 'clearDebugLogOnStartHint' | 'logRetentionDaysLabel' | 'logRetentionDaysHint'
  | 'logMaxSizeMbLabel' | 'logMaxSizeMbHint' | 'settingsEntry' | 'settingsEntryHint'
  | 'cacheHits' | 'cacheMisses' | 'sourcePrefix' | 'sourceCache' | 'sourceUpstream' | 'sourceBlocked'
  | 'domainCacheHits' | 'domainUpstreamQueries'
  | 'importedRules'
  | 'customBlockRules' | 'customAllowRules' | 'builtInRuleProfileLocked' | 'addRuleActionTitle'
  | 'addAllowRuleAction' | 'addBlockRuleAction' | 'ruleAddedNeedsRestart' | 'ruleAlreadyExists'
  | 'tapDomainToCreateRule' | 'addRuleLine' | 'customBlockRulePlaceholder' | 'customAllowRulePlaceholder'
  | 'confirmDeleteRuleLine' | 'removeAllRuleLines' | 'confirmRemoveAllBlockRules'
  | 'noCustomRulesHint' | 'swipeAgainToExit'
  | 'ruleListTitle' | 'ruleVisualMode' | 'ruleRawMode' | 'ruleDomainField' | 'ruleMatchScope'
  | 'ruleExactDomain' | 'ruleIncludeSubdomains' | 'ruleQueryType' | 'ruleAnyQuery' | 'rulePreviewTitle'
  | 'rulePreviewEmpty' | 'ruleInvalidDomain' | 'ruleSingleLineOnly' | 'ruleMoreActions' | 'ruleUpdateLine'
  | 'ruleDomainAndSubdomains' | 'ruleBlockPreview' | 'ruleAllowPreview'
  | 'continueLabel' | 'keepAliveWarnTitle' | 'keepAliveWarnMessage'
  | 'dnsProxyTitle' | 'dnsProxyDesc' | 'dnsProxyCopied' | 'dnsProxyStart' | 'dnsProxyStop'
  | 'dnsProxyDashboard' | 'dnsProxyDashboardDesc' | 'dnsProxyRunningStatus' | 'dnsProxyStoppedStatus'
  | 'dnsProxyStopVpnFirst' | 'dnsProxyEngineLite' | 'dnsProxyEngineFull'
  | 'modeVpn' | 'modeDnsProxy' | 'dnsProxyPortTitle' | 'dnsProxyPortHint' | 'dnsProxyPortInvalid'
  | 'aghPanelPortTitle' | 'aghPanelPortHint' | 'aghPanelPortConflict' | 'dnsProxyPortBumped'
  | 'autoRestartAttempt' | 'autoRestartGaveUp' | 'autoStarting' | 'startingStatus'
  | 'creatingVpnNote' | 'vpnActiveNote' | 'vpnStoppedNote'
  | 'notificationGroup' | 'persistentNotification' | 'persistentNotificationHint'
  | 'notificationRefreshInterval' | 'notificationRefreshIntervalHint'
  | 'notificationTitle' | 'notificationTotal'
  | 'configBackupGroup' | 'importConfig' | 'importConfigHint' | 'exportConfig' | 'exportConfigHint'
  | 'configImportInvalid' | 'configImportedSummary' | 'configImportSkipped'
  | 'upstreamAutoTitle' | 'upstreamAutoHint' | 'upstreamAutoCurrent' | 'upstreamAutoWaiting'
  | 'importRuleInvalid'
  | 'quickImport' | 'dataTransferKeepAlive' | 'dataTransferKeepAliveHint' | 'dataTransferMode' | 'dataTransferNotifyTitle' | 'keepAliveCancelledBySystem' | 'appSplitTitle' | 'appSplitEntryHint' | 'appSplitDesc' | 'appSplitProxyModeNote' | 'appSplitModeOff' | 'appSplitModeBypass' | 'appSplitModeOnly' | 'appSplitModeOffHint' | 'appSplitModeBypassHint' | 'appSplitModeOnlyHint' | 'appSplitCount' | 'appSplitListTitle' | 'appSplitEmpty' | 'appSplitApplying' | 'appSplitAddTitle' | 'appSplitBundleLabel' | 'appSplitBundlePlaceholder' | 'appSplitNameLabel' | 'appSplitNamePlaceholder' | 'appSplitAdd' | 'appSplitInvalidBundle' | 'appSplitSelfBundle' | 'appSplitDuplicate' | 'appSplitLimitReached'
  | 'configImportedAppSplit';

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
    case 'upstreamDnsEncryptedLabel': return $r('app.string.upstreamDnsEncryptedLabel').id;
    case 'upstreamDnsLiteOnlyIp': return $r('app.string.upstreamDnsLiteOnlyIp').id;
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
    case 'removeAllRuleLines': return $r('app.string.removeAllRuleLines').id;
    case 'confirmRemoveAllBlockRules': return $r('app.string.confirmRemoveAllBlockRules').id;
    case 'noCustomRulesHint': return $r('app.string.noCustomRulesHint').id;
    case 'ruleListTitle': return $r('app.string.ruleListTitle').id;
    case 'ruleVisualMode': return $r('app.string.ruleVisualMode').id;
    case 'ruleRawMode': return $r('app.string.ruleRawMode').id;
    case 'ruleDomainField': return $r('app.string.ruleDomainField').id;
    case 'ruleMatchScope': return $r('app.string.ruleMatchScope').id;
    case 'ruleExactDomain': return $r('app.string.ruleExactDomain').id;
    case 'ruleIncludeSubdomains': return $r('app.string.ruleIncludeSubdomains').id;
    case 'ruleQueryType': return $r('app.string.ruleQueryType').id;
    case 'ruleAnyQuery': return $r('app.string.ruleAnyQuery').id;
    case 'rulePreviewTitle': return $r('app.string.rulePreviewTitle').id;
    case 'rulePreviewEmpty': return $r('app.string.rulePreviewEmpty').id;
    case 'ruleInvalidDomain': return $r('app.string.ruleInvalidDomain').id;
    case 'ruleSingleLineOnly': return $r('app.string.ruleSingleLineOnly').id;
    case 'ruleMoreActions': return $r('app.string.ruleMoreActions').id;
    case 'ruleUpdateLine': return $r('app.string.ruleUpdateLine').id;
    case 'ruleDomainAndSubdomains': return $r('app.string.ruleDomainAndSubdomains').id;
    case 'ruleBlockPreview': return $r('app.string.ruleBlockPreview').id;
    case 'ruleAllowPreview': return $r('app.string.ruleAllowPreview').id;
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
    case 'autoRestartAttempt': return $r('app.string.autoRestartAttempt').id;
    case 'autoRestartGaveUp': return $r('app.string.autoRestartGaveUp').id;
    case 'autoStarting': return $r('app.string.autoStarting').id;
    case 'startingStatus': return $r('app.string.startingStatus').id;
    case 'creatingVpnNote': return $r('app.string.creatingVpnNote').id;
    case 'vpnActiveNote': return $r('app.string.vpnActiveNote').id;
    case 'vpnStoppedNote': return $r('app.string.vpnStoppedNote').id;
    case 'notificationGroup': return $r('app.string.notificationGroup').id;
    case 'persistentNotification': return $r('app.string.persistentNotification').id;
    case 'persistentNotificationHint': return $r('app.string.persistentNotificationHint').id;
    case 'notificationRefreshInterval': return $r('app.string.notificationRefreshInterval').id;
    case 'notificationRefreshIntervalHint': return $r('app.string.notificationRefreshIntervalHint').id;
    case 'notificationTitle': return $r('app.string.notificationTitle').id;
    case 'notificationTotal': return $r('app.string.notificationTotal').id;
    case 'configBackupGroup': return $r('app.string.configBackupGroup').id;
    case 'importConfig': return $r('app.string.importConfig').id;
    case 'importConfigHint': return $r('app.string.importConfigHint').id;
    case 'exportConfig': return $r('app.string.exportConfig').id;
    case 'exportConfigHint': return $r('app.string.exportConfigHint').id;
    case 'configImportInvalid': return $r('app.string.configImportInvalid').id;
    case 'configImportedSummary': return $r('app.string.configImportedSummary').id;
    case 'configImportSkipped': return $r('app.string.configImportSkipped').id;
    case 'upstreamAutoTitle': return $r('app.string.upstreamAutoTitle').id;
    case 'upstreamAutoHint': return $r('app.string.upstreamAutoHint').id;
    case 'upstreamAutoCurrent': return $r('app.string.upstreamAutoCurrent').id;
    case 'upstreamAutoWaiting': return $r('app.string.upstreamAutoWaiting').id;
    case 'importRuleInvalid': return $r('app.string.importRuleInvalid').id;
    case 'quickImport': return $r('app.string.quickImport').id;
    case 'dataTransferKeepAlive': return $r('app.string.dataTransferKeepAlive').id;
    case 'dataTransferKeepAliveHint': return $r('app.string.dataTransferKeepAliveHint').id;
    case 'dataTransferMode': return $r('app.string.dataTransferMode').id;
    case 'dataTransferNotifyTitle': return $r('app.string.dataTransferNotifyTitle').id;
    case 'keepAliveCancelledBySystem': return $r('app.string.keepAliveCancelledBySystem').id;
    case 'appSplitTitle': return $r('app.string.appSplitTitle').id;
    case 'appSplitEntryHint': return $r('app.string.appSplitEntryHint').id;
    case 'appSplitDesc': return $r('app.string.appSplitDesc').id;
    case 'appSplitProxyModeNote': return $r('app.string.appSplitProxyModeNote').id;
    case 'appSplitModeOff': return $r('app.string.appSplitModeOff').id;
    case 'appSplitModeBypass': return $r('app.string.appSplitModeBypass').id;
    case 'appSplitModeOnly': return $r('app.string.appSplitModeOnly').id;
    case 'appSplitModeOffHint': return $r('app.string.appSplitModeOffHint').id;
    case 'appSplitModeBypassHint': return $r('app.string.appSplitModeBypassHint').id;
    case 'appSplitModeOnlyHint': return $r('app.string.appSplitModeOnlyHint').id;
    case 'appSplitCount': return $r('app.string.appSplitCount').id;
    case 'appSplitListTitle': return $r('app.string.appSplitListTitle').id;
    case 'appSplitEmpty': return $r('app.string.appSplitEmpty').id;
    case 'appSplitApplying': return $r('app.string.appSplitApplying').id;
    case 'appSplitAddTitle': return $r('app.string.appSplitAddTitle').id;
    case 'appSplitBundleLabel': return $r('app.string.appSplitBundleLabel').id;
    case 'appSplitBundlePlaceholder': return $r('app.string.appSplitBundlePlaceholder').id;
    case 'appSplitNameLabel': return $r('app.string.appSplitNameLabel').id;
    case 'appSplitNamePlaceholder': return $r('app.string.appSplitNamePlaceholder').id;
    case 'appSplitAdd': return $r('app.string.appSplitAdd').id;
    case 'appSplitInvalidBundle': return $r('app.string.appSplitInvalidBundle').id;
    case 'appSplitSelfBundle': return $r('app.string.appSplitSelfBundle').id;
    case 'appSplitDuplicate': return $r('app.string.appSplitDuplicate').id;
    case 'appSplitLimitReached': return $r('app.string.appSplitLimitReached').id;
    case 'configImportedAppSplit': return $r('app.string.configImportedAppSplit').id;
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
  // Resolver actually in use (newline-joined) + whether auto-derived. Optional
  // for backward compat with snapshots written before this field existed.
  effectiveUpstream?: string;
  upstreamAuto?: boolean;
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
  domain: string;
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
  // Local download/validation status. The app fetches each enabled list, validates
  // it looks like a rule list, and caches it on disk: 'ok' (downloaded + valid),
  // 'failed' (unreachable or not a rule list — force-disabled), 'loading', or
  // undefined (not fetched yet). `lines` is the cached rule-line count.
  state?: string;
  lines?: number;
  err?: string;
}

// Result of fetching a URL's text body.
interface UrlFetchResult {
  ok: boolean;
  code: number;
  text: string;
  error: string;
}

// An upstream-DNS quick-fill chip. Encrypted (DoH/DoT) presets only work on the
// full AdGuardHome engine, so their chips are disabled on the lightweight engine.
interface UpstreamPreset {
  label: string;
  value: string;
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

// Passed by reference to settings @Builder helpers so they re-render when the
// in-app language changes (ArkUI memoizes value-type @Builder params, so the
// translated strings must arrive inside a fresh object each render).
interface SettingsGroupTitleParam {
  text: string;
}

interface SettingsRowTextParam {
  glyph: ResourceStr;
  iconBg?: string;
  iconFg?: string;
  title: string;
  desc: string;
  dimmed?: boolean;
}

interface MeLinkParam {
  name: string;
  icon: Resource;
  description: string;
  tile?: boolean;
}

const CONFIG_GRID: GridRowOptions = {
  columns: { xs: 1, sm: 2, md: 3 },
  gutter: 10,
  breakpoints: { value: ['520vp', '870vp'], reference: BreakpointsReference.ComponentSize }
};

interface ThemeSegButtonParam {
  label: string;
  mode: number;
}


function defaultAdvancedDnsConfig(): AdvancedDnsConfig {
  return {
    blockingMode: 'default',
    upstreamMode: 'load_balance',
    enableDnssec: false,
    cacheEnabled: true,
    cacheSizeMb: 4,
    // Optimistic caching answers from an expired entry and refreshes in the
    // background: fewer synchronous upstream round-trips means fewer radio
    // wakeups, which on a phone outweighs the marginally staler answers.
    cacheOptimistic: true,
    ratelimit: 0,
  };
}

interface PersistState {
  // Read only to remove generated service rules from older installations.
  blockedServiceIds?: string[];
  configSyncEnabled?: boolean;
  configSyncDeviceId?: string;
  keepAliveEnabled?: boolean;
  audioKeepAliveEnabled?: boolean;
  locationKeepAliveEnabled?: boolean;
  dataTransferKeepAliveEnabled?: boolean;
  autoStartFilterEnabled?: boolean;
  persistentNotificationEnabled?: boolean;
  notificationRefreshSeconds?: number;
  language?: LangCode;
  themeMode?: number;
  paletteId?: string;
  ruleProfiles?: RuleProfile[];
  dnsCacheTtlSeconds?: number;
  blockAaaa?: boolean;
  blockIpv6Connections?: boolean;
  upstreamDnsIp?: string;
  upstreamAutoEnabled?: boolean;
  logRetentionDays?: number;
  logMaxSizeMb?: number;
  logRetentionDefaultsApplied?: boolean;
  clearDnsLogOnStart?: boolean;
  clearDebugLogOnStart?: boolean;
  fullModeEnabled?: boolean;
  proxyModeEnabled?: boolean;
  dnsProxyPort?: string;
  aghHttpPort?: string;
  aghWebEnabled?: boolean;
  filterSubscriptions?: FilterSubscription[];
  dnsRewrites?: DnsRewriteRule[];
  advancedDns?: AdvancedDnsConfig;
  disclaimerAccepted?: boolean;
  appSplitMode?: string;
  appSplitList?: AppSplitEntry[];
  appSplitDnsAllowlistEnabled?: boolean;
  appSplitDnsAllowlist?: string;
  appTunnelEnabled?: boolean;
  appTunnelRules?: string;
  currentTab: number;
}

// Mirror of NotifyConfig in MyVpnExtAbility — the on-disk shape of notify.json.
interface NotifyConfigFile {
  enabled: boolean;
  refreshSeconds: number;
  title: string;
  blockedLabel: string;
  allowedLabel: string;
  totalLabel: string;
}

// Mirror of NotifyCounts in MyVpnExtAbility — the on-disk shape of
// notify_counts.json.
interface NotifyCountsFile {
  cumAllowed: number;
  cumBlocked: number;
  natAllowed: number;
  natBlocked: number;
}

// Import/export config JSON. The four list sections are compatible with the
// AdGuard-style adguard.json (sources / blocked / allowed / redirected); `app`
// is this app's extra settings and is ignored by other apps. Import accepts a
// plain adguard.json (no `app`); export always writes the superset.
// `sources[].allow` / `redirect` are AdGuard per-source flags this app doesn't
// model — kept for round-trip only. The list URLs themselves can be in any
// format (hosts / AdGuard / plain-domain): the full engine (AdGuardHome) fetches
// and parses them, so they're stored verbatim and only take effect in full mode.
interface ConfigSource {
  label: string;
  url: string;
  enabled: boolean;
  allow: boolean;
  redirect: boolean;
}

interface ConfigHostRule {
  host: string;
  enabled: boolean;
}

interface ConfigRedirect {
  host: string;
  redirect: string;
  enabled: boolean;
}

// An imported local rule list (a .txt/.conf snapshot, stored inline as content —
// distinct from `sources`, which are URLs the full engine re-downloads).
interface ConfigRuleProfile {
  name: string;
  content: string;
  enabled: boolean;
}

interface ConfigAppSettings {
  upstreamDns?: string;
  upstreamAuto?: boolean;
  fullMode?: boolean;
  blockAaaa?: boolean;
  blockIpv6Connections?: boolean;
  proxyModeEnabled?: boolean;
  dnsProxyPort?: string;
  aghHttpPort?: string;
  aghWebEnabled?: boolean;
  advancedDns?: AdvancedDnsConfig;
  dnsCacheTtlSeconds?: number;
  logRetentionDays?: number;
  logMaxSizeMb?: number;
  ruleProfiles?: ConfigRuleProfile[];
  // Per-app routing (data/AppSplit.ets): 'off' | 'bypass' | 'only', plus the list.
  appSplitMode?: string;
  appSplitApps?: AppSplitEntry[];
  appSplitDnsAllowlistEnabled?: boolean;
  appSplitDnsAllowlist?: string;
  appTunnelEnabled?: boolean;
  appTunnelRules?: string;
}

interface ConfigExport {
  sources: ConfigSource[];
  blocked: ConfigHostRule[];
  allowed: ConfigHostRule[];
  redirected: ConfigRedirect[];
  app?: ConfigAppSettings;
}

interface SyncedCustomRules {
  content: string;
  enabled: boolean;
}

interface SyncedConfig {
  sources: ConfigSource[];
  redirected: ConfigRedirect[];
  app: ConfigAppSettings;
  customBlock: SyncedCustomRules;
  customAllow: SyncedCustomRules;
}

// Per-section import tallies for the result toast.
interface ConfigImportResult {
  sources: number;
  blocked: number;
  allowed: number;
  redirected: number;
  ruleFiles: number;
  skippedSources: number;
  appSplitApps: number;
}

// mergeImportedSources outcome: added vs skipped (unusable, non-http(s) URLs).
interface SourceMergeResult {
  added: number;
  skipped: number;
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
  @State paletteId: string = DEFAULT_SHIELD_PALETTE;
  @State keepAliveEnabled: boolean = false;
  @State audioKeepAliveEnabled: boolean = true;
  @State locationKeepAliveEnabled: boolean = false;
  @State dataTransferKeepAliveEnabled: boolean = false;
  @State appSplitMode: AppSplitMode = 'off';
  @State appSplitList: AppSplitEntry[] = [];
  @State appSplitDnsAllowlistEnabled: boolean = false;
  @State appSplitDnsAllowlist: string = '';
  @State appSplitDnsAllowlistDraft: string = '';
  @State appSplitDnsAllowlistError: string = '';
  @State appTunnelEnabled: boolean = true;
  @State appTunnelRules: string = '';
  @State appTunnelRulesDraft: string = '';
  @State appTunnelRulesError: string = '';
  private appTunnelAvailable: boolean = vpnclientbridge.appTunnelAvailable();
  @State showAppSplitAddSheet: boolean = false;
  @State appSplitBundleInput: string = '';
  @State appSplitNameInput: string = '';
  @State appSplitAddError: string = '';
  @State autoStartFilterEnabled: boolean = false;
  // Persistent status-bar notification ("常驻通知栏") showing live filtered /
  // allowed / total DNS counts. Default OFF to save battery (republishing wakes
  // the device every few seconds); the refresh interval is 1-5s when enabled.
  @State persistentNotificationEnabled: boolean = false;
  @State notificationRefreshSeconds: number = DEFAULT_NOTIFICATION_REFRESH_SECONDS;
  @State keepAliveRunning: boolean = false;
  @State keepAliveStatusText: string = '';
  @State status: StatusSnapshot = defaultStatus();
  @State errorText: string = '';
  @State statusFilePath: string = '';
  @State rulesFilePath: string = '';
  @State queryLogFilePath: string = '';
  @State debugLogFilePath: string = '';
  private appTunnelLogFilePath: string = '';
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
  @State editingRuleLineIndex: number = -1;
  @State ruleComposerOpen: boolean = false;
  @State ruleComposerRaw: boolean = false;
  @State ruleComposerDomain: string = '';
  @State ruleComposerRawText: string = '';
  @State ruleComposerSubdomains: boolean = true;
  @State ruleComposerQueryType: RuleQueryType = 'all';
  @State ruleComposerError: string = '';
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
  @State private blockAaaa: boolean = false;
  @State private blockIpv6Connections: boolean = false;
  @State upstreamDnsInput: string = '';
  // Auto upstream: follow the system/router-provided DNS (default off). The
  // manual list above stays editable and serves as the fallback.
  @State upstreamAutoEnabled: boolean = false;
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
  // Whether the embedded AdGuardHome serves its web admin dashboard. Off by
  // default: the HTTP server (listener + serve goroutines) costs battery and
  // most sessions never open the panel. Applies to both full-mode VPN and
  // full-mode DNS proxy; changes restart the running engine.
  @State aghWebEnabled: boolean = false;
  // Actual bound ports while the DNS proxy runs (may differ from the configured
  // values when those were busy and auto-incremented). 0 = use the configured.
  @State dnsProxyActivePort: number = 0;
  @State aghActiveHttpPort: number = 0;
  @State showAghWebSheet: boolean = false;
  // Full-mode AdGuardHome extras: online subscriptions, DNS rewrites, advanced DNS.
  @State filterSubscriptions: FilterSubscription[] = [];
  @State dnsRewrites: DnsRewriteRule[] = [];
  @State advancedDns: AdvancedDnsConfig = defaultAdvancedDnsConfig();
  @State subAddNameInput: string = '';
  @State subAddUrlInput: string = '';
  @State subFeedbackText: string = '';
  // Subscription content viewer (tap a subscription to fetch and browse its list).
  @State showSubContentSheet: boolean = false;
  @State subContentTitle: string = '';
  @State subContentUrl: string = '';
  @State subContentText: string = '';
  @State subContentLineCount: number = 0;
  @State subContentLoading: boolean = false;
  @State subContentError: string = '';
  private subContentRequestSeq: number = 0;
  @State showRewritesSheet: boolean = false;
  @State rewriteAddDomainInput: string = '';
  @State rewriteAddAnswerInput: string = '';
  @State rewriteFeedbackText: string = '';
  @State showAdvancedDnsSheet: boolean = false;
  @State cacheSizeInput: string = '4';
  @State ratelimitInput: string = '0';
  private aghWebController: webview.WebviewController = new webview.WebviewController();
  @State showImportMenu: boolean = false;
  @State configOnlineTab: boolean = false;
  @State showAllMySubscriptions: boolean = false;
  @State showDisclaimerSheet: boolean = false;
  @State showFirstRunDisclaimer: boolean = false;
  private disclaimerAccepted: boolean = false;
  @State appVersionName: string = 'loading';
  @State appVersionCode: number = 0;
  @State avoidPaddingTop: number = 0;
  @State avoidPaddingBottom: number = 0;
  @State windowWidthVp: number = 0;
  @State windowHeightVp: number = 0;

  private refreshTimer: number = -1;
  // DNS query-log RDB ingestion state. The native layer keeps appending jsonl;
  // we incrementally ingest new lines into SQLite (DnsLogDb) and query it. Offsets
  // are BYTE offsets into the log file (only the appended tail is read each tick,
  // never the whole file); lastTs is the ingest watermark used to skip
  // already-stored rows on a full re-scan (launch/rotation).
  private dnsDbReady: boolean = false;
  private dnsDbInitStarted: boolean = false;
  private dnsRefreshing: boolean = false;
  private appLogReader: LogReader = new LogReader();
  private appLogLastTs: number = 0;
  private aghLogReader: LogReader = new LogReader();
  private lastDnsLogPruneAt: number = 0;
  private logMaintenanceTimer: number = -1;
  private logMaintenanceRunning: boolean = false;
  private lastLogMaintenanceAt: number = 0;
  private aghLogLastTs: number = 0;
  // Query-result caches for the refresh tick: the page/count SQL only reruns when
  // the sheet is open and either new rows arrived or the filter/search/page
  // changed; the recent window only reruns on new rows, rate-limited.
  private dnsLoadedQueryKey: string = '';
  private recentRowsLoaded: boolean = false;
  private lastRecentRefreshMs: number = 0;
  private logTailDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  // Auto-restart of a dropped service. "Desired" mirrors the user's intent (set
  // on start, cleared on manual stop); when the status pump reports the service
  // dead while still desired, it is restarted with exponential backoff.
  private vpnDesiredRunning: boolean = false;
  private dnsProxyDesiredRunning: boolean = false;
  private autoRestartAttempts: number = 0;
  private lastAutoRestartAt: number = 0;
  private autoRestarting: boolean = false;
  private autoRestartGaveUp: boolean = false;
  // When the last start request was issued (manual, auto-start, or watchdog);
  // drives the START_SETTLE_GRACE_MS hold-off.
  private lastStartRequestAt: number = 0;
  @State private vpnStartTimedOut: boolean = false;
  private pendingVpnStart: Promise<void> | undefined;
  private fullEngineRestartPending: boolean = false;
  // True while the auto-start permission probe briefly starts/stops the VPN, so
  // the watchdog does not adopt that transient run and restart it afterwards.
  private probingVpnPermission: boolean = false;
  // When this UI process started; used to reject "ghost running" status files
  // left behind by a killed session (see isStaleRunningSnapshot).
  private readonly appLaunchMs: number = Date.now();
  // ui_watch marker plumbing (see UI_WATCH_FILE_NAME): touched while visible,
  // throttled to one write per UI_WATCH_TOUCH_INTERVAL_MS.
  private uiWatchFilePath: string = '';
  private lastUiWatchTouchMs: number = 0;
  private notifyConfigFilePath: string = '';
  private notifyCountsFilePath: string = '';
  private appSplitFilePath: string = '';
  private lastAppSplitFileContent: string = '';
  private lastNotifyCountsSignature: string = '';
  // Proxy-mode notification: published by THIS process (no VPN extension exists in
  // DNS-proxy mode). Driven by a timer that runs regardless of page visibility so
  // it keeps updating while backgrounded (the proxy itself is kept alive by the
  // continuous task).
  private proxyNotifyTimer: number = -1;
  private lastUiNotificationText: string = '';
  private lastUiNotificationPublishMs: number = 0;
  private uiNotificationActive: boolean = false;
  private notificationWantAgent?: WantAgent;
  // When this page last became visible; until UI_WATCH_RESUME_GRACE_MS has
  // passed the extension may legitimately still be on its slow idle heartbeat.
  private uiWatchSinceMs: number = Date.now();
  private pageVisible: boolean = true;
  // True while a "running" snapshot stamped before launch is awaiting its first
  // post-launch write (live extension) or the grace timeout (dead leftover).
  // Auto-start and the watchdog hold off while this is set.
  private launchStatusPending: boolean = false;
  // Locale-specific resource manager so t() reflects the in-app language choice
  // immediately, without waiting for an app restart.
  private overrideResManager?: resourceManager.ResourceManager;
  private overrideResManagerLocale: string = '';
  private dnsListScroller: Scroller = new Scroller();
  private domainListScroller: Scroller = new Scroller();
  // One per scrolling page: HdsNavigation / HdsNavDestination bind to these to
  // drive the title bar's scroll blur.
  private homeScroller: Scroller = new Scroller();
  private configScroller: Scroller = new Scroller();
  private meScroller: Scroller = new Scroller();
  private meSectionScrollers: Map<string, Scroller> = new Map<string, Scroller>();
  @State private configSyncEnabled: boolean = false;
  @State private configSyncBusy: boolean = false;
  @State private configSyncStatus: string = '';
  @State private configSyncDevices: ConfigSyncDevice[] = [];
  private configSyncDeviceId: string = '';
  private configSyncInboxBusy: boolean = false;
  private configSyncInboxPending: boolean = false;
  private readonly onConfigSyncAvailable = (): void => {
    this.configSyncInboxPending = true;
    void this.receiveConfigSync();
  };
  private appSplitScroller: Scroller = new Scroller();
  // Sub pages of the "Me" tab (settings, per-app routing) live on this stack so
  // they get the same immersive title bar, back button and swipe-back.
  private meStack: NavPathStack = new NavPathStack();
  private continuousTaskId: number = -1;
  // DATA_TRANSFER keep-alive: the system cancels the task unless its live-view
  // progress notification is refreshed (first update within 10 min), so a timer
  // republishes it on the notification id returned by startBackgroundRunning.
  private dataTransferNotificationId: number = -1;
  private dataTransferTimer: number = -1;
  private dataTransferTick: number = 0;
  private continuousTaskListenersOn: boolean = false;
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
    if (this.showSubContentSheet) {
      this.closeSubContentSheet();
      return true;
    }
    // Normally the Navigation consumes back itself; this covers the case where
    // the event reaches the page first.
    if (this.meStack.size() > 0) {
      this.meStack.pop();
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
    return chunks.join('\n\n');
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
    this.restartFullEngineForConfig();
  }

  private restartFullEngineForConfig(): void {
    this.fullEngineRestartPending = this.fullModeEnabled &&
      (!this.canChangeFilterSettings() || this.showRuleEditorSheet);
    if (this.fullModeEnabled && !this.fullEngineRestartPending) {
      this.restartActiveFilter();
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

  // Collapse subscriptions that share a URL (keeping the first) and reassign
  // stable sequential ids. Without this, an import that re-adds an existing list
  // — or any corrupted persisted state with duplicate ids — makes the keyed
  // subscription List under-render (ForEach drops same-key items) while
  // filterSubscriptions.length keeps over-counting, so the overview shows e.g. 22
  // while the list only shows 8. Run on every import and on load so the list and
  // the count stay in lockstep.
  private dedupeSubscriptions(list: FilterSubscription[]): FilterSubscription[] {
    const seen: Set<string> = new Set<string>();
    const out: FilterSubscription[] = [];
    list.forEach((s: FilterSubscription) => {
      const url: string = typeof s?.url === 'string' ? s.url.trim() : '';
      if (url.length === 0 || seen.has(url)) {
        return;
      }
      seen.add(url);
      out.push({
        id: out.length + 1,
        name: typeof s?.name === 'string' && s.name.trim().length > 0 ? s.name.trim() : url,
        url: url,
        enabled: s?.enabled !== false,
        state: typeof s?.state === 'string' ? s.state : undefined,
        lines: typeof s?.lines === 'number' ? s.lines : undefined,
        err: typeof s?.err === 'string' ? s.err : undefined,
      });
    });
    return out;
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
      state: 'loading',
    }]);
    this.subAddNameInput = '';
    this.subAddUrlInput = '';
    this.subFeedbackText = this.tri('Added', '已添加', '已新增');
    this.applyFullModeConfigChange();
    // Download + validate the list now; a failure force-disables it.
    void this.downloadAndCacheSubscription(u, true);
  }

  // The subscriptions shown in the config-tab "My subscriptions" list — collapsed
  // to the first few until the user expands, so a big import doesn't flood the page.
  private mySubscriptionsToShow(): FilterSubscription[] {
    if (this.showAllMySubscriptions || this.filterSubscriptions.length <= 4) {
      return this.filterSubscriptions;
    }
    return this.filterSubscriptions.slice(0, 4);
  }

  private toggleFilterSubscription(id: number, enabled: boolean): void {
    let targetUrl: string = '';
    this.filterSubscriptions = this.filterSubscriptions.map((s: FilterSubscription) => {
      if (s.id === id) {
        targetUrl = s.url;
        return { id: s.id, name: s.name, url: s.url, enabled: enabled,
          state: s.state, lines: s.lines, err: s.err } as FilterSubscription;
      }
      return s;
    });
    this.applyFullModeConfigChange();
    // Enabling a list (re)downloads + validates it; failure force-disables it.
    if (enabled && targetUrl.length > 0) {
      void this.downloadAndCacheSubscription(targetUrl, true);
    }
  }

  private removeFilterSubscription(id: number): void {
    this.filterSubscriptions = this.filterSubscriptions.filter((s: FilterSubscription) => s.id !== id);
    this.subFeedbackText = this.tri('Removed', '已删除', '已刪除');
    this.applyFullModeConfigChange();
  }

  // ----- Subscription download + local cache -----

  private subsCacheDir(): string {
    return `${this.getHostContext().filesDir}/${VPN_DIR_NAME}/subs`;
  }

  // A stable per-URL cache filename (djb2 hash → hex) so the same list always maps
  // to the same local file regardless of display-name changes.
  private subCacheFilePath(url: string): string {
    return `${this.subsCacheDir()}/${subscriptionCacheName(url)}`;
  }

  private writeSubCache(url: string, content: string): void {
    try {
      fileIo.mkdirSync(this.subsCacheDir(), true);
    } catch (_) {
    }
    this.writeTextFile(this.subCacheFilePath(url), content);
  }

  private readSubCache(url: string): string {
    return this.readTextFile(this.subCacheFilePath(url));
  }

  // Non-empty, non-comment lines — the rule count shown on each subscription row.
  private countRuleLines(text: string): number {
    let n: number = 0;
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const t: string = lines[i].trim();
      if (t.length === 0 || t.startsWith('#') || t.startsWith('!')) {
        continue;
      }
      n += 1;
    }
    return n;
  }

  // Fetch a URL's text body (capped). Shared by the content viewer and the
  // download-on-subscribe flow.
  private async fetchUrlText(url: string, maxChars: number): Promise<UrlFetchResult> {
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      return { ok: false, code: 0, text: '',
        error: this.tri('Only http(s) lists can be fetched.', '仅支持 http(s) 列表。', '僅支援 http(s) 清單。') };
    }
    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.STRING,
      });
      if (resp.responseCode !== http.ResponseCode.OK) {
        return { ok: false, code: resp.responseCode, text: '',
          error: this.tri(`HTTP ${resp.responseCode}`, `HTTP ${resp.responseCode}`, `HTTP ${resp.responseCode}`) };
      }
      let body: string = typeof resp.result === 'string' ? resp.result : this.decodeHttpBody(resp.result);
      if (body.length > maxChars) {
        body = body.substring(0, maxChars);
      }
      return { ok: true, code: 200, text: body, error: '' };
    } catch (err) {
      return { ok: false, code: 0, text: '', error: this.errorMessage(err) };
    } finally {
      try {
        httpRequest.destroy();
      } catch (_) {
      }
    }
  }

  // Set a subscription's download status by URL, then re-render by reassigning the
  // array. A 'failed' list is force-disabled (its toggle defaults off — "enabled"
  // means downloaded + valid); 'ok'/'loading' keep the current enabled state.
  // Removal is a separate Delete button, so a disabled-failed list isn't stranded.
  private setSubscriptionStatus(url: string, state: string, lines: number, err: string): void {
    this.filterSubscriptions = this.filterSubscriptions.map((s: FilterSubscription) => {
      if (s.url !== url) {
        return s;
      }
      const enabled: boolean = state === 'failed' ? false : s.enabled;
      return { id: s.id, name: s.name, url: s.url, enabled: enabled, state: state, lines: lines, err: err };
    });
  }

  private markSubscriptionLoading(url: string): void {
    this.filterSubscriptions = this.filterSubscriptions.map((s: FilterSubscription) => {
      if (s.url !== url) {
        return s;
      }
      return { id: s.id, name: s.name, url: s.url, enabled: s.enabled, state: 'loading', lines: s.lines, err: '' };
    });
  }

  // Download a list, validate it looks like a rule list, cache it on disk, and
  // record the result. On failure (unreachable / not a rule list) the list is
  // force-disabled — "enabled" means "downloaded + valid" (the user's model).
  private async downloadAndCacheSubscription(url: string, persist: boolean = false): Promise<boolean> {
    this.markSubscriptionLoading(url);
    const res: UrlFetchResult = await this.fetchUrlText(url, 2000000);
    let ok: boolean = false;
    if (!res.ok) {
      this.setSubscriptionStatus(url, 'failed', 0, res.error);
    } else if (!this.looksLikeRuleList(res.text)) {
      this.setSubscriptionStatus(url, 'failed', 0,
        this.tri('Not a rule list (a web page?)', '不是规则列表（可能是网页）', '不是規則清單（可能是網頁）'));
    } else {
      this.writeSubCache(url, res.text);
      this.setSubscriptionStatus(url, 'ok', this.countRuleLines(res.text), '');
      ok = true;
    }
    if (persist) {
      this.savePersistState();
    }
    return ok;
  }

  // Download several lists concurrently, then persist + re-bake the running full
  // engine once (rather than per list).
  private async downloadSubscriptions(urls: string[]): Promise<void> {
    if (urls.length === 0) {
      return;
    }
    const tasks: Promise<boolean>[] = urls.map((u: string) => this.downloadAndCacheSubscription(u, false));
    await Promise.all(tasks);
    this.savePersistState();
    if (this.activeRunning() && this.fullModeEnabled) {
      this.applyFullModeConfigChange();
    }
  }

  // The per-row download status label ('' = nothing to show yet).
  private subStatusText(s: FilterSubscription): string {
    if (s.state === 'loading') {
      return this.tri('⏳ Downloading…', '⏳ 下载中…', '⏳ 下載中…');
    }
    if (s.state === 'failed') {
      const why: string = typeof s.err === 'string' && s.err.length > 0 ? s.err : '';
      return this.tri(`✗ Can't use: ${why}`, `✗ 无法使用：${why}`, `✗ 無法使用：${why}`);
    }
    if (s.state === 'ok') {
      const n: number = typeof s.lines === 'number' ? s.lines : 0;
      return this.tri(`✓ ${n} rules`, `✓ ${n} 条规则`, `✓ ${n} 條規則`);
    }
    return '';
  }

  private subStatusColor(s: FilterSubscription): string {
    if (s.state === 'failed') {
      return this.isDarkModeActive() ? '#FF8A8A' : '#D14343';
    }
    if (s.state === 'ok') {
      return this.accentGreenTone();
    }
    return this.mutedTextColor();
  }

  // Re-download + re-validate every subscription, updating each list's cache and
  // status. `detect` only changes the wording of the result toast (usable count);
  // both re-fetch so a previously-failed list can recover and a stale one updates.
  private async refreshAllSubscriptions(detect: boolean): Promise<void> {
    const urls: string[] = this.filterSubscriptions
      .map((s: FilterSubscription) => s.url)
      .filter((u: string) => u.startsWith('http://') || u.startsWith('https://'));
    if (urls.length === 0) {
      try {
        this.ensurePromptAction()?.showToast({ message: this.tri('No subscriptions', '暂无订阅', '尚無訂閱') });
      } catch (_) {
      }
      return;
    }
    try {
      this.ensurePromptAction()?.showToast({
        message: detect ? this.tri('Checking…', '正在检测…', '正在檢測…')
          : this.tri('Refreshing…', '正在刷新…', '正在刷新…')
      });
    } catch (_) {
    }
    await Promise.all(urls.map((u: string) => this.downloadAndCacheSubscription(u, false)));
    this.savePersistState();
    if (this.activeRunning() && this.fullModeEnabled) {
      this.applyFullModeConfigChange();
    }
    let ok: number = 0;
    let bad: number = 0;
    this.filterSubscriptions.forEach((s: FilterSubscription) => {
      if (s.state === 'ok') {
        ok += 1;
      } else if (s.state === 'failed') {
        bad += 1;
      }
    });
    try {
      this.ensurePromptAction()?.showToast({
        message: this.tri(`✓ ${ok} usable · ✗ ${bad} unusable`,
          `✓ ${ok} 可用 · ✗ ${bad} 不可用`, `✓ ${ok} 可用 · ✗ ${bad} 不可用`)
      });
    } catch (_) {
    }
  }

  // Delete a subscription, confirming first.
  private confirmDeleteSubscription(s: FilterSubscription): void {
    this.getUIContext().showAlertDialog({
      message: this.tri(`Delete this subscription?\n${s.name}`,
        `确定删除该订阅？\n${s.name}`, `確定刪除該訂閱？\n${s.name}`),
      buttons: [
        {
          value: this.tri('Cancel', '取消', '取消'),
          action: () => {
          }
        },
        {
          value: this.tri('Delete', '删除', '刪除'),
          action: () => {
            this.removeFilterSubscription(s.id);
          }
        }
      ]
    });
  }

  // ----- Subscription content viewer -----

  // Show a subscription's rule list. Prefers the locally cached copy (downloaded on
  // subscribe/import) so viewing is instant and works offline; only falls back to a
  // live fetch when there's no cache yet. The body is capped to keep large hosts
  // files from janking the UI; a monotonic request seq drops stale responses.
  private async viewSubscriptionContent(sub: FilterSubscription): Promise<void> {
    const url: string = typeof sub?.url === 'string' ? sub.url.trim() : '';
    this.subContentTitle = typeof sub?.name === 'string' && sub.name.length > 0 ? sub.name : url;
    this.subContentUrl = url;
    this.subContentText = '';
    this.subContentLineCount = 0;
    this.subContentError = '';
    this.showSubContentSheet = true;
    const seq: number = ++this.subContentRequestSeq;

    // 1) Local cache first.
    const cached: string = this.readSubCache(url);
    if (cached.trim().length > 0) {
      this.showSubContentBody(cached);
      return;
    }

    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      this.subContentError = this.tri('Only http(s) lists can be previewed.',
        '仅支持预览 http(s) 列表。', '僅支援預覽 http(s) 清單。');
      return;
    }

    // 2) No cache — fetch live (and cache it for next time if it's a valid list).
    this.subContentLoading = true;
    const res: UrlFetchResult = await this.fetchUrlText(url, 2000000);
    if (seq !== this.subContentRequestSeq) {
      return;  // superseded by a newer request or a close
    }
    this.subContentLoading = false;
    if (!res.ok) {
      this.subContentError = this.tri(`Could not load: ${res.error}`,
        `加载失败：${res.error}`, `載入失敗：${res.error}`);
      return;
    }
    if (res.text.trim().length === 0) {
      this.subContentError = this.tri('The list is empty.', '该列表为空。', '該清單為空。');
      return;
    }
    if (this.looksLikeRuleList(res.text)) {
      this.writeSubCache(url, res.text);
    }
    this.showSubContentBody(res.text);
  }

  // Render fetched/cached text into the viewer, capping the displayed length.
  private showSubContentBody(body: string): void {
    this.subContentLineCount = body.length === 0 ? 0 : body.split('\n').length;
    const MAX_CHARS: number = 200000;
    let shown: string = body;
    if (shown.length > MAX_CHARS) {
      shown = shown.substring(0, MAX_CHARS) + '\n\n'
        + this.tri('… (preview truncated)', '……（预览已截断）', '……（預覽已截斷）');
    }
    this.subContentText = shown;
  }

  private decodeHttpBody(result: string | Object | ArrayBuffer): string {
    try {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(result as ArrayBuffer));
    } catch (_) {
      return '';
    }
  }

  private closeSubContentSheet(): void {
    this.subContentRequestSeq += 1;  // invalidate any in-flight response
    this.showSubContentSheet = false;
    this.subContentText = '';
    this.subContentError = '';
    this.subContentLoading = false;
  }

  // Viewer "Refresh" — force a live re-download of the open list (bypassing the
  // cache), update the on-disk cache + the subscription's ✓/✗ status, and re-show.
  private async refreshSubContent(): Promise<void> {
    const url: string = this.subContentUrl.trim();
    if (url.length === 0 || !(url.startsWith('http://') || url.startsWith('https://'))) {
      return;
    }
    const seq: number = ++this.subContentRequestSeq;
    this.subContentLoading = true;
    this.subContentError = '';
    const res: UrlFetchResult = await this.fetchUrlText(url, 2000000);
    if (seq !== this.subContentRequestSeq) {
      return;
    }
    this.subContentLoading = false;
    if (!res.ok) {
      this.subContentError = this.tri(`Could not refresh: ${res.error}`,
        `刷新失败：${res.error}`, `重新整理失敗：${res.error}`);
      this.setSubscriptionStatus(url, 'failed', 0, res.error);
      this.savePersistState();
      return;
    }
    if (res.text.trim().length === 0) {
      this.subContentError = this.tri('The list is empty.', '该列表为空。', '該清單為空。');
      return;
    }
    if (this.looksLikeRuleList(res.text)) {
      this.writeSubCache(url, res.text);
      this.setSubscriptionStatus(url, 'ok', this.countRuleLines(res.text), '');
    } else {
      this.setSubscriptionStatus(url, 'failed', 0,
        this.tri('Not a rule list (a web page?)', '不是规则列表（可能是网页）', '不是規則清單（可能是網頁）'));
    }
    this.savePersistState();
    if (this.activeRunning() && this.fullModeEnabled) {
      this.applyFullModeConfigChange();
    }
    this.showSubContentBody(res.text);
  }

  // Open the subscription URL in the system browser — handy for lists that are a
  // web page (a repo/redirect URL) rather than a raw rule file.
  private openSubContentInBrowser(): void {
    const url: string = this.subContentUrl.trim();
    if (url.length === 0) {
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url,
    };
    this.getHostContext().startAbility(want).catch((err: BusinessError) => {
      this.appendDebugLog(`==/vpn_ui/open_sub_browser_error/ ${this.errorMessage(err)}`);
    });
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

  // ----- Config import/export (AdGuard-compatible JSON) -----

  // Reduce a custom block/allow rule line to its bare host. Returns '' for
  // comments and complex rules that don't map to a single host (those simply
  // aren't representable in the host-based adguard.json shape).
  private hostFromRuleLine(line: string, allow: boolean): string {
    let s: string = line.trim();
    if (s.length === 0 || s.startsWith('!') || s.startsWith('#')) {
      return '';
    }
    if (allow) {
      if (!s.startsWith('@@')) {
        return '';
      }
      s = s.slice(2);
    } else if (s.startsWith('@@')) {
      return '';  // an allow rule has no place in the blocked list
    }
    if (s.startsWith('||')) {
      s = s.slice(2);
    }
    if (s.endsWith('^')) {
      s = s.slice(0, -1);
    }
    if (s.length === 0 || !/^[A-Za-z0-9._*-]+$/.test(s)) {
      return '';  // still carries a path / modifier / regex — skip
    }
    return s.toLowerCase();
  }

  // Heuristic: does this file look like an AdGuard/hosts/domain rule list (vs a
  // JSON config or random text)? Permissive — only rejects clearly-non-rule
  // content, so a config JSON imported via "import file" is caught.
  private looksLikeRuleList(content: string): boolean {
    const trimmed: string = content.trim();
    if (trimmed.length === 0) {
      return false;
    }
    // A JSON object/array is a config, not a rule list.
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        JSON.parse(trimmed);
        return false;
      } catch (_) {
        // not valid JSON — judge by line content below
      }
    }
    const lines: string[] = trimmed.split('\n')
      .map((l: string) => l.trim())
      .filter((l: string) => l.length > 0 && !l.startsWith('!') && !l.startsWith('#'));
    if (lines.length === 0) {
      return false;
    }
    let ruleLike: number = 0;
    for (const line of lines) {
      if (this.isPlausibleRuleLine(line)) {
        ruleLike += 1;
      }
    }
    return ruleLike * 2 >= lines.length;  // majority of content lines look like rules
  }

  private isPlausibleRuleLine(line: string): boolean {
    // AdGuard / AdBlock syntax
    if (line.startsWith('||') || line.startsWith('@@') || line.startsWith('|')
      || line.startsWith('/') || line.includes('##') || line.includes('#@#') || line.includes('$')) {
      return true;
    }
    // hosts format: <ipv4|ipv6> <host>
    if (/^(\d{1,3}\.){3}\d{1,3}\s+\S+/.test(line) || /^[0-9a-fA-F:]+:[0-9a-fA-F:]*\s+\S+/.test(line)) {
      return true;
    }
    // plain domain (optionally wildcard), e.g. example.com, *.ads.example.com
    if (/^[*A-Za-z0-9_.-]+\.[A-Za-z]{2,}$/.test(line)) {
      return true;
    }
    return false;
  }

  private hostRulesFromProfile(profileId: string, allow: boolean): ConfigHostRule[] {
    const profile: RuleProfile | undefined = this.ruleProfiles.find((p: RuleProfile) => p.id === profileId);
    if (profile === undefined) {
      return [];
    }
    const out: ConfigHostRule[] = [];
    const seen: string[] = [];
    this.ruleProfileLines(profile.content).forEach((line: string) => {
      const host: string = this.hostFromRuleLine(line, allow);
      if (host.length > 0 && !seen.includes(host)) {
        seen.push(host);
        out.push({ host: host, enabled: true });
      }
    });
    return out;
  }

  private buildConfigExport(includeHostRules: boolean = true): ConfigExport {
    const sources: ConfigSource[] = this.filterSubscriptions.map((s: FilterSubscription) => {
      const e: ConfigSource = { label: s.name, url: s.url, enabled: s.enabled, allow: false, redirect: true };
      return e;
    });
    const redirected: ConfigRedirect[] = this.dnsRewrites.map((r: DnsRewriteRule) => {
      const e: ConfigRedirect = { host: r.domain, redirect: r.answer, enabled: true };
      return e;
    });
    // Imported local rule lists (non-built-in profiles) — stored inline so the
    // export is a self-contained snapshot. The built-in custom block/allow
    // profiles are excluded here; they're already represented by blocked/allowed.
    const profiles: ConfigRuleProfile[] = this.ruleProfiles
      .filter((p: RuleProfile) => !p.builtIn)
      .map((p: RuleProfile) => {
        const e: ConfigRuleProfile = { name: p.name, content: p.content, enabled: p.enabled };
        return e;
      });
    const app: ConfigAppSettings = {
      upstreamDns: this.upstreamDnsInput,
      upstreamAuto: this.upstreamAutoEnabled,
      fullMode: this.fullModeEnabled,
      blockAaaa: this.blockAaaa,
      blockIpv6Connections: this.blockIpv6Connections,
      proxyModeEnabled: this.proxyModeEnabled,
      dnsProxyPort: this.dnsProxyPort,
      aghHttpPort: this.aghHttpPort,
      aghWebEnabled: this.aghWebEnabled,
      advancedDns: this.cloneAdvancedDns(),
      dnsCacheTtlSeconds: this.dnsCacheTtlSeconds,
      logRetentionDays: this.logRetentionDays,
      logMaxSizeMb: this.logMaxSizeMb,
      ruleProfiles: profiles,
      appSplitMode: this.appSplitMode,
      appSplitApps: this.appSplitList,
      appSplitDnsAllowlistEnabled: this.appSplitDnsAllowlistEnabled,
      appSplitDnsAllowlist: this.appSplitDnsAllowlist,
      appTunnelEnabled: this.appTunnelEnabled,
      appTunnelRules: this.appTunnelRules,
    };
    return {
      sources: sources,
      blocked: includeHostRules ? this.hostRulesFromProfile(CUSTOM_BLOCK_RULE_PROFILE_ID, false) : [],
      allowed: includeHostRules ? this.hostRulesFromProfile(CUSTOM_ALLOW_RULE_PROFILE_ID, true) : [],
      redirected: redirected,
      app: app,
    };
  }

  private async exportConfigFile(): Promise<void> {
    try {
      const fileName: string | undefined =
        await this.exportTextToDownloadDirectory('home_cloud_shield_config', 'json',
          JSON.stringify(this.buildConfigExport(), null, 2));
      if (fileName === undefined) {
        this.setConfigFeedback(this.exportCanceledMessage());
        return;
      }
      this.setConfigFeedback(this.exportSuccessMessage(fileName));
      try {
        this.promptAction?.showToast({ message: this.t('exportSuccessToast', fileName) });
      } catch (_) {
      }
      this.appendDebugLog(`==/vpn_ui/export_config/ ${fileName}`);
    } catch (err) {
      this.errorText = this.errorMessage(err);
      this.appendDebugLog(`==/vpn_ui/export_config_error/ ${this.errorText}`);
    }
  }

  // Merge a batch of hosts into a built-in custom rule profile, deduping against
  // existing lines. Returns the count actually added.
  private mergeHostsIntoProfile(profileId: string, hosts: string[], allow: boolean): number {
    const lines: string[] = [];
    hosts.forEach((h: string) => {
      const host: string = h.trim().toLowerCase();
      if (host.length > 0 && /^[A-Za-z0-9._*-]+$/.test(host)) {
        const line: string = this.buildRuleLineForDomain(host, allow);
        if (!lines.includes(line)) {
          lines.push(line);
        }
      }
    });
    if (lines.length === 0) {
      return 0;
    }
    let added: number = 0;
    this.ruleProfiles = this.normalizeRuleProfiles(this.ruleProfiles).map((profile: RuleProfile) => {
      if (profile.id !== profileId) {
        return profile;
      }
      const originalLines: string[] = this.ruleProfileLines(profile.content);
      const nextLines: string[] = originalLines.slice();
      lines.forEach((line: string) => {
        if (!nextLines.includes(line)) {
          nextLines.push(line);
          added += 1;
        }
      });
      return this.updateRuleProfileContent(profile, nextLines, originalLines);
    });
    return added;
  }

  private mergeImportedSources(sources: ConfigSource[]): SourceMergeResult {
    let added: number = 0;
    let skipped: number = 0;
    let nextId: number = this.nextSubscriptionId();
    const merged: FilterSubscription[] = this.filterSubscriptions.slice();
    sources.forEach((s: ConfigSource) => {
      const url: string = typeof s?.url === 'string' ? s.url.trim() : '';
      // Only http(s) lists are usable; count and skip content:// file URIs and
      // other non-fetchable schemes. (Note: an http(s) URL that isn't a raw rule
      // list — a repo page, a redirect wrapper — still imports; the engine just
      // won't parse it. We can't reliably detect that from the URL alone.)
      if (!(url.startsWith('http://') || url.startsWith('https://'))) {
        if (url.length > 0) {
          skipped += 1;
        }
        return;
      }
      if (merged.some((e: FilterSubscription) => e.url === url)) {
        return;  // duplicate of an existing subscription — silently deduped
      }
      const label: string = typeof s?.label === 'string' && s.label.trim().length > 0 ? s.label.trim() : url;
      merged.push({ id: nextId, name: label, url: url, enabled: s?.enabled !== false });
      nextId += 1;
      added += 1;
    });
    // Always reassign (deduped + reindexed) so a single import also heals any
    // pre-existing duplicate-id/url corruption, keeping list and count consistent.
    this.filterSubscriptions = this.dedupeSubscriptions(merged);
    return { added: added, skipped: skipped };
  }

  // Re-create imported local rule lists from the app section, deduping by content
  // against existing non-built-in profiles. Returns the count actually added.
  private mergeImportedRuleProfiles(profiles: ConfigRuleProfile[]): number {
    const existingContents: string[] = this.ruleProfiles
      .filter((p: RuleProfile) => !p.builtIn)
      .map((p: RuleProfile) => this.normalizeRuleContent(p.content).trim());
    const toAdd: RuleProfile[] = [];
    profiles.forEach((profile: ConfigRuleProfile) => {
      const content: string = typeof profile?.content === 'string' ? profile.content : '';
      const normalized: string = this.normalizeRuleContent(content).trim();
      if (normalized.length === 0 || existingContents.includes(normalized)) {
        return;
      }
      existingContents.push(normalized);
      const name: string = typeof profile?.name === 'string' && profile.name.trim().length > 0
        ? profile.name.trim()
        : `${this.defaultCustomRuleName()} ${this.ruleProfiles.length + toAdd.length + 1}`;
      toAdd.push(this.createRuleProfile(name, content, profile?.enabled !== false));
    });
    if (toAdd.length === 0) {
      return 0;
    }
    // Keep imported lists ahead of the built-in custom profiles (same ordering as
    // importRulesFile), so normalizeRuleProfiles re-sorts them consistently.
    const importedOnly: RuleProfile[] = this.ruleProfiles.filter((p: RuleProfile) => !p.builtIn);
    const builtIns: RuleProfile[] = this.ruleProfiles.filter((p: RuleProfile) => p.builtIn);
    this.ruleProfiles = this.normalizeRuleProfiles(importedOnly.concat(toAdd).concat(builtIns));
    return toAdd.length;
  }

  private mergeImportedRedirects(redirected: ConfigRedirect[]): number {
    let added: number = 0;
    const merged: DnsRewriteRule[] = this.dnsRewrites.slice();
    redirected.forEach((r: ConfigRedirect) => {
      if (r?.enabled === false) {
        return;
      }
      const domain: string = typeof r?.host === 'string' ? r.host.trim().toLowerCase() : '';
      const answer: string = typeof r?.redirect === 'string' ? r.redirect.trim() : '';
      if (domain.length === 0 || answer.length === 0 || merged.some((x: DnsRewriteRule) => x.domain === domain)) {
        return;
      }
      merged.push({ domain: domain, answer: answer });
      added += 1;
    });
    if (added > 0) {
      this.dnsRewrites = merged;
    }
    return added;
  }

  // Collect hosts from imported block/allow entries. Disabled entries are skipped
  // (the app has no per-rule disable flag to preserve their state).
  private hostsFromImportRules(rules: ConfigHostRule[]): string[] {
    const out: string[] = [];
    rules.forEach((r: ConfigHostRule) => {
      if (r?.enabled === false) {
        return;
      }
      const host: string = typeof r?.host === 'string' ? r.host.trim() : '';
      if (host.length > 0) {
        out.push(host);
      }
    });
    return out;
  }

  // Merge imported per-app routing: the mode overrides when present (like the
  // other scalar settings); apps are merged by bundle name, keeping existing
  // entries as they are. Returns how many apps were added. Mirrors the result
  // to app_split.json so a running VPN picks it up live.
  private mergeImportedAppSplit(app: ConfigAppSettings, mirror: boolean = true): number {
    let added: number = 0;
    let changed: boolean = this.applyImportedAppSplitPolicies(app);
    if (typeof app.appSplitMode === 'string' && normalizeAppSplitMode(app.appSplitMode) !== this.appSplitMode) {
      this.appSplitMode = normalizeAppSplitMode(app.appSplitMode);
      changed = true;
    }
    if (Array.isArray(app.appSplitApps)) {
      const incoming: AppSplitEntry[] = normalizeAppSplitList(app.appSplitApps)
        .filter((e: AppSplitEntry) => e.bundle !== VPN_BUNDLE_NAME &&
          this.appSplitList.find((x: AppSplitEntry) => x.bundle === e.bundle) === undefined);
      if (incoming.length > 0) {
        const merged: AppSplitEntry[] = normalizeAppSplitList(this.appSplitList.concat(incoming));
        added = merged.length - this.appSplitList.length;
        this.appSplitList = merged;
        changed = true;
      }
    }
    if (changed && mirror) {
      this.writeAppSplitFile();
    }
    return added;
  }

  private applyImportedAppSplitPolicies(app: ConfigAppSettings): boolean {
    let changed = false;
    const domains = typeof app.appSplitDnsAllowlist === 'string' ?
      parseAppSplitDnsAllowlist(app.appSplitDnsAllowlist)?.join('\n') : undefined;
    if (app.appSplitDnsAllowlist === undefined || domains !== undefined) {
      if (domains !== undefined && domains !== this.appSplitDnsAllowlist) {
        this.appSplitDnsAllowlist = domains;
        this.appSplitDnsAllowlistDraft = domains;
        this.appSplitDnsAllowlistError = '';
        changed = true;
      }
      if (typeof app.appSplitDnsAllowlistEnabled === 'boolean' &&
        app.appSplitDnsAllowlistEnabled !== this.appSplitDnsAllowlistEnabled) {
        this.appSplitDnsAllowlistEnabled = app.appSplitDnsAllowlistEnabled;
        changed = true;
      }
    }
    const rules = typeof app.appTunnelRules === 'string' ? app.appTunnelRules.trim() : undefined;
    const validRules = rules !== undefined && rules.length <= APP_TUNNEL_RULES_MAX_LENGTH &&
      !rules.includes('\u0000') && (rules.length === 0 || vpnclientbridge.validateAppTunnelRules(rules) === undefined);
    if (app.appTunnelRules === undefined || validRules) {
      if (rules !== undefined && rules !== this.appTunnelRules) {
        this.appTunnelRules = rules;
        this.appTunnelRulesDraft = rules;
        this.appTunnelRulesError = '';
        changed = true;
      }
      if (typeof app.appTunnelEnabled === 'boolean' && app.appTunnelEnabled !== this.appTunnelEnabled) {
        this.appTunnelEnabled = app.appTunnelEnabled;
        changed = true;
      }
    }
    return changed;
  }

  private applyImportedAppSettings(app: ConfigAppSettings): void {
    if (typeof app.upstreamDns === 'string') {
      this.upstreamDnsInput = app.upstreamDns.trim();
    }
    if (typeof app.upstreamAuto === 'boolean') {
      this.upstreamAutoEnabled = app.upstreamAuto;
    }
    if (typeof app.fullMode === 'boolean') {
      this.fullModeEnabled = app.fullMode;
    }
    if (typeof app.blockAaaa === 'boolean') {
      this.blockAaaa = app.blockAaaa;
    }
    if (typeof app.blockIpv6Connections === 'boolean') {
      this.blockIpv6Connections = app.blockIpv6Connections;
    }
    if (typeof app.proxyModeEnabled === 'boolean') {
      this.proxyModeEnabled = app.proxyModeEnabled;
    }
    if (typeof app.dnsProxyPort === 'string' && app.dnsProxyPort.trim().length > 0) {
      this.dnsProxyPort = app.dnsProxyPort.trim();
    }
    if (typeof app.aghHttpPort === 'string' && app.aghHttpPort.trim().length > 0) {
      this.aghHttpPort = app.aghHttpPort.trim();
    }
    if (typeof app.aghWebEnabled === 'boolean') {
      this.aghWebEnabled = app.aghWebEnabled;
    }
    if (typeof app.dnsCacheTtlSeconds === 'number' && Number.isFinite(app.dnsCacheTtlSeconds)
      && app.dnsCacheTtlSeconds >= 0) {
      this.dnsCacheTtlSeconds = Math.floor(app.dnsCacheTtlSeconds);
      this.dnsCacheTtlInput = `${this.dnsCacheTtlSeconds}`;
    }
    if (typeof app.logRetentionDays === 'number' && Number.isFinite(app.logRetentionDays)
      && app.logRetentionDays >= 0) {
      this.logRetentionDays = Math.floor(app.logRetentionDays);
      this.logRetentionDaysInput = `${this.logRetentionDays}`;
    }
    if (typeof app.logMaxSizeMb === 'number' && Number.isFinite(app.logMaxSizeMb) && app.logMaxSizeMb >= 0) {
      this.logMaxSizeMb = Math.floor(app.logMaxSizeMb);
      this.logMaxSizeMbInput = `${this.logMaxSizeMb}`;
    }
  }

  private async importConfigFile(): Promise<void> {
    try {
      const p: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.getHostContext());
      const uris: string[] = await p.select({ maxSelectNumber: 1, fileSuffixFilters: ['.json'] });
      if (!uris || uris.length === 0) {
        this.setConfigFeedback(this.t('noConfigSelected'));
        return;
      }
      const importedPath: string = `${this.getHostContext().filesDir}/${VPN_DIR_NAME}/imported_config.json`;
      try {
        await fileIo.copyFile(uris[0], importedPath);
      } catch (_) {
        const srcPath: string = decodeURIComponent(new uri.URI(uris[0]).encodedPath);
        await fileIo.copyFile(srcPath, importedPath);
      }
      const raw: string = this.readTextFile(importedPath);
      if (raw.trim().length === 0) {
        this.setConfigFeedback(this.t('configImportInvalid'));
        return;
      }
      let config: ConfigExport;
      try {
        config = JSON.parse(raw) as ConfigExport;
      } catch (_) {
        this.setConfigFeedback(this.t('configImportInvalid'));
        return;
      }

      this.ensureRuleProfilesInitialized();
      const fullMode = this.fullModeEnabled;
      const blockAaaa = this.blockAaaa;
      const blockIpv6Connections = this.blockIpv6Connections;
      const result: ConfigImportResult =
        { sources: 0, blocked: 0, allowed: 0, redirected: 0, ruleFiles: 0, skippedSources: 0, appSplitApps: 0 };
      if (Array.isArray(config.sources)) {
        const sourceResult: SourceMergeResult = this.mergeImportedSources(config.sources);
        result.sources = sourceResult.added;
        result.skippedSources = sourceResult.skipped;
      }
      if (Array.isArray(config.blocked)) {
        result.blocked =
          this.mergeHostsIntoProfile(CUSTOM_BLOCK_RULE_PROFILE_ID, this.hostsFromImportRules(config.blocked), false);
      }
      if (Array.isArray(config.allowed)) {
        result.allowed =
          this.mergeHostsIntoProfile(CUSTOM_ALLOW_RULE_PROFILE_ID, this.hostsFromImportRules(config.allowed), true);
      }
      if (Array.isArray(config.redirected)) {
        result.redirected = this.mergeImportedRedirects(config.redirected);
      }
      if (config.app !== undefined && config.app !== null) {
        this.applyImportedAppSettings(config.app);
        if (Array.isArray(config.app.ruleProfiles)) {
          result.ruleFiles = this.mergeImportedRuleProfiles(config.app.ruleProfiles);
        }
        result.appSplitApps = this.mergeImportedAppSplit(config.app);
      }

      this.syncRuleCountBadges();
      this.rulesText = this.buildMergedRulesText();
      this.rulesDirty = true;
      this.savePersistState();
      this.errorText = '';
      // Force fresh array references so the config-page counts (rendered via
      // memoizing @Builder rows) refresh immediately instead of after the next
      // unrelated state change.
      this.filterSubscriptions = this.filterSubscriptions.slice();
      this.dnsRewrites = this.dnsRewrites.slice();
      this.ruleProfiles = this.ruleProfiles.slice();
      this.applyImportedFilterChanges(fullMode, blockAaaa, blockIpv6Connections);
      // Download + validate the imported subscriptions in the background. Lists that
      // can't be fetched or aren't rule lists are marked failed and force-disabled,
      // so "enabled" reflects "downloaded + valid".
      const importedUrls: string[] = this.filterSubscriptions
        .filter((s: FilterSubscription) => s.enabled)
        .map((s: FilterSubscription) => s.url);
      void this.downloadSubscriptions(importedUrls);
      let summary: string = this.t('configImportedSummary', result.sources, result.blocked, result.allowed,
        result.redirected, result.ruleFiles);
      if (result.appSplitApps > 0) {
        summary += this.t('configImportedAppSplit', result.appSplitApps);
      }
      if (result.skippedSources > 0) {
        summary += this.t('configImportSkipped', result.skippedSources);
      }
      if (importedUrls.length > 0) {
        summary += this.tri(' · downloading list contents…', ' · 正在下载订阅内容…', ' · 正在下載訂閱內容…');
      }
      this.setConfigFeedback(summary);
      try {
        this.promptAction?.showToast({ message: summary });
      } catch (_) {
      }
      this.appendDebugLog(
        `==/vpn_ui/import_config/ sources=${result.sources} blocked=${result.blocked} allowed=${result.allowed} redirected=${result.redirected} ruleFiles=${result.ruleFiles} appSplit=${result.appSplitApps} skipped=${result.skippedSources}`
      );
    } catch (err) {
      this.errorText = this.errorMessage(err);
      this.setConfigFeedback(this.t('configImportInvalid'));
      this.appendDebugLog(`==/vpn_ui/import_config_error/ ${this.errorText}`);
    }
  }

  private syncedAppSettings(app: ConfigAppSettings): ConfigAppSettings {
    return {
      fullMode: app.fullMode,
      blockAaaa: app.blockAaaa,
      blockIpv6Connections: app.blockIpv6Connections,
      upstreamDns: app.upstreamDns,
      upstreamAuto: app.upstreamAuto,
      advancedDns: app.advancedDns,
      dnsCacheTtlSeconds: app.dnsCacheTtlSeconds,
      ruleProfiles: app.ruleProfiles,
      appSplitMode: app.appSplitMode,
      appSplitApps: app.appSplitApps,
      appSplitDnsAllowlistEnabled: app.appSplitDnsAllowlistEnabled,
      appSplitDnsAllowlist: app.appSplitDnsAllowlist,
      appTunnelEnabled: app.appTunnelEnabled,
      appTunnelRules: app.appTunnelRules,
    };
  }

  private buildSyncedConfig(): SyncedConfig {
    const config = this.buildConfigExport(false);
    return {
      sources: config.sources,
      redirected: config.redirected,
      app: this.syncedAppSettings(config.app ?? {}),
      customBlock: this.syncedCustomRules(CUSTOM_BLOCK_RULE_PROFILE_ID),
      customAllow: this.syncedCustomRules(CUSTOM_ALLOW_RULE_PROFILE_ID),
    };
  }

  private syncedCustomRules(id: string): SyncedCustomRules {
    const profile = this.ruleProfiles.find((item: RuleProfile) => item.id === id);
    return { content: profile?.content ?? '', enabled: profile?.enabled ?? true };
  }

  private parseSyncedConfig(raw: string): SyncedConfig | undefined {
    try {
      const config = JSON.parse(raw) as SyncedConfig;
      if (config && Array.isArray(config.sources) && Array.isArray(config.redirected) && config.app &&
        typeof config.app === 'object' && !Array.isArray(config.app) &&
        typeof config.customBlock?.content === 'string' && typeof config.customBlock?.enabled === 'boolean' &&
        typeof config.customAllow?.content === 'string' && typeof config.customAllow?.enabled === 'boolean') {
        return config;
      }
    } catch (_) {}
    return undefined;
  }

  private mergeSyncedCustomRules(profile: RuleProfile, incoming: SyncedCustomRules): RuleProfile {
    const original = this.ruleProfileLines(profile.content);
    const seen = new Set<string>(original);
    const merged = original.slice();
    for (const line of this.ruleProfileLines(incoming.content)) {
      if (!seen.has(line)) {
        seen.add(line);
        merged.push(line);
      }
    }
    if (merged.length === original.length) {
      return profile;
    }
    const updated = this.updateRuleProfileContent(profile, merged, original);
    if (original.length === 0) {
      updated.enabled = incoming.enabled;
    }
    return updated;
  }

  private applySyncedConfig(config: SyncedConfig): boolean {
    const before = JSON.stringify(this.buildSyncedConfig());
    const subscriptions = this.filterSubscriptions;
    const rewrites = this.dnsRewrites;
    const rules = this.ruleProfiles;
    const advancedDns = this.advancedDns;
    const upstreamDns = this.upstreamDnsInput;
    const upstreamAuto = this.upstreamAutoEnabled;
    const fullMode = this.fullModeEnabled;
    const blockAaaa = this.blockAaaa;
    const blockIpv6Connections = this.blockIpv6Connections;
    const cacheTtl = this.dnsCacheTtlSeconds;
    const cacheTtlInput = this.dnsCacheTtlInput;
    const appSplitMode = this.appSplitMode;
    const appSplitList = this.appSplitList;
    const dnsAllowlist = this.appSplitDnsAllowlist;
    const dnsAllowlistEnabled = this.appSplitDnsAllowlistEnabled;
    const dnsAllowlistDraft = this.appSplitDnsAllowlistDraft;
    const dnsAllowlistError = this.appSplitDnsAllowlistError;
    const tunnelRules = this.appTunnelRules;
    const tunnelEnabled = this.appTunnelEnabled;
    const tunnelRulesDraft = this.appTunnelRulesDraft;
    const tunnelRulesError = this.appTunnelRulesError;
    let persisted = false;
    try {
      this.mergeImportedSources(config.sources);
      this.mergeImportedRedirects(config.redirected);
      const app = this.syncedAppSettings(config.app);
      this.applyImportedAppSettings(app);
      if (Array.isArray(app.ruleProfiles)) {
        this.mergeImportedRuleProfiles(app.ruleProfiles);
      }
      this.mergeImportedAppSplit(app, false);
      this.ruleProfiles = this.ruleProfiles.map((profile: RuleProfile): RuleProfile => {
        if (profile.id === CUSTOM_BLOCK_RULE_PROFILE_ID) {
          return this.mergeSyncedCustomRules(profile, config.customBlock);
        }
        if (profile.id === CUSTOM_ALLOW_RULE_PROFILE_ID) {
          return this.mergeSyncedCustomRules(profile, config.customAllow);
        }
        return profile;
      });
      if (before === JSON.stringify(this.buildSyncedConfig())) {
        return false;
      }
      persisted = this.savePersistState(true);
      if (!persisted || !this.writeAppSplitFile()) {
        throw new Error('Could not save synced settings');
      }
    } catch (err) {
      this.filterSubscriptions = subscriptions;
      this.dnsRewrites = rewrites;
      this.ruleProfiles = rules;
      this.advancedDns = advancedDns;
      this.upstreamDnsInput = upstreamDns;
      this.upstreamAutoEnabled = upstreamAuto;
      this.fullModeEnabled = fullMode;
      this.blockAaaa = blockAaaa;
      this.blockIpv6Connections = blockIpv6Connections;
      this.dnsCacheTtlSeconds = cacheTtl;
      this.dnsCacheTtlInput = cacheTtlInput;
      this.appSplitMode = appSplitMode;
      this.appSplitList = appSplitList;
      this.appSplitDnsAllowlist = dnsAllowlist;
      this.appSplitDnsAllowlistEnabled = dnsAllowlistEnabled;
      this.appSplitDnsAllowlistDraft = dnsAllowlistDraft;
      this.appSplitDnsAllowlistError = dnsAllowlistError;
      this.appTunnelRules = tunnelRules;
      this.appTunnelEnabled = tunnelEnabled;
      this.appTunnelRulesDraft = tunnelRulesDraft;
      this.appTunnelRulesError = tunnelRulesError;
      if (persisted) {
        this.savePersistState(true);
      }
      throw err as Error;
    }
    this.syncRuleCountBadges();
    this.rulesText = this.buildMergedRulesText();
    this.rulesDirty = true;
    this.applyImportedFilterChanges(fullMode, blockAaaa, blockIpv6Connections);
    const previousUrls = new Set<string>(subscriptions.map((source: FilterSubscription) => source.url));
    const newUrls = this.filterSubscriptions.filter((source: FilterSubscription) => source.enabled &&
      !previousUrls.has(source.url)).map((source: FilterSubscription) => source.url);
    void this.downloadSubscriptions(newUrls);
    return true;
  }

  private applyImportedFilterChanges(fullMode: boolean, blockAaaa: boolean, blockIpv6Connections: boolean): void {
    if (!this.activeRunning()) {
      return;
    }
    this.writeTextFile(this.rulesFilePath, this.rulesText);
    this.writeUpstreamFile();
    // Both DNS engines receive their IPv6 policy when the filter starts.
    if (fullMode !== this.fullModeEnabled || blockAaaa !== this.blockAaaa ||
      blockIpv6Connections !== this.blockIpv6Connections) {
      this.restartActiveFilter();
    } else {
      this.restartFullEngineForConfig();
    }
  }

  private setConfigSyncStatus(message: string): void {
    this.configSyncStatus = message;
    if (this.pageVisible) {
      try {
        this.ensurePromptAction()?.showToast({ message });
      } catch (_) {}
    }
  }

  private configSyncFailed(): string {
    return this.tri('Sync failed. Check Multi-Device Collaboration and try again.',
      '同步失败，请检查系统多设备协同设置后重试。', '同步失敗，請檢查系統多裝置協作設定後重試。');
  }

  private async updateConfigSync(enabled: boolean, requested: boolean = false): Promise<void> {
    if (this.configSyncBusy || !this.disclaimerAccepted) {
      return;
    }
    this.configSyncBusy = true;
    try {
      if (requested) {
        this.configSyncStatus = '';
        this.configSyncDevices = [];
      }
      if (enabled) {
        if (requested && !(await this.hasPermission(CONFIG_SYNC_PERMISSION))) {
          await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.getHostContext(),
            [CONFIG_SYNC_PERMISSION]);
        }
        enabled = await this.hasPermission(CONFIG_SYNC_PERMISSION);
        if (!enabled) {
          this.setConfigSyncStatus(this.tri('Allow distributed data sync first.', '请允许分布式数据同步权限。',
            '請允許分散式資料同步權限。'));
        }
      }
      if (this.configSyncEnabled !== enabled || (enabled && !this.configSyncDeviceId)) {
        this.configSyncEnabled = enabled;
        if (enabled && !this.configSyncDeviceId) {
          this.configSyncDeviceId = util.generateRandomUUID();
        }
        if (!this.savePersistState(true)) {
          throw new Error('Could not save sync preference');
        }
      }
      if (enabled) {
        await configSync.enable(this.getHostContext(), this.configSyncDeviceId,
          () => JSON.stringify(this.buildSyncedConfig()), this.onConfigSyncAvailable);
      } else {
        configSync.disable();
      }
    } catch (_) {
      this.configSyncEnabled = false;
      configSync.disable();
      this.savePersistState(true);
      this.setConfigSyncStatus(this.configSyncFailed());
    } finally {
      const state = configSync.isEnabled(this.onConfigSyncAvailable) ?
        AbilityConstant.ContinueState.ACTIVE : AbilityConstant.ContinueState.INACTIVE;
      try {
        await this.getHostContext().setMissionContinueState(state);
      } catch (_) {}
      this.configSyncBusy = false;
    }
  }

  private openConfigSyncDevices(): void {
    this.configSyncStatus = '';
    try {
      this.configSyncDevices = configSync.devices(this.getHostContext());
      if (this.configSyncDevices.length === 0) {
        this.setConfigSyncStatus(this.tri('No devices available for sync.', '没有找到可同步的设备。',
          '找不到可同步的裝置。'));
      }
    } catch (_) {
      this.configSyncDevices = [];
      this.setConfigSyncStatus(this.configSyncFailed());
    }
  }

  private async sendConfigSync(device: ConfigSyncDevice): Promise<void> {
    if (this.configSyncBusy || !configSync.isEnabled(this.onConfigSyncAvailable)) {
      return;
    }
    this.configSyncBusy = true;
    this.configSyncDevices = [];
    const name = device.name || this.tri('Nearby device', '附近设备', '附近裝置');
    this.configSyncStatus = this.tri(`Preparing settings for ${name}…`, `正在准备发送给 ${name} 的配置…`,
      `正在準備傳送至 ${name} 的設定…`);
    try {
      const result = await configSync.send(this.getHostContext(), device.id, {
        onSubmitted: () => {
          this.configSyncStatus = this.tri(`Syncing settings to ${name}…`, `正在向 ${name} 同步配置…`,
            `正在將設定同步至 ${name}…`);
        }
      });
      if (result.confirmation === ConfigSyncConfirmation.Delivered) {
        this.setConfigSyncStatus(this.tri('Settings received by the other device.', '对方设备已接收配置。',
          '對方裝置已接收設定。'));
      } else if (result.confirmation === ConfigSyncConfirmation.Sent) {
        this.setConfigSyncStatus(this.tri('Settings sent. Check the other device.', '配置已发送，请在对方设备查看。',
          '設定已傳送，請在對方裝置查看。'));
      } else {
        this.setConfigSyncStatus(this.tri('Delivery unconfirmed. Open the app on the other device to check.',
          '尚未确认送达，请打开对方设备上的应用查看。', '尚未確認送達，請開啟對方裝置上的應用程式查看。'));
      }
    } catch (err) {
      this.setConfigSyncStatus((err as Error).message === 'Config data too large' ?
        this.tri('Settings are too large to sync.', '配置文件过大，无法同步。', '設定檔過大，無法同步。') :
        this.configSyncFailed());
    } finally {
      this.configSyncBusy = false;
    }
  }

  private canReceiveConfigSync(): boolean {
    return this.pageVisible && !this.showRuleEditorSheet && this.canChangeFilterSettings() &&
      configSync.isEnabled(this.onConfigSyncAvailable);
  }

  private async receiveConfigSync(): Promise<void> {
    if (!this.configSyncInboxPending || this.configSyncInboxBusy || !this.canReceiveConfigSync()) {
      return;
    }
    this.configSyncInboxBusy = true;
    this.configSyncInboxPending = false;
    try {
      const deliveries = await configSync.inbox();
      for (const delivery of deliveries) {
        if (!this.canReceiveConfigSync()) {
          this.configSyncInboxPending = true;
          break;
        }
        const config = delivery.payload ? this.parseSyncedConfig(delivery.payload.config) : undefined;
        const changed = config ? this.applySyncedConfig(config) : false;
        await configSync.finishDelivery(delivery, config !== undefined);
        if (config) {
          this.setConfigSyncStatus(delivery.continuation ?
            this.tri('App continued. Settings are ready.', '已接续应用，配置已就绪。', '已接續應用程式，設定已就緒。') :
            changed ? this.tri('Synced settings received.', '已接收同步配置。', '已接收同步設定。') :
            this.tri('Settings received. No changes needed.', '已接收配置，无需更新。', '已接收設定，無需更新。'));
        }
      }
    } catch (_) {
      this.setConfigSyncStatus(this.configSyncFailed());
    } finally {
      this.configSyncInboxBusy = false;
    }
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

  private ruleProfileCountText(profile: RuleProfile): string {
    let lineCount: number = this.ruleProfileLineCount(profile);
    if (profile.id === CUSTOM_BLOCK_RULE_PROFILE_ID) {
      lineCount = this.customBlockRuleCountBadge;
    } else if (profile.id === CUSTOM_ALLOW_RULE_PROFILE_ID) {
      lineCount = this.customAllowRuleCountBadge;
    }
    return `${lineCount} ${this.t('lines')}`;
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
    this.closeRuleComposer();
    this.rulesText = profile.content;
    this.showRuleEditorSheet = true;
  }

  private closeRuleEditor(): void {
    this.showRuleEditorSheet = false;
    this.editingRuleProfileId = '';
    this.editingRuleNameText = '';
    this.closeRuleComposer();
    this.rulesText = this.buildMergedRulesText();
  }

  private editingRuleProfile(): RuleProfile | undefined {
    return this.ruleProfiles.find((item: RuleProfile) => item.id === this.editingRuleProfileId);
  }

  private builtInRuleEditorActive(): boolean {
    return this.isBuiltInRuleProfile(this.editingRuleProfileId);
  }

  private builtInRuleInputPlaceholder(): string {
    if (this.editingAllowRules()) {
      return this.t('customAllowRulePlaceholder');
    }
    return this.t('customBlockRulePlaceholder');
  }

  private editingAllowRules(): boolean {
    return this.editingRuleProfileId === CUSTOM_ALLOW_RULE_PROFILE_ID;
  }

  private editingRuleLineItems(): RuleLineItem[] {
    return this.normalizeRuleContent(this.rulesText).split('\n').map((raw: string, index: number) => {
      const line: string = raw.trim();
      const item: RuleLineItem = {
        key: `${index}_${line}`,
        line,
        index,
        domain: parseVisualDnsRule(line)?.domain ?? '',
      };
      return item;
    }).filter((item: RuleLineItem) => item.line.length > 0);
  }

  private openRuleComposer(item?: RuleLineItem): void {
    this.editingRuleLineIndex = item?.index ?? -1;
    this.ruleComposerRawText = item?.line ?? '';
    this.ruleComposerDomain = '';
    this.ruleComposerSubdomains = true;
    this.ruleComposerQueryType = 'all';
    this.ruleComposerError = '';
    this.ruleComposerRaw = item !== undefined && !this.loadVisualRule(item.line);
    this.ruleComposerOpen = true;
  }

  private closeRuleComposer(): void {
    this.ruleComposerOpen = false;
    this.editingRuleLineIndex = -1;
  }

  private loadVisualRule(line: string): boolean {
    const rule: VisualDnsRule | undefined = parseVisualDnsRule(line);
    if (rule === undefined || rule.allow !== this.editingAllowRules()) {
      return false;
    }
    this.ruleComposerDomain = rule.domain;
    this.ruleComposerSubdomains = rule.includeSubdomains;
    this.ruleComposerQueryType = rule.queryType;
    return true;
  }

  private visualRulePreview(): string {
    const domain: string = normalizeRuleDomain(this.ruleComposerDomain);
    return domain ? formatVisualDnsRule(domain, this.editingAllowRules(), this.ruleComposerSubdomains,
      this.ruleComposerQueryType) : '';
  }

  private ruleQueryTypeLabel(type: RuleQueryType): string {
    return type === 'all' ? this.t('ruleAnyQuery') : (type === 'A' ? 'IPv4 (A)' : 'IPv6 (AAAA)');
  }

  private visualRuleEffect(): string {
    const domain: string = normalizeRuleDomain(this.ruleComposerDomain);
    const scope: string = this.ruleComposerSubdomains ? this.t('ruleDomainAndSubdomains', domain) : domain;
    return this.t(this.editingAllowRules() ? 'ruleAllowPreview' : 'ruleBlockPreview', scope,
      this.ruleQueryTypeLabel(this.ruleComposerQueryType));
  }

  private selectRuleComposerMode(raw: boolean): void {
    if (raw === this.ruleComposerRaw) {
      return;
    }
    if (raw) {
      const preview: string = this.visualRulePreview();
      if (preview) {
        this.ruleComposerRawText = preview;
      }
    } else if (!this.loadVisualRule(this.ruleComposerRawText.trim())) {
      this.ruleComposerDomain = '';
      this.ruleComposerSubdomains = true;
      this.ruleComposerQueryType = 'all';
    }
    this.ruleComposerRaw = raw;
    this.ruleComposerError = '';
  }

  private ruleComposerCanApply(): boolean {
    return this.ruleComposerRaw ? this.ruleComposerRawText.trim().length > 0 : this.visualRulePreview().length > 0;
  }

  private applyRuleComposer(): void {
    const preview: string = this.visualRulePreview();
    const pending: string[] = this.ruleComposerRaw ? this.ruleProfileLines(this.ruleComposerRawText) :
      (preview ? [preview] : []);
    if (pending.length === 0) {
      return;
    }
    const index: number = this.editingRuleLineIndex;
    const lines: string[] = this.normalizeRuleContent(this.rulesText).split('\n');
    const existing: Set<string> = new Set<string>(lines.map((line: string) => line.trim()));
    if (index >= 0) {
      if (pending.length !== 1) {
        this.ruleComposerError = this.t('ruleSingleLineOnly');
        return;
      }
      if (pending[0] === lines[index].trim()) {
        this.closeRuleComposer();
        return;
      }
      if (existing.has(pending[0])) {
        this.ruleComposerError = this.t('ruleAlreadyExists', pending[0]);
        return;
      }
      lines[index] = pending[0];
      this.rulesText = lines.join('\n');
    } else {
      const additions: string[] = [];
      for (const line of pending) {
        if (!existing.has(line)) {
          existing.add(line);
          additions.push(line);
        }
      }
      if (additions.length === 0) {
        this.ruleComposerError = this.t('ruleAlreadyExists', pending[0]);
        return;
      }
      const content: string = this.normalizeRuleContent(this.rulesText).trimEnd();
      this.rulesText = (content ? `${content}\n` : '') + additions.join('\n');
    }
    this.closeRuleComposer();
  }

  private confirmDeleteRuleLine(lineIndex: number): void {
    const lines: string[] = this.normalizeRuleContent(this.rulesText).split('\n');
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
              lines.splice(lineIndex, 1);
              this.rulesText = lines.join('\n');
            } catch (err) {
              this.errorText = this.errorMessage(err);
            }
          }
        }
      ]
    });
  }

  private confirmRemoveAllCustomBlockRules(): void {
    if (this.editingRuleProfileId !== CUSTOM_BLOCK_RULE_PROFILE_ID || !this.rulesText.trim()) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: this.t('removeAllRuleLines'),
      message: this.t('confirmRemoveAllBlockRules'),
      buttons: [
        { value: this.t('cancel'), action: () => {} },
        {
          value: this.t('removeAllRuleLines'),
          action: () => {
            if (this.showRuleEditorSheet && this.editingRuleProfileId === CUSTOM_BLOCK_RULE_PROFILE_ID) {
              this.rulesText = '';
              this.applyRuleEditorChanges();
              this.saveRules();
              this.restartFullEngineForConfig();
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

  // Plain IPv4/IPv6 literal — the only upstream form the lightweight C++ engine
  // accepts (it inet_pton()s the string and talks plain Do53 over UDP/TCP).
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

  // AdGuardHome upstream forms only the full engine understands: scheme URLs
  // (DoH https://, DoT tls://, DoQ quic://, h3://, sdns://, tcp/udp://),
  // domain-specific [/example.com/]server syntax, and bare hostname[:port].
  private isAdvancedUpstream(value: string): boolean {
    const v: string = value.trim();
    if (v.length === 0) {
      return false;
    }
    if (/^(udp|tcp|tls|https|h3|quic|sdns):\/\/\S+$/i.test(v)) {
      return true;
    }
    if (/^\[\/.*\/\].+$/.test(v)) {
      return true;
    }
    // hostname (must contain a dot) with optional :port, e.g. dns.google:853
    if (/^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+(:\d{1,5})?$/.test(v)) {
      return true;
    }
    return false;
  }

  // An upstream entry is valid for the active engine: full mode also accepts the
  // encrypted/advanced forms above; the lightweight engine is restricted to IPs.
  private isValidUpstreamEntry(value: string, allowAdvanced: boolean): boolean {
    if (this.isValidUpstreamIp(value)) {
      return true;
    }
    return allowAdvanced && this.isAdvancedUpstream(value);
  }

  // Whether the current input holds entries the lightweight engine cannot use.
  // Drives the inline warning shown when DoH/DoT is left in place on lite mode.
  private upstreamInputHasUnsupportedForLite(): boolean {
    if (this.fullModeEnabled) {
      return false;
    }
    return this.splitUpstreamEntries(this.upstreamDnsInput).some((e: string) => !this.isValidUpstreamIp(e));
  }

  private splitUpstreamEntries(value: string): string[] {
    return value.split(/[\s,;]+/).map((s: string) => s.trim()).filter((s: string) => s.length > 0);
  }

  private onUpstreamDnsInputChange(value: string): void {
    this.upstreamDnsInput = value;
    this.savePersistState();
  }

  // Encrypted upstream quick-fills (DoH/DoT). Full engine only — the chips are
  // disabled when the lightweight engine is active.
  private upstreamEncryptedPresets(): UpstreamPreset[] {
    return [
      { label: 'AliDNS DoH', value: 'https://dns.alidns.com/dns-query' },
      { label: 'DNSPod DoH', value: 'https://doh.pub/dns-query' },
      { label: 'AdGuard DoH', value: 'https://dns.adguard-dns.com/dns-query' },
      { label: 'AliDNS DoT', value: 'tls://dns.alidns.com' },
    ];
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
    const allowAdvanced: boolean = this.fullModeEnabled;
    for (const entry of entries) {
      if (!this.isValidUpstreamEntry(entry, allowAdvanced)) {
        // Distinguish "wrong format" from "right format, wrong engine" so a user
        // who pastes a DoH URL on the lightweight engine knows to switch modes.
        this.errorText = (!allowAdvanced && this.isAdvancedUpstream(entry))
          ? this.t('upstreamDnsLiteOnlyIp')
          : this.t('upstreamDnsInvalid');
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
    this.writeUpstreamFile();
    this.appendDebugLog(`==/vpn_ui/upstream_set/ auto=${this.upstreamAutoEnabled} upstream=${text.length > 0 ? cleaned.join(',') : DEFAULT_UPSTREAM_DNS_IP}`);
    try {
      this.ensurePromptAction()?.showToast({ message: this.t('upstreamDnsApplied') });
    } catch (_) {
    }
  }

  // The content written to upstream.txt: an __AUTO__ marker line (so the VPN
  // extension follows the system/router DNS) followed by the manual list as the
  // fallback, or just the manual list when auto is off.
  private upstreamFileText(): string {
    const manual: string = this.upstreamDnsInput.trim();
    return this.upstreamAutoEnabled ? `${UPSTREAM_AUTO_MARKER}\n${manual}` : manual;
  }

  private writeUpstreamFile(): void {
    this.writeTextFile(this.upstreamDnsFilePath, this.upstreamFileText());
  }

  // DNS-proxy mode resolves the upstream in THIS process (no VPN extension), so
  // it needs its own query of the system/router resolvers for auto mode. Filters
  // out loopback, IPv6 link-local, and unusable entries (mirror of the extension).
  private async queryUnderlyingDnsServers(): Promise<string[]> {
    const out: string[] = [];
    try {
      const netHandle: connection.NetHandle = await connection.getDefaultNet();
      if (netHandle.netId === 0) {
        return out;
      }
      const props: connection.ConnectionProperties = await connection.getConnectionProperties(netHandle);
      const servers: connection.NetAddress[] = props.dnses ?? [];
      servers.forEach((s: connection.NetAddress) => {
        const ip: string = (s.address ?? '').trim();
        const lower: string = ip.toLowerCase();
        if (ip.length === 0 || out.includes(ip)) {
          return;
        }
        if (ip.startsWith('127.') || ip === '::1' || lower.startsWith('fe80') || lower.includes('%')) {
          return;
        }
        if (this.isValidUpstreamIp(ip)) {
          out.push(ip);
        }
      });
    } catch (err) {
      this.appendDebugLog(`==/vpn_ui/underlying_dns_error/ ${this.errorMessage(err)}`);
    }
    return out;
  }

  // Auto upstream is only meaningful in VPN mode, where the extension owns the
  // physical network and can read the system/router DNS. In pure DNS-proxy mode
  // there is no tunnel and no reliable underlying resolver to follow, so the
  // toggle is greyed out and the manual list is always used.
  private upstreamAutoAvailable(): boolean {
    return !this.proxyModeEnabled;
  }

  // The upstream the DNS-proxy server should use. Auto mode never applies here
  // (see upstreamAutoAvailable) — proxy mode always uses the manual IP list.
  private async resolveProxyUpstream(manualList: string): Promise<string> {
    if (!this.upstreamAutoEnabled || !this.upstreamAutoAvailable()) {
      return manualList;
    }
    const system: string[] = await this.queryUnderlyingDnsServers();
    return system.length > 0 ? system.join('\n') : manualList;
  }

  private onUpstreamAutoChange(value: boolean): void {
    // Defensive: the toggle is disabled in proxy mode, but never let it flip on.
    if (value && !this.upstreamAutoAvailable()) {
      return;
    }
    this.upstreamAutoEnabled = value;
    this.savePersistState();
    // Rewrite the file the VPN extension watches: lite mode hot-reloads within
    // ~1s, full mode applies on next restart. (Proxy mode uses the manual list.)
    this.writeUpstreamFile();
    this.appendDebugLog(`==/vpn_ui/upstream_auto/ ${value}`);
    try {
      this.ensurePromptAction()?.showToast({ message: this.t('upstreamDnsApplied') });
    } catch (_) {
    }
  }

  // The resolver(s) the running filter actually uses, for display. In auto mode
  // this comes from the live status snapshot (the system/router DNS); empty until
  // the filter is up.
  private effectiveUpstreamDisplay(): string {
    const eff: string = (this.status.effectiveUpstream ?? '').trim();
    return eff.length > 0 ? eff.replace(/\n/g, ', ') : '';
  }

  private parseLogLimitInput(value: string, current: number): number {
    const trimmed: string = value.trim();
    const parsed = Number(trimmed);
    return /^\d+$/.test(trimmed) && Number.isSafeInteger(parsed) ? parsed : current;
  }

  private updateLogRetentionDays(value: string): void {
    const days = this.parseLogLimitInput(value, this.logRetentionDays);
    this.logRetentionDaysInput = `${days}`;
    if (days !== this.logRetentionDays) {
      this.logRetentionDays = days;
      this.lastDnsLogPruneAt = 0;
      this.savePersistState(true);
    }
  }

  private updateLogMaxSizeMb(value: string): void {
    const size = this.parseLogLimitInput(value, this.logMaxSizeMb);
    this.logMaxSizeMbInput = `${size}`;
    if (size !== this.logMaxSizeMb) {
      this.logMaxSizeMb = size;
      this.lastDnsLogPruneAt = 0;
      this.savePersistState(true);
    }
  }

  private updateClearDnsLogOnStart(value: boolean): void {
    this.clearDnsLogOnStart = value;
    this.savePersistState();
  }

  private updateClearDebugLogOnStart(value: boolean): void {
    this.clearDebugLogOnStart = value;
    this.savePersistState();
  }

  private updateIpv6Blocking(blockAaaa: boolean, blockConnections: boolean): void {
    if (!this.canChangeFilterSettings() ||
      (this.blockAaaa === blockAaaa && this.blockIpv6Connections === blockConnections)) {
      return;
    }
    const previousAaaa = this.blockAaaa;
    const previousConnections = this.blockIpv6Connections;
    this.blockAaaa = blockAaaa;
    this.blockIpv6Connections = blockConnections;
    if (!this.savePersistState(true)) {
      this.blockAaaa = previousAaaa;
      this.blockIpv6Connections = previousConnections;
      this.errorText = this.tri('Could not save IPv6 settings.', '无法保存 IPv6 设置。', '無法儲存 IPv6 設定。');
      return;
    }
    this.restartActiveFilter();
  }

  private canChangeFilterSettings(): boolean {
    return !this.busy && !this.stopping && !this.homeStarting() &&
      (this.proxyModeEnabled || (this.status.phase !== 'starting' && this.status.phase !== 'creating' &&
        this.status.phase !== 'stopping'));
  }

  private restartActiveFilter(): void {
    if (this.proxyModeEnabled && this.dnsProxyRunning) {
      void this.startDnsProxy(true);
    } else if (!this.proxyModeEnabled && this.status.running) {
      void this.startVpn(true, true);
    }
  }

  private setEngineFullMode(full: boolean): void {
    if (!this.canChangeFilterSettings() || this.fullModeEnabled === full) {
      return;
    }
    const previousMode: boolean = this.fullModeEnabled;
    this.fullModeEnabled = full;
    if (!this.savePersistState(true)) {
      this.fullModeEnabled = previousMode;
      this.errorText = this.tri('Could not save engine settings.', '无法保存引擎设置。', '無法儲存引擎設定。');
      return;
    }
    this.restartActiveFilter();
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
      ? this.tri('Full engine', '完整引擎', '完整引擎')
      : this.tri('Lite engine', '轻量引擎', '輕量引擎');
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
    // The watchdog must not restart the previous mode's service after a switch.
    this.vpnDesiredRunning = false;
    this.dnsProxyDesiredRunning = false;
    this.autoRestartAttempts = 0;
    this.autoRestartGaveUp = false;
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

  // Toggle the embedded AdGuardHome web dashboard. Applies at engine start, so
  // restart a running full engine the same way other full-mode config does.
  private updateAghWebEnabled(value: boolean): void {
    if (this.aghWebEnabled === value) {
      return;
    }
    this.aghWebEnabled = value;
    this.applyFullModeConfigChange();
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
    return formatVisualDnsRule(domain, allow, true, 'all');
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
    const appCleared = clearLogFile(this.queryLogFilePath);
    const aghCleared = clearLogFile(this.aghQueryLogPath());
    if (!appCleared || !aghCleared) {
      throw new Error(this.t('clearDnsRequestsFailed'));
    }
    dnsLogDb.clear().catch(() => {
    });
    dnsStats.reset();
    this.appLogReader.reset();
    this.aghLogReader.reset();
    this.appLogLastTs = Date.now();
    this.aghLogLastTs = this.appLogLastTs;
    this.queryEvents = [];
    this.recentRows = [];
    this.querySummary = defaultQuerySummary();
    this.dnsFilteredCount = 0;
    this.dnsLoadedQueryKey = '';
    this.recentRowsLoaded = true;
    this.lastRecentRefreshMs = 0;
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
      const rect = this.mainWindow.getWindowProperties().windowRect;
      this.windowWidthVp = uiContext.px2vp(rect.width);
      this.windowHeightVp = uiContext.px2vp(rect.height);
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

  private setPalette(id: string): void {
    const next = shieldPalette(id).id;
    if (this.paletteId !== next) {
      this.paletteId = next;
      this.savePersistState();
    }
  }

  private paletteColors(): ShieldColors {
    const palette = shieldPalette(this.paletteId);
    return this.isDarkModeActive() ? palette.dark : palette.light;
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
    // Make sure notify.json exists with the current settings/labels before any
    // (auto-)start, so the extension reads a fresh config on launch.
    this.writeNotifyConfigFile();
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
    void this.updateConfigSync(this.configSyncEnabled);
    void this.tryAutoStartFilterOnLaunch();
    this.touchUiWatch(true);
    this.startRefreshTimer();
  }

  aboutToDisappear(): void {
    configSync.detach(this.onConfigSyncAvailable);
    this.stopRefreshTimer();
    this.stopLogMaintenanceTimer();
    // Avoid an orphaned timer firing on a torn-down component. Leave the last
    // published notification in place (don't cancel) — the proxy keeps filtering.
    if (this.proxyNotifyTimer >= 0) {
      clearInterval(this.proxyNotifyTimer);
      this.proxyNotifyTimer = -1;
    }
  }

  // Pause the 1.2s refresh loop (and stop touching ui_watch) while this page is
  // not visible: nothing it computes can be seen, and the stale ui_watch lets
  // the VPN extension drop its status pump to the slow idle heartbeat.
  onPageShow(): void {
    this.pageVisible = true;
    this.uiWatchSinceMs = Date.now();
    this.touchUiWatch(true);
    this.startRefreshTimer();
    this.refreshAll();
    void this.updateConfigSync(this.configSyncEnabled);
  }

  onPageHide(): void {
    this.pageVisible = false;
    this.stopRefreshTimer();
  }

  private startRefreshTimer(): void {
    if (this.refreshTimer >= 0) {
      return;
    }
    this.refreshTimer = setInterval(() => {
      this.refreshAll();
    }, 1200);
  }

  private stopRefreshTimer(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  // Refresh the ui_watch marker's mtime (throttled) so the extension keeps the
  // fast status cadence only while this page is actually visible.
  private touchUiWatch(force: boolean = false): void {
    if (!this.pageVisible && !force) {
      return;
    }
    const now: number = Date.now();
    if (!force && now - this.lastUiWatchTouchMs < UI_WATCH_TOUCH_INTERVAL_MS) {
      return;
    }
    this.lastUiWatchTouchMs = now;
    this.writeTextFile(this.uiWatchFilePath, '1');
  }

  private ensureRuntimeFiles(): void {
    const ctx = this.getHostContext();
    const vpnDir = `${ctx.filesDir}/${VPN_DIR_NAME}`;
    this.statusFilePath = `${vpnDir}/${STATUS_FILE_NAME}`;
    this.rulesFilePath = `${vpnDir}/${RULES_FILE_NAME}`;
    this.queryLogFilePath = `${vpnDir}/${QUERY_LOG_FILE_NAME}`;
    this.debugLogFilePath = `${vpnDir}/${DEBUG_LOG_FILE_NAME}`;
    this.appTunnelLogFilePath = `${vpnDir}/${APP_TUNNEL_LOG_FILE}`;
    this.upstreamDnsFilePath = `${vpnDir}/${UPSTREAM_DNS_FILE_NAME}`;
    this.stateFilePath = `${vpnDir}/${STATE_FILE_NAME}`;
    this.uiWatchFilePath = `${vpnDir}/${UI_WATCH_FILE_NAME}`;
    this.notifyConfigFilePath = `${vpnDir}/${NOTIFY_CONFIG_FILE_NAME}`;
    this.notifyCountsFilePath = `${vpnDir}/${NOTIFY_COUNTS_FILE_NAME}`;
    this.appSplitFilePath = `${vpnDir}/${APP_SPLIT_FILE_NAME}`;
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
        blockAaaa: this.blockAaaa,
        blockIpv6Connections: this.blockIpv6Connections,
        dnsCacheTtlSeconds: this.dnsCacheTtlSeconds,
        logRetentionDays: this.logRetentionDays,
        logMaxSizeMb: this.logMaxSizeMb,
        clearDnsLogOnStart: this.clearDnsLogOnStart,
        clearDebugLogOnStart: this.clearDebugLogOnStart,
        filterMode: this.fullModeEnabled ? 'full' : 'lightweight',
        // Exclude lists that failed to download/validate — the full engine should
        // not try to fetch a URL we already know is broken or not a rule list.
        aghFiltersJson: JSON.stringify(
          this.filterSubscriptions.filter((s: FilterSubscription) => s.state !== 'failed')),
        aghRewritesJson: JSON.stringify(this.dnsRewrites),
        aghAdvancedJson: JSON.stringify(this.advancedDns),
        aghHttpPort: this.aghHttpPortNumber(),
        aghWebEnabled: this.aghWebEnabled,
        appSplitMode: this.appSplitMode,
        appSplitBundles: JSON.stringify(this.appSplitEnabledBundles()),
      },
    };
  }

  private buildKeepAliveWantAgentInfo(): wantAgent.WantAgentInfo {
    return {
      wants: [{
        bundleName: VPN_BUNDLE_NAME,
        moduleName: VPN_MODULE_NAME,
        abilityName: ENTRY_ABILITY_NAME,
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
  }

  private clampNotificationRefreshSeconds(value: number): number {
    if (!Number.isFinite(value)) {
      return DEFAULT_NOTIFICATION_REFRESH_SECONDS;
    }
    const rounded: number = Math.round(value);
    if (rounded < NOTIFICATION_REFRESH_MIN_SECONDS) {
      return NOTIFICATION_REFRESH_MIN_SECONDS;
    }
    if (rounded > NOTIFICATION_REFRESH_MAX_SECONDS) {
      return NOTIFICATION_REFRESH_MAX_SECONDS;
    }
    return rounded;
  }

  // Persist the persistent-notification config (enable flag, refresh interval,
  // and the labels resolved against the in-app language) to notify.json. The VPN
  // extension watches this file and applies changes live (see MyVpnExtAbility).
  private writeNotifyConfigFile(): void {
    if (this.notifyConfigFilePath.length === 0) {
      return;
    }
    const config: NotifyConfigFile = {
      enabled: this.persistentNotificationEnabled,
      refreshSeconds: this.clampNotificationRefreshSeconds(this.notificationRefreshSeconds),
      title: this.t('notificationTitle'),
      blockedLabel: this.t('blocked'),
      allowedLabel: this.t('allowed'),
      totalLabel: this.t('notificationTotal'),
    };
    this.writeTextFile(this.notifyConfigFilePath, JSON.stringify(config));
  }

  // Best-effort: ask the user to allow notifications so the persistent stats
  // notification can show. Safe to call repeatedly — once decided the system
  // just rejects, which we ignore.
  private async ensureNotificationPermission(): Promise<void> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return;
      }
      await notificationManager.requestEnableNotification(this.getHostContext());
    } catch (err) {
      this.appendDebugLog(`==/vpn_ui/notify_permission/ ${this.errorMessage(err)}`);
    }
  }

  private async onPersistentNotificationChange(value: boolean): Promise<void> {
    this.persistentNotificationEnabled = value;
    this.savePersistState();
    if (value) {
      await this.ensureNotificationPermission();
    }
    // VPN mode applies via notify.json (savePersistState wrote it); proxy mode is
    // published from this process, so react immediately.
    if (this.proxyModeEnabled && this.dnsProxyRunning) {
      if (value) {
        this.startProxyNotify();
      } else {
        this.stopProxyNotify();
      }
    }
  }

  private setNotificationRefreshSeconds(seconds: number): void {
    const next: number = this.clampNotificationRefreshSeconds(seconds);
    if (next === this.notificationRefreshSeconds) {
      return;
    }
    this.notificationRefreshSeconds = next;
    this.savePersistState();
    // Re-pace the proxy-mode publisher immediately when running.
    if (this.proxyModeEnabled && this.dnsProxyRunning && this.persistentNotificationEnabled) {
      this.startProxyNotify();
    }
  }

  private formatCount(value: number): string {
    const digits: string = `${Math.max(0, Math.floor(value))}`;
    return digits.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  }

  // Capture the live cumulative baseline for the VPN extension's notification:
  // the home-page cumulative counts (querySummary) plus the native session counts
  // at this instant. The extension adds its live native delta on top so the
  // notification matches the home page yet keeps ticking in the background.
  // Deduped so an unchanged baseline doesn't churn the file the extension watches.
  private writeNotifyCountsFile(): void {
    this.writeNotifyCountsBaseline(this.status.nativeStats.allowedQueries, this.status.nativeStats.blockedQueries);
  }

  private writeNotifyCountsBaseline(natAllowed: number, natBlocked: number): void {
    if (this.notifyCountsFilePath.length === 0) {
      return;
    }
    const counts: NotifyCountsFile = {
      cumAllowed: Math.max(0, this.querySummary.allowed),
      cumBlocked: Math.max(0, this.querySummary.blocked),
      natAllowed: Math.max(0, natAllowed),
      natBlocked: Math.max(0, natBlocked),
    };
    const signature: string = `${counts.cumAllowed}:${counts.cumBlocked}:${counts.natAllowed}:${counts.natBlocked}`;
    if (signature === this.lastNotifyCountsSignature) {
      return;
    }
    this.lastNotifyCountsSignature = signature;
    this.writeTextFile(this.notifyCountsFilePath, JSON.stringify(counts));
  }

  // ---- Proxy-mode notification (published by this process) ------------------

  private async ensureUiNotificationWantAgent(): Promise<WantAgent | undefined> {
    if (this.notificationWantAgent !== undefined) {
      return this.notificationWantAgent;
    }
    try {
      this.notificationWantAgent = await wantAgent.getWantAgent(this.buildKeepAliveWantAgentInfo());
    } catch (err) {
      this.appendDebugLog(`==/vpn_ui/notify_wantagent_error/ ${this.errorMessage(err)}`);
    }
    return this.notificationWantAgent;
  }

  private async publishStatsNotificationUI(text: string): Promise<void> {
    try {
      const agent: WantAgent | undefined = await this.ensureUiNotificationWantAgent();
      const request: notificationManager.NotificationRequest = {
        id: STATS_NOTIFICATION_ID,
        // CONTENT_INFORMATION = silent LEVEL_MIN slot, so repeated republishes
        // (live counts) don't sound/vibrate.
        notificationSlotType: notificationManager.SlotType.CONTENT_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: this.t('notificationTitle'),
            text: text,
          },
        },
        isOngoing: true,
        isUnremovable: false,
        tapDismissed: false,
        wantAgent: agent,
      };
      await notificationManager.publish(request);
      this.uiNotificationActive = true;
    } catch (err) {
      this.appendDebugLog(`==/vpn_ui/notify_publish_error/ ${this.errorMessage(err)}`);
    }
  }

  private cancelStatsNotificationUI(): void {
    this.lastUiNotificationText = '';
    this.lastUiNotificationPublishMs = 0;
    if (!this.uiNotificationActive) {
      return;
    }
    this.uiNotificationActive = false;
    notificationManager.cancel(STATS_NOTIFICATION_ID).catch((err: BusinessError) => {
      this.appendDebugLog(`==/vpn_ui/notify_cancel_error/ ${this.errorMessage(err)}`);
    });
  }

  // Proxy mode has no native query counters wired into getStats, so it shows the
  // cumulative query-log counts (querySummary) directly — identical to the home
  // page. The timer below keeps querySummary fresh in the background.
  private updateProxyStatsNotification(force: boolean): void {
    if (!this.persistentNotificationEnabled || !this.dnsProxyRunning) {
      if (this.uiNotificationActive) {
        this.cancelStatsNotificationUI();
      }
      return;
    }
    const now: number = Date.now();
    if (!force && now - this.lastUiNotificationPublishMs < this.clampNotificationRefreshSeconds(this.notificationRefreshSeconds) * 1000) {
      return;
    }
    const text: string =
      `${this.t('blocked')} ${this.formatCount(this.querySummary.blocked)}    ` +
      `${this.t('allowed')} ${this.formatCount(this.querySummary.allowed)}    ` +
      `${this.t('notificationTotal')} ${this.formatCount(this.querySummary.total)}`;
    if (!force && text === this.lastUiNotificationText) {
      return;
    }
    this.lastUiNotificationText = text;
    this.lastUiNotificationPublishMs = now;
    void this.publishStatsNotificationUI(text);
  }

  private startProxyNotify(): void {
    this.stopProxyNotify();
    if (!this.persistentNotificationEnabled) {
      return;
    }
    void this.ensureNotificationPermission();
    this.updateProxyStatsNotification(true);
    this.proxyNotifyTimer = setInterval(() => {
      // Keep the cumulative counts advancing while backgrounded (the foreground
      // refresh loop is paused then). Cheap incremental ingestion, gated to the
      // notification cadence.
      if (!this.pageVisible) {
        this.refreshQueryLog();
      }
      this.updateProxyStatsNotification(false);
    }, this.clampNotificationRefreshSeconds(this.notificationRefreshSeconds) * 1000);
  }

  private stopProxyNotify(): void {
    if (this.proxyNotifyTimer >= 0) {
      clearInterval(this.proxyNotifyTimer);
      this.proxyNotifyTimer = -1;
    }
    this.cancelStatsNotificationUI();
  }

  private loadPersistState(): void {
    try {
      const raw: string = this.readTextFile(this.stateFilePath);
      if (raw.trim().length === 0) {
        this.language = this.detectSystemLang();
        return;
      }
      const state: PersistState = JSON.parse(raw) as PersistState;
      this.blockAaaa = state.blockAaaa === true;
      this.blockIpv6Connections = state.blockIpv6Connections === true;
      this.configSyncEnabled = state.configSyncEnabled === true;
      if (typeof state.configSyncDeviceId === 'string' && /^[0-9a-f-]{36}$/.test(state.configSyncDeviceId)) {
        this.configSyncDeviceId = state.configSyncDeviceId;
      }
      if (state.language === 'zhHans' || state.language === 'en' || state.language === 'zhHant') {
        this.language = state.language;
      } else {
        this.language = this.detectSystemLang();
      }
      if (typeof state.themeMode === 'number') {
        this.themeMode = state.themeMode;
      }
      this.paletteId = shieldPalette(typeof state.paletteId === 'string' ? state.paletteId : DEFAULT_SHIELD_PALETTE).id;
      if (typeof state.audioKeepAliveEnabled === 'boolean') {
        this.audioKeepAliveEnabled = state.audioKeepAliveEnabled;
      } else if (typeof state.keepAliveEnabled === 'boolean') {
        this.audioKeepAliveEnabled = state.keepAliveEnabled;
      }
      if (typeof state.locationKeepAliveEnabled === 'boolean') {
        this.locationKeepAliveEnabled = state.locationKeepAliveEnabled;
      }
      if (typeof state.dataTransferKeepAliveEnabled === 'boolean') {
        this.dataTransferKeepAliveEnabled = state.dataTransferKeepAliveEnabled;
      }
      this.appSplitMode = normalizeAppSplitMode(state.appSplitMode);
      this.appSplitList = normalizeAppSplitList(state.appSplitList);
      this.appSplitDnsAllowlistEnabled = state.appSplitDnsAllowlistEnabled === true;
      this.appSplitDnsAllowlist = typeof state.appSplitDnsAllowlist === 'string' ? state.appSplitDnsAllowlist : '';
      this.appSplitDnsAllowlistDraft = this.appSplitDnsAllowlist;
      this.appTunnelEnabled = state.appTunnelEnabled !== false;
      this.appTunnelRules = typeof state.appTunnelRules === 'string' ? state.appTunnelRules : '';
      this.appTunnelRulesDraft = this.appTunnelRules;
      if (typeof state.autoStartFilterEnabled === 'boolean') {
        this.autoStartFilterEnabled = state.autoStartFilterEnabled;
      }
      if (typeof state.persistentNotificationEnabled === 'boolean') {
        this.persistentNotificationEnabled = state.persistentNotificationEnabled;
      }
      if (typeof state.notificationRefreshSeconds === 'number'
        && Number.isFinite(state.notificationRefreshSeconds)) {
        this.notificationRefreshSeconds = this.clampNotificationRefreshSeconds(state.notificationRefreshSeconds);
      }
      if (typeof state.currentTab === 'number' && state.currentTab >= 0 && state.currentTab <= 2) {
        this.currentTab = state.currentTab;
      }
      if (typeof state.upstreamDnsIp === 'string') {
        this.upstreamDnsInput = state.upstreamDnsIp.trim();
      }
      if (typeof state.upstreamAutoEnabled === 'boolean') {
        this.upstreamAutoEnabled = state.upstreamAutoEnabled;
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
      const migrateLogDefaults = state.logRetentionDefaultsApplied !== true &&
        this.logRetentionDays === 0 && this.logMaxSizeMb === 0;
      if (migrateLogDefaults) {
        this.logRetentionDays = DEFAULT_LOG_RETENTION_DAYS;
        this.logRetentionDaysInput = `${DEFAULT_LOG_RETENTION_DAYS}`;
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
      if (typeof state.aghWebEnabled === 'boolean') {
        this.aghWebEnabled = state.aghWebEnabled;
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
            state: typeof s?.state === 'string' ? s.state : undefined,
            lines: typeof s?.lines === 'number' ? s.lines : undefined,
            err: typeof s?.err === 'string' ? s.err : undefined,
          });
        });
        this.filterSubscriptions = this.dedupeSubscriptions(subs);
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
      const migrateServiceRules = Array.isArray(state.blockedServiceIds) && state.blockedServiceIds.length > 0;
      if (migrateServiceRules) {
        const currentRules = this.normalizeRuleContent(this.readTextFile(this.rulesFilePath));
        const suffixStart = currentRules.lastIndexOf('\n\n! service: ');
        const legacyStart = suffixStart >= 0 ? suffixStart : (currentRules.startsWith('! service: ') ? 0 : -1);
        if (legacyStart >= 0) {
          const userRules = this.ruleProfiles.length > 0
            ? this.buildMergedRulesText() : currentRules.slice(0, legacyStart);
          if (!this.writeAtomicTextFile(this.rulesFilePath, userRules)) {
            this.errorText = this.t('saveRulesFailed');
            return;
          }
        }
      }
      if (migrateLogDefaults || migrateServiceRules) {
        this.savePersistState(true);
      }
    } catch (_) {
    }
  }

  private savePersistState(atomic: boolean = false): boolean {
    this.syncKeepAliveEnabledFlag();
    const state: PersistState = {
      configSyncEnabled: this.configSyncEnabled,
      configSyncDeviceId: this.configSyncDeviceId,
      keepAliveEnabled: this.keepAliveEnabled,
      audioKeepAliveEnabled: this.audioKeepAliveEnabled,
      locationKeepAliveEnabled: this.locationKeepAliveEnabled,
      dataTransferKeepAliveEnabled: this.dataTransferKeepAliveEnabled,
      autoStartFilterEnabled: this.autoStartFilterEnabled,
      persistentNotificationEnabled: this.persistentNotificationEnabled,
      notificationRefreshSeconds: this.notificationRefreshSeconds,
      language: this.language,
      themeMode: this.themeMode,
      paletteId: this.paletteId,
      ruleProfiles: this.ruleProfiles,
      dnsCacheTtlSeconds: this.dnsCacheTtlSeconds,
      blockAaaa: this.blockAaaa,
      blockIpv6Connections: this.blockIpv6Connections,
      upstreamDnsIp: this.upstreamDnsInput,
      upstreamAutoEnabled: this.upstreamAutoEnabled,
      logRetentionDays: this.logRetentionDays,
      logMaxSizeMb: this.logMaxSizeMb,
      logRetentionDefaultsApplied: true,
      clearDnsLogOnStart: this.clearDnsLogOnStart,
      clearDebugLogOnStart: this.clearDebugLogOnStart,
      fullModeEnabled: this.fullModeEnabled,
      proxyModeEnabled: this.proxyModeEnabled,
      dnsProxyPort: this.dnsProxyPort,
      aghHttpPort: this.aghHttpPort,
      aghWebEnabled: this.aghWebEnabled,
      filterSubscriptions: this.filterSubscriptions,
      dnsRewrites: this.dnsRewrites,
      advancedDns: this.advancedDns,
      disclaimerAccepted: this.disclaimerAccepted,
      appSplitMode: this.appSplitMode,
      appSplitList: this.appSplitList,
      appSplitDnsAllowlistEnabled: this.appSplitDnsAllowlistEnabled,
      appSplitDnsAllowlist: this.appSplitDnsAllowlist,
      appTunnelEnabled: this.appTunnelEnabled,
      appTunnelRules: this.appTunnelRules,
      currentTab: this.currentTab,
    };
    const serialized = JSON.stringify(state);
    const saved = atomic ? this.writeAtomicTextFile(this.stateFilePath, serialized)
      : this.writeTextFile(this.stateFilePath, serialized);
    // Mirror the notification settings (and current localized labels) into
    // notify.json so the running VPN extension applies any change live.
    this.writeNotifyConfigFile();
    return saved;
  }

  private writeAtomicTextFile(path: string, serialized: string): boolean {
    const pending = `${path}.pending`;
    try {
      if (!this.writeTextFile(pending, serialized) ||
        fileIo.statSync(pending).size !== new util.TextEncoder().encodeInto(serialized).byteLength) {
        return false;
      }
      fileIo.renameSync(pending, path);
      return true;
    } catch (_) {
      return false;
    } finally {
      try { fileIo.unlinkSync(pending); } catch (_) {}
    }
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

  private fileByteSize(path: string): number {
    try {
      return fileIo.statSync(path).size;
    } catch (_) {
      return 0;
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
    this.touchUiWatch();
    this.refreshStatus();
    this.refreshQueryLog();
    this.refreshDebugLog();
    this.checkLogMaintenance();
    // Capture the cumulative baseline for the VPN extension's notification (it
    // adds its live native delta on top). Deduped internally.
    this.writeNotifyCountsFile();
    // DNS-proxy mode has no status pump; poll the in-process native flag so a
    // dead proxy is noticed (and can be auto-restarted) instead of the toggle
    // staying stuck on "running".
    if (this.proxyModeEnabled && this.dnsProxyRunning) {
      this.syncDnsProxyRunning();
    }
    // Re-attempt the launch auto-start once an unconfirmed launch snapshot has
    // resolved (guarded internally: runs at most once per launch).
    void this.tryAutoStartFilterOnLaunch();
    this.checkAutoRestart();
    if (this.fullEngineRestartPending && this.canChangeFilterSettings() && !this.showRuleEditorSheet) {
      this.restartFullEngineForConfig();
    }
    if (this.configSyncInboxPending) {
      void this.receiveConfigSync();
    }
  }

  private checkLogMaintenance(): void {
    const now = Date.now();
    // The VPN extension owns rotation while its engine is running.
    if (this.busy || this.status.running || this.status.phase === 'starting' || this.logMaintenanceRunning ||
      now - this.lastLogMaintenanceAt < LOG_MAINTENANCE_INTERVAL_MS) {
      return;
    }
    this.lastLogMaintenanceAt = now;
    this.logMaintenanceRunning = true;
    const days = this.logRetentionDays;
    const size = this.logMaxSizeMb;
    maintainLogFiles([this.queryLogFilePath, this.aghQueryLogPath()], days, size).then(() =>
      maintainLogFiles([this.debugLogFilePath], days, size, this.appTunnelLogFilePath)).finally(() => {
      this.logMaintenanceRunning = false;
    }).catch(() => {});
  }

  private stopLogMaintenanceTimer(): void {
    if (this.logMaintenanceTimer >= 0) {
      clearInterval(this.logMaintenanceTimer);
      this.logMaintenanceTimer = -1;
    }
  }

  // Watchdog: when the service the user started is reported dead (VPN status
  // pump stale / native proxy flag off) while still desired, restart it
  // automatically with exponential backoff instead of silently staying down
  // (e.g. after the system reclaimed the extension in the background).
  private checkAutoRestart(): void {
    if (this.busy || this.stopping || this.autoRestarting || this.probingVpnPermission
      || this.launchStatusPending || this.showFirstRunDisclaimer) {
      return;
    }
    if (this.activeRunning()) {
      // Adopt an externally observed running service (e.g. the UI was re-created
      // while the extension kept running) so it gets watchdogged too.
      if (this.proxyModeEnabled) {
        this.dnsProxyDesiredRunning = true;
      } else {
        this.vpnDesiredRunning = true;
      }
      this.autoRestartAttempts = 0;
      this.autoRestartGaveUp = false;
      return;
    }
    const desired: boolean = this.proxyModeEnabled ? this.dnsProxyDesiredRunning : this.vpnDesiredRunning;
    if (!desired) {
      return;
    }
    // A start/stop transition is still in flight — let it settle. The settle
    // window matters: right after a start the extension transiently reports
    // phases like 'creating' (or 'stopped' during a restart), which previously
    // made the watchdog fire a duplicate start one tick after the first.
    if (Date.now() - this.lastStartRequestAt < START_SETTLE_GRACE_MS) {
      return;
    }
    if (!this.proxyModeEnabled && (this.status.phase === 'starting' || this.status.phase === 'creating'
      || this.status.phase === 'stopping')) {
      return;
    }
    if (this.autoRestartAttempts >= AUTO_RESTART_MAX_ATTEMPTS) {
      if (!this.autoRestartGaveUp) {
        this.autoRestartGaveUp = true;
        this.appendDebugLog('==/vpn_ui/auto_restart_gave_up/');
        this.keepAliveStatusText = this.t('autoRestartGaveUp');
      }
      return;
    }
    const now: number = Date.now();
    const delayMs: number = Math.min(AUTO_RESTART_MAX_DELAY_MS,
      AUTO_RESTART_BASE_DELAY_MS * Math.pow(2, this.autoRestartAttempts));
    if (now - this.lastAutoRestartAt < delayMs) {
      return;
    }
    this.lastAutoRestartAt = now;
    this.autoRestartAttempts += 1;
    const mode: string = this.proxyModeEnabled ? 'proxy' : 'vpn';
    this.appendDebugLog(`==/vpn_ui/auto_restart/ mode=${mode} attempt=${this.autoRestartAttempts}`);
    this.keepAliveStatusText = this.t('autoRestartAttempt', `${this.autoRestartAttempts}`);
    this.autoRestarting = true;
    const task: Promise<void> = this.proxyModeEnabled ? this.startDnsProxy(true) : this.startVpn(true);
    task.catch((err: BusinessError) => {
      this.appendDebugLog(`==/vpn_ui/auto_restart_error/ ${this.errorMessage(err)}`);
    }).finally(() => {
      this.autoRestarting = false;
    });
  }

  private refreshStatus(): void {
    const raw = this.readTextFile(this.statusFilePath);
    try {
      const missing = raw.trim().length === 0;
      const snapshot = missing ? defaultStatus() : JSON.parse(raw) as StatusSnapshot;
      const now = Date.now();
      const updatedAt = Date.parse(snapshot.updatedAt);
      const startPhase = snapshot.phase === 'starting' || snapshot.phase === 'creating';
      const transition = !snapshot.running && (startPhase || snapshot.phase === 'stopping');
      // Old versions could leave an undated "starting" snapshot written by the
      // UI. Only a recent request or a fresh extension snapshot keeps it alive.
      const transitionSince = Math.max(Number.isFinite(updatedAt) ? updatedAt : 0,
        startPhase ? this.lastStartRequestAt : 0);
      const staleTransition = transition && (transitionSince === 0 || now - transitionSince >= START_SETTLE_GRACE_MS);
      const staleRunning = this.isStaleRunningSnapshot(snapshot);
      if (missing || staleRunning || staleTransition) {
        this.launchStatusPending = false;
        this.suppressRuntimeArtifacts = true;
        this.status = this.buildInactiveStatus();
        if (staleRunning) {
          this.writeTextFile(this.statusFilePath, JSON.stringify(defaultStatus()));
        }
      } else if (this.isPendingLaunchSnapshot(snapshot)) {
        // Unconfirmed pre-launch "running": don't trust it (a killed session's
        // leftover) and don't kill it (the extension may stamp a fresh write any
        // moment). With auto-start armed, surface "auto-starting" instead of
        // flashing running→stopped→running; either way it resolves within
        // LAUNCH_STATUS_GRACE_MS.
        this.launchStatusPending = true;
        this.suppressRuntimeArtifacts = false;
        if (this.autoStartFilterEnabled && !this.proxyModeEnabled) {
          this.status = this.updatedStatus('starting', this.t('autoStarting'));
        } else {
          this.status = this.normalizeStatusSnapshot(snapshot);
        }
      } else {
        this.launchStatusPending = false;
        this.suppressRuntimeArtifacts = false;
        this.status = this.normalizeStatusSnapshot(snapshot);
      }
      if (!this.proxyModeEnabled && !this.busy && !this.launchStatusPending) {
        const afterRequest = this.lastStartRequestAt === 0 || updatedAt >= this.lastStartRequestAt;
        const requestExpired = this.lastStartRequestAt > 0 && now - this.lastStartRequestAt >= START_SETTLE_GRACE_MS;
        if (afterRequest && (this.status.running || this.status.phase === 'error')) {
          this.lastStartRequestAt = 0;
          this.vpnStartTimedOut = false;
        } else if (!this.status.running && ((staleTransition && startPhase) ||
          (requestExpired && (!transition || staleTransition)))) {
          if (!this.vpnStartTimedOut) {
            this.appendDebugLog('==/vpn_ui/start_timeout/');
          }
          this.lastStartRequestAt = 0;
          this.vpnStartTimedOut = true;
        }
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
      // Wipe once, not every tick — reassigning @State arrays each 1.2s forces
      // pointless re-renders while idle.
      if (this.queryEvents.length > 0 || this.recentRows.length > 0
        || this.querySummary.total !== 0 || this.dnsFilteredCount !== 0) {
        this.queryEvents = [];
        this.recentRows = [];
        this.querySummary = defaultQuerySummary();
        this.dnsFilteredCount = 0;
        this.dnsLoadedQueryKey = '';
        this.recentRowsLoaded = false;
      }
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
    // Persistent stat counters: load them, and on the first run after upgrading
    // to incremental stats seed them from the existing table contents (the only
    // remaining full-table aggregation, off the refresh loop, once ever).
    dnsStats.load(this.getHostContext());
    if (!dnsStats.isSeeded()) {
      const seed: DnsLogSummary = await dnsLogDb.summary();
      dnsStats.seedFrom(seed);
    }
    if (!this.suppressRuntimeArtifacts) {
      this.querySummary = this.statsToQuerySummary();
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
      // Each engine writes its own log. Read both tails so requests remain visible
      // while the VPN is switching engines or the running engine differs from the setting.
      const ingested: number = await this.ingestDnsLog(false) + await this.ingestDnsLog(true);
      const now: number = Date.now();
      let pruned: boolean = false;
      if (now - this.lastDnsLogPruneAt >= LOG_MAINTENANCE_INTERVAL_MS) {
        this.lastDnsLogPruneAt = now;
        pruned = await dnsLogDb.prune(logCutoff(this.logRetentionDays), this.logMaxSizeMb);
      }

      // Totals come from the incrementally maintained persistent counters
      // (DnsStats) — no COUNT/SUM aggregation over the table on the refresh tick
      // anymore; that full-table scan froze (and could crash) the app once the
      // log held tens of thousands of rows.
      // recentRowsLoaded doubles as the "displays primed" flag: false right
      // after launch or a suppression wipe, so the cached totals reappear even
      // before any new row is ingested.
      if (ingested > 0 || !this.recentRowsLoaded) {
        this.querySummary = this.statsToQuerySummary();
      }

      // The filtered count + current page only matter while the requests sheet
      // is open; rerun that SQL only when it is AND either new rows arrived or
      // the filter/search/page changed.
      if (this.showDnsSheet) {
        const filter: string = this.dnsActionFilter;
        const search: string = this.dnsSearchText;
        const queryKey: string = `${filter}|${search}|${this.dnsPage}`;
        if (ingested > 0 || pruned || queryKey !== this.dnsLoadedQueryKey) {
          const count: number = await dnsLogDb.countFor(filter, search);
          const totalPages: number = Math.max(1, Math.ceil(count / DNS_PAGE_SIZE));
          const page: number = Math.min(Math.max(0, this.dnsPage), totalPages - 1);
          const rows: DnsLogRow[] = await dnsLogDb.page(filter, search, DNS_PAGE_SIZE, page * DNS_PAGE_SIZE);
          this.dnsFilteredCount = count;
          this.queryEvents = rows.map((r: DnsLogRow) => this.rowToEntry(r));
          this.dnsLoadedQueryKey = queryKey;
        }
      }

      // The recent-rows window (domain leaderboard source) is loaded once and
      // then re-queried only when new rows arrived, rate-limited — pulling 2000
      // rows plus a 2000-element @State reassignment every tick was the other
      // big-table freeze.
      if (!this.recentRowsLoaded || pruned || (ingested > 0 && now - this.lastRecentRefreshMs >= RECENT_REFRESH_MIN_MS)) {
        const recent: DnsLogRow[] = await dnsLogDb.recentRows(MAX_QUERY_EVENTS);
        this.recentRows = recent.map((r: DnsLogRow) => this.rowToEntry(r));
        this.recentRowsLoaded = true;
        this.lastRecentRefreshMs = now;
      }
    } finally {
      this.dnsRefreshing = false;
    }
  }

  private statsToQuerySummary(): QuerySummary {
    const s: DnsLogSummary = dnsStats.toSummary();
    return {
      total: s.total,
      allowed: s.allowed,
      blocked: s.blocked,
      lastDomain: s.lastDomain,
      lastRule: s.lastRule,
      requestBytes: s.requestBytes,
      responseBytes: s.responseBytes,
      totalDnsBytes: s.totalDnsBytes,
    };
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

  private async ingestDnsLog(isAgh: boolean): Promise<number> {
    const reader: LogReader = isAgh ? this.aghLogReader : this.appLogReader;
    const watermark: number = isAgh ? this.aghLogLastTs : this.appLogLastTs;
    const path: string = isAgh ? this.aghQueryLogPath() : this.queryLogFilePath;
    const batch = reader.read(path, watermark);
    if (batch === undefined) {
      return 0;
    }
    const cutoff: number = Math.max(logCutoff(this.logRetentionDays), batch.next.watermark + 1);
    const rows: DnsLogRow[] = [];
    let maxTs: number = watermark;
    for (const line of batch.chunk.split('\n')) {
      if (line.length === 0) {
        continue;
      }
      const row: DnsLogRow | undefined = isAgh ? this.parseAghLogLine(line) : this.parseAppLogLine(line);
      if (row !== undefined && Number.isFinite(row.ts) && row.ts >= cutoff) {
        rows.push(row);
        maxTs = Math.max(maxTs, row.ts);
      }
    }
    if (rows.length > 0 && !(await dnsLogDb.insertRows(rows, isAgh ? 'agh' : 'app'))) {
      return 0;
    }
    if ((isAgh ? this.aghLogLastTs : this.appLogLastTs) !== watermark) {
      // The user cleared the history while this insert was in flight.
      return 0;
    }
    reader.advance(batch);
    if (isAgh) {
      this.aghLogLastTs = maxTs;
    } else {
      this.appLogLastTs = maxTs;
    }
    dnsStats.addRows(rows);
    return rows.length;
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

  // Read at most the trailing maxBytes of a text file, starting at the first
  // complete line. The debug-log preview only needs the last ~20 lines; reading
  // the whole (potentially multi-MB, never-rotated-by-default) file every 1.2s
  // tick caused launch jank and steady-state stutter.
  private readTextFileTail(path: string, maxBytes: number): string {
    const size: number = this.fileByteSize(path);
    if (size <= 0) {
      return '';
    }
    const from: number = size > maxBytes ? size - maxBytes : 0;
    const buf: ArrayBuffer = new ArrayBuffer(size - from);
    let got: number = 0;
    let f: fileIo.File | undefined = undefined;
    try {
      f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      got = fileIo.readSync(f.fd, buf, { offset: from });
    } catch (_) {
      return '';
    } finally {
      if (f !== undefined) {
        try {
          fileIo.closeSync(f);
        } catch (_) {
        }
      }
    }
    if (got <= 0) {
      return '';
    }
    const bytes: Uint8Array = new Uint8Array(buf, 0, got);
    let start: number = 0;
    if (from > 0) {
      // Skip the partial (possibly mid-UTF-8) first line of the window.
      for (let i: number = 0; i < bytes.length; i++) {
        if (bytes[i] === 0x0A) {
          start = i + 1;
          break;
        }
      }
    }
    if (start >= got) {
      return '';
    }
    return this.logTailDecoder.decodeToString(new Uint8Array(buf, start, got - start));
  }

  private refreshDebugLog(): void {
    let remaining = DEBUG_LOG_TAIL_BYTES;
    const files = archivedLogPaths(this.debugLogFilePath).concat([this.debugLogFilePath]);
    const chunks: string[] = [];
    for (let i = files.length - 1; i >= 0 && remaining > 0; i--) {
      chunks.unshift(this.readTextFileTail(files[i], remaining));
      remaining -= this.fileByteSize(files[i]);
    }
    const raw = chunks.join('\n');
    const lines: string[] = raw.split('\n');
    const items: string[] = [];
    const cutoff = logCutoff(this.logRetentionDays);
    let index: number = lines.length - 1;
    while (index >= 0 && items.length < 20) {
      const line: string = lines[index].trim();
      if (line.length > 0 && !(Date.parse(line.split(' ', 1)[0]) < cutoff)) {
        items.push(line);
      }
      index -= 1;
    }
    const connections = this.readTextFileTail(this.appTunnelLogFilePath, DEBUG_LOG_TAIL_BYTES).split('\n');
    let connectionCount = 0;
    for (let i = connections.length - 1; i >= 0 && connectionCount < 50; i--) {
      const fields = connections[i].trim().split('\t');
      const timestamp = Date.parse(fields[0]);
      if (fields.length !== 4 || fields[2] === 'dns' || !Number.isFinite(timestamp) || timestamp < cutoff) {
        continue;
      }
      const action = fields[2] === 'blocked' ? this.t('blocked') : fields[2] === 'failed' ?
        this.tri('Failed', '失败', '失敗') : this.t('allowed');
      items.push(`${fields[0]} [TUN] ${fields[1].toUpperCase()} ${action} ${fields[3]}`);
      connectionCount += 1;
    }
    if (connectionCount > 0) {
      items.sort((a: string, b: string) =>
        (Date.parse(b.split(' ', 1)[0]) || 0) - (Date.parse(a.split(' ', 1)[0]) || 0));
    }
    // Skip the @State reassignment when nothing changed — reassigning forces a
    // re-render every tick even while idle.
    if (items.length === this.debugLines.length) {
      let same: boolean = true;
      for (let i: number = 0; i < items.length; i++) {
        if (items[i] !== this.debugLines[i]) {
          same = false;
          break;
        }
      }
      if (same) {
        return;
      }
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

  private async waitForVpnRequest(request: Promise<void>): Promise<boolean> {
    let timer = -1;
    try {
      return await Promise.race([
        request.then(() => true),
        new Promise<boolean>((resolve) => {
          timer = setTimeout(() => resolve(false), START_SETTLE_GRACE_MS);
        })
      ]);
    } finally {
      clearTimeout(timer);
    }
  }

  private async startVpn(auto: boolean = false, restart: boolean = false): Promise<void> {
    if (this.busy || (!this.status.running && Date.now() - this.lastStartRequestAt < START_SETTLE_GRACE_MS)) {
      return;
    }

    // Warn (and let the user decide) when no background keep-alive is enabled —
    // in either mode filtering can be killed once the app is backgrounded.
    // Watchdog restarts reuse the original consent and skip the dialog.
    if (!auto && !(await this.confirmStartWithoutKeepAlive())) {
      return;
    }
    if (!auto) {
      this.autoRestartAttempts = 0;
      this.autoRestartGaveUp = false;
    }

    // Free the loopback DNS port if the experimental DNS-proxy server is running
    // in this process, so the VPN extension can bind it.
    if (this.dnsProxyRunning) {
      await this.stopDnsProxy();
    }

    this.busy = true;
    this.errorText = '';
    const wasRunning: boolean = this.status.running;
    const recoverTimedOutStart = this.vpnStartTimedOut;
    this.vpnStartTimedOut = false;
    try {
      if (restart && wasRunning) {
        await vpnExtension.stopVpnExtensionAbility(this.buildVpnWant());
      } else if ((recoverTimedOutStart || this.pendingVpnStart !== undefined) && !wasRunning) {
        try {
          const stopped = await this.waitForVpnRequest(vpnExtension.stopVpnExtensionAbility(this.buildVpnWant()));
          if (!stopped) {
            this.vpnStartTimedOut = true;
            this.appendDebugLog('==/vpn_ui/start_recovery_stop_timeout/');
            return;
          }
        } catch (err) {
          this.appendDebugLog(`==/vpn_ui/start_recovery_stop_error/ ${this.errorMessage(err)}`);
        }
        // Even after requesting a stop, the original start call may still be
        // awaiting the system response. Never enqueue another start over it.
        if (this.pendingVpnStart !== undefined) {
          this.vpnStartTimedOut = true;
          return;
        }
      }
      if (!this.writeTextFile(this.rulesFilePath, this.rulesText)) {
        throw new Error('Failed to write rules file');
      }
      this.writeUpstreamFile();
      if (!this.writeAppSplitFile()) {
        throw new Error('Failed to write app split settings.');
      }
      // Refresh notify.json and (if enabled) prompt for notification permission
      // before the extension comes up, so the persistent stats notification can
      // appear immediately.
      this.writeNotifyConfigFile();
      // The (re)start resets the native session counters to 0, so seed the
      // baseline against nat=0: the extension shows cumulative + native from the
      // first query, with no stale-session transient.
      this.writeNotifyCountsBaseline(0, 0);
      if (this.persistentNotificationEnabled) {
        await this.ensureNotificationPermission();
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
      this.lastStartRequestAt = Date.now();
      const startRequest = vpnExtension.startVpnExtensionAbility(this.buildVpnWant());
      this.pendingVpnStart = startRequest;
      const clearPendingStart = () => {
        if (this.pendingVpnStart === startRequest) {
          this.pendingVpnStart = undefined;
        }
      };
      void startRequest.then(clearPendingStart, clearPendingStart);
      if (!(await this.waitForVpnRequest(startRequest))) {
        this.lastStartRequestAt = 0;
        this.vpnStartTimedOut = true;
        this.appendDebugLog('==/vpn_ui/start_api_timeout/');
        return;
      }
      hilog.info(DOMAIN, TAG, '%{public}s', '==/vpn_ui/start_resolved/');
      this.appendDebugLog('==/vpn_ui/start_resolved/');
      this.vpnDesiredRunning = true;
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
      // Don't leave a locally written "starting" status (or an open settle
      // window) behind when the start failed.
      this.lastStartRequestAt = 0;
      if (!wasRunning) {
        this.status = this.buildInactiveStatus();
        this.writeTextFile(this.statusFilePath, JSON.stringify(defaultStatus()));
      }
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
    this.probingVpnPermission = true;
    try {
      await vpnExtension.startVpnExtensionAbility(this.buildVpnWant());
      this.appendDebugLog('==/vpn_ui/auto_start_permission_granted/');
      await vpnExtension.stopVpnExtensionAbility(this.buildVpnWant());
      this.vpnDesiredRunning = false;
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
    } finally {
      // Keep the guard up briefly after the probe: the extension's status pump
      // can still report "running" for a tick or two while it shuts down, and
      // the watchdog must not adopt that transient run.
      setTimeout(() => {
        this.probingVpnPermission = false;
        this.vpnDesiredRunning = false;
      }, 5000);
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
    // While the launch snapshot is unconfirmed, hold the decision (re-invoked by
    // the refresh ticks): starting now could double-start a live extension.
    if (this.autoStartAttempted || !this.autoStartFilterEnabled || this.homeStarting() || this.activeRunning()
      || this.launchStatusPending) {
      return;
    }
    this.autoStartAttempted = true;
    if (this.proxyModeEnabled) {
      await this.startDnsProxy();
    } else {
      // Keep the optimistic state in the UI. Only the extension can confirm
      // that VPN setup has actually begun.
      if (this.keepAliveModeList().length > 0) {
        this.status = this.updatedStatus('starting', this.t('autoStarting'));
      }
      await this.startVpn();
    }
  }

  private async stopVpn(): Promise<void> {
    if (this.busy) {
      return;
    }

    this.vpnDesiredRunning = false;  // user intent: stay down, no watchdog restart
    this.lastStartRequestAt = 0;  // close the start-settle window
    this.vpnStartTimedOut = false;
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
      let invalidCount: number = 0;
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
          // Reject files that aren't rule lists (e.g. a config JSON dropped here
          // by mistake — it belongs in "Import config", not "Import file").
          if (!this.looksLikeRuleList(importedText)) {
            invalidCount += 1;
            continue;
          }
          importedProfiles.push(this.createRuleProfile(this.ruleProfileNameFromUri(currentUri, index + 1), importedText, true));
        } catch (_) {
        }
      }

      if (importedProfiles.length === 0) {
        this.errorText = invalidCount > 0 ? this.t('importRuleInvalid') : this.t('importedEmpty');
        this.setConfigFeedback(this.errorText);
        return;
      }

      this.addImportedRuleProfiles(importedProfiles);
    } catch (err) {
      this.errorText = this.errorMessage(err);
      this.appendDebugLog(`==/vpn_ui/import_rules_error/ ${this.errorText}`);
    }
  }

  private async importRulesFromClipboard(): Promise<void> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      const content = data.getPrimaryText() ?? '';
      if (!content.trim()) {
        this.setConfigFeedback(this.tri('The clipboard has no text.', '剪贴板中没有文本。', '剪貼簿中沒有文字。'));
        return;
      }
      if (!this.looksLikeRuleList(content)) {
        this.setConfigFeedback(this.tri('Clipboard text is not a rule list.',
          '剪贴板中的文本不是规则列表。', '剪貼簿中的文字不是規則清單。'));
        return;
      }
      const name = this.tri('Clipboard rules', '剪贴板规则', '剪貼簿規則');
      this.addImportedRuleProfiles([this.createRuleProfile(name, content)]);
      this.showImportMenu = false;
    } catch (_) {
      this.setConfigFeedback(this.tri('Could not read the clipboard.', '无法读取剪贴板。', '無法讀取剪貼簿。'));
    }
  }

  private addImportedRuleProfiles(importedProfiles: RuleProfile[]): void {
    this.ensureRuleProfilesInitialized();
    const importedOnly = this.ruleProfiles.filter((profile: RuleProfile) => !profile.builtIn);
    const builtIns = this.ruleProfiles.filter((profile: RuleProfile) => profile.builtIn);
    this.ruleProfiles = importedOnly.concat(importedProfiles).concat(builtIns);
    this.syncRuleCountBadges();
    this.rulesText = this.buildMergedRulesText();
    this.rulesDirty = true;
    this.currentTab = 1;
    this.savePersistState();
    this.errorText = '';
    this.setConfigFeedback(this.rulesImportedMessage(importedProfiles.length));
    this.appendDebugLog(`==/vpn_ui/import_rules/ count=${importedProfiles.length}`);
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
    this.keepAliveEnabled = this.audioKeepAliveEnabled || this.locationKeepAliveEnabled ||
      this.dataTransferKeepAliveEnabled;
  }

  private keepAliveModeList(): Array<string> {
    const list: Array<string> = [];
    if (this.audioKeepAliveEnabled) {
      list.push('audioPlayback');
    }
    if (this.locationKeepAliveEnabled) {
      list.push('location');
    }
    if (this.dataTransferKeepAliveEnabled) {
      list.push('dataTransfer');
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
    if (this.dataTransferKeepAliveEnabled) {
      modes.push(this.t('dataTransferMode'));
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

  private async onDataTransferKeepAliveChange(enabled: boolean): Promise<void> {
    this.dataTransferKeepAliveEnabled = enabled;
    if (enabled) {
      // The progress live view is a notification; without permission the task
      // can't be kept alive, so ask up front.
      await this.ensureNotificationPermission();
    }
    this.syncKeepAliveEnabledFlag();
    this.savePersistState();
    await this.syncLongTaskKeepAlive();
  }

  private dataTransferNotifyText(): string {
    return `${this.t('blocked')} ${this.formatCount(this.querySummary.blocked)}  ·  ` +
      `${this.t('allowed')} ${this.formatCount(this.querySummary.allowed)}`;
  }

  private publishDataTransferProgress(): void {
    if (this.dataTransferNotificationId < 0) {
      return;
    }
    // There is no real "download" — the bar just keeps advancing so the system
    // sees a live, updating transfer task.
    this.dataTransferTick = (this.dataTransferTick + 1) % 100;
    const template: notificationManager.NotificationTemplate = {
      name: 'downloadTemplate',
      data: {
        title: this.t('dataTransferNotifyTitle'),
        fileName: this.dataTransferNotifyText(),
        progressValue: this.dataTransferTick,
      }
    };
    const request: notificationManager.NotificationRequest = {
      id: this.dataTransferNotificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: 8,
          title: this.t('dataTransferNotifyTitle'),
          text: this.dataTransferNotifyText(),
        }
      },
      template: template,
    };
    notificationManager.publish(request).catch((err: BusinessError) => {
      this.appendDebugLog(`==/vpn_ui/data_transfer_publish_error/ ${this.errorMessage(err)}`);
    });
  }

  private startDataTransferProgress(notificationId: number): void {
    this.stopDataTransferProgress();
    this.dataTransferNotificationId = notificationId;
    this.dataTransferTick = 0;
    this.publishDataTransferProgress();
    this.dataTransferTimer = setInterval(() => {
      this.publishDataTransferProgress();
    }, DATA_TRANSFER_PROGRESS_INTERVAL_MS);
    this.appendDebugLog(`==/vpn_ui/data_transfer_started/ notificationId=${notificationId}`);
  }

  private stopDataTransferProgress(): void {
    if (this.dataTransferTimer >= 0) {
      clearInterval(this.dataTransferTimer);
      this.dataTransferTimer = -1;
    }
    this.dataTransferNotificationId = -1;
  }

  // The system may cancel or suspend a continuous task on its own (e.g. a
  // DATA_TRANSFER task whose throughput is too low, or audio that isn't
  // playing). Registering the suspend listener makes the system suspend the
  // task first instead of cancelling it outright; either way, reflect it in the
  // UI so the keep-alive state shown isn't stale.
  private registerContinuousTaskListeners(): void {
    if (this.continuousTaskListenersOn) {
      return;
    }
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        this.appendDebugLog(`==/vpn_ui/keepalive_cancelled/ id=${info.id} reason=${info.reason}`);
        if (info.id !== this.continuousTaskId) {
          return;
        }
        this.stopDataTransferProgress();
        this.continuousTaskId = -1;
        this.keepAliveRunning = false;
        this.keepAliveStatusText = this.t('keepAliveCancelledBySystem');
      });
      backgroundTaskManager.on('continuousTaskSuspend', (info: backgroundTaskManager.ContinuousTaskSuspendInfo) => {
        this.appendDebugLog(`==/vpn_ui/keepalive_suspend/ id=${info.continuousTaskId} suspended=${info.suspendState} reason=${info.suspendReason}`);
      });
      backgroundTaskManager.on('continuousTaskActive', (info: backgroundTaskManager.ContinuousTaskActiveInfo) => {
        this.appendDebugLog(`==/vpn_ui/keepalive_active/ id=${info.id}`);
      });
      this.continuousTaskListenersOn = true;
    } catch (err) {
      this.appendDebugLog(`==/vpn_ui/keepalive_listener_error/ ${this.errorMessage(err)}`);
    }
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
      this.registerContinuousTaskListeners();
      if (this.dataTransferKeepAliveEnabled) {
        // With several modes the returned notificationId is the data-transfer
        // one (the others share a merged notification).
        this.startDataTransferProgress(taskInfo.notificationId);
      }
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
    this.stopDataTransferProgress();
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
  private buildAghProxyYaml(dnsPort: number, httpPort: number, upstreamSource: string,
    vpnDir: string, workDir: string): string {
    const yamlQuote = (value: string): string => `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

    const upstreams: string[] = [];
    for (const raw of upstreamSource.split(/[\s,;\n]+/)) {
      const ip: string = raw.trim();
      if (ip.length > 0 && !upstreams.includes(ip)) {
        upstreams.push(ip);
      }
    }
    if (upstreams.length === 0) {
      upstreams.push(DEFAULT_UPSTREAM_DNS_IP);
    }
    const upstreamLines: string = upstreams.map((u: string) => `    - ${yamlQuote(u)}`).join('\n');
    // bootstrap_dns must be plain IPs — it is what resolves DoH/DoT hostnames.
    // Feeding it a DoH URL would deadlock the bootstrap, so keep only IP upstreams
    // and fall back to the default resolver when every upstream is encrypted.
    const bootstrapIps: string[] = upstreams.filter((u: string) => this.isValidUpstreamIp(u));
    if (bootstrapIps.length === 0) {
      bootstrapIps.push(DEFAULT_UPSTREAM_DNS_IP);
    }
    const bootstrapLines: string = bootstrapIps.map((u: string) => `    - ${yamlQuote(u)}`).join('\n');

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
      (s: FilterSubscription) => s.enabled && s.state !== 'failed'
        && typeof s.url === 'string' && s.url.trim().length > 0);
    let filtersBlock: string;
    if (enabledSubs.length === 0) {
      filtersBlock = 'filters: []';
    } else {
      const entries: string[] = [];
      enabledSubs.forEach((s: FilterSubscription) => {
        const url: string = s.url.trim();
        const id = aghSubscriptionId(url);
        seedAghSubscriptionCache(vpnDir, workDir, url, id);
        entries.push('  - enabled: true');
        entries.push(`    url: ${yamlQuote(url)}`);
        entries.push(`    name: ${yamlQuote(s.name.length > 0 ? s.name : url)}`);
        entries.push(`    id: ${id}`);
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
      `  aaaa_disabled: ${this.blockAaaa}`,
      '  upstream_dns:',
      upstreamLines,
      '  bootstrap_dns:',
      bootstrapLines,
      // The proxy app funnels every query through the single 127.0.0.1 source, so
      // AdGuardHome's per-client rate limit would otherwise throttle the device.
      '  ratelimit: 0',
      // Flush each querylog entry to data/querylog.json immediately (default
      // size_memory=1000 buffers in RAM, leaving the file — which the app's DNS
      // list ingests — stale while the web panel looks live). 24h rotation keeps
      // the shared file small; the app copies rows into its own DB anyway.
      'querylog:',
      '  enabled: true',
      '  file_enabled: true',
      '  size_memory: 1',
      '  interval: 24h',
      // The app keeps its own persistent counters; AGH's statistics module
      // would redundantly maintain stats.db on disk (web panel dashboard
      // charts go empty, its query log page still works).
      'statistics:',
      '  enabled: false',
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

  private async startDnsProxy(auto: boolean = false): Promise<void> {
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
    // Watchdog restarts reuse the original consent and skip the dialog.
    if (!auto && !(await this.confirmStartWithoutKeepAlive())) {
      return;
    }
    if (!auto) {
      this.autoRestartAttempts = 0;
      this.autoRestartGaveUp = false;
    }

    this.busy = true;
    this.errorText = '';
    try {
      this.writeTextFile(this.rulesFilePath, this.rulesText);
      this.writeUpstreamFile();
      // Auto mode (proxy runs in-process, so resolve the system/router DNS here);
      // otherwise the manual list. Full mode reads this via buildAghProxyYaml below.
      const upstreamSource: string = await this.resolveProxyUpstream(this.upstreamDnsInput.trim());
      this.appendDebugLog(`==/vpn_ui/dns_proxy_upstream/ auto=${this.upstreamAutoEnabled} upstream=${upstreamSource.replace(/\n/g, ',')}`);
      // The lightweight native engine only speaks plain Do53, so strip any
      // encrypted/advanced entries before handing the list to it.
      const liteUpstreams: string[] = this.splitUpstreamEntries(upstreamSource)
        .filter((e: string) => this.isValidUpstreamIp(e));
      const upstream: string = liteUpstreams.length > 0
        ? liteUpstreams.join('\n')
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

      this.lastStartRequestAt = Date.now();
      let err: string | undefined;
      if (this.fullModeEnabled) {
        // Full engine: AdGuardHome as a standalone DNS server (serves UDP + TCP).
        const vpnDir: string = `${this.getHostContext().filesDir}/${VPN_DIR_NAME}`;
        const cfgPath: string = `${vpnDir}/${AGH_CONFIG_FILE_NAME}`;
        const workDir: string = `${vpnDir}/${AGH_WORK_DIR_NAME}`;
        const logPath: string = `${vpnDir}/${AGH_LOG_FILE_NAME}`;
        this.writeTextFile(cfgPath, this.buildAghProxyYaml(port, httpPort, upstreamSource, vpnDir, workDir));
        try {
          fileIo.mkdirSync(workDir, true);
        } catch (_) {
        }
        this.appendDebugLog(`==/vpn_ui/dns_proxy_start_request/ engine=full cfg=${cfgPath} port=${port} web=${this.aghWebEnabled}`);
        err = vpnclientbridge.startAghServerOnly(cfgPath, workDir, logPath, port, this.aghWebEnabled);
      } else {
        // Lightweight engine: a DNS server (TCP + UDP) backed by the local matcher.
        this.appendDebugLog(`==/vpn_ui/dns_proxy_start_request/ engine=lite port=${port} upstream=${upstream}`);
        err = vpnclientbridge.startLwDnsServer('127.0.0.1', port, upstream,
          this.rulesFilePath, this.queryLogFilePath, this.dnsCacheTtlSeconds, this.blockAaaa);
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
      this.syncDnsProxyRunning();
      this.dnsProxyDesiredRunning = true;
      this.dnsProxyStatusText = this.t('dnsProxyRunningStatus', `tcp://127.0.0.1:${port}`);
      this.startProxyNotify();
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
      this.lastStartRequestAt = 0;  // failed start: close the settle window
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
      if (running && this.logMaintenanceTimer < 0) {
        this.logMaintenanceTimer = setInterval(() => {
          this.checkLogMaintenance();
          if (!this.pageVisible) {
            this.refreshQueryLog();
          }
        }, LOG_MAINTENANCE_INTERVAL_MS);
      } else if (!running) {
        this.stopLogMaintenanceTimer();
      }
      if (running && this.dnsProxyStatusText.length === 0) {
        this.dnsProxyStatusText = this.t('dnsProxyRunningStatus', `tcp://127.0.0.1:${this.displayedDnsPort()}`);
      }
      // Adopt a proxy that's running but whose notification publisher isn't (e.g.
      // the UI was re-created while the keep-alive task kept the proxy alive).
      if (running && this.persistentNotificationEnabled && this.proxyNotifyTimer < 0) {
        this.startProxyNotify();
      } else if (!running && this.proxyNotifyTimer >= 0) {
        this.stopProxyNotify();
      }
    } catch (_) {
    }
  }

  private async stopDnsProxy(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.dnsProxyDesiredRunning = false;  // user intent: stay down, no watchdog restart
    this.lastStartRequestAt = 0;  // close the start-settle window
    this.busy = true;
    try {
      const err: string | undefined = vpnclientbridge.stopDnsFilter();
      if (err !== undefined) {
        this.appendDebugLog(`==/vpn_ui/dns_proxy_stop_error/ ${err}`);
      }
      await this.stopLongTaskKeepAlive(true);
      this.dnsProxyRunning = false;
      this.stopLogMaintenanceTimer();
      this.dnsProxyActivePort = 0;
      this.aghActiveHttpPort = 0;
      this.stopProxyNotify();
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

        if (this.dnsProxyRunning && this.fullModeEnabled && this.aghWebEnabled) {
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
      'This app is an on-device DNS filtering tool.\n\n• Online rule subscriptions are provided by third parties and may over- or under-block.\n\n• Whether to enable filtering, which rules to use and which lists to subscribe to are entirely your own decisions and responsibility. Use it only on devices/networks you are authorized to manage, and never for any unlawful purpose.\n\n• The authors provide no warranty and are not liable for any service disruption, data loss or other damage arising from use of this app.\n\n• This app is open source under GPL-3.0.',
      '本应用是运行在本机的 DNS 过滤工具。\n\n• 在线订阅的规则由第三方提供，可能存在误拦截或漏拦截。\n\n• 是否启用过滤、使用哪些规则、订阅哪些列表，均由你自行决定并承担相应后果。请仅在你有权管理的设备 / 网络上使用，请勿用于任何非法用途。\n\n• 作者不提供任何担保，且不对因使用本应用造成的服务不可用、数据丢失或其他损失承担责任。\n\n• 本应用基于 GPL-3.0 开源。',
      '本應用是執行在本機的 DNS 過濾工具。\n\n• 線上訂閱的規則由第三方提供，可能存在誤攔截或漏攔截。\n\n• 是否啟用過濾、使用哪些規則、訂閱哪些清單，均由你自行決定並承擔相應後果。請僅在你有權管理的裝置 / 網路上使用，請勿用於任何非法用途。\n\n• 作者不提供任何擔保，且不對因使用本應用造成的服務不可用、資料遺失或其他損失承擔責任。\n\n• 本應用基於 GPL-3.0 開源。');
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
            .backgroundColor(this.actionTone())
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
        .backgroundColor(this.actionTone())
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

  // True while a start is in flight (locally initiated, auto-start, or reported
  // by the VPN extension's status pump) — the home banner shows a third
  // "starting" face for it instead of pretending the filter is stopped.
  private homeStarting(): boolean {
    if (this.activeRunning() || this.stopping) {
      return false;
    }
    if (this.busy) {
      return true;
    }
    // Within the settle window after a start request, keep the "starting" face
    // through the extension's transient intermediate phases ('creating', or
    // 'stopped' while a restart tears the old instance down).
    if (Date.now() - this.lastStartRequestAt < START_SETTLE_GRACE_MS) {
      return true;
    }
    return !this.proxyModeEnabled
      && (this.status.phase === 'starting' || this.status.phase === 'creating');
  }

  // Hint line under the home banner while starting: prefer the live status note
  // (auto-starting / start requested), falling back to the generic label.
  private homeStartingHint(): string {
    const note: string = this.status.note.trim();
    if (!this.proxyModeEnabled && note.length > 0 &&
      (this.status.phase === 'starting' || this.status.phase === 'creating')) {
      return note;
    }
    return this.t('working');
  }

  private homeStoppedHint(): string {
    if (!this.proxyModeEnabled) {
      if (this.vpnStartTimedOut) {
        return this.tri('VPN startup timed out. Try starting again.',
          'VPN 启动超时，请重试。', 'VPN 啟動逾時，請重試。');
      }
      if (this.status.phase === 'error' && this.status.note.trim().length > 0) {
        return this.status.note;
      }
    }
    return this.t('stoppedHint');
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
    // The extension writes its status notes as fixed English strings (it has no
    // access to the in-app language override); map every known one here.
    let localizedNote = snapshot.note;
    switch (snapshot.note) {
      case 'DNS filter has not been started yet.':
        localizedNote = this.t('dnsFilterNotStarted');
        break;
      case 'Preparing DNS filter runtime.':
        localizedNote = this.t('startingStatus');
        break;
      case 'Creating DNS-only VPN and preparing the local filter engine.':
        localizedNote = this.t('creatingVpnNote');
        break;
      case 'DNS-only VPN is active. DNS requests are visible, rule-matched, and forwarded or blocked locally.':
        localizedNote = this.t('vpnActiveNote');
        break;
      case 'DNS-only VPN has been stopped.':
        localizedNote = this.t('vpnStoppedNote');
        break;
      default:
        break;
    }
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
      effectiveUpstream: snapshot.effectiveUpstream,
      upstreamAuto: snapshot.upstreamAuto,
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
    const now: number = Date.now();
    // A "running" snapshot stamped BEFORE this UI process launched is suspect.
    // A live extension idling at the slow heartbeat may legitimately be up to
    // IDLE_STATUS_HEARTBEAT_MS behind, so only a stamp older than that is
    // declared dead right away; anything newer gets a short grace to confirm
    // itself with a post-launch write (the extension returns to the 1s cadence
    // once it notices our ui_watch touch).
    if (updatedAtMs < this.appLaunchMs) {
      if (updatedAtMs < this.appLaunchMs - STATUS_IDLE_STALE_TIMEOUT_MS
        || now - this.appLaunchMs >= LAUNCH_STATUS_GRACE_MS) {
        return true;
      }
    }
    // Steady state: with the page visible long enough for the extension to be
    // back on the 1s cadence, expect fresh stamps; right after becoming
    // visible, tolerate one idle heartbeat.
    const staleLimitMs: number = now - this.uiWatchSinceMs >= UI_WATCH_RESUME_GRACE_MS
      ? STATUS_STALE_TIMEOUT_MS
      : STATUS_IDLE_STALE_TIMEOUT_MS;
    return now - updatedAtMs > staleLimitMs;
  }

  // A not-yet-stale "running" snapshot stamped before launch: either a live
  // extension that hasn't written since this process started (~1s away from
  // confirming itself) or the leftover of a session killed moments ago. Only
  // meaningful when isStaleRunningSnapshot() returned false.
  private isPendingLaunchSnapshot(snapshot: StatusSnapshot): boolean {
    if (!snapshot.running) {
      return false;
    }
    const updatedAtMs = Date.parse(snapshot.updatedAt);
    return Number.isFinite(updatedAtMs) && updatedAtMs < this.appLaunchMs;
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
    return this.isDarkModeActive() ? '#9AA6BA' : '#647085';
  }

  // Base color shared by the page gradient and immersive title bar.
  private canvasTone(): string {
    return this.paletteColors().canvas;
  }

  private cardSurfaceTone(): string {
    return this.paletteColors().card;
  }

  private cardBorderTone(): string {
    return this.paletteColors().border;
  }

  private cardShadowTone(): string {
    return this.isDarkModeActive() ? '#32070C1B' : '#1023355B';
  }

  private chipSurfaceTone(): string {
    return this.paletteColors().soft;
  }

  private floatingBarTone(): string {
    return paletteAlpha(this.cardSurfaceTone(), 'F2');
  }

  private elevatedSurfaceTone(): string {
    return this.paletteColors().card;
  }

  private softPanelTone(): string {
    return this.paletteColors().soft;
  }

  private selectedChipSurfaceTone(): string {
    return this.paletteColors().selected;
  }

  private selectedChipTextTone(): string {
    return this.paletteColors().accent;
  }

  private coolChipSurfaceTone(): string {
    return this.selectedChipSurfaceTone();
  }

  private coolNeutralChipSurfaceTone(): string {
    return this.softPanelTone();
  }

    private warmChipSurfaceTone(): string {
      return this.isDarkModeActive() ? '#3E2630' : '#FCEAEA';
    }

    private selectedOutlineTone(): string {
      return this.selectedChipTextTone();
    }

    private selectedShadowTone(): string {
      return this.isDarkModeActive() ? '#40000000' : paletteAlpha(this.actionTone(), '1F');
  }

  private accentBlueTone(): string {
    return this.selectedChipTextTone();
  }

  private actionTone(): string {
    return this.paletteColors().action;
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
    return this.selectedChipSurfaceTone();
  }

  private softGreenTone(): string {
      return this.isDarkModeActive() ? '#1E3A2E' : '#E7F5EE';
  }

  private softAmberTone(): string {
    return this.softPanelTone();
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
    return this.cardSurfaceTone();
  }

  private sheetSecondarySurfaceTone(): string {
    return this.softPanelTone();
  }

  private sheetInputSurfaceTone(): string {
    return this.softPanelTone();
  }

  private sheetBorderTone(): string {
    return this.cardBorderTone();
  }

  private sheetShadowTone(): string {
    return this.isDarkModeActive() ? '#55000000' : '#22101A2E';
  }

  private sheetGlowTone(): string {
    return paletteAlpha(this.selectedChipTextTone(), this.isDarkModeActive() ? '22' : '14');
  }

  private getBottomTabOverlayHeight(): number {
    const tabHeight: number = 50;
    const floatingBottomMargin: number = 24;
    return tabHeight + floatingBottomMargin;
  }

  private contentBottomInset(): number {
    return Math.max(0, this.avoidPaddingBottom) + (this.useSidebarLayout() ? 16 : this.getBottomTabOverlayHeight());
  }

  private useSidebarLayout(): boolean {
    return deviceInfo.deviceType === '2in1' ||
      (deviceInfo.deviceType === 'tablet' && this.windowHeightVp > 0 && this.windowWidthVp > this.windowHeightVp);
  }

  private useWideMe(): boolean {
    return this.useSidebarLayout() || (deviceInfo.deviceType === 'tablet' && this.windowWidthVp >= 620);
  }

  private contentSideInset(): number {
    const contentWidth = this.windowWidthVp - (this.useSidebarLayout() ? 170 : 0);
    return this.useWideMe() ? Math.max(20, Math.round((contentWidth - 1720) / 2)) : 16;
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

  // One segment of the persistent-notification refresh-interval selector (1-5s).
  @Builder
  private NotifyIntervalSegButton(seconds: number) {
    Button(`${seconds}${this.language === 'en' ? 's' : '秒'}`)
      .type(ButtonType.Normal)
      .layoutWeight(1)
      .height(36)
      .fontSize(13)
      .fontWeight(this.notificationRefreshSeconds === seconds ? FontWeight.Bold : FontWeight.Medium)
      .backgroundColor(this.notificationRefreshSeconds === seconds ? this.cardSurfaceTone() : Color.Transparent)
      .fontColor(this.notificationRefreshSeconds === seconds ? this.accentBlueTone() : this.secondaryTextColor())
      .borderRadius(11)
      .shadow(this.notificationRefreshSeconds === seconds
        ? { radius: 8, color: this.cardShadowTone(), offsetX: 0, offsetY: 2 }
        : { radius: 0, color: '#00000000' })
      .onClick(() => {
        this.setNotificationRefreshSeconds(seconds);
      })
  }

  // Leading icon + title + description block for a settings list row. The
  // trailing control (chevron / Toggle) is placed by the caller as a sibling.
  @Builder
  private SettingsIconText(p: SettingsRowTextParam) {
    Row({ space: 12 }) {
      if (typeof p.glyph === 'string') {
        this.IconBubble(p.glyph, p.iconBg ?? this.selectedChipSurfaceTone(),
          p.iconFg ?? this.selectedChipTextTone(), 36, 16)
      } else {
        this.MeLinkIcon(p.glyph)
      }
      Column({ space: 2 }) {
        Text(p.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(p.dimmed ? this.secondaryTextColor() : this.primaryTextColor())
        Text(p.desc)
          .fontSize(12)
          .lineHeight(17)
          .fontColor(p.dimmed ? this.mutedTextColor() : this.secondaryTextColor())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .alignItems(VerticalAlign.Center)
  }

  // One of the user's active subscriptions: tap the card to preview its content
  // (cache first), use the switch to enable it, or open the menu to remove it.
  @Builder
  private MySubscriptionRow(s: FilterSubscription) {
    Row({ space: 8 }) {
      this.MeLinkIcon($r('sys.symbol.link'))
      Column({ space: 2 }) {
        Text(s.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(s.url)
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subStatusText(s).length > 0) {
          Text(this.subStatusText(s))
            .fontSize(11)
            .fontColor(this.subStatusColor(s))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: s.enabled })
        .enabled(this.fullModeEnabled)
        .selectedColor(this.actionTone())
        .onChange((value: boolean) => {
          this.toggleFilterSubscription(s.id, value);
        })
      Button('···')
        .width(28)
        .height(36)
        .padding(0)
        .fontSize(20)
        .fontColor(this.secondaryTextColor())
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.tri('Subscription actions', '订阅操作', '訂閱操作'))
        .bindMenu([{
          value: this.t('deleteRule'),
          action: () => this.confirmDeleteSubscription(s)
        }])
    }
    .width('100%')
    .constraintSize({ minHeight: 72 })
    .padding(10)
    .backgroundColor(this.cardSurfaceTone())
    .borderRadius(13)
    .border({ width: 1, color: this.cardBorderTone() })
    // Tapping the card (anywhere but the switch / menu) previews content.
    .onClick(() => {
      this.viewSubscriptionContent(s);
    })
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
  private SubContentSheet() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.subContentTitle.length > 0
            ? this.subContentTitle
            : this.tri('Subscription content', '订阅内容', '訂閱內容'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subContentUrl)
            .fontSize(11)
            .fontColor(this.mutedTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
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
            this.closeSubContentSheet();
          })
      }
      .width('100%')

      Row({ space: 10 }) {
        Text(this.subContentLoading
          ? this.tri('Loading…', '加载中…', '載入中…')
          : (this.subContentLineCount > 0
              ? this.tri(`${this.subContentLineCount} lines`,
                  `共 ${this.subContentLineCount} 行`, `共 ${this.subContentLineCount} 行`)
              : ''))
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
          .layoutWeight(1)
        Button(this.tri('🔄 Refresh', '🔄 刷新', '🔄 刷新'))
          .fontSize(12)
          .height(34)
          .backgroundColor(this.coolChipSurfaceTone())
          .fontColor(this.primaryTextColor())
          .borderRadius(10)
          .enabled(!this.subContentLoading)
          .onClick(() => {
            void this.refreshSubContent();
          })
        Button(this.tri('Open in browser', '浏览器打开', '瀏覽器開啟'))
          .fontSize(12)
          .height(34)
          .backgroundColor(this.coolChipSurfaceTone())
          .fontColor(this.primaryTextColor())
          .borderRadius(10)
          .onClick(() => {
            this.openSubContentInBrowser();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.subContentLoading) {
        Column() {
          LoadingProgress()
            .width(44)
            .height(44)
            .color(this.accentBlueTone())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.subContentError.length > 0) {
        Column() {
          Text(this.subContentError)
            .fontSize(14)
            .lineHeight(21)
            .fontColor(this.isDarkModeActive() ? '#FF8A8A' : '#D14343')
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Start)
      } else {
        Scroll() {
          Text(this.subContentText)
            .fontSize(12)
            .lineHeight(18)
            .fontColor(this.primaryTextColor())
            .textAlign(TextAlign.Start)
            .width('100%')
            .copyOption(CopyOptions.LocalDevice)
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Auto)
        .padding(12)
        .backgroundColor(this.sheetSecondarySurfaceTone())
        .borderRadius(14)
        .border({ width: 1, color: this.sheetBorderTone() })
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
          }, (item: string, index: number) => `${index}:${item}`)
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

  // ===== Immersive shell: page backdrop, tab roots, sub pages =================

  // The title bar fades between the page colour at alpha 0 and the blur, so the
  // RGB must match canvasTone (see components/BlurTitleBar.ets).
  private pageToneClear(): string {
    return paletteAlpha(this.canvasTone(), '00');
  }

  private pageTitleBar(title: string, menu?: Array<HdsNavigationMenuItemOptions>): HdsNavigationTitleBarOptions {
    return blurTitleBar(title, this.primaryTextColor(), this.secondaryTextColor(), this.canvasTone(),
      this.pageToneClear(), { menu: menu });
  }

  private configTitleMenu(): Array<HdsNavigationMenuItemOptions> {
    return [{
      content: {
        icon: new SymbolGlyphModifier($r(this.showImportMenu ? 'sys.symbol.xmark' : 'sys.symbol.plus')),
        label: this.configOnlineTab ? this.tri('Add subscription', '添加订阅', '新增訂閱') : this.t('quickImport'),
        action: () => {
          this.showImportMenu = !this.showImportMenu;
          if (this.showImportMenu) {
            this.configScroller.scrollEdge(Edge.Top);
          }
        }
      }
    }];
  }

  private appSplitTitleMenu(): Array<HdsNavigationMenuItemOptions> {
    return [{
      content: {
        icon: new SymbolGlyphModifier($r('sys.symbol.plus')),
        label: this.t('appSplitAddTitle'),
        action: () => {
          this.openAppSplitAddSheet();
        }
      }
    }];
  }

  // Opaque backdrop prevents the tab root from showing during navigation.
  @Builder
  private PageBackdrop() {
    Column() {}
      .width('100%')
      .height('100%')
      .linearGradient({ angle: 155, colors: [[this.canvasTone(), 0], [this.paletteColors().canvasEnd, 1]] })
  }

  // Each tab is its own HdsNavigation so the immersive title bar tracks that
  // tab's scroller.
  @Builder
  private TabRoot(index: number) {
    if (index === 0) {
      HdsNavigation() {
        this.HomeTab()
      }
      .titleBar(this.pageTitleBar(this.t('appTitle')))
      .bindToScrollable([this.homeScroller])
      .titleMode(HdsNavigationTitleMode.MINI)
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .hideToolBar(true)
      .backgroundColor(Color.Transparent)
      .width('100%')
      .height('100%')
    } else if (index === 1) {
      HdsNavigation() {
        this.ConfigTab()
      }
      .titleBar(this.pageTitleBar(this.t('configTitle'), this.configTitleMenu()))
      .bindToScrollable([this.configScroller])
      .titleMode(HdsNavigationTitleMode.MINI)
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .hideToolBar(true)
      .backgroundColor(Color.Transparent)
      .width('100%')
      .height('100%')
    } else {
      HdsNavigation() {
        this.MeTab()
      }
      .titleBar(this.pageTitleBar(this.t('tabMe')))
      .bindToScrollable([this.meScroller])
      .titleMode(HdsNavigationTitleMode.MINI)
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .hideToolBar(true)
      .backgroundColor(Color.Transparent)
      .width('100%')
      .height('100%')
    }
  }

  @Builder
  private MePageMap(name: string) {
    if (name === ME_PAGE_APP_SPLIT) {
      HdsNavDestination() {
        this.AppSplitPage()
      }
      .titleBar(this.pageTitleBar(this.t('appSplitTitle'), this.appSplitTitleMenu()))
      .bindToScrollable([this.appSplitScroller])
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .hideToolBar(true)
      .background(this.PageBackdrop())
      .bindSheet(this.showAppSplitAddSheet, this.AppSplitAddSheet(), {
        height: SheetSize.FIT_CONTENT,
        backgroundColor: this.canvasTone(),
        showClose: false,
        onDisappear: () => {
          this.showAppSplitAddSheet = false;
        }
      })
    } else {
      HdsNavDestination() {
        this.SettingsSubPage(name)
      }
      .titleBar(this.pageTitleBar(this.mePageTitle(name)))
      .bindToScrollable([this.meSectionScroller(name)])
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .hideToolBar(true)
      .background(this.PageBackdrop())
    }
  }

  private meSectionScroller(name: string): Scroller {
    const existing = this.meSectionScrollers.get(name);
    if (existing !== undefined) {
      return existing;
    }
    const scroller = new Scroller();
    this.meSectionScrollers.set(name, scroller);
    return scroller;
  }

  // ===== Per-app routing (分应用代理) ========================================

  private appSplitEnabledBundles(): string[] {
    return this.appSplitList
      .filter((e: AppSplitEntry) => e.enabled)
      .map((e: AppSplitEntry) => e.bundle);
  }

  private appSplitDisplayName(e: AppSplitEntry): string {
    return e.name.length > 0 ? e.name : e.bundle;
  }

  private appSplitModeHint(): string {
    if (this.appSplitMode === 'bypass') {
      return this.t('appSplitModeBypassHint');
    }
    if (this.appSplitMode === 'only') {
      return this.t('appSplitModeOnlyHint');
    }
    return this.t('appSplitModeOffHint');
  }

  // One-line state for the entry row on the "Me" tab.
  private appSplitSummary(): string {
    if (this.appSplitMode === 'off') {
      return this.t('appSplitEntryHint');
    }
    const label: string = this.appSplitMode === 'bypass' ? this.t('appSplitModeBypass') : this.t('appSplitModeOnly');
    return `${label} · ${this.t('appSplitCount', this.appSplitEnabledBundles().length)}`;
  }

  private onAppSplitChanged(): void {
    this.appSplitList = normalizeAppSplitList(this.appSplitList);
    this.savePersistState();
    const previous: string = this.lastAppSplitFileContent;
    if (this.writeAppSplitFile() && previous !== this.lastAppSplitFileContent &&
      this.status.running && !this.proxyModeEnabled) {
      // The running extension picks the file up within a second and rebuilds
      // the tun (a brief network blip), so no manual restart is needed.
      try {
        this.ensurePromptAction()?.showToast({ message: this.t('appSplitApplying') });
      } catch (_) {
      }
    }
  }

  // Mirror the effective per-app settings without rewriting an unchanged file.
  private writeAppSplitFile(): boolean {
    if (this.appSplitFilePath.length === 0) {
      return false;
    }
    const cfg: AppSplitFile = { mode: this.appSplitMode, bundles: this.appSplitEnabledBundles() };
    if (cfg.mode === 'only' && cfg.bundles.length > 0 && this.appSplitDnsAllowlistEnabled) {
      cfg.dnsAllowlist = parseAppSplitDnsAllowlist(this.appSplitDnsAllowlist);
    }
    if (cfg.mode === 'only' && cfg.bundles.length > 0 && this.appTunnelEnabled && this.appTunnelAvailable) {
      cfg.tunnelRules = this.appTunnelRules;
    }
    const content: string = JSON.stringify(cfg);
    if (content === this.lastAppSplitFileContent) {
      return true;
    }
    if (!this.writeAtomicTextFile(this.appSplitFilePath, content)) {
      return false;
    }
    this.lastAppSplitFileContent = content;
    return true;
  }

  private saveAppSplitDnsAllowlist(enabled: boolean, saveDraft: boolean): void {
    const domains: string = this.appSplitDnsAllowlist;
    const wasEnabled: boolean = this.appSplitDnsAllowlistEnabled;
    if (saveDraft) {
      const parsed: string[] | undefined = parseAppSplitDnsAllowlist(this.appSplitDnsAllowlistDraft);
      if (parsed === undefined) {
        this.appSplitDnsAllowlistError = this.tri('Enter hostnames only, for example www.example.com.',
          '请输入域名，例如 www.example.com。', '請輸入網域名稱，例如 www.example.com。');
        return;
      }
      this.appSplitDnsAllowlist = parsed.join('\n');
    }
    this.appSplitDnsAllowlistEnabled = enabled;
    if (!this.savePersistState(true) || !this.writeAppSplitFile()) {
      this.appSplitDnsAllowlist = domains;
      this.appSplitDnsAllowlistEnabled = wasEnabled;
      this.savePersistState(true);
      this.appSplitDnsAllowlistError = this.tri('Could not save the DNS allowlist.', '无法保存 DNS 白名单。',
        '無法儲存 DNS 允許清單。');
      return;
    }
    if (saveDraft) {
      this.appSplitDnsAllowlistDraft = this.appSplitDnsAllowlist;
    }
    this.appSplitDnsAllowlistError = '';
  }

  private saveAppTunnel(enabled: boolean, saveDraft: boolean): void {
    const previousRules: string = this.appTunnelRules;
    const previousEnabled: boolean = this.appTunnelEnabled;
    const rules: string = saveDraft ? this.appTunnelRulesDraft.trim() : previousRules;
    if (saveDraft) {
      const error: string | undefined = vpnclientbridge.validateAppTunnelRules(rules);
      if (error !== undefined) {
        const line: string | undefined = error.match(/line (\d+)$/)?.[1];
        this.appTunnelRulesError = line === undefined ?
          this.tri('Use at most 256 IP rules.', '最多可保存 256 条 IP 规则。', '最多可儲存 256 條 IP 規則。') :
          this.tri(`Invalid IP or port on line ${line}.`, `第 ${line} 行的 IP 或端口无效。`, `第 ${line} 行的 IP 或連接埠無效。`);
        return;
      }
    }
    this.appTunnelRules = rules;
    this.appTunnelEnabled = enabled;
    if (!this.savePersistState(true) || !this.writeAppSplitFile()) {
      this.appTunnelRules = previousRules;
      this.appTunnelEnabled = previousEnabled;
      this.savePersistState(true);
      this.appTunnelRulesError = this.tri('Could not save the tunnel settings.', '无法保存全量 VPN 设置。',
        '無法儲存全量 VPN 設定。');
      this.ensurePromptAction()?.showToast({ message: this.appTunnelRulesError });
      return;
    }
    if (saveDraft) {
      this.appTunnelRulesDraft = rules;
    }
    this.appTunnelRulesError = '';
  }

  private setAppSplitMode(mode: AppSplitMode): void {
    if (this.appSplitMode === mode) {
      return;
    }
    this.appSplitMode = mode;
    this.onAppSplitChanged();
  }

  private setAppSplitEntryEnabled(bundle: string, enabled: boolean): void {
    this.appSplitList = this.appSplitList.map((e: AppSplitEntry): AppSplitEntry =>
      e.bundle === bundle ? { bundle: e.bundle, name: e.name, enabled: enabled } : e);
    this.onAppSplitChanged();
  }

  private removeAppSplitEntry(bundle: string): void {
    this.appSplitList = this.appSplitList.filter((e: AppSplitEntry) => e.bundle !== bundle);
    this.onAppSplitChanged();
  }

  private openAppSplitAddSheet(): void {
    this.appSplitBundleInput = '';
    this.appSplitNameInput = '';
    this.appSplitAddError = '';
    this.showAppSplitAddSheet = true;
  }

  private addAppSplitEntry(): void {
    const bundle: string = this.appSplitBundleInput.trim();
    if (!isValidBundleName(bundle)) {
      this.appSplitAddError = this.t('appSplitInvalidBundle');
      return;
    }
    if (bundle === VPN_BUNDLE_NAME) {
      this.appSplitAddError = this.t('appSplitSelfBundle');
      return;
    }
    if (this.appSplitList.find((e: AppSplitEntry) => e.bundle === bundle) !== undefined) {
      this.appSplitAddError = this.t('appSplitDuplicate');
      return;
    }
    if (this.appSplitList.length >= APP_SPLIT_MAX_BUNDLES) {
      this.appSplitAddError = this.t('appSplitLimitReached', APP_SPLIT_MAX_BUNDLES);
      return;
    }
    const entry: AppSplitEntry = { bundle: bundle, name: this.appSplitNameInput.trim(), enabled: true };
    this.appSplitList = this.appSplitList.concat([entry]);
    // Adding the first app while still "off" almost always means "bypass it".
    if (this.appSplitMode === 'off') {
      this.appSplitMode = 'bypass';
    }
    this.onAppSplitChanged();
    this.showAppSplitAddSheet = false;
  }

  @Builder
  private AppSplitModeSegButton(label: string, mode: AppSplitMode) {
    Button(label)
      .type(ButtonType.Normal)
      .layoutWeight(1)
      .height(36)
      .fontSize(13)
      .fontWeight(this.appSplitMode === mode ? FontWeight.Bold : FontWeight.Medium)
      .backgroundColor(this.appSplitMode === mode ? this.cardSurfaceTone() : Color.Transparent)
      .fontColor(this.appSplitMode === mode ? this.accentBlueTone() : this.secondaryTextColor())
      .borderRadius(11)
      .shadow(this.appSplitMode === mode
        ? { radius: 8, color: this.cardShadowTone(), offsetX: 0, offsetY: 2 }
        : { radius: 0, color: '#00000000' })
      .onClick(() => {
        this.setAppSplitMode(mode);
      })
  }

  @Builder
  private AppSplitRow(e: AppSplitEntry) {
    Row({ space: 12 }) {
      Stack() {
        Text(this.appSplitDisplayName(e).substring(0, 1).toUpperCase())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
      .width(40)
      .height(40)
      .borderRadius(12)
      .linearGradient({
        angle: 135,
        colors: e.enabled
          ? [['#22C1E0', 0.0], ['#2F6FDB', 1.0]]
          : (this.isDarkModeActive() ? [['#3A4558', 0.0], ['#2C3545', 1.0]] : [['#C3CAD5', 0.0], ['#A9B2BF', 1.0]])
      })

      Column({ space: 2 }) {
        Text(this.appSplitDisplayName(e))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(e.bundle)
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: e.enabled })
        .onChange((value: boolean) => {
          this.setAppSplitEntryEnabled(e.bundle, value);
        })

      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize(18)
        .fontColor([this.mutedTextColor()])
        .padding(6)
        .onClick(() => {
          this.removeAppSplitEntry(e.bundle);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 10, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.elevatedSurfaceTone())
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
    .borderRadius(18)
    .border({ width: 1, color: this.cardBorderTone() })
    .shadow({ radius: 10, color: this.cardShadowTone() })
  }

  @Builder
  private AppSplitDnsAllowlistCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text(this.tri('DNS allowlist', 'DNS 白名单', 'DNS 允許清單'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.appSplitDnsAllowlistEnabled })
          .enabled(this.appSplitEnabledBundles().length > 0)
          .onChange((enabled: boolean) => this.saveAppSplitDnsAllowlist(enabled, enabled))
      }
      .width('100%')
      Text(this.tri(
        'While enabled, other DNS rules are paused. Only listed hostnames can be resolved. An empty list blocks all new DNS queries from the selected apps.',
        '开启时暂停其他 DNS 规则，只放行名单中的完整域名。留空会拦截所选应用的全部新 DNS 请求。',
        '開啟時暫停其他 DNS 規則，只允許清單中的完整網域。留空會攔截所選應用程式的所有新 DNS 請求。'))
        .fontSize(12)
        .lineHeight(18)
        .fontColor(this.secondaryTextColor())
        .width('100%')
      TextArea({ text: this.appSplitDnsAllowlistDraft, placeholder: this.tri('One hostname per line',
        '每行一个域名', '每行一個網域') })
        .width('100%')
        .height(100)
        .fontSize(14)
        .borderRadius(14)
        .backgroundColor(this.softPanelTone())
        .onChange((value: string) => {
          this.appSplitDnsAllowlistDraft = value;
          this.appSplitDnsAllowlistError = '';
        })
      if (this.appSplitDnsAllowlistError.length > 0) {
        Text(this.appSplitDnsAllowlistError)
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
      }
      Button(this.tri('Save allowlist', '保存白名单', '儲存允許清單'))
        .enabled(this.appSplitDnsAllowlistDraft !== this.appSplitDnsAllowlist)
        .onClick(() => this.saveAppSplitDnsAllowlist(this.appSplitDnsAllowlistEnabled, true))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius(18)
    .backgroundColor(this.elevatedSurfaceTone())
    .border({ width: 1, color: this.cardBorderTone() })
  }

  @Builder
  private AppTunnelRulesCard() {
    Column({ space: 10 }) {
      Text(this.tri('IP blocking rules', 'IP 拦截规则', 'IP 封鎖規則'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
      TextArea({ text: this.appTunnelRulesDraft,
        placeholder: this.tri('Block one IP or IP:port per line', '每行一个要拦截的 IP 或 IP:端口',
          '每行一個要封鎖的 IP 或 IP:連接埠') })
        .width('100%')
        .height(100)
        .fontSize(14)
        .maxLength(APP_TUNNEL_RULES_MAX_LENGTH)
        .borderRadius(14)
        .backgroundColor(this.softPanelTone())
        .onChange((value: string) => {
          this.appTunnelRulesDraft = value;
          this.appTunnelRulesError = '';
        })
      Text(this.tri('For example 192.0.2.1 or [2001:db8::1]:443.',
        '例如 192.0.2.1 或 [2001:db8::1]:443。', '例如 192.0.2.1 或 [2001:db8::1]:443。'))
        .fontSize(12)
        .fontColor(this.secondaryTextColor())
      if (this.appTunnelRulesError.length > 0) {
        Text(this.appTunnelRulesError)
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
      }
      Button(this.tri('Save IP rules', '保存 IP 规则', '儲存 IP 規則'))
        .enabled(this.appTunnelRulesDraft !== this.appTunnelRules)
        .onClick(() => this.saveAppTunnel(this.appTunnelEnabled, true))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius(18)
    .backgroundColor(this.elevatedSurfaceTone())
    .border({ width: 1, color: this.cardBorderTone() })
  }

  @Builder
  private AppSplitPage() {
    Scroll(this.appSplitScroller) {
      Column({ space: 14 }) {
        Text(this.t('appSplitDesc'))
          .fontSize(13)
          .lineHeight(19)
          .fontColor(this.secondaryTextColor())
          .width('100%')
          .padding({ left: 4, right: 4 })

        if (this.proxyModeEnabled) {
          Text(this.t('appSplitProxyModeNote'))
            .fontSize(12)
            .lineHeight(18)
            .fontColor(this.isDarkModeActive() ? '#F5C26B' : '#9A5B00')
            .padding(12)
            .width('100%')
            .backgroundColor(this.isDarkModeActive() ? '#2A2312' : '#FFF4DE')
            .borderRadius(14)
        }

        Column({ space: 10 }) {
          Row({ space: 5 }) {
            this.AppSplitModeSegButton(this.t('appSplitModeOff'), 'off')
            this.AppSplitModeSegButton(this.t('appSplitModeBypass'), 'bypass')
            this.AppSplitModeSegButton(this.t('appSplitModeOnly'), 'only')
          }
          .width('100%')
          .padding(5)
          .backgroundColor(this.softPanelTone())
          .borderRadius(14)
          .border({ width: 1, color: this.cardBorderTone() })

          Text(this.appSplitModeHint())
            .fontSize(12)
            .lineHeight(18)
            .fontColor(this.secondaryTextColor())
            .width('100%')
            .padding({ left: 4, right: 4 })
        }
        .width('100%')
        .padding(14)
        .backgroundColor(this.elevatedSurfaceTone())
        .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
        .borderRadius(22)
        .border({ width: 1, color: this.cardBorderTone() })
        .shadow({ radius: 12, color: this.cardShadowTone() })

        this.SettingsGroupTitle({ text: this.t('appSplitListTitle', this.appSplitList.length) })

        if (this.appSplitList.length === 0) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.square_grid_2x2'))
              .fontSize(34)
              .fontColor([this.mutedTextColor()])
            Text(this.t('appSplitEmpty'))
              .fontSize(13)
              .fontColor(this.mutedTextColor())
              .textAlign(TextAlign.Center)
            Button(this.t('appSplitAddTitle'))
              .height(36)
              .fontSize(14)
              .margin({ top: 4 })
              .backgroundColor(this.actionTone())
              .fontColor('#FFFFFF')
              .onClick(() => {
                this.openAppSplitAddSheet();
              })
          }
          .width('100%')
          .padding({ top: 28, bottom: 28 })
          .alignItems(HorizontalAlign.Center)
        } else {
          ForEach(this.appSplitList, (e: AppSplitEntry) => {
            this.AppSplitRow(e)
          }, (e: AppSplitEntry) => `${e.bundle}:${e.enabled}:${e.name}`)
        }

        if (!this.proxyModeEnabled && this.appSplitMode === 'only') {
          this.SettingsGroupTitle({ text: this.tri('Advanced debugging', '高级调试', '進階除錯') })
          this.AppSplitDnsAllowlistCard()
          if (this.appTunnelEnabled && this.appTunnelAvailable) {
            this.AppTunnelRulesCard()
          }
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 8, bottom: Math.max(12, this.avoidPaddingBottom) })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  @Builder
  private AppSplitFieldLabel(label: string) {
    Text(label)
      .fontSize(15)
      .fontColor(this.primaryTextColor())
      .width(96)
  }

  @Builder
  private AppSplitAddSheet() {
    Column({ space: 12 }) {
      Row() {
        Text(this.t('appSplitAddTitle'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
        Blank()
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([this.primaryTextColor()])
        }
        .type(ButtonType.Circle)
        .width(40)
        .height(40)
        .backgroundColor(this.softPanelTone())
        .onClick(() => {
          this.showAppSplitAddSheet = false;
        })
      }
      .width('100%')
      .margin({ bottom: 8 })

      Column() {
        Row() {
          this.AppSplitFieldLabel(this.t('appSplitBundleLabel'))
          TextInput({ text: this.appSplitBundleInput, placeholder: this.t('appSplitBundlePlaceholder') })
            .layoutWeight(1)
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .onChange((value: string) => {
              this.appSplitBundleInput = value;
              this.appSplitAddError = '';
            })
            .onBlur(() => {
              const bundle = this.appSplitBundleInput.trim();
              if (bundle.length > 0 && !isValidBundleName(bundle)) {
                this.appSplitAddError = this.t('appSplitInvalidBundle');
              }
            })
        }
        .width('100%')
        .padding({ left: 16, right: 8, top: 4, bottom: 4 })
        .alignItems(VerticalAlign.Center)

        Divider().strokeWidth(1).color(this.cardBorderTone()).margin({ left: 16, right: 16 })

        Row() {
          this.AppSplitFieldLabel(this.t('appSplitNameLabel'))
          TextInput({ text: this.appSplitNameInput, placeholder: this.t('appSplitNamePlaceholder') })
            .layoutWeight(1)
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .onChange((value: string) => {
              this.appSplitNameInput = value;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 8, top: 4, bottom: 4 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(this.cardSurfaceTone())
      .borderRadius(18)

      if (this.appSplitAddError.length > 0) {
        Text(this.appSplitAddError)
          .fontSize(12)
          .fontColor('#D92D20')
          .width('100%')
          .padding({ left: 4 })
      }

      Button() {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(18)
            .fontColor(['#FFFFFF'])
          Text(this.t('appSplitAdd'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
        }
      }
      .width('100%')
      .height(48)
      .margin({ top: 4 })
      .backgroundColor(this.actionTone())
      .onClick(() => {
        this.addAppSplitEntry();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 20, bottom: 28 })
  }

  @Builder
  private CurrentTabPage() {
    Column() {
      this.TabRoot(this.currentTab)
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
      this.meStack.clear(false);
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
  private NetworkModeControl() {
    Row() {
      Button(this.t('modeVpn'))
        .layoutWeight(1)
        .height(34)
        .fontSize(13)
        .fontWeight(this.proxyModeEnabled ? FontWeight.Normal : FontWeight.Bold)
        .fontColor(this.proxyModeEnabled ? this.secondaryTextColor() : this.selectedChipTextTone())
        .backgroundColor(this.proxyModeEnabled ? Color.Transparent : this.selectedChipSurfaceTone())
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
        .fontColor(this.proxyModeEnabled ? this.selectedChipTextTone() : this.secondaryTextColor())
        .backgroundColor(this.proxyModeEnabled ? this.selectedChipSurfaceTone() : Color.Transparent)
        .borderRadius(9)
        .enabled(!this.status.running && !this.dnsProxyRunning && !this.busy && !this.stopping)
        .onClick(() => {
          this.setNetworkProxyMode(true);
        })
    }
    .width(this.useWideMe() ? 344 : '100%')
    .padding(3)
    .backgroundColor(this.coolNeutralChipSurfaceTone())
    .borderRadius(12)
    .border({ width: 1, color: this.cardBorderTone() })
    .alignSelf(ItemAlign.Center)
  }

  @Builder
  private HomeActions() {
    Flex({ direction: this.useWideMe() ? FlexDirection.Row : FlexDirection.Column,
      justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center, space: { main: LengthMetrics.vp(10) } }) {
      Button(this.stopping
        ? this.tri('Stopping…', '停止中…', '停止中…')
        : (this.busy || this.homeStarting() ? this.t('working')
          : (this.proxyModeEnabled
            ? (this.dnsProxyRunning ? this.t('dnsProxyStop') : this.t('dnsProxyStart'))
            : (this.status.running ? this.t('stopFilter') : this.t('startFilter')))))
        .enabled(!this.busy && !this.stopping && !this.homeStarting())
        .width(this.useWideMe() ? 152 : '100%')
        .height(this.useWideMe() ? 44 : 48)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.busy || this.stopping || this.homeStarting() ? this.chipSurfaceTone() : this.actionTone())
        .fontColor((this.busy || this.stopping || this.homeStarting()) ? this.secondaryTextColor() : '#FFFFFF')
        .borderRadius(16)
        .shadow({ radius: 10, color: paletteAlpha(this.actionTone(), '26') })
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
          .width(this.useWideMe() ? 132 : '100%')
          .height(44)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(this.softPanelTone())
          .fontColor(this.primaryTextColor())
          .borderRadius(14)
          .border({ width: 1, color: this.cardBorderTone() })
          .onClick(() => this.restartActiveFilter())
      }
    }
    .width('100%')
  }

  @Builder
  private DnsRequestsCard() {
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
  }

  @Builder
  private DomainRankingCard() {
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

  @Builder
  private EngineModePicker(height: number) {
    Button(this.engineModeLabel() + ' ▾')
      .enabled(this.canChangeFilterSettings())
      .opacity(this.canChangeFilterSettings() ? 1 : 0.5)
      .height(height)
      .padding({ left: 11, right: 11 })
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.selectedChipTextTone())
      .backgroundColor(this.coolNeutralChipSurfaceTone())
      .borderRadius(8)
      .border({ width: 1, color: this.cardBorderTone() })
      .bindMenu([
        {
          value: this.tri('Lite engine', '轻量引擎', '輕量引擎'),
          action: () => this.setEngineFullMode(false)
        },
        {
          value: this.tri('Full engine', '完整引擎', '完整引擎'),
          action: () => this.setEngineFullMode(true)
        }
      ])
  }

  @Builder
  private HomeTab() {
    Scroll(this.homeScroller) {
      Column({ space: 16 }) {
        // ===== Brand Hero: status at a glance + one primary action =====
        Column({ space: 18 }) {
          Row() {
            // The app name now lives in the immersive title bar.
            Text(this.t('filterStatus'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.secondaryTextColor())
            Blank()
            Row({ space: 10 }) {
              this.EngineModePicker(30)
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

          this.NetworkModeControl()

          Column({ space: 10 }) {
            Stack() {
              Text(this.activeRunning() ? '✓' : '◈')
                .fontSize(40)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
            }
            .width(78)
            .height(78)
            .borderRadius(39)
            .shadow({ radius: 18, color: this.activeRunning() ? '#5910B981' : '#590099CC', offsetX: 0, offsetY: 6 })
            .linearGradient({
              angle: 135,
              colors: this.activeRunning()
                ? (this.isDarkModeActive()
                    ? [['#10997D', 0.0], ['#047D5F', 1.0]]
                    : [['#25BA8C', 0.0], ['#07936B', 1.0]])
                : (this.isDarkModeActive()
                    ? [['#06B6D4', 0.0], ['#0891B2', 1.0]]
                    : [['#00D9FF', 0.0], ['#0099CC', 1.0]])
            })

            Text(this.activeRunning()
              ? this.t('running')
              : (this.homeStarting() ? this.t('startingStatus') : this.t('stopped')))
              .fontSize(23)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.primaryTextColor())
            Text(this.activeRunning()
              ? this.t('runningHint')
              : (this.homeStarting() ? this.homeStartingHint() : this.homeStoppedHint()))
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

          this.HomeActions()

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

        if (this.useSidebarLayout() && this.windowWidthVp >= 880) {
          Row({ space: 12 }) {
            Column() { this.DnsRequestsCard() }.layoutWeight(1)
            Column() { this.DomainRankingCard() }.layoutWeight(1)
          }
          .alignItems(VerticalAlign.Top)
          .width('100%')
        } else {
          this.DnsRequestsCard()
          this.DomainRankingCard()
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: this.contentSideInset(), right: this.contentSideInset(), top: 8,
        bottom: this.contentBottomInset() })
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
    .clip(false)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  @Builder
  private ConfigSegment(online: boolean, title: string) {
    Button(title)
      .layoutWeight(1)
      .height(36)
      .fontColor(this.configOnlineTab === online ? this.selectedChipTextTone() : this.secondaryTextColor())
      .backgroundColor(this.configOnlineTab === online ? this.cardSurfaceTone() : Color.Transparent)
      .borderRadius(9)
      .onClick(() => {
        this.configOnlineTab = online;
        this.showImportMenu = false;
        this.configScroller.scrollEdge(Edge.Top);
      })
  }

  @Builder
  private SubscriptionImportForm() {
    Column({ space: 9 }) {
      if (this.fullModeEnabled) {
        TextInput({ text: this.subAddNameInput,
          placeholder: this.tri('Custom name (optional)', '备注名称（可选）', '備註名稱（可選）') })
          .width('100%')
          .height(42)
          .fontSize(14)
          .maxLength(100)
          .backgroundColor(this.softPanelTone())
          .borderRadius(10)
          .onChange((value: string) => { this.subAddNameInput = value; })
        Row({ space: 8 }) {
          TextInput({ text: this.subAddUrlInput, placeholder: 'https://example.com/list.txt' })
            .layoutWeight(1)
            .height(42)
            .fontSize(14)
            .backgroundColor(this.softPanelTone())
            .borderRadius(10)
            .onChange((value: string) => { this.subAddUrlInput = value; })
          Button(this.tri('Import', '导入', '匯入'))
            .height(42)
            .backgroundColor(this.actionTone())
            .fontColor(Color.White)
            .borderRadius(10)
            .onClick(() => {
              this.addFilterSubscription(this.subAddNameInput, this.subAddUrlInput);
            })
        }
        .width('100%')
        if (this.subFeedbackText.length > 0) {
          Text(this.subFeedbackText).fontSize(12).fontColor(this.selectedChipTextTone()).width('100%')
        }
      } else {
        Text(this.tri('Online subscriptions require the full engine.', '在线订阅需要完整引擎。', '線上訂閱需要完整引擎。'))
          .fontSize(13)
          .fontColor(this.secondaryTextColor())
          .width('100%')
      }
    }
    .width('100%')
  }

  @Builder
  private ConfigAction(label: string, action: () => void) {
    Button(label)
      .height(34)
      .padding({ left: 11, right: 11 })
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.selectedChipTextTone())
      .backgroundColor(this.selectedChipSurfaceTone())
      .borderRadius(9)
      .onClick(action)
  }

  @Builder
  private ConfigSectionTitle(title: string) {
    Text(title)
      .fontSize(16)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.primaryTextColor())
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
  }

  @Builder
  private RuleProfileCard(profile: RuleProfile) {
    Row({ space: 8 }) {
      Row({ space: 8 }) {
        this.MeLinkIcon($r('sys.symbol.doc_text'))
        Column({ space: 3 }) {
          Text(profile.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.ruleProfileCountText(profile))
            .fontSize(12)
            .fontColor(this.secondaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: 44 })
      .onClick(() => this.openRuleEditor(profile.id))

      Toggle({ type: ToggleType.Switch, isOn: profile.enabled })
        .selectedColor(this.actionTone())
        .accessibilityText(profile.name)
        .onChange((value: boolean) => this.toggleRuleProfileEnabled(profile.id, value))

      if (profile.builtIn) {
        Button(this.t('editRule'))
          .width(48)
          .height(44)
          .padding(0)
          .fontSize(12)
          .fontColor(this.accentBlueTone())
          .backgroundColor(Color.Transparent)
          .onClick(() => this.openRuleEditor(profile.id))
      } else {
        Button('···')
          .width(48)
          .height(44)
          .padding(0)
          .fontSize(20)
          .fontColor(this.secondaryTextColor())
          .backgroundColor(Color.Transparent)
          .accessibilityText(this.tri('Rule actions', '规则操作', '規則操作'))
          .bindMenu([
            { value: this.t('editRule'), action: () => this.openRuleEditor(profile.id) },
            { value: this.t('deleteRule'), action: () => this.confirmDeleteRuleProfile(profile.id) }
          ])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 72 })
    .padding(10)
    .backgroundColor(this.cardSurfaceTone())
    .borderRadius(13)
    .border({ width: 1, color: this.cardBorderTone() })
  }

  @Builder
  private RuleProfileGrid(profiles: RuleProfile[]) {
    GridRow(CONFIG_GRID) {
      ForEach(profiles, (profile: RuleProfile) => {
        GridCol() {
          this.RuleProfileCard(profile)
        }
      }, (profile: RuleProfile) => this.ruleProfileRenderKey(profile))
    }
    .width('100%')
  }

  @Builder
  private ConfigRuleSections() {
    if (this.ruleProfiles.some((profile: RuleProfile) => profile.builtIn)) {
      Column({ space: 8 }) {
        this.ConfigSectionTitle(this.tri('Built-in rules', '内置规则', '內建規則'))
        this.RuleProfileGrid(this.ruleProfiles.filter((profile: RuleProfile) => profile.builtIn))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }

    Column({ space: 8 }) {
      this.ConfigSectionTitle(this.tri('Imported rules', '导入的规则', '匯入的規則'))
      if (this.ruleProfiles.some((profile: RuleProfile) => !profile.builtIn)) {
        this.RuleProfileGrid(this.ruleProfiles.filter((profile: RuleProfile) => !profile.builtIn))
      } else {
        Row({ space: 8 }) {
          this.MeLinkIcon($r('sys.symbol.doc_text'))
          Text(this.tri('No imported rules', '还没有导入的规则', '還沒有匯入的規則'))
            .fontSize(13)
            .fontColor(this.secondaryTextColor())
            .layoutWeight(1)
          this.ConfigAction(this.t('importFile'), () => {
            this.importRulesFile().catch((err: BusinessError) => {
              this.errorText = this.errorMessage(err);
            });
          })
        }
        .width('100%')
        .constraintSize({ maxWidth: 430 })
        .padding(10)
        .backgroundColor(this.cardSurfaceTone())
        .borderRadius(13)
        .border({ width: 1, color: this.cardBorderTone() })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ConfigOnlineSections() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Column() {
          this.ConfigSectionTitle(this.tri('My subscriptions', '我的订阅', '我的訂閱'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.filterSubscriptions.length > 0) {
          this.ConfigAction(this.tri('Refresh', '刷新', '重新整理'), () => { void this.refreshAllSubscriptions(false); })
          this.ConfigAction(this.tri('Check', '检测', '檢測'), () => { void this.refreshAllSubscriptions(true); })
        }
      }
      .width('100%')
      if (this.filterSubscriptions.length === 0) {
        Row({ space: 8 }) {
          this.MeLinkIcon($r('sys.symbol.link'))
          Text(this.tri('No subscriptions yet', '还没有在线订阅', '還沒有線上訂閱'))
            .fontSize(13)
            .fontColor(this.secondaryTextColor())
            .layoutWeight(1)
          this.ConfigAction(this.tri('Add', '添加', '新增'), () => {
            this.showImportMenu = true;
            this.configScroller.scrollEdge(Edge.Top);
          })
        }
        .width('100%')
        .constraintSize({ maxWidth: 430 })
        .padding(10)
        .backgroundColor(this.cardSurfaceTone())
        .borderRadius(13)
        .border({ width: 1, color: this.cardBorderTone() })
      } else {
        GridRow(CONFIG_GRID) {
          ForEach(this.mySubscriptionsToShow(), (s: FilterSubscription) => {
            GridCol() {
              this.MySubscriptionRow(s)
            }
          }, (s: FilterSubscription) => JSON.stringify(s))
        }
        .width('100%')
        if (this.filterSubscriptions.length > 4) {
          this.ConfigAction(this.showAllMySubscriptions ? this.tri('Show fewer', '收起', '收起')
            : this.tri('Show all', '查看全部', '查看全部'), () => {
            this.showAllMySubscriptions = !this.showAllMySubscriptions;
          })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ConfigTab() {
    Scroll(this.configScroller) {
      Column({ space: 16 }) {
        Row({ space: 4 }) {
          this.ConfigSegment(false, this.tri('Custom rules', '自定义规则', '自訂規則'))
          this.ConfigSegment(true, this.tri('Online subscriptions', '在线订阅', '線上訂閱'))
        }
        .width('100%')
        .constraintSize({ maxWidth: 380 })
        .padding(4)
        .backgroundColor(this.softPanelTone())
        .borderRadius(13)
        .border({ width: 1, color: this.cardBorderTone() })

        if (this.configFeedbackText.length > 0) {
          Text(this.configFeedbackText)
            .fontSize(12)
            .fontColor(this.accentBlueTone())
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .padding({ left: 4, right: 4 })
        }

        if (this.showImportMenu) {
          Column({ space: 10 }) {
            Row() {
              Text(this.configOnlineTab ? this.tri('Add subscription', '添加订阅', '新增訂閱')
                : this.tri('Quick import', '快速导入', '快速匯入'))
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

            if (this.configOnlineTab) {
              this.SubscriptionImportForm()
            } else {
              Row({ space: 8 }) {
                Text(this.tri('Import from file', '从文件导入', '從檔案匯入'))
                  .fontSize(14)
                  .fontColor(this.primaryTextColor())
                  .layoutWeight(1)
                Button(this.tri('Choose', '选择', '選擇'), { type: ButtonType.Normal })
                  .width(84)
                  .height(42)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .backgroundColor(this.softBlueTone())
                  .fontColor(this.primaryTextColor())
                  .borderRadius(12)
                  .onClick(() => {
                    this.showImportMenu = false;
                    this.importRulesFile().catch((err: BusinessError) => {
                      this.errorText = this.errorMessage(err);
                    });
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Row({ space: 8 }) {
                Text(this.tri('Import from clipboard', '从剪贴板导入', '從剪貼簿匯入'))
                  .fontSize(14)
                  .fontColor(this.primaryTextColor())
                  .layoutWeight(1)
                PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
                  .width(84)
                  .height(42)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .backgroundColor(this.softBlueTone())
                  .fontColor(this.primaryTextColor())
                  .borderRadius(12)
                  .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
                    if (result === PasteButtonOnClickResult.SUCCESS) {
                      void this.importRulesFromClipboard();
                    }
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
          }
          .width('100%')
          .constraintSize({ maxWidth: 600 })
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .backgroundColor(this.cardSurfaceTone())
          .borderRadius(14)
          .border({ width: 1, color: this.cardBorderTone() })
        }

        if (this.configOnlineTab) {
          this.ConfigOnlineSections()
        } else {
          this.ConfigRuleSections()
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: this.contentSideInset(), right: this.contentSideInset(), top: 8,
        bottom: this.contentBottomInset() })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  private mePageTitle(name: string): string {
    switch (name) {
      case ME_PAGE_PROTECTION: return this.tri('Protection settings', '防护设置', '防護設定');
      case ME_PAGE_PREFERENCES: return this.tri('Appearance', '外观', '外觀');
      case ME_PAGE_BACKGROUND: return this.tri('Background & notifications', '后台与通知', '背景與通知');
      case ME_PAGE_DIAGNOSTICS: return this.tri('Logs & diagnostics', '日志与诊断', '日誌與診斷');
      case ME_PAGE_SYNC: return this.tri('Sync & backup', '同步与备份', '同步與備份');
      case ME_PAGE_ABOUT: return this.tri('About Home Cloud Shield', '关于栖云盾', '關於棲雲盾');
      case ME_PAGE_NETWORK: return this.tri('Network routing', '网络接管', '網路接管');
      case ME_PAGE_DNS: return this.tri('DNS resolution', 'DNS 解析', 'DNS 解析');
      case ME_PAGE_WEB: return this.tri('Management dashboard', '管理面板', '管理面板');
      default: return this.t('settingsTitle');
    }
  }

  @Builder
  private MeLink(p: MeLinkParam) {
    if (p.tile) {
      Column({ space: 6 }) {
        Row() {
          this.MeLinkIcon(p.icon)
          Blank()
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([this.secondaryTextColor()])
        }
        .width('100%')
        this.MeLinkLabel(p)
      }
      .layoutWeight(1)
      .padding(12)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(this.cardSurfaceTone())
      .borderRadius(16)
      .border({ width: 1, color: this.cardBorderTone() })
      .onClick(() => this.openMeLink(p))
    } else {
      Row({ space: 10 }) {
        this.MeLinkIcon(p.icon)
        Column() {
          this.MeLinkLabel(p)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([this.secondaryTextColor()])
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => this.openMeLink(p))
    }
  }

  private openMeLink(p: MeLinkParam): void {
    this.meStack.pushPathByName(p.name, null);
  }

  @Builder
  private MeLinkIcon(icon: Resource) {
    Stack() {
      SymbolGlyph(icon).fontSize(17).fontColor([this.selectedChipTextTone()])
    }
    .width(32)
    .height(32)
    .backgroundColor(this.selectedChipSurfaceTone())
    .borderRadius(9)
  }

  @Builder
  private MeLinkLabel(p: MeLinkParam) {
    Column({ space: 3 }) {
      Text(this.mePageTitle(p.name))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(p.description)
        .fontSize(11)
        .fontColor(this.secondaryTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
  }

  private meThemeLabel(): string {
    const palette = shieldPalette(this.paletteId);
    return this.tri(palette.en, palette.zh, palette.hant);
  }

  @Builder
  private MeTop() {
    Column({ space: 10 }) {
      Row({ space: 11 }) {
        Image($r('app.media.foreground'))
          .width(44)
          .height(44)
          .objectFit(ImageFit.Contain)
          .backgroundColor(Color.White)
          .borderRadius(12)
        Column({ space: 3 }) {
          Text(this.t('appTitle')).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.primaryTextColor())
          Text(this.useWideMe()
            ? this.tri('On-device DNS protection', '本地 DNS 防护', '本機 DNS 防護')
            : this.tri('Version ', '版本 ', '版本 ') + this.appVersionName)
            .fontSize(12).fontColor(this.secondaryTextColor())
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (!this.useWideMe()) {
          Text(this.tri('About ›', '关于 ›', '關於 ›'))
            .fontSize(12).fontColor(this.selectedChipTextTone())
            .padding({ left: 9, right: 9, top: 6, bottom: 6 })
            .borderRadius(8)
            .backgroundColor(this.selectedChipSurfaceTone())
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor(this.elevatedSurfaceTone())
      .border({ width: 1, color: this.cardBorderTone() })
      .borderRadius(16)
      .onClick(() => {
        if (!this.useWideMe()) {
          this.meStack.pushPathByName(ME_PAGE_ABOUT, null);
        }
      })

      Row({ space: 10 }) {
        this.MeLink({ name: ME_PAGE_PROTECTION, icon: $r('sys.symbol.gearshape'), tile: true,
          description: (this.proxyModeEnabled ? this.t('modeDnsProxy') : this.t('modeVpn')) + ' · ' + this.engineModeLabel() })
        this.MeLink({ name: ME_PAGE_PREFERENCES, icon: $r('sys.symbol.sun_max'), tile: true,
          description: this.meThemeLabel() })
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  private MeLanguagePicker() {
    Row({ space: 10 }) {
      this.MeLinkIcon($r('sys.symbol.translation'))
      Text(this.tri('Language', '语言', '語言'))
        .layoutWeight(1)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
      Button(this.t(this.language === 'en' ? 'langEn' :
        (this.language === 'zhHant' ? 'langZhHant' : 'langZhHans')) + ' ▾')
        .constraintSize({ minWidth: 86 })
        .height(36)
        .padding({ left: 11, right: 11 })
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.selectedChipTextTone())
        .backgroundColor(this.coolNeutralChipSurfaceTone())
        .borderRadius(8)
        .border({ width: 1, color: this.cardBorderTone() })
        .bindMenu([
          { value: this.t('langZhHans'), action: () => this.setLanguage('zhHans') },
          { value: this.t('langEn'), action: () => this.setLanguage('en') },
          { value: this.t('langZhHant'), action: () => this.setLanguage('zhHant') }
        ])
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private MeManagement() {
    Column() {
      this.MeLanguagePicker()
      Divider().color(this.cardBorderTone())
      this.MeLink({ name: ME_PAGE_BACKGROUND, icon: $r('sys.symbol.bell'),
        description: this.tri('Auto-start, keep-alive and notifications', '自动启动、保活与通知频率', '自動啟動、背景保活與通知頻率') })
      Divider().color(this.cardBorderTone())
      this.MeLink({ name: ME_PAGE_DIAGNOSTICS, icon: $r('sys.symbol.doc_text'),
        description: this.logRetentionDays + this.tri(' days', ' 天', ' 天') + ' · ' + this.logMaxSizeMb + ' MB' })
      Divider().color(this.cardBorderTone())
      this.MeLink({ name: ME_PAGE_SYNC, icon: $r('sys.symbol.arrow_clockwise'),
        description: this.tri('Device sync, JSON import and export', '设备同步、JSON 导入与导出', '裝置同步、JSON 匯入與匯出') })
    }
    .width('100%')
    .backgroundColor(this.cardSurfaceTone())
    .borderRadius(16)
    .border({ width: 1, color: this.cardBorderTone() })
  }

  private useMeColumns(): boolean {
    return this.useWideMe() && this.windowWidthVp - (this.useSidebarLayout() ? 170 : 0) >= 700;
  }

  @Builder
  private MeTab() {
    Scroll(this.meScroller) {
      Column({ space: 12 }) {
        if (this.useMeColumns()) {
          Row({ space: 14 }) {
            Column() { this.MeTop() }.layoutWeight(1)
            Column() { this.MeManagement() }.layoutWeight(1)
          }
          .alignItems(VerticalAlign.Top)
          .width('100%')
        } else {
          this.MeTop()
          this.MeManagement()
        }
        if (this.useWideMe()) {
          this.MeAbout()
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Start)
      .padding({ left: this.contentSideInset(), right: this.contentSideInset(), top: 8,
        bottom: this.contentBottomInset() })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  @Builder
  private MeAboutItem(title: string, detail: string, action: string = '') {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.primaryTextColor())
        Text(detail).fontSize(12).fontColor(this.secondaryTextColor()).maxLines(2)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (action.length > 0) {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(13).fontColor([this.secondaryTextColor()])
      }
    }
    .alignSelf(ItemAlign.Stretch)
    .layoutWeight(this.useMeColumns() ? 1 : 0)
    .padding(10)
    .constraintSize({ minHeight: 54 })
    .backgroundColor(this.softPanelTone())
    .borderRadius(12)
    .onClick(() => {
      if (action === 'license') {
        this.openLicensePage();
      } else if (action === 'disclaimer') {
        this.showDisclaimerSheet = true;
      }
    })
  }

  @Builder
  private MeAbout() {
    Column({ space: 10 }) {
      if (this.useWideMe()) {
        this.SettingsGroupTitle({ text: this.mePageTitle(ME_PAGE_ABOUT) })
      }
      Flex({ direction: this.useMeColumns() ? FlexDirection.Row : FlexDirection.Column, space: { main: LengthMetrics.vp(8) } }) {
        this.MeAboutItem(this.tri('Version', '应用版本', '應用版本'), this.appVersionName)
        this.MeAboutItem(this.t('openSource'), 'GPL-3.0-only', 'license')
        this.MeAboutItem(this.tri('Disclaimer', '免责声明', '免責聲明'),
          this.tri('DNS requests are processed on this device.', 'DNS 请求在本机处理', 'DNS 請求在本機處理'), 'disclaimer')
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.cardSurfaceTone())
    .borderRadius(16)
    .border({ width: 1, color: this.cardBorderTone() })
    .bindSheet(this.showDisclaimerSheet, this.DisclaimerSheet(), {
      height: '60%', backgroundColor: this.sheetSurfaceTone(), showClose: false,
      onDisappear: () => { this.showDisclaimerSheet = false; }
    })
  }

  @Builder
  private ConfigSyncSettings() {
    Column({ space: 8 }) {
      this.SettingsGroupTitle({ text: this.tri('Cross-device sync', '跨设备同步', '跨裝置同步') })
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          this.SettingsIconText({
            glyph: '⇄', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
            title: this.tri('Enable cross-device sync', '开启跨设备同步', '開啟跨裝置同步'),
            desc: this.tri('Enable on both devices using the same HUAWEI ID to continue the app or sync settings.',
              '同一华为帐号下的两台设备都开启后，可接续应用或手动同步配置。',
              '同一華為帳號下的兩台裝置都開啟後，可接續應用程式或手動同步設定。')
          })
          Toggle({ type: ToggleType.Switch, isOn: this.configSyncEnabled })
            .enabled(!this.configSyncBusy)
            .onChange((value: boolean) => {
              if (value !== this.configSyncEnabled) {
                void this.updateConfigSync(value, true);
              }
            })
        }
        .width('100%')
        if (this.configSyncEnabled) {
          Divider().strokeWidth(1).color(this.cardBorderTone())
          Button(this.tri('Sync settings manually', '手动同步配置', '手動同步設定'))
            .width('100%')
            .fontColor(this.primaryTextColor())
            .backgroundColor(this.softPanelTone())
            .enabled(!this.configSyncBusy)
            .onClick(() => this.openConfigSyncDevices())
          if (this.configSyncDevices.length > 0) {
            Text(this.tri('Choose a device', '选择目标设备', '選擇目標裝置'))
              .fontSize(13)
              .fontColor(this.secondaryTextColor())
            ForEach(this.configSyncDevices, (device: ConfigSyncDevice) => {
              Button(device.name || this.tri('Nearby device', '附近设备', '附近裝置'))
                .width('100%')
                .fontColor(this.primaryTextColor())
                .backgroundColor(this.softPanelTone())
                .onClick(() => { void this.sendConfigSync(device); })
            }, (device: ConfigSyncDevice) => device.id)
            Button(this.tri('Cancel', '取消', '取消'), { type: ButtonType.Normal })
              .fontColor(this.secondaryTextColor())
              .backgroundColor(Color.Transparent)
              .onClick(() => { this.configSyncDevices = []; })
          }
        }
        if (this.configSyncStatus.length > 0) {
          Text(this.configSyncStatus)
            .fontSize(13)
            .fontColor(this.secondaryTextColor())
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(16)
      .backgroundColor(this.elevatedSurfaceTone())
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
      .borderRadius(22)
      .border({ width: 1, color: this.cardBorderTone() })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private SettingsSubPage(name: string) {
    Scroll(this.meSectionScroller(name)) {
      Column({ space: 14 }) {
        if (name === ME_PAGE_PROTECTION) {
          this.ProtectionSettings()
        } else if (name === ME_PAGE_PREFERENCES) {
          this.AppearanceSettings()
        } else if (name === ME_PAGE_BACKGROUND) {
          this.BackgroundSettings()
        } else if (name === ME_PAGE_DIAGNOSTICS) {
          this.DiagnosticsSettings()
        } else if (name === ME_PAGE_SYNC) {
          this.ConfigSyncSettings()
          this.BackupSettings()
        } else if (name === ME_PAGE_ABOUT) {
          this.MeAbout()
        } else if (name === ME_PAGE_NETWORK) {
          this.NetworkSettings()
        } else if (name === ME_PAGE_DNS) {
          this.DnsSettings()
        } else if (name === ME_PAGE_WEB) {
          this.WebSettings()
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: this.contentSideInset(), right: this.contentSideInset(), top: 8,
        bottom: Math.max(16, this.avoidPaddingBottom) })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .clip(false)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  @Builder
  private ProtectionSettings() {
    Column() {
      this.MeLink({ name: ME_PAGE_NETWORK, icon: $r('sys.symbol.link'),
        description: this.tri('VPN, per-app routing and DNS proxy', 'VPN、分应用与代理端口', 'VPN、分應用與代理連接埠') })
      Divider().color(this.cardBorderTone())
      this.MeLink({ name: ME_PAGE_DNS, icon: $r('sys.symbol.link'),
        description: this.tri('Upstream DNS, cache and rewrites', '上游、缓存与 DNS 重写', '上游、快取與 DNS 重寫') })
      Divider().color(this.cardBorderTone())
      Row({ space: 10 }) {
        this.MeLinkIcon($r('sys.symbol.gearshape'))
        Text(this.tri('Filtering engine', '过滤引擎', '過濾引擎'))
          .layoutWeight(1)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
        this.EngineModePicker(36)
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      Divider().color(this.cardBorderTone())
      this.MeLink({ name: ME_PAGE_WEB, icon: $r('sys.symbol.doc_text'),
        description: this.tri('Web service, port and dashboard', 'Web 服务、端口与面板入口', 'Web 服務、連接埠與面板入口') })
    }
    .width('100%')
    .backgroundColor(this.cardSurfaceTone())
    .borderRadius(16)
    .border({ width: 1, color: this.cardBorderTone() })
  }

  @Builder
  private PalettePreview(palette: ShieldPalette) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 8 }) {
        Stack({ alignContent: Alignment.BottomStart }) {
          Column()
            .width('100%')
            .height(58)
            .linearGradient({ angle: 135, colors: [[palette.swatches[0], 0], [palette.swatches[1], 1]] })
          Row({ space: 6 }) {
            Blank()
              .width(48)
              .height(16)
              .backgroundColor(this.isDarkModeActive() ? palette.dark.card : palette.light.card)
              .borderRadius(5)
            Blank()
              .width(22)
              .height(16)
              .backgroundColor(palette.light.action)
              .borderRadius(5)
          }
          .margin({ left: 9, bottom: 9 })
        }
        .width('100%')
        .height(58)
        .borderRadius(9)
        .clip(true)

        Row({ space: 5 }) {
          Text(this.tri(palette.en, palette.zh, palette.hant))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.paletteId === palette.id) {
            Text('✓')
              .width(18)
              .height(18)
              .textAlign(TextAlign.Center)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .backgroundColor(this.actionTone())
              .borderRadius(9)
          }
        }
        .width('100%')
        .constraintSize({ minHeight: 22 })
      }
      .width('100%')
      .padding(8)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(0)
    .backgroundColor(this.paletteId === palette.id ? this.selectedChipSurfaceTone() : this.cardSurfaceTone())
    .borderRadius(13)
    .border({ width: 1, radius: 13, color: this.paletteId === palette.id ? this.accentBlueTone() : this.cardBorderTone() })
    .clip(true)
    .accessibilitySelected(this.paletteId === palette.id)
    .onClick(() => this.setPalette(palette.id))
  }

  @Builder
  private AppearanceSettings() {
    Column({ space: 9 }) {
      this.SettingsGroupTitle({ text: this.tri('Display mode', '显示模式', '顯示模式') })
      Row({ space: 5 }) {
        this.ThemeSegButton({ label: this.t('themeAuto'), mode: ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET })
        this.ThemeSegButton({ label: this.t('themeLight'), mode: ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT })
        this.ThemeSegButton({ label: this.t('themeDark'), mode: ConfigurationConstant.ColorMode.COLOR_MODE_DARK })
      }
      .width('100%')
      .padding(5)
      .backgroundColor(this.softPanelTone())
      .borderRadius(13)
      .border({ width: 1, color: this.cardBorderTone() })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)

    Column({ space: 9 }) {
      this.SettingsGroupTitle({ text: this.tri('Color themes', '主题配色', '主題配色') })
      GridRow({
        columns: { xs: 2, sm: 3 },
        gutter: 8,
        breakpoints: { value: ['490vp'], reference: BreakpointsReference.ComponentSize }
      }) {
        ForEach(SHIELD_PALETTES, (palette: ShieldPalette) => {
          GridCol() {
            this.PalettePreview(palette)
          }
        }, (palette: ShieldPalette) => palette.id)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private BackgroundSettings() {
    Column() {
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
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.cardSurfaceTone())
    .borderRadius(16)
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

        Divider().strokeWidth(1).color(this.cardBorderTone())

        Row({ space: 12 }) {
          this.SettingsIconText({ glyph: '⇅', iconBg: this.isDarkModeActive() ? '#1E2E4A' : '#E8F1FE', iconFg: '#2F6FDB',
            title: this.t('dataTransferKeepAlive'), desc: this.t('dataTransferKeepAliveHint') })
          Toggle({ type: ToggleType.Switch, isOn: this.dataTransferKeepAliveEnabled })
            .onChange((value: boolean) => {
              this.onDataTransferKeepAliveChange(value).catch((err: BusinessError) => {
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
    Column({ space: 8 }) {
      this.SettingsGroupTitle({ text: this.t('notificationGroup') })
      Column() {
        Row({ space: 12 }) {
          this.SettingsIconText({ glyph: '🔔', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
            title: this.t('persistentNotification'), desc: this.t('persistentNotificationHint') })
          Toggle({ type: ToggleType.Switch, isOn: this.persistentNotificationEnabled })
            .onChange((value: boolean) => {
              this.onPersistentNotificationChange(value).catch((err: BusinessError) => {
                this.errorText = this.errorMessage(err);
              });
            })
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)

        if (this.persistentNotificationEnabled) {
          Divider().strokeWidth(1).color(this.cardBorderTone())

          Row({ space: 12 }) {
            Column({ space: 2 }) {
              Text(this.t('notificationRefreshInterval'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.primaryTextColor())
              Text(this.t('notificationRefreshIntervalHint'))
                .fontSize(12)
                .lineHeight(17)
                .fontColor(this.secondaryTextColor())
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: 10, bottom: 6 })
          .alignItems(VerticalAlign.Center)

          Row({ space: 5 }) {
            this.NotifyIntervalSegButton(1)
            this.NotifyIntervalSegButton(2)
            this.NotifyIntervalSegButton(3)
            this.NotifyIntervalSegButton(4)
            this.NotifyIntervalSegButton(5)
          }
          .width('100%')
          .padding(5)
          .margin({ bottom: 6 })
          .backgroundColor(this.softPanelTone())
          .borderRadius(14)
          .border({ width: 1, color: this.cardBorderTone() })
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
  }

  @Builder
  private DiagnosticsSettings() {
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
              .type(InputType.Number)
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
                this.logRetentionDaysInput = value;
              })
              .onBlur(() => this.updateLogRetentionDays(this.logRetentionDaysInput))
              .onSubmit(() => this.updateLogRetentionDays(this.logRetentionDaysInput))
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
              .type(InputType.Number)
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
                this.logMaxSizeMbInput = value;
              })
              .onBlur(() => this.updateLogMaxSizeMb(this.logMaxSizeMbInput))
              .onSubmit(() => this.updateLogMaxSizeMb(this.logMaxSizeMbInput))
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
        this.refreshDebugLog();
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

  @Builder
  private BackupSettings() {
    Column({ space: 8 }) {
      this.SettingsGroupTitle({ text: this.t('configBackupGroup') })
      Column() {
        Row({ space: 12 }) {
          this.SettingsIconText({ glyph: '⬇', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
            title: this.t('importConfig'), desc: this.t('importConfigHint') })
          Text('›')
            .fontSize(20)
            .fontColor(this.secondaryTextColor())
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.importConfigFile().catch((err: BusinessError) => {
            this.errorText = this.errorMessage(err);
          });
        })

        Divider().strokeWidth(1).color(this.cardBorderTone())

        Row({ space: 12 }) {
          this.SettingsIconText({ glyph: '⬆', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
            title: this.t('exportConfig'), desc: this.t('exportConfigHint') })
          Text('›')
            .fontSize(20)
            .fontColor(this.secondaryTextColor())
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.exportConfigFile().catch((err: BusinessError) => {
            this.errorText = this.errorMessage(err);
          });
        })
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
  }

  @Builder
  private NetworkSettings() {
    this.NetworkModeControl()
    Column() {
      Row({ space: 12 }) {
        this.SettingsIconText({ glyph: '⊞', iconBg: this.isDarkModeActive() ? '#163238' : '#E3F6F9', iconFg: '#0891B2',
          title: this.t('appSplitTitle'), desc: this.appSplitSummary() })
        Text('›')
          .fontSize(20)
          .fontColor(this.secondaryTextColor())
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.meStack.pushPathByName(ME_PAGE_APP_SPLIT, null);
      })
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.cardSurfaceTone())
    .borderRadius(16)
    if (this.proxyModeEnabled) {
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
    }
    Column({ space: 8 }) {
      this.SettingsGroupTitle({ text: 'VPN' })
      Column({ space: 12 }) {
        Row({ space: 12 }) {
          this.SettingsIconText({
            glyph: '⇄', iconBg: this.softPanelTone(), iconFg: this.accentBlueTone(),
            title: this.tri('Full VPN (experimental)', '全量 VPN（实验）', '全量 VPN（實驗）'),
            desc: this.appTunnelAvailable ?
              this.tri('Works with both DNS engines. Routes TCP and UDP in selected-app mode.',
                '轻量和完整模式均可使用。在「仅代理」模式下接管所选应用的 TCP 和 UDP。',
                '輕量與完整模式均可使用。在「僅代理」模式下接管所選應用程式的 TCP 和 UDP。') :
              this.tri('The tunnel core is unavailable in this build.', '当前安装包缺少全量 VPN 内核。',
                '目前的安裝套件缺少全量 VPN 核心。')
          })
          Toggle({ type: ToggleType.Switch, isOn: this.appTunnelEnabled && this.appTunnelAvailable })
            .enabled(this.appTunnelAvailable && !this.proxyModeEnabled)
            .onChange((enabled: boolean) => this.saveAppTunnel(enabled, false))
        }
        .width('100%')
        Divider().strokeWidth(1).color(this.cardBorderTone())
        Row({ space: 12 }) {
          this.SettingsIconText({
            glyph: '⊘', iconBg: this.softPanelTone(), iconFg: this.accentBlueTone(),
            title: this.tri('Block IPv6 connections', '阻断 IPv6 连接', '阻擋 IPv6 連線'),
            desc: this.tri('VPN only. Blocks IPv6 traffic from apps routed through this VPN.',
              '仅在 VPN 模式生效，阻断经过本 VPN 的应用发出的 IPv6 流量。',
              '僅在 VPN 模式生效，阻擋經過本 VPN 的應用程式送出的 IPv6 流量。')
          })
          Toggle({ type: ToggleType.Switch, isOn: this.blockIpv6Connections })
            .enabled(this.canChangeFilterSettings() && !this.proxyModeEnabled)
            .onChange((value: boolean) => this.updateIpv6Blocking(this.blockAaaa, value))
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(16)
      .backgroundColor(this.elevatedSurfaceTone())
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
      .borderRadius(22)
      .border({ width: 1, color: this.cardBorderTone() })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private DnsSettings() {
    Column({ space: 8 }) {
      this.SettingsGroupTitle({ text: this.tri('Upstream DNS', '上游 DNS', '上游 DNS') })
      Column({ space: 10 }) {
        // Auto upstream: follow the system/router DNS (VPN mode). The manual
        // list below stays editable and is used as the fallback.
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text(this.t('upstreamAutoTitle'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.primaryTextColor())
            Text(this.t('upstreamAutoHint'))
              .fontSize(12)
              .lineHeight(17)
              .fontColor(this.secondaryTextColor())
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .opacity(this.upstreamAutoAvailable() ? 1 : 0.4)
          Toggle({ type: ToggleType.Switch, isOn: this.upstreamAutoEnabled && this.upstreamAutoAvailable() })
            .enabled(this.upstreamAutoAvailable())
            .opacity(this.upstreamAutoAvailable() ? 1 : 0.4)
            .onChange((value: boolean) => {
              this.onUpstreamAutoChange(value);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // Proxy mode can't follow the system DNS — explain why it's greyed out.
        if (!this.upstreamAutoAvailable()) {
          Text(this.tri('Unavailable in DNS-proxy mode — the manual upstream below is used.',
            '纯 DNS 代理模式下不可用，将使用下方手动填写的上游。',
            '純 DNS 代理模式下不可用，將使用下方手動填寫的上游。'))
            .fontSize(12)
            .lineHeight(17)
            .fontColor(this.mutedTextColor())
            .width('100%')
        } else if (this.upstreamAutoEnabled) {
          Text(this.effectiveUpstreamDisplay().length > 0
            ? this.t('upstreamAutoCurrent', this.effectiveUpstreamDisplay())
            : this.t('upstreamAutoWaiting'))
            .fontSize(12)
            .lineHeight(17)
            .fontColor(this.accentBlueTone())
            .width('100%')
          Divider().strokeWidth(1).color(this.cardBorderTone())
        }

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

        // Encrypted upstreams (DoH/DoT) — only the full AdGuardHome engine can
        // resolve these, so the row is greyed out and disabled on lite mode.
        Text(this.t('upstreamDnsEncryptedLabel'))
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
          .opacity(this.fullModeEnabled ? 1 : 0.4)
          .width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.upstreamEncryptedPresets(), (preset: UpstreamPreset) => {
            Button(preset.label)
              .type(ButtonType.Normal)
              .fontSize(13)
              .fontColor(this.primaryTextColor())
              .backgroundColor(this.softPanelTone())
              .borderRadius(10)
              .border({ width: 1, color: this.cardBorderTone() })
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .margin({ right: 8, bottom: 8 })
              .enabled(this.fullModeEnabled)
              .opacity(this.fullModeEnabled ? 1 : 0.4)
              .onClick(() => {
                this.addUpstreamPreset(preset.value);
              })
          }, (preset: UpstreamPreset) => preset.value)
        }
        .width('100%')

        if (this.upstreamInputHasUnsupportedForLite()) {
          Text(this.t('upstreamDnsLiteOnlyIp'))
            .fontSize(12)
            .lineHeight(18)
            .fontColor(this.isDarkModeActive() ? '#F5A524' : '#B54708')
            .width('100%')
        }

        Button(this.t('upstreamDnsApply'))
          .type(ButtonType.Normal)
          .width('100%')
          .height(42)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor(this.actionTone())
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
    Column({ space: 8 }) {
      this.SettingsGroupTitle({ text: this.tri('Resolution options', '解析选项', '解析選項') })
      Column() {
        Row({ space: 12 }) {
          this.SettingsIconText({
            glyph: $r('sys.symbol.clock'),
            title: this.language === 'en' ? this.t('dnsCacheTtlLabel') + ' (s)' : this.t('dnsCacheTtlLabel') + '（秒）',
            desc: this.t('dnsCacheHint')
          })
          TextInput({ text: this.dnsCacheTtlInput, placeholder: `${DEFAULT_DNS_CACHE_TTL_SECONDS}` })
            .width(88)
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

        Divider().strokeWidth(1).color(this.cardBorderTone())

        Row({ space: 12 }) {
          this.SettingsIconText({
            glyph: $r('sys.symbol.lock_shield'),
            title: this.tri('Block IPv6 DNS lookups', '屏蔽 IPv6 解析', '封鎖 IPv6 解析'),
            desc: this.tri('Empty answers for AAAA. IPv4 works normally.',
              'AAAA 返回空结果，IPv4 解析照常。', 'AAAA 傳回空結果，IPv4 解析照常。')
          })
          Toggle({ type: ToggleType.Switch, isOn: this.blockAaaa })
            .enabled(this.canChangeFilterSettings())
            .onChange((value: boolean) => this.updateIpv6Blocking(value, this.blockIpv6Connections))
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)

        Divider().strokeWidth(1).color(this.cardBorderTone())
        Row({ space: 12 }) {
          this.SettingsIconText({
            glyph: $r('sys.symbol.square_and_pencil'),
            dimmed: !this.fullModeEnabled,
            title: this.tri('DNS rewrites', 'DNS 重写', 'DNS 重寫'),
            desc: this.tri(`${this.dnsRewrites.length} rewrites`,
              `共 ${this.dnsRewrites.length} 条`, `共 ${this.dnsRewrites.length} 條`) })
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor([this.fullModeEnabled ? this.secondaryTextColor() : this.mutedTextColor()])
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)
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
          this.SettingsIconText({
            glyph: $r('sys.symbol.gearshape'),
            dimmed: !this.fullModeEnabled,
            title: this.tri('Advanced DNS', 'DNS 高级设置', 'DNS 進階設定'),
            desc: `${this.blockingModeLabel(this.advancedDns.blockingMode)} · ${this.upstreamModeLabel(this.advancedDns.upstreamMode)}` })
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor([this.fullModeEnabled ? this.secondaryTextColor() : this.mutedTextColor()])
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .alignItems(VerticalAlign.Center)
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
      }
      .width('100%')
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.cardSurfaceTone())
      .borderRadius(16)
      .border({ width: 1, color: this.cardBorderTone() })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private WebSettings() {
    Column() {
      Row({ space: 12 }) {
        this.SettingsIconText({ glyph: '🌐', iconBg: this.isDarkModeActive() ? '#22324A' : '#EEF3FA', iconFg: '#2B5B95',
          title: this.tri('Web dashboard service', 'Web 管理面板服务', 'Web 管理面板服務'),
          desc: this.tri('Off saves battery · toggling restarts the filter',
            '默认关闭更省电 · 切换后自动重启过滤', '預設關閉更省電 · 切換後自動重啟過濾') })
        Toggle({ type: ToggleType.Switch, isOn: this.aghWebEnabled })
          .enabled(this.fullModeEnabled)
          .onChange((value: boolean) => {
            this.updateAghWebEnabled(value);
          })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
      .opacity(this.fullModeEnabled ? 1 : 0.4)

      Divider().strokeWidth(1).color(this.cardBorderTone())

      // AdGuardHome dashboard — full engine + dashboard service + running.
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
      // Enabled whenever the full engine is running with the dashboard
      // service on, in either VPN or DNS-proxy mode.
      .opacity(this.fullModeEnabled && this.aghWebEnabled && this.activeRunning() ? 1 : 0.4)
      .onClick(() => {
        if (!this.fullModeEnabled) {
          this.notifyFullEngineRequired();
          return;
        }
        if (!this.aghWebEnabled) {
          try {
            this.ensurePromptAction()?.showToast({
              message: this.tri('Turn on the web dashboard service first',
                '请先开启 Web 管理面板服务', '請先開啟 Web 管理面板服務')
            });
          } catch (_) {
          }
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
    }
    .width('100%')
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.cardSurfaceTone())
    .borderRadius(16)
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
  }

﻿
  private ruleEditorMenu(): MenuElement[] {
    const actions: MenuElement[] = [{
      value: this.t('exportRules'),
      action: () => {
        this.exportRuleEditorContent().catch((err: BusinessError) => {
          this.errorText = this.errorMessage(err);
          this.promptAction?.showToast({ message: this.t('exportRulesFailed') });
        });
      }
    }];
    if (this.editingRuleProfileId === CUSTOM_BLOCK_RULE_PROFILE_ID && this.rulesText.trim().length > 0) {
      actions.push({ value: this.t('removeAllRuleLines'), action: () => this.confirmRemoveAllCustomBlockRules() });
    }
    return actions;
  }

  @Builder
  private RuleEditorHeader() {
    Row({ space: 10 }) {
      if (this.ruleComposerOpen) {
        Button(this.t('back'), { type: ButtonType.Normal })
          .height(40)
          .padding({ left: 12, right: 12 })
          .borderRadius(12)
          .backgroundColor(this.softPanelTone())
          .fontSize(14)
          .fontColor(this.primaryTextColor())
          .onClick(() => this.closeRuleComposer())
      } else {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(19)
          .fontColor([this.selectedChipTextTone()])
          .width(42)
          .height(42)
          .borderRadius(13)
          .backgroundColor(this.selectedChipSurfaceTone())
      }
      Column({ space: 3 }) {
        Text(this.ruleComposerOpen ? this.editingRuleNameText : this.t('rulesEditor'))
          .fontSize(12)
          .fontColor(this.secondaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.ruleComposerOpen ?
          this.t(this.editingRuleLineIndex < 0 ? 'addRuleLine' : 'ruleUpdateLine') : this.editingRuleNameText)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (!this.ruleComposerOpen) {
        Button('···', { type: ButtonType.Normal })
          .width(40)
          .height(40)
          .padding(0)
          .fontSize(22)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .backgroundColor(this.softPanelTone())
          .borderRadius(12)
          .accessibilityText(this.t('ruleMoreActions'))
          .bindMenu(this.ruleEditorMenu())
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(15)
            .fontColor([this.primaryTextColor()])
        }
        .width(40)
        .height(40)
        .padding(0)
        .backgroundColor(this.softPanelTone())
        .borderRadius(12)
        .accessibilityText(this.t('closeEditor'))
        .onClick(() => this.closeRuleEditor())
      }
    }
    .width('100%')
  }

  @Builder
  private RuleEditorChoice(label: string, selected: () => boolean, action: () => void) {
    Button(label, { type: ButtonType.Normal })
      .layoutWeight(1)
      .constraintSize({ minHeight: 40 })
      .padding({ left: 5, right: 5, top: 6, bottom: 6 })
      .fontSize(13)
      .fontWeight(selected() ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(selected() ? this.selectedChipTextTone() : this.secondaryTextColor())
      .backgroundColor(selected() ? this.selectedChipSurfaceTone() : Color.Transparent)
      .border({ width: 1, color: selected() ? this.selectedOutlineTone() : Color.Transparent })
      .borderRadius(10)
      .accessibilitySelected(selected())
      .onClick(action)
  }

  @Builder
  private RuleVisualFields() {
    Column({ space: 9 }) {
      Text(this.t('ruleDomainField'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
      TextInput({ text: this.ruleComposerDomain, placeholder: 'example.com' })
        .id('rule-composer-domain')
        .width('100%')
        .height(48)
        .type(InputType.URL)
        .fontSize(16)
        .backgroundColor(this.cardSurfaceTone())
        .border({ width: 1, color: this.cardBorderTone() })
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.ruleComposerDomain = value;
          this.ruleComposerError = '';
        })
      this.RuleVisualPreview()
      Text(this.t('ruleMatchScope'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .margin({ top: 4 })
      Row({ space: 4 }) {
        this.RuleEditorChoice(this.t('ruleExactDomain'), () => !this.ruleComposerSubdomains, () => {
          this.ruleComposerSubdomains = false;
          this.ruleComposerError = '';
        })
        this.RuleEditorChoice(this.t('ruleIncludeSubdomains'), () => this.ruleComposerSubdomains, () => {
          this.ruleComposerSubdomains = true;
          this.ruleComposerError = '';
        })
      }
      .width('100%')
      .padding(4)
      .backgroundColor(this.softPanelTone())
      .borderRadius(13)
      Text(this.t('ruleQueryType'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .margin({ top: 4 })
      Row({ space: 4 }) {
        ForEach(['all', 'A', 'AAAA'] as RuleQueryType[], (type: RuleQueryType) => {
          this.RuleEditorChoice(this.ruleQueryTypeLabel(type), () => this.ruleComposerQueryType === type, () => {
            this.ruleComposerQueryType = type;
            this.ruleComposerError = '';
          })
        }, (type: RuleQueryType) => type)
      }
      .width('100%')
      .padding(4)
      .backgroundColor(this.softPanelTone())
      .borderRadius(13)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private RuleVisualPreview() {
    Column({ space: 8 }) {
      Text(this.t('rulePreviewTitle'))
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.selectedChipTextTone())
      if (this.visualRulePreview().length > 0) {
        Text(this.visualRulePreview())
          .width('100%')
          .fontSize(13)
          .fontFamily('monospace')
          .fontColor(this.selectedChipTextTone())
          .wordBreak(WordBreak.BREAK_ALL)
          .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
        Text(this.visualRuleEffect())
          .width('100%')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.primaryTextColor())
          .wordBreak(WordBreak.BREAK_WORD)
      } else {
        Text(this.t(this.ruleComposerDomain.trim().length > 0 ? 'ruleInvalidDomain' : 'rulePreviewEmpty'))
          .fontSize(13)
          .fontColor(this.ruleComposerDomain.trim().length > 0 ?
            (this.isDarkModeActive() ? '#FFABAB' : '#A52C23') : this.secondaryTextColor())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(this.selectedChipSurfaceTone())
    .borderRadius(14)
  }

  @Builder
  private RuleComposer() {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 6 }) {
          this.RuleEditorChoice(this.t('ruleVisualMode'), () => !this.ruleComposerRaw,
            () => this.selectRuleComposerMode(false))
          this.RuleEditorChoice(this.t('ruleRawMode'), () => this.ruleComposerRaw,
            () => this.selectRuleComposerMode(true))
        }
        .width('100%')
        .padding(4)
        .backgroundColor(this.softPanelTone())
        .borderRadius(13)
        if (this.ruleComposerRaw) {
          TextArea({ text: this.ruleComposerRawText, placeholder: this.builtInRuleInputPlaceholder() })
            .width('100%')
            .height(170)
            .fontSize(14)
            .fontFamily('monospace')
            .backgroundColor(this.cardSurfaceTone())
            .border({ width: 1, color: this.cardBorderTone() })
            .borderRadius(12)
            .padding(12)
            .onChange((value: string) => {
              this.ruleComposerRawText = value;
              this.ruleComposerError = '';
            })
        } else {
          this.RuleVisualFields()
        }
        if (this.ruleComposerError.length > 0) {
          Text(this.ruleComposerError)
            .fontSize(13)
            .fontColor(this.isDarkModeActive() ? '#FFABAB' : '#A52C23')
            .width('100%')
            .wordBreak(WordBreak.BREAK_ALL)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ bottom: 4 })
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.TopStart)
    .scrollBar(BarState.Auto)
  }

  @Builder
  private RuleEditorListItem(item: RuleLineItem) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        if (item.domain.length > 0) {
          Text(item.domain)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        Text(item.line)
          .fontSize(13)
          .fontFamily('monospace')
          .fontColor(item.domain.length > 0 ? this.secondaryTextColor() : this.primaryTextColor())
          .maxLines(item.domain.length > 0 ? 1 : 2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button(this.t('editRule'), { type: ButtonType.Normal })
        .height(40)
        .padding({ left: 11, right: 11 })
        .fontSize(13)
        .fontColor(this.selectedChipTextTone())
        .backgroundColor(this.selectedChipSurfaceTone())
        .borderRadius(10)
        .onClick(() => this.openRuleComposer(item))
      Button() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(16)
          .fontColor([this.isDarkModeActive() ? '#FFABAB' : '#A52C23'])
      }
      .width(40)
      .height(40)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(10)
      .accessibilityText(this.t('deleteRule'))
      .onClick(() => this.confirmDeleteRuleLine(item.index))
    }
    .width('100%')
    .padding({ left: 13, right: 6, top: 9, bottom: 9 })
    .backgroundColor(this.cardSurfaceTone())
    .border({ width: 1, color: this.cardBorderTone() })
    .borderRadius(14)
  }

  @Builder
  private RuleEditorList() {
    Row({ space: 10 }) {
      Text(this.t('ruleListTitle', this.ruleProfileLines(this.rulesText).length))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.secondaryTextColor())
        .layoutWeight(1)
      Button() {
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(14)
            .fontColor([this.selectedChipTextTone()])
          Text(this.t('addRuleLine'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.selectedChipTextTone())
        }
      }
      .height(42)
      .padding({ left: 12, right: 12 })
      .backgroundColor(this.selectedChipSurfaceTone())
      .borderRadius(12)
      .accessibilityText(this.t('addRuleLine'))
      .onClick(() => this.openRuleComposer())
    }
    .width('100%')
    if (this.rulesText.trim().length > 0) {
      List({ space: 8 }) {
        ForEach(this.editingRuleLineItems(), (item: RuleLineItem) => {
          ListItem() {
            this.RuleEditorListItem(item)
          }
        }, (item: RuleLineItem) => item.key)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    } else {
      Column() {
        Text(this.t('noCustomRulesHint'))
          .fontSize(14)
          .fontColor(this.secondaryTextColor())
          .textAlign(TextAlign.Center)
          .padding(18)
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(this.cardSurfaceTone())
      .border({ width: 1, color: this.cardBorderTone() })
      .borderRadius(14)
    }
  }

  @Builder
  private RuleEditorSheet() {
    Column({ space: 14 }) {
      this.RuleEditorHeader()
      if (this.ruleComposerOpen) {
        this.RuleComposer()
      } else if (this.builtInRuleEditorActive()) {
        this.RuleEditorList()
      } else {
        TextArea({ text: this.rulesText, placeholder: this.t('writeRulesHere') })
          .width('100%')
          .layoutWeight(1)
          .fontSize(14)
          .fontFamily('monospace')
          .backgroundColor(this.cardSurfaceTone())
          .border({ width: 1, color: this.cardBorderTone() })
          .borderRadius(14)
          .padding(12)
          .onChange((value: string) => {
            this.rulesText = value;
          })
      }
      Button(this.t(this.ruleComposerOpen ? (this.editingRuleLineIndex < 0 ? 'addRuleLine' : 'ruleUpdateLine') :
        'saveRules'), { type: ButtonType.Normal })
        .width('100%')
        .height(46)
        .borderRadius(14)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor(this.actionTone())
        .enabled(!this.ruleComposerOpen || this.ruleComposerCanApply())
        .opacity(!this.ruleComposerOpen || this.ruleComposerCanApply() ? 1 : 0.5)
        .onClick(() => {
          if (this.ruleComposerOpen) {
            this.applyRuleComposer();
          } else {
            this.applyRuleEditorChanges();
          }
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 12, bottom: Math.max(12, this.avoidPaddingBottom + 6) })
    .backgroundColor(this.canvasTone())
  }

  @Builder
  private SidebarTab(index: number, icon: Resource, label: string) {
    Row({ space: 10 }) {
      SymbolGlyph(icon).fontSize(18)
        .fontColor([this.currentTab === index ? this.selectedChipTextTone() : this.secondaryTextColor()])
      Text(label).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(this.currentTab === index ? this.selectedChipTextTone() : this.secondaryTextColor())
    }
    .width('100%')
    .height(44)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.currentTab === index ? this.selectedChipSurfaceTone() : Color.Transparent)
    .borderRadius(12)
    .onClick(() => {
      if (this.currentTab !== index) {
        this.currentTab = index;
        this.savePersistState();
      }
    })
  }

  @Builder
  private SidebarTabs() {
    Row() {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Image($r('app.media.foreground')).width(34).height(34)
            .objectFit(ImageFit.Contain).backgroundColor(Color.White).borderRadius(9)
          Text(this.t('appTitle')).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.primaryTextColor())
        }
        .width('100%')
        .padding({ left: 6, bottom: 14 })
        this.SidebarTab(0, $r('sys.symbol.house'), this.t('tabHome'))
        this.SidebarTab(1, $r('sys.symbol.gearshape'), this.t('tabConfig'))
        this.SidebarTab(2, $r('sys.symbol.person'), this.t('tabMe'))
        Blank()
        Row({ space: 8 }) {
          Column() {}
            .width(7).height(7).borderRadius(4)
            .backgroundColor(this.activeRunning() ? this.accentGreenTone() : this.secondaryTextColor())
          Text(this.activeRunning() ? this.t('active') : this.t('idle'))
            .fontSize(12).fontColor(this.secondaryTextColor())
        }
        .width('100%')
        .padding(10)
        .backgroundColor(this.canvasTone())
        .borderRadius(9)
      }
      .width(170)
      .height('100%')
      .padding({ left: 12, right: 12, top: this.contentTopInset() + 14,
        bottom: this.avoidPaddingBottom + 14 })
      .backgroundColor(this.paletteColors().sidebar)
      .border({ width: { right: 1 }, color: this.cardBorderTone() })
      Column() {
        this.CurrentTabPage()
      }
      .height('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private TabHost() {
    Stack({ alignContent: Alignment.Bottom }) {
      this.PageBackdrop()

      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          if (this.useSidebarLayout()) {
            this.SidebarTabs()
          } else if (deviceInfo.sdkApiVersion >= 23) {
            HdsTabs({ barPosition: BarPosition.End, index: this.currentTab }) {
              TabContent() {
                this.TabRoot(0)
              }
              .width('100%')
              .height('100%')
              .backgroundColor('#00000000')
              .tabBar(this.bottomTabStyle($r('sys.symbol.house'), $r('sys.symbol.house_fill'),
                this.t('tabHome')))

              TabContent() {
                this.TabRoot(1)
              }
              .width('100%')
              .height('100%')
              .backgroundColor('#00000000')
              .tabBar(this.bottomTabStyle($r('sys.symbol.gearshape'), $r('sys.symbol.gearshape_fill'),
                this.t('tabConfig')))

              TabContent() {
                this.TabRoot(2)
              }
              .width('100%')
              .height('100%')
              .backgroundColor('#00000000')
              .tabBar(this.bottomTabStyle($r('sys.symbol.person'), $r('sys.symbol.person_fill'),
                this.t('tabMe')))
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
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
        .align(Alignment.TopStart)
        .bindSheet(this.showRuleEditorSheet, this.RuleEditorSheet(), {
          height: '90%',
          backgroundColor: this.canvasTone(),
          showClose: false,
          keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
          onDisappear: () => {
            if (this.showRuleEditorSheet) {
              this.closeRuleEditor();
            }
          }
        })
      }
      .width('100%')
      .height('100%')
      if (!this.useSidebarLayout() && deviceInfo.sdkApiVersion < 23) {
        this.ClassicTabHost()
      }

      // Error banner floats just below the title bar so it never shifts the
      // immersive layout; tap to dismiss.
      if (this.errorText.length > 0) {
        Column() {
          Text(this.errorText)
            .fontSize(13)
            .fontColor('#B42318')
            .padding(12)
            .backgroundColor(this.softRedTone())
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
            .borderRadius(14)
            .width('100%')
            .onClick(() => {
              this.errorText = '';
            })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16, top: this.contentTopInset() + 60 })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // Subscription content viewer — a plain top-of-Stack overlay (like the
      // disclaimer) instead of a bindContentCover. A second modal binding on the
      // root column (which already hosts bindSheet) was being dropped, so taps did
      // nothing; an overlay rendered here always shows, from any tab.
      if (this.showSubContentSheet) {
        this.SubContentSheet()
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

  private bottomTabStyle(icon: Resource, selected: Resource, label: string): BottomTabBarStyle {
    return new BottomTabBarStyle({
      normal: new SymbolGlyphModifier(icon).fontColor([this.secondaryTextColor()]),
      selected: new SymbolGlyphModifier(selected).fontColor([this.accentBlueTone()])
    }, label).labelStyle({
      selectedColor: this.accentBlueTone(),
      unselectedColor: this.secondaryTextColor()
    });
  }

  build() {
    HdsNavigation(this.meStack) {
      this.TabHost()
    }
    .navDestination(this.MePageMap)
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
    .backgroundColor(Color.Transparent)
    .width('100%')
    .height('100%')
  }
}
