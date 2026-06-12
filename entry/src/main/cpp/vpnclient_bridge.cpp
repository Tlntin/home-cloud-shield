#include <napi/native_api.h>

#include <algorithm>
#include <arpa/inet.h>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <netinet/in.h>
#include <poll.h>
#include <sstream>
#include <string>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <thread>
#include <unordered_map>
#include <unistd.h>
#include <vector>

#include <hilog/log.h>

// Prebuilt AdGuardHome c-shared engine (full mode).  Declares the extern "C"
// entry points AdGuardHomeVersion/Start/Stop/FreeCString.
#include "libadguardhome_ohos.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "vpnbridge"

namespace {

// Returns the embedded AdGuardHome version, freeing the C string returned by
// the Go layer.  Used as a smoke test that the prebuilt .so links and loads.
std::string AdGuardHomeVersionString()
{
    char *raw = AdGuardHomeVersion();
    std::string out = (raw != nullptr) ? raw : "";
    if (raw != nullptr) {
        AdGuardHomeFreeCString(raw);
    }
    return out;
}

// Starts the embedded AdGuardHome engine (full mode) with the given config
// file, working dir, and log path. startWeb controls whether the web admin
// dashboard HTTP server is served (off saves battery: no listener, no HTTP
// goroutines). Returns the Go layer's error string (empty on success).
std::string StartAdGuardHome(const std::string &configPath, const std::string &workDir, const std::string &logPath,
    bool startWeb)
{
    char *raw = AdGuardHomeStart(const_cast<char *>(configPath.c_str()),
        const_cast<char *>(workDir.c_str()), const_cast<char *>(logPath.c_str()), startWeb ? 1 : 0);
    std::string out = (raw != nullptr) ? raw : "";
    if (raw != nullptr) {
        AdGuardHomeFreeCString(raw);
    }
    return out;
}

// Stops the embedded AdGuardHome engine. Safe to call when nothing is running.
void StopAdGuardHome()
{
    char *raw = AdGuardHomeStop();
    if (raw != nullptr) {
        AdGuardHomeFreeCString(raw);
    }
}


struct RuleEntry {
    bool allow = false;
    bool important = false;
    bool badfilter = false;
    bool exactHost = false;
    bool dnstypeRestricted = false;
    bool matchTypeA = true;
    bool matchTypeAAAA = true;
    std::string pattern;
    std::string original;
};

struct DnsQuestion {
    bool valid = false;
    std::string name;
    uint16_t qtype = 0;
    size_t questionEndOffset = 0;
};

struct Ipv4UdpPacketView {
    bool valid = false;
    uint32_t srcAddr = 0;
    uint32_t dstAddr = 0;
    uint16_t srcPort = 0;
    uint16_t dstPort = 0;
    uint16_t identification = 0;
    const uint8_t *dnsPayload = nullptr;
    size_t dnsLen = 0;
};

struct Ipv6UdpPacketView {
    bool valid = false;
    std::array<uint8_t, 16> srcAddr {};
    std::array<uint8_t, 16> dstAddr {};
    uint16_t srcPort = 0;
    uint16_t dstPort = 0;
    const uint8_t *dnsPayload = nullptr;
    size_t dnsLen = 0;
};

struct MatchResult {
    bool matched = false;
    bool blocked = false;
    bool important = false;
    size_t score = 0;
    std::string matchedRule;
};

struct DnsCacheEntry {
    std::vector<uint8_t> response;
    int64_t expiresAtMs = 0;
};

struct StatsState {
    std::mutex mu;
    bool running = false;
    bool stopRequested = false;
    int tunFd = -1;
    int64_t startedAtMs = 0;
    uint64_t totalPackets = 0;
    uint64_t totalBytes = 0;
    uint64_t ipv4Packets = 0;
    uint64_t ipv6Packets = 0;
    uint64_t tcpPackets = 0;
    uint64_t udpPackets = 0;
    uint64_t dnsPackets = 0;
    uint64_t allowedQueries = 0;
    uint64_t blockedQueries = 0;
    uint64_t loggedQueries = 0;
        uint64_t dnsCacheHits = 0;
        uint64_t dnsCacheMisses = 0;
    std::string lastQueryDomain;
    std::string lastMatchedRule;
    std::string lastError;
    std::string rulesPath;
    std::string queryLogPath;
    std::vector<std::string> upstreamDnsIps;
    std::string dnsServerIp;
    // Full mode: forward every query to the embedded AdGuardHome engine on
    // 127.0.0.1:aghDnsPort (which performs all filtering/upstream/caching)
    // instead of matching rules locally. aghDnsPort == 0 means lightweight mode.
    bool fullMode = false;
    uint16_t aghDnsPort = 0;
    std::shared_ptr<const std::vector<RuleEntry>> activeRules;
    uint32_t dnsCacheTtlSeconds = 3600;
    std::unordered_map<std::string, DnsCacheEntry> dnsResponseCache;
    // Wakes the TUN reader's poll() immediately on stop, so the loop can sleep
    // indefinitely instead of waking every 200ms to re-check stopRequested
    // (5 wakeups/s on an idle, screen-off device adds up). -1 means creation
    // failed and the reader falls back to the old short-timeout polling.
    int stopEventFd = -1;
    std::thread worker;
    // Lightweight DNS-over-TCP server (DNS-proxy / coexist mode, no VPN): the
    // listening socket and its accept thread. listenFd == -1 means not running.
    int dnsServerListenFd = -1;
    std::thread dnsServerThread;
    // Companion DNS-over-UDP listener for the same coexist server (plain RFC 1035
    // datagrams, no length prefix). udpFd == -1 means not running.
    int dnsServerUdpFd = -1;
    std::thread dnsServerUdpThread;
};

StatsState g_state;

constexpr int kForwardWorkerCount = 8;
constexpr size_t kMaxQueuedForwardTasks = 2048;
constexpr int kUpstreamTimeoutSec = 2;
constexpr int kUpstreamAttempts = 2;

// Serializes writes back to the TUN fd across the reader thread (blocked
// responses) and the forward worker threads (upstream responses).
std::mutex g_tunWriteMu;

// Caps concurrent DNS-over-TCP connections served by the lightweight DNS server,
// so a misbehaving local client cannot spawn unbounded handler threads.
constexpr int kLwMaxDnsConns = 64;
std::atomic<int> g_lwConnCount{0};

// Caps concurrent in-flight DNS-over-UDP queries served by the lightweight DNS
// server, mirroring the TCP connection cap above.
constexpr int kLwMaxUdpInflight = 64;
std::atomic<int> g_lwUdpInflight{0};

// Gates the per-DNS-query and periodic packet-counter hilog lines. A phone
// easily makes tens of thousands of DNS queries a day; one hilog call per query
// keeps the log daemon busy and costs battery, so this is off unless a
// debugging session turns it on via setNativeVerboseLog.
std::atomic<bool> g_verboseLog{false};

// A DNS query that passed the filter and must be resolved upstream. Forwarding
// is the slow part (a network round-trip), so it runs on a worker pool instead
// of blocking the single reader thread that drains the TUN device.
struct ForwardTask {
    int tunFd = -1;
    bool isIpv6 = false;
    Ipv4UdpPacketView view4;
    Ipv6UdpPacketView view6;
    std::vector<uint8_t> query;
    DnsQuestion question;
    std::string matchedRule;
    std::vector<std::string> upstreams;
    uint16_t upstreamPort = 53;
    bool useCache = true;
    std::string queryLogPath;
};

struct ForwardPool {
    std::mutex mu;
    std::condition_variable cv;
    std::deque<ForwardTask> tasks;
    std::vector<std::thread> workers;
    bool running = false;
    bool stopRequested = false;
};

ForwardPool g_pool;

void LogInfo(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    OH_LOG_VPrint(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, fmt, args);
    va_end(args);
}

void LogError(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    OH_LOG_VPrint(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, fmt, args);
    va_end(args);
}

int64_t NowMs()
{
    using namespace std::chrono;
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

std::string EscapeJson(const std::string &value)
{
    std::string out;
    out.reserve(value.size() + 8);
    for (char ch : value) {
        switch (ch) {
            case '\\':
                out += "\\\\";
                break;
            case '"':
                out += "\\\"";
                break;
            case '\n':
                out += "\\n";
                break;
            case '\r':
                out += "\\r";
                break;
            case '\t':
                out += "\\t";
                break;
            default:
                out += ch;
                break;
        }
    }
    return out;
}

std::string ToLowerAscii(const std::string &value)
{
    std::string out = value;
    for (char &ch : out) {
        if (ch >= 'A' && ch <= 'Z') {
            ch = static_cast<char>(ch - 'A' + 'a');
        }
    }
    return out;
}

std::string Trim(const std::string &value)
{
    size_t start = 0;
    while (start < value.size() && (value[start] == ' ' || value[start] == '\t' || value[start] == '\r' || value[start] == '\n')) {
        start++;
    }

    size_t end = value.size();
    while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t' || value[end - 1] == '\r' || value[end - 1] == '\n')) {
        end--;
    }

    return value.substr(start, end - start);
}

bool EndsWith(const std::string &value, const std::string &suffix)
{
    return value.size() >= suffix.size() && value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool StartsWith(const std::string &value, const std::string &prefix)
{
    return value.size() >= prefix.size() && value.compare(0, prefix.size(), prefix) == 0;
}

bool ReadArgInt32(napi_env env, napi_value value, int32_t &out)
{
    return napi_get_value_int32(env, value, &out) == napi_ok;
}

bool ReadArgBool(napi_env env, napi_value value, bool &out)
{
    return napi_get_value_bool(env, value, &out) == napi_ok;
}

bool ReadArgString(napi_env env, napi_value value, std::string &out)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    std::string buf(len, '\0');
    if (napi_get_value_string_utf8(env, value, &buf[0], len + 1, &len) != napi_ok) {
        return false;
    }
    out.assign(buf.c_str(), len);
    return true;
}

napi_value MakeUtf8(napi_env env, const std::string &value)
{
    napi_value out = nullptr;
    napi_create_string_utf8(env, value.c_str(), NAPI_AUTO_LENGTH, &out);
    return out;
}

napi_value MakeUndefined(napi_env env)
{
    napi_value out = nullptr;
    napi_get_undefined(env, &out);
    return out;
}

napi_value ReturnErrOrUndefined(napi_env env, const std::string &err)
{
    if (err.empty()) {
        return MakeUndefined(env);
    }
    return MakeUtf8(env, err);
}

std::string ReadWholeFile(const std::string &path)
{
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        return {};
    }

    std::string content;
    char buffer[4096];
    for (;;) {
        ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n > 0) {
            content.append(buffer, static_cast<size_t>(n));
            continue;
        }
        break;
    }

    close(fd);
    return content;
}

void AppendTextLine(const std::string &path, const std::string &line)
{
    if (path.empty()) {
        return;
    }

    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        return;
    }

    const std::string content = line + "\n";
    size_t offset = 0;
    while (offset < content.size()) {
        ssize_t n = write(fd, content.data() + offset, content.size() - offset);
        if (n <= 0) {
            break;
        }
        offset += static_cast<size_t>(n);
    }

    close(fd);
}

std::vector<std::string> SplitLines(const std::string &content)
{
    std::vector<std::string> lines;
    size_t start = 0;
    while (start <= content.size()) {
        size_t end = content.find('\n', start);
        if (end == std::string::npos) {
            lines.push_back(content.substr(start));
            break;
        }
        lines.push_back(content.substr(start, end - start));
        start = end + 1;
    }
    return lines;
}

bool IsDomainChar(char ch)
{
    return (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '.' || ch == '-';
}

bool LooksLikeDomain(const std::string &value)
{
    if (value.empty()) {
        return false;
    }
    for (char ch : value) {
        if (!IsDomainChar(ch)) {
            return false;
        }
    }
    return value.find('.') != std::string::npos;
}

bool LooksLikeRulePattern(const std::string &value)
{
    if (value.empty()) {
        return false;
    }

    bool hasDot = false;
    for (char ch : value) {
        if (ch == '.') {
            hasDot = true;
            continue;
        }
        if (ch == '*') {
            continue;
        }
        if (!IsDomainChar(ch)) {
            return false;
        }
    }
    return hasDot;
}

std::vector<std::string> SplitByChar(const std::string &value, char separator)
{
    std::vector<std::string> items;
    size_t start = 0;
    while (start <= value.size()) {
        size_t end = value.find(separator, start);
        if (end == std::string::npos) {
            items.push_back(value.substr(start));
            break;
        }
        items.push_back(value.substr(start, end - start));
        start = end + 1;
    }
    return items;
}

void ApplyDnsTypeModifier(RuleEntry &rule, const std::string &modifierValue)
{
    bool allowA = false;
    bool allowAAAA = false;
    bool hasPositive = false;
    bool hasNegativeA = false;
    bool hasNegativeAAAA = false;

    for (const std::string &partRaw : SplitByChar(modifierValue, '|')) {
        std::string part = ToLowerAscii(Trim(partRaw));
        if (part.empty()) {
            continue;
        }

        bool negative = false;
        if (part[0] == '~') {
            negative = true;
            part = Trim(part.substr(1));
        }

        if (part == "a") {
            if (negative) {
                hasNegativeA = true;
            } else {
                allowA = true;
                hasPositive = true;
            }
        } else if (part == "aaaa") {
            if (negative) {
                hasNegativeAAAA = true;
            } else {
                allowAAAA = true;
                hasPositive = true;
            }
        }
    }

    rule.dnstypeRestricted = true;
    if (hasPositive) {
        rule.matchTypeA = allowA;
        rule.matchTypeAAAA = allowAAAA;
    } else {
        rule.matchTypeA = !hasNegativeA;
        rule.matchTypeAAAA = !hasNegativeAAAA;
    }
}

RuleEntry ParseRuleLine(const std::string &line)
{
    RuleEntry rule;
    std::string value = Trim(line);
    if (value.empty() || value[0] == '!' || value[0] == '#') {
        return rule;
    }
    if (value.find("##") != std::string::npos || value.find("#@#") != std::string::npos || value.find("#$#") != std::string::npos) {
        return rule;
    }

    if (StartsWith(value, "@@")) {
        rule.allow = true;
        value = value.substr(2);
    }

    value = Trim(value);
    if (value.empty()) {
        return rule;
    }

    size_t spacePos = value.find_first_of(" \t");
    if (spacePos != std::string::npos) {
        std::string first = ToLowerAscii(Trim(value.substr(0, spacePos)));
        std::string second = ToLowerAscii(Trim(value.substr(spacePos + 1)));
        if ((first == "0.0.0.0" || first == "127.0.0.1" || first == "::" || first == "::1") && LooksLikeDomain(second)) {
            value = second;
        }
    }

    value = ToLowerAscii(value);
    size_t optionPos = value.find('$');
    std::string modifiers;
    if (optionPos != std::string::npos) {
        modifiers = value.substr(optionPos + 1);
        value = value.substr(0, optionPos);
    }
    for (const std::string &modifierRaw : SplitByChar(modifiers, ',')) {
        const std::string modifier = Trim(modifierRaw);
        if (modifier == "important") {
            rule.important = true;
        } else if (modifier == "badfilter") {
            rule.badfilter = true;
        } else if (StartsWith(modifier, "dnstype=")) {
            ApplyDnsTypeModifier(rule, modifier.substr(std::strlen("dnstype=")));
        }
    }

    if (StartsWith(value, "||")) {
        value = value.substr(2);
    } else if (StartsWith(value, "|")) {
        rule.exactHost = true;
        value = value.substr(1);
    }
    size_t schemePos = value.find("://");
    if (schemePos != std::string::npos) {
        value = value.substr(schemePos + 3);
        rule.exactHost = true;
    }
    if (StartsWith(value, "*.")) {
        value = value.substr(2);
    }
    size_t slashPos = value.find('/');
    if (slashPos != std::string::npos) {
        value = value.substr(0, slashPos);
        rule.exactHost = true;
    }
    size_t questionPos = value.find('?');
    if (questionPos != std::string::npos) {
        value = value.substr(0, questionPos);
        rule.exactHost = true;
    }
    while (StartsWith(value, ".")) {
        value = value.substr(1);
    }
    if (EndsWith(value, "^")) {
        value.pop_back();
    }
    size_t caretPos = value.find('^');
    if (caretPos != std::string::npos) {
        value = value.substr(0, caretPos);
    }
    if (EndsWith(value, "|")) {
        value.pop_back();
        rule.exactHost = true;
    }

    value = Trim(value);
    if (!LooksLikeRulePattern(value)) {
        return rule;
    }

    rule.pattern = value;
    rule.original = line;
    return rule;
}

std::vector<RuleEntry> LoadRulesSnapshot(const std::string &rulesPath)
{
    std::vector<RuleEntry> rules;
    std::vector<RuleEntry> badfilters;
    const std::vector<std::string> lines = SplitLines(ReadWholeFile(rulesPath));
    for (const std::string &line : lines) {
        RuleEntry rule = ParseRuleLine(line);
        if (!rule.pattern.empty()) {
            if (rule.badfilter) {
                badfilters.push_back(rule);
            } else {
                rules.push_back(rule);
            }
        }
    }
    for (const RuleEntry &badfilter : badfilters) {
        rules.erase(std::remove_if(rules.begin(), rules.end(), [&](const RuleEntry &rule) {
            return rule.pattern == badfilter.pattern && rule.allow == badfilter.allow;
        }), rules.end());
    }
    return rules;
}

bool WildcardMatch(const std::string &value, const std::string &pattern)
{
    size_t valuePos = 0;
    size_t patternPos = 0;
    size_t starPos = std::string::npos;
    size_t matchPos = 0;
    while (valuePos < value.size()) {
        if (patternPos < pattern.size() && (pattern[patternPos] == value[valuePos])) {
            valuePos++;
            patternPos++;
            continue;
        }
        if (patternPos < pattern.size() && pattern[patternPos] == '*') {
            starPos = patternPos++;
            matchPos = valuePos;
            continue;
        }
        if (starPos != std::string::npos) {
            patternPos = starPos + 1;
            valuePos = ++matchPos;
            continue;
        }
        return false;
    }
    while (patternPos < pattern.size() && pattern[patternPos] == '*') {
        patternPos++;
    }
    return patternPos == pattern.size();
}

bool DomainMatches(const std::string &domain, const RuleEntry &rule)
{
    if (rule.pattern.find('*') != std::string::npos) {
        if (WildcardMatch(domain, rule.pattern)) {
            return true;
        }
        return !rule.exactHost && WildcardMatch(domain, "*." + rule.pattern);
    }
    if (domain == rule.pattern) {
        return true;
    }
    return !rule.exactHost && domain.size() > rule.pattern.size() && EndsWith(domain, "." + rule.pattern);
}

bool DnsTypeMatches(const RuleEntry &rule, uint16_t qtype)
{
    if (!rule.dnstypeRestricted) {
        return true;
    }
    if (qtype == 1) {
        return rule.matchTypeA;
    }
    if (qtype == 28) {
        return rule.matchTypeAAAA;
    }
    return false;
}

MatchResult MatchDomain(const std::string &domain, uint16_t qtype, const std::vector<RuleEntry> &rules)
{
    MatchResult bestBlock;
    MatchResult bestAllow;

    for (const RuleEntry &rule : rules) {
        if (!DnsTypeMatches(rule, qtype)) {
            continue;
        }
        if (!DomainMatches(domain, rule)) {
            continue;
        }
        const size_t score = rule.pattern.size() + (rule.important ? 1000000U : 0U);
        if (rule.allow) {
            if (!bestAllow.matched || score >= bestAllow.score) {
                bestAllow.matched = true;
                bestAllow.score = score;
                bestAllow.important = rule.important;
                bestAllow.matchedRule = rule.original;
            }
        } else {
            if (!bestBlock.matched || score >= bestBlock.score) {
                bestBlock.matched = true;
                bestBlock.score = score;
                bestBlock.important = rule.important;
                bestBlock.matchedRule = rule.original;
            }
        }
    }

    if (bestAllow.matched) {
        if (bestBlock.matched && bestBlock.important && !bestAllow.important) {
            bestBlock.blocked = true;
            return bestBlock;
        }
        if (!bestBlock.matched || bestAllow.score >= bestBlock.score) {
            bestAllow.blocked = false;
            return bestAllow;
        }
    }
    if (bestBlock.matched) {
        bestBlock.blocked = true;
        return bestBlock;
    }
    return {};
}

uint16_t Load16(const uint8_t *p)
{
    return static_cast<uint16_t>((static_cast<uint16_t>(p[0]) << 8) | static_cast<uint16_t>(p[1]));
}

void Store16(uint8_t *p, uint16_t value)
{
    p[0] = static_cast<uint8_t>((value >> 8) & 0xFF);
    p[1] = static_cast<uint8_t>(value & 0xFF);
}

void Store32(uint8_t *p, uint32_t value)
{
    p[0] = static_cast<uint8_t>((value >> 24) & 0xFF);
    p[1] = static_cast<uint8_t>((value >> 16) & 0xFF);
    p[2] = static_cast<uint8_t>((value >> 8) & 0xFF);
    p[3] = static_cast<uint8_t>(value & 0xFF);
}

uint16_t InternetChecksum(const uint8_t *data, size_t len)
{
    uint32_t sum = 0;
    size_t i = 0;
    while (i + 1 < len) {
        sum += static_cast<uint16_t>((data[i] << 8) | data[i + 1]);
        i += 2;
    }
    if (i < len) {
        sum += static_cast<uint16_t>(data[i] << 8);
    }
    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFFU) + (sum >> 16);
    }
    return static_cast<uint16_t>(~sum);
}

Ipv4UdpPacketView ParseIpv4UdpPacket(const uint8_t *packet, size_t len)
{
    Ipv4UdpPacketView view;
    if (len < 28) {
        return view;
    }
    const uint8_t version = packet[0] >> 4;
    if (version != 4) {
        return view;
    }
    const size_t ipHeaderLen = static_cast<size_t>(packet[0] & 0x0F) * 4;
    if (ipHeaderLen < 20 || len < ipHeaderLen + 8) {
        return view;
    }
    if (packet[9] != 17) {
        return view;
    }

    const uint16_t totalLen = Load16(packet + 2);
    const size_t packetLen = totalLen > 0 && totalLen <= len ? totalLen : len;
    if (packetLen < ipHeaderLen + 8) {
        return view;
    }

    const uint8_t *udp = packet + ipHeaderLen;
    const uint16_t udpLen = Load16(udp + 4);
    if (udpLen < 8 || ipHeaderLen + udpLen > packetLen) {
        return view;
    }

    view.valid = true;
    view.srcAddr = static_cast<uint32_t>(packet[12] << 24 | packet[13] << 16 | packet[14] << 8 | packet[15]);
    view.dstAddr = static_cast<uint32_t>(packet[16] << 24 | packet[17] << 16 | packet[18] << 8 | packet[19]);
    view.srcPort = Load16(udp);
    view.dstPort = Load16(udp + 2);
    view.identification = Load16(packet + 4);
    view.dnsPayload = udp + 8;
    view.dnsLen = udpLen - 8;
    return view;
}

Ipv6UdpPacketView ParseIpv6UdpPacket(const uint8_t *packet, size_t len)
{
    Ipv6UdpPacketView view;
    if (len < 48) {
        return view;
    }
    const uint8_t version = packet[0] >> 4;
    if (version != 6 || packet[6] != 17) {
        return view;
    }

    const uint16_t payloadLen = Load16(packet + 4);
    if (payloadLen < 8 || len < static_cast<size_t>(40 + payloadLen)) {
        return view;
    }

    const uint8_t *udp = packet + 40;
    const uint16_t udpLen = Load16(udp + 4);
    if (udpLen < 8 || udpLen > payloadLen) {
        return view;
    }

    view.valid = true;
    std::memcpy(view.srcAddr.data(), packet + 8, 16);
    std::memcpy(view.dstAddr.data(), packet + 24, 16);
    view.srcPort = Load16(udp);
    view.dstPort = Load16(udp + 2);
    view.dnsPayload = udp + 8;
    view.dnsLen = udpLen - 8;
    return view;
}

DnsQuestion ParseDnsQuestion(const uint8_t *payload, size_t len)
{
    DnsQuestion question;
    if (len < 17) {
        return question;
    }
    if (Load16(payload + 4) == 0) {
        return question;
    }

    size_t offset = 12;
    std::string name;
    while (offset < len) {
        const uint8_t labelLen = payload[offset++];
        if (labelLen == 0) {
            break;
        }
        if ((labelLen & 0xC0U) != 0 || offset + labelLen > len) {
            return question;
        }
        if (!name.empty()) {
            name.push_back('.');
        }
        for (size_t i = 0; i < labelLen; ++i) {
            char ch = static_cast<char>(payload[offset + i]);
            if (ch >= 'A' && ch <= 'Z') {
                ch = static_cast<char>(ch - 'A' + 'a');
            }
            name.push_back(ch);
        }
        offset += labelLen;
    }

    if (offset + 4 > len || name.empty()) {
        return question;
    }

    question.valid = true;
    question.name = name;
    question.qtype = Load16(payload + offset);
    question.questionEndOffset = offset + 4;
    return question;
}

const char *QuestionTypeName(uint16_t qtype)
{
    switch (qtype) {
        case 1:
            return "A";
        case 28:
            return "AAAA";
        case 5:
            return "CNAME";
        case 15:
            return "MX";
        default:
            return "OTHER";
    }
}

std::vector<uint8_t> BuildBlockedDnsResponse(const uint8_t *query, size_t len, const DnsQuestion &question)
{
    if (len < question.questionEndOffset) {
        return {};
    }

    std::vector<uint8_t> out;
    out.reserve(len + 32);
    out.insert(out.end(), query, query + 2);
    out.push_back(0x81);
    out.push_back(0x80);
    out.push_back(0x00);
    out.push_back(0x01);

    const bool synthesizeAddress = question.qtype == 1 || question.qtype == 28;
    out.push_back(0x00);
    out.push_back(synthesizeAddress ? 0x01 : 0x00);
    out.push_back(0x00);
    out.push_back(0x00);
    out.push_back(0x00);
    out.push_back(0x00);

    out.insert(out.end(), query + 12, query + question.questionEndOffset);

    if (!synthesizeAddress) {
        return out;
    }

    out.push_back(0xC0);
    out.push_back(0x0C);
    out.push_back(static_cast<uint8_t>((question.qtype >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(question.qtype & 0xFF));
    out.push_back(0x00);
    out.push_back(0x01);
    out.push_back(0x00);
    out.push_back(0x00);
    out.push_back(0x00);
    out.push_back(0x3C);

    if (question.qtype == 1) {
        out.push_back(0x00);
        out.push_back(0x04);
        out.push_back(0x00);
        out.push_back(0x00);
        out.push_back(0x00);
        out.push_back(0x00);
    } else {
        out.push_back(0x00);
        out.push_back(0x10);
        for (int i = 0; i < 16; ++i) {
            out.push_back(0x00);
        }
    }

    return out;
}

std::string BuildDnsCacheKey(const DnsQuestion &question)
{
    return question.name + "|" + std::to_string(question.qtype);
}

void PruneExpiredDnsCacheLocked(StatsState &state, int64_t nowMs)
{
    for (auto it = state.dnsResponseCache.begin(); it != state.dnsResponseCache.end();) {
        if (it->second.expiresAtMs <= nowMs) {
            it = state.dnsResponseCache.erase(it);
        } else {
            ++it;
        }
    }
}

std::vector<uint8_t> CloneCachedDnsResponseForQuery(const std::vector<uint8_t> &cachedResponse, const uint8_t *query,
    size_t queryLen)
{
    if (cachedResponse.size() < 2 || query == nullptr || queryLen < 2) {
        return {};
    }

    std::vector<uint8_t> response = cachedResponse;
    response[0] = query[0];
    response[1] = query[1];
    return response;
}

bool TryGetCachedDnsResponse(const DnsQuestion &question, const uint8_t *query, size_t queryLen,
    std::vector<uint8_t> &response)
{
    const int64_t nowMs = NowMs();
    std::lock_guard<std::mutex> lock(g_state.mu);
    if (g_state.dnsCacheTtlSeconds == 0) {
        return false;
    }

    PruneExpiredDnsCacheLocked(g_state, nowMs);
    const auto entry = g_state.dnsResponseCache.find(BuildDnsCacheKey(question));
    if (entry == g_state.dnsResponseCache.end()) {
        return false;
    }

    response = CloneCachedDnsResponseForQuery(entry->second.response, query, queryLen);
    return !response.empty();
}

void StoreDnsResponseCache(const DnsQuestion &question, const std::vector<uint8_t> &response)
{
    if (response.size() < 2) {
        return;
    }

    const int64_t nowMs = NowMs();
    std::lock_guard<std::mutex> lock(g_state.mu);
    if (g_state.dnsCacheTtlSeconds == 0) {
        return;
    }

    PruneExpiredDnsCacheLocked(g_state, nowMs);
    g_state.dnsResponseCache[BuildDnsCacheKey(question)] = {response,
        nowMs + static_cast<int64_t>(g_state.dnsCacheTtlSeconds) * 1000};
}

// Split a raw upstream string (comma / whitespace / newline separated) into an
// ordered, de-duplicated list of upstream resolvers.
std::vector<std::string> ParseUpstreamList(const std::string &raw)
{
    std::vector<std::string> entries;
    std::string current;
    for (char ch : raw) {
        if (ch == ',' || ch == ';' || ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
            if (!current.empty()) {
                entries.push_back(current);
                current.clear();
            }
        } else {
            current.push_back(ch);
        }
    }
    if (!current.empty()) {
        entries.push_back(current);
    }

    std::vector<std::string> deduped;
    for (const std::string &entry : entries) {
        if (std::find(deduped.begin(), deduped.end(), entry) == deduped.end()) {
            deduped.push_back(entry);
        }
    }
    return deduped;
}

// Resolve a query against a single upstream over UDP.
std::vector<uint8_t> ForwardDnsQueryOne(const uint8_t *query, size_t len, const std::string &upstreamDnsIp,
    uint16_t port, std::string &error)
{
    std::vector<uint8_t> response;
    if (upstreamDnsIp.empty()) {
        error = "upstream DNS is empty";
        return response;
    }

    const bool isIpv6 = upstreamDnsIp.find(':') != std::string::npos;
    int sock = socket(isIpv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        error = std::string("create upstream socket failed: ") + std::strerror(errno);
        return response;
    }

    timeval timeout {};
    timeout.tv_sec = kUpstreamTimeoutSec;
    timeout.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    // Connect the UDP socket so only datagrams from the chosen upstream are
    // delivered; combined with the fresh ephemeral port this keeps responses
    // from leaking across concurrent queries handled by other workers.
    if (isIpv6) {
        sockaddr_in6 addr {};
        addr.sin6_family = AF_INET6;
        addr.sin6_port = htons(port);
        if (inet_pton(AF_INET6, upstreamDnsIp.c_str(), &addr.sin6_addr) != 1) {
            close(sock);
            error = "invalid upstream DNS ip";
            return response;
        }
        if (connect(sock, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
            error = std::string("connect upstream failed: ") + std::strerror(errno);
            close(sock);
            return response;
        }
    } else {
        sockaddr_in addr {};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        if (inet_pton(AF_INET, upstreamDnsIp.c_str(), &addr.sin_addr) != 1) {
            close(sock);
            error = "invalid upstream DNS ip";
            return response;
        }
        if (connect(sock, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
            error = std::string("connect upstream failed: ") + std::strerror(errno);
            close(sock);
            return response;
        }
    }

    const uint16_t txnId = len >= 2 ? Load16(query) : 0;
    for (int attempt = 0; attempt < kUpstreamAttempts; ++attempt) {
        if (send(sock, query, len, 0) < 0) {
            error = std::string("send upstream failed: ") + std::strerror(errno);
            break;
        }

        uint8_t buffer[2048];
        const ssize_t received = recv(sock, buffer, sizeof(buffer), 0);
        if (received > 0) {
            if (txnId != 0 && received >= 2 && Load16(buffer) != txnId) {
                error = "upstream response id mismatch";
                break;
            }
            error.clear();
            response.assign(buffer, buffer + received);
            break;
        }
        if (received == 0) {
            error = "upstream closed connection";
            break;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            error = "upstream timeout";
            continue;  // retry once more
        }
        error = std::string("recv upstream failed: ") + std::strerror(errno);
        break;
    }

    close(sock);
    return response;
}

// Resolve over UDP, failing over to each upstream in order until one answers.
// Returns the first non-empty response, or empty if every upstream failed.
std::vector<uint8_t> ForwardDnsQuery(const uint8_t *query, size_t len, const std::vector<std::string> &upstreams,
    uint16_t port, std::string &error)
{
    if (upstreams.empty()) {
        error = "no upstream DNS configured";
        return {};
    }
    std::vector<uint8_t> response;
    for (const std::string &upstream : upstreams) {
        std::string attemptError;
        response = ForwardDnsQueryOne(query, len, upstream, port, attemptError);
        if (!response.empty()) {
            error.clear();
            return response;
        }
        error = attemptError;
    }
    return response;
}

std::vector<uint8_t> BuildIpv4UdpResponse(const Ipv4UdpPacketView &request, const std::vector<uint8_t> &dnsPayload)
{
    const size_t packetLen = 20 + 8 + dnsPayload.size();
    std::vector<uint8_t> out(packetLen, 0);
    out[0] = 0x45;
    out[1] = 0x00;
    Store16(&out[2], static_cast<uint16_t>(packetLen));
    Store16(&out[4], request.identification);
    Store16(&out[6], 0x0000);
    out[8] = 64;
    out[9] = 17;
    Store32(&out[12], request.dstAddr);
    Store32(&out[16], request.srcAddr);
    const uint16_t ipChecksum = InternetChecksum(out.data(), 20);
    Store16(&out[10], ipChecksum);

    uint8_t *udp = out.data() + 20;
    Store16(udp, request.dstPort);
    Store16(udp + 2, request.srcPort);
    Store16(udp + 4, static_cast<uint16_t>(8 + dnsPayload.size()));
    Store16(udp + 6, 0);
    std::memcpy(udp + 8, dnsPayload.data(), dnsPayload.size());
    return out;
}

uint16_t ChecksumFold(uint32_t sum)
{
    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFFU) + (sum >> 16);
    }
    return static_cast<uint16_t>(~sum);
}

uint16_t UdpChecksumIpv6(const std::array<uint8_t, 16> &src, const std::array<uint8_t, 16> &dst,
    const uint8_t *udp, size_t udpLen)
{
    uint32_t sum = 0;
    for (size_t i = 0; i < 16; i += 2) {
        sum += static_cast<uint16_t>((src[i] << 8) | src[i + 1]);
        sum += static_cast<uint16_t>((dst[i] << 8) | dst[i + 1]);
    }
    sum += static_cast<uint16_t>((udpLen >> 16) & 0xFFFFU);
    sum += static_cast<uint16_t>(udpLen & 0xFFFFU);
    sum += 17U;
    size_t i = 0;
    while (i + 1 < udpLen) {
        sum += static_cast<uint16_t>((udp[i] << 8) | udp[i + 1]);
        i += 2;
    }
    if (i < udpLen) {
        sum += static_cast<uint16_t>(udp[i] << 8);
    }
    return ChecksumFold(sum);
}

std::vector<uint8_t> BuildIpv6UdpResponse(const Ipv6UdpPacketView &request, const std::vector<uint8_t> &dnsPayload)
{
    const size_t udpLen = 8 + dnsPayload.size();
    const size_t packetLen = 40 + udpLen;
    std::vector<uint8_t> out(packetLen, 0);
    out[0] = 0x60;
    Store16(&out[4], static_cast<uint16_t>(udpLen));
    out[6] = 17;
    out[7] = 64;
    std::memcpy(out.data() + 8, request.dstAddr.data(), 16);
    std::memcpy(out.data() + 24, request.srcAddr.data(), 16);

    uint8_t *udp = out.data() + 40;
    Store16(udp, request.dstPort);
    Store16(udp + 2, request.srcPort);
    Store16(udp + 4, static_cast<uint16_t>(udpLen));
    Store16(udp + 6, 0);
    std::memcpy(udp + 8, dnsPayload.data(), dnsPayload.size());
    const uint16_t checksum = UdpChecksumIpv6(request.dstAddr, request.srcAddr, udp, udpLen);
    Store16(udp + 6, checksum == 0 ? 0xFFFFU : checksum);
    return out;
}

bool WriteAll(int fd, const uint8_t *data, size_t len, std::string &error)
{
    size_t offset = 0;
    while (offset < len) {
        const ssize_t n = write(fd, data + offset, len - offset);
        if (n > 0) {
            offset += static_cast<size_t>(n);
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }
        error = std::string("write tun response failed: ") + std::strerror(errno);
        return false;
    }
    return true;
}

void UpdatePacketStatsLocked(StatsState &state, const uint8_t *packet, ssize_t len)
{
    state.totalPackets++;
    state.totalBytes += static_cast<uint64_t>(len);

    if (len <= 0) {
        return;
    }

    const uint8_t version = packet[0] >> 4;
    if (version == 4) {
        state.ipv4Packets++;
        if (len < 20) {
            return;
        }
        const size_t ipHeaderLen = static_cast<size_t>(packet[0] & 0x0FU) * 4;
        if (ipHeaderLen < 20 || len < static_cast<ssize_t>(ipHeaderLen + 4)) {
            return;
        }
        const uint8_t protocol = packet[9];
        const uint8_t *l4 = packet + ipHeaderLen;
        const uint16_t srcPort = Load16(l4);
        const uint16_t dstPort = Load16(l4 + 2);
        if (protocol == 6) {
            state.tcpPackets++;
        } else if (protocol == 17) {
            state.udpPackets++;
        }
        if (srcPort == 53 || dstPort == 53) {
            state.dnsPackets++;
        }
        return;
    }

    if (version == 6) {
        state.ipv6Packets++;
        if (len < 44) {
            return;
        }
        const uint8_t nextHeader = packet[6];
        const uint8_t *l4 = packet + 40;
        const uint16_t srcPort = Load16(l4);
        const uint16_t dstPort = Load16(l4 + 2);
        if (nextHeader == 6) {
            state.tcpPackets++;
        } else if (nextHeader == 17) {
            state.udpPackets++;
        }
        if (srcPort == 53 || dstPort == 53) {
            state.dnsPackets++;
        }
    }
}

void LogDnsEvent(const std::string &path, const std::string &domain, uint16_t qtype, bool blocked,
    const std::string &rule, const std::string &source, size_t requestBytes, size_t responseBytes)
{
    // An empty path means this mode keeps no app-side jsonl (full mode: the
    // embedded AdGuardHome querylog is the single source of truth, so writing a
    // second per-query file here would just burn battery).
    if (!path.empty()) {
        std::ostringstream out;
        out << '{'
            << "\"ts\":" << NowMs() << ','
            << "\"domain\":\"" << EscapeJson(domain) << "\","
            << "\"qtype\":\"" << QuestionTypeName(qtype) << "\","
            << "\"action\":\"" << (blocked ? "blocked" : "allowed") << "\","
            << "\"rule\":\"" << EscapeJson(rule) << "\","
            << "\"source\":\"" << EscapeJson(source) << "\","
            << "\"requestBytes\":" << requestBytes << ','
            << "\"responseBytes\":" << responseBytes << ','
            << "\"totalDnsBytes\":" << (requestBytes + responseBytes)
            << '}';
        AppendTextLine(path, out.str());
    }
    if (g_verboseLog.load(std::memory_order_relaxed)) {
        LogInfo("==/vpn_native/dns/ domain=%{public}s qtype=%{public}s action=%{public}s source=%{public}s rule=%{public}s req=%{public}zu resp=%{public}zu",
            domain.c_str(), QuestionTypeName(qtype), blocked ? "blocked" : "allowed", source.c_str(), rule.c_str(),
            requestBytes, responseBytes);
    }
}

// Resolve a filtered-through query upstream (or from cache) and write the
// response back to the TUN device. Runs on a forward worker thread.
void ProcessForwardTask(ForwardTask &task)
{
    std::vector<uint8_t> dnsResponse;
    std::string source = "upstream";
    std::string responseError;

    // In full mode the embedded AdGuardHome owns caching, so the C++ cache is
    // bypassed to keep every query visible to AGH (accurate filtering/stats).
    const bool cacheHit = task.useCache &&
        TryGetCachedDnsResponse(task.question, task.query.data(), task.query.size(), dnsResponse);
    if (task.useCache) {
        std::lock_guard<std::mutex> lock(g_state.mu);
        if (cacheHit) {
            g_state.dnsCacheHits++;
        } else {
            g_state.dnsCacheMisses++;
        }
    }

    if (cacheHit) {
        source = "cache";
    } else {
        dnsResponse = ForwardDnsQuery(task.query.data(), task.query.size(), task.upstreams, task.upstreamPort,
            responseError);
        if (task.useCache && !dnsResponse.empty()) {
            StoreDnsResponseCache(task.question, dnsResponse);
        }
    }

    if (dnsResponse.empty()) {
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.lastError = responseError;
        LogError("==/vpn_native/dns_error/ domain=%{public}s err=%{public}s", task.question.name.c_str(),
            responseError.c_str());
        return;
    }

    const std::vector<uint8_t> responsePacket = task.isIpv6
        ? BuildIpv6UdpResponse(task.view6, dnsResponse)
        : BuildIpv4UdpResponse(task.view4, dnsResponse);
    std::string writeError;
    bool written = false;
    {
        std::lock_guard<std::mutex> writeLock(g_tunWriteMu);
        written = WriteAll(task.tunFd, responsePacket.data(), responsePacket.size(), writeError);
    }
    if (!written) {
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.lastError = writeError;
        LogError("==/vpn_native/write_error/ domain=%{public}s err=%{public}s", task.question.name.c_str(),
            writeError.c_str());
        return;
    }

    LogDnsEvent(task.queryLogPath, task.question.name, task.question.qtype, false, task.matchedRule, source,
        task.query.size(), dnsResponse.size());
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.lastQueryDomain = task.question.name;
        g_state.lastMatchedRule = task.matchedRule;
        g_state.loggedQueries++;
        g_state.allowedQueries++;
    }
}

void ForwardWorkerLoop()
{
    for (;;) {
        ForwardTask task;
        {
            std::unique_lock<std::mutex> lock(g_pool.mu);
            g_pool.cv.wait(lock, [] { return g_pool.stopRequested || !g_pool.tasks.empty(); });
            if (g_pool.stopRequested) {
                break;
            }
            task = std::move(g_pool.tasks.front());
            g_pool.tasks.pop_front();
        }
        ProcessForwardTask(task);
    }
}

void EnqueueForwardTask(ForwardTask &&task)
{
    std::lock_guard<std::mutex> lock(g_pool.mu);
    if (!g_pool.running) {
        return;
    }
    if (g_pool.tasks.size() >= kMaxQueuedForwardTasks) {
        // Bound memory under a flood: drop the oldest pending query (the client
        // will retry) rather than grow without limit.
        g_pool.tasks.pop_front();
    }
    g_pool.tasks.push_back(std::move(task));
    g_pool.cv.notify_one();
}

void StartForwardPool()
{
    std::lock_guard<std::mutex> lock(g_pool.mu);
    g_pool.stopRequested = false;
    g_pool.running = true;
    g_pool.tasks.clear();
    g_pool.workers.clear();
    for (int i = 0; i < kForwardWorkerCount; ++i) {
        g_pool.workers.emplace_back(ForwardWorkerLoop);
    }
}

void StopForwardPool()
{
    std::vector<std::thread> workers;
    {
        std::lock_guard<std::mutex> lock(g_pool.mu);
        g_pool.stopRequested = true;
        g_pool.running = false;
        g_pool.tasks.clear();
        workers = std::move(g_pool.workers);
        g_pool.workers.clear();
    }
    g_pool.cv.notify_all();
    for (std::thread &worker : workers) {
        if (worker.joinable()) {
            worker.join();
        }
    }
}

// ---------------------------------------------------------------------------
// DNS-over-TCP (RFC 7766) support.
//
// The TUN hands us raw IP packets, so to answer a client that opens a TCP
// connection to our DNS server we have to terminate a minimal TCP endpoint
// ourselves: complete the handshake, acknowledge data, reassemble the
// length-prefixed DNS message, resolve it (upstream over TCP for a full,
// untruncated answer), stream the response back, and tear the connection down.
//
// All of this runs on the single reader thread, so the connection table needs
// no locking. TCP DNS is an uncommon fallback (resolvers prefer UDP), so the
// brief synchronous upstream round-trip here is an acceptable trade for the
// large reduction in concurrency complexity. If TCP volume ever grows enough to
// stall UDP, the upstream fetch can be moved onto the forward worker pool.
// ---------------------------------------------------------------------------

constexpr int64_t kTcpConnIdleMs = 30000;
constexpr size_t kMaxTcpConns = 256;
constexpr uint8_t kTcpFin = 0x01;
constexpr uint8_t kTcpSyn = 0x02;
constexpr uint8_t kTcpRst = 0x04;
constexpr uint8_t kTcpPsh = 0x08;
constexpr uint8_t kTcpAck = 0x10;

uint32_t Load32(const uint8_t *p)
{
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16)
        | (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}

// 32-bit serial-number comparison (RFC 1982): true if a is "before" b.
bool SeqLt(uint32_t a, uint32_t b)
{
    return static_cast<int32_t>(a - b) < 0;
}

uint16_t ParseTcpMss(const uint8_t *tcp, size_t dataOffset)
{
    size_t i = 20;
    while (i + 1 < dataOffset) {
        const uint8_t kind = tcp[i];
        if (kind == 0) {
            break;
        }
        if (kind == 1) {
            i += 1;
            continue;
        }
        const uint8_t optLen = tcp[i + 1];
        if (optLen < 2 || i + optLen > dataOffset) {
            break;
        }
        if (kind == 2 && optLen == 4) {
            return Load16(tcp + i + 2);
        }
        i += optLen;
    }
    return 0;
}

struct TcpSegmentView {
    bool valid = false;
    bool isIpv6 = false;
    uint32_t srcAddr4 = 0;
    uint32_t dstAddr4 = 0;
    std::array<uint8_t, 16> srcAddr6 {};
    std::array<uint8_t, 16> dstAddr6 {};
    uint16_t srcPort = 0;
    uint16_t dstPort = 0;
    uint32_t seq = 0;
    uint32_t ack = 0;
    uint8_t flags = 0;
    uint16_t mss = 0;
    const uint8_t *payload = nullptr;
    size_t payloadLen = 0;
};

TcpSegmentView ParseTcpSegment(const uint8_t *packet, size_t len)
{
    TcpSegmentView view;
    if (len < 1) {
        return view;
    }
    const uint8_t version = packet[0] >> 4;
    if (version == 4) {
        if (len < 20) {
            return view;
        }
        const size_t ipHeaderLen = static_cast<size_t>(packet[0] & 0x0FU) * 4;
        if (ipHeaderLen < 20 || len < ipHeaderLen + 20 || packet[9] != 6) {
            return view;
        }
        const uint16_t totalLen = Load16(packet + 2);
        const size_t packetLen = totalLen > 0 && totalLen <= len ? totalLen : len;
        const uint8_t *tcp = packet + ipHeaderLen;
        const size_t dataOffset = static_cast<size_t>(tcp[12] >> 4) * 4;
        if (dataOffset < 20 || ipHeaderLen + dataOffset > packetLen) {
            return view;
        }
        view.valid = true;
        view.srcAddr4 = Load32(packet + 12);
        view.dstAddr4 = Load32(packet + 16);
        view.srcPort = Load16(tcp);
        view.dstPort = Load16(tcp + 2);
        view.seq = Load32(tcp + 4);
        view.ack = Load32(tcp + 8);
        view.flags = tcp[13];
        view.payload = tcp + dataOffset;
        view.payloadLen = packetLen - ipHeaderLen - dataOffset;
        if (view.flags & kTcpSyn) {
            view.mss = ParseTcpMss(tcp, dataOffset);
        }
        return view;
    }
    if (version == 6) {
        if (len < 60 || packet[6] != 6) {
            return view;
        }
        const uint16_t payloadLen = Load16(packet + 4);
        if (payloadLen < 20 || len < static_cast<size_t>(40) + payloadLen) {
            return view;
        }
        const uint8_t *tcp = packet + 40;
        const size_t dataOffset = static_cast<size_t>(tcp[12] >> 4) * 4;
        if (dataOffset < 20 || dataOffset > payloadLen) {
            return view;
        }
        view.valid = true;
        view.isIpv6 = true;
        std::memcpy(view.srcAddr6.data(), packet + 8, 16);
        std::memcpy(view.dstAddr6.data(), packet + 24, 16);
        view.srcPort = Load16(tcp);
        view.dstPort = Load16(tcp + 2);
        view.seq = Load32(tcp + 4);
        view.ack = Load32(tcp + 8);
        view.flags = tcp[13];
        view.payload = tcp + dataOffset;
        view.payloadLen = payloadLen - dataOffset;
        if (view.flags & kTcpSyn) {
            view.mss = ParseTcpMss(tcp, dataOffset);
        }
        return view;
    }
    return view;
}

struct TcpConn {
    bool isIpv6 = false;
    uint32_t cliAddr4 = 0;
    uint32_t srvAddr4 = 0;
    std::array<uint8_t, 16> cliAddr6 {};
    std::array<uint8_t, 16> srvAddr6 {};
    uint16_t cliPort = 0;
    uint16_t srvPort = 0;
    uint32_t sndNxt = 0;
    uint32_t rcvNxt = 0;
    uint16_t cliMss = 536;
    bool established = false;
    bool clientFin = false;
    bool ourFin = false;
    std::vector<uint8_t> inbound;
    int64_t lastActiveMs = 0;
};

// Reader-thread-only; no mutex required.
std::unordered_map<std::string, TcpConn> g_tcpConns;

std::string BuildTcpKey(const TcpSegmentView &v)
{
    std::string key;
    key.reserve(24);
    key.push_back(v.isIpv6 ? '6' : '4');
    if (v.isIpv6) {
        key.append(reinterpret_cast<const char *>(v.srcAddr6.data()), 16);
    } else {
        uint8_t addr[4];
        Store32(addr, v.srcAddr4);
        key.append(reinterpret_cast<const char *>(addr), 4);
    }
    uint8_t ports[4];
    Store16(ports, v.srcPort);
    Store16(ports + 2, v.dstPort);
    key.append(reinterpret_cast<const char *>(ports), 4);
    return key;
}

uint32_t NextTcpIsn()
{
    static uint32_t counter = 0;
    counter += 0x9E3779B9U;
    return static_cast<uint32_t>(NowMs()) + counter;
}

void PruneIdleTcpConns(int64_t nowMs)
{
    for (auto it = g_tcpConns.begin(); it != g_tcpConns.end();) {
        if (nowMs - it->second.lastActiveMs > kTcpConnIdleMs) {
            it = g_tcpConns.erase(it);
        } else {
            ++it;
        }
    }
    if (g_tcpConns.size() > kMaxTcpConns) {
        auto oldest = g_tcpConns.begin();
        for (auto it = g_tcpConns.begin(); it != g_tcpConns.end(); ++it) {
            if (it->second.lastActiveMs < oldest->second.lastActiveMs) {
                oldest = it;
            }
        }
        g_tcpConns.erase(oldest);
    }
}

uint16_t TcpChecksum4(uint32_t src, uint32_t dst, const uint8_t *tcp, size_t tcpLen)
{
    uint32_t sum = 0;
    sum += (src >> 16) & 0xFFFFU;
    sum += src & 0xFFFFU;
    sum += (dst >> 16) & 0xFFFFU;
    sum += dst & 0xFFFFU;
    sum += 6U;
    sum += static_cast<uint16_t>(tcpLen);
    size_t i = 0;
    while (i + 1 < tcpLen) {
        sum += static_cast<uint16_t>((tcp[i] << 8) | tcp[i + 1]);
        i += 2;
    }
    if (i < tcpLen) {
        sum += static_cast<uint16_t>(tcp[i] << 8);
    }
    return ChecksumFold(sum);
}

uint16_t TcpChecksum6(const std::array<uint8_t, 16> &src, const std::array<uint8_t, 16> &dst,
    const uint8_t *tcp, size_t tcpLen)
{
    uint32_t sum = 0;
    for (size_t i = 0; i < 16; i += 2) {
        sum += static_cast<uint16_t>((src[i] << 8) | src[i + 1]);
        sum += static_cast<uint16_t>((dst[i] << 8) | dst[i + 1]);
    }
    sum += static_cast<uint16_t>((tcpLen >> 16) & 0xFFFFU);
    sum += static_cast<uint16_t>(tcpLen & 0xFFFFU);
    sum += 6U;
    size_t i = 0;
    while (i + 1 < tcpLen) {
        sum += static_cast<uint16_t>((tcp[i] << 8) | tcp[i + 1]);
        i += 2;
    }
    if (i < tcpLen) {
        sum += static_cast<uint16_t>(tcp[i] << 8);
    }
    return ChecksumFold(sum);
}

std::vector<uint8_t> BuildIpv4TcpSeg(const TcpConn &c, uint8_t flags, uint32_t seq, uint32_t ack,
    const uint8_t *payload, size_t payloadLen, bool withMss)
{
    const size_t tcpHeaderLen = withMss ? 24 : 20;
    const size_t tcpLen = tcpHeaderLen + payloadLen;
    const size_t totalLen = 20 + tcpLen;
    std::vector<uint8_t> out(totalLen, 0);
    out[0] = 0x45;
    Store16(&out[2], static_cast<uint16_t>(totalLen));
    Store16(&out[6], 0x4000);
    out[8] = 64;
    out[9] = 6;
    Store32(&out[12], c.srvAddr4);
    Store32(&out[16], c.cliAddr4);
    Store16(&out[10], InternetChecksum(out.data(), 20));

    uint8_t *t = out.data() + 20;
    Store16(t, c.srvPort);
    Store16(t + 2, c.cliPort);
    Store32(t + 4, seq);
    Store32(t + 8, ack);
    t[12] = static_cast<uint8_t>((tcpHeaderLen / 4) << 4);
    t[13] = flags;
    Store16(t + 14, 65535);
    if (withMss) {
        t[20] = 2;
        t[21] = 4;
        Store16(t + 22, 1400 - 40);
    }
    if (payloadLen > 0) {
        std::memcpy(t + tcpHeaderLen, payload, payloadLen);
    }
    Store16(t + 16, TcpChecksum4(c.srvAddr4, c.cliAddr4, t, tcpLen));
    return out;
}

std::vector<uint8_t> BuildIpv6TcpSeg(const TcpConn &c, uint8_t flags, uint32_t seq, uint32_t ack,
    const uint8_t *payload, size_t payloadLen, bool withMss)
{
    const size_t tcpHeaderLen = withMss ? 24 : 20;
    const size_t tcpLen = tcpHeaderLen + payloadLen;
    const size_t totalLen = 40 + tcpLen;
    std::vector<uint8_t> out(totalLen, 0);
    out[0] = 0x60;
    Store16(&out[4], static_cast<uint16_t>(tcpLen));
    out[6] = 6;
    out[7] = 64;
    std::memcpy(out.data() + 8, c.srvAddr6.data(), 16);
    std::memcpy(out.data() + 24, c.cliAddr6.data(), 16);

    uint8_t *t = out.data() + 40;
    Store16(t, c.srvPort);
    Store16(t + 2, c.cliPort);
    Store32(t + 4, seq);
    Store32(t + 8, ack);
    t[12] = static_cast<uint8_t>((tcpHeaderLen / 4) << 4);
    t[13] = flags;
    Store16(t + 14, 65535);
    if (withMss) {
        t[20] = 2;
        t[21] = 4;
        Store16(t + 22, 1400 - 60);
    }
    if (payloadLen > 0) {
        std::memcpy(t + tcpHeaderLen, payload, payloadLen);
    }
    Store16(t + 16, TcpChecksum6(c.srvAddr6, c.cliAddr6, t, tcpLen));
    return out;
}

void SendTcpSeg(int tunFd, TcpConn &c, uint8_t flags, const uint8_t *payload, size_t payloadLen, bool withMss)
{
    const std::vector<uint8_t> pkt = c.isIpv6
        ? BuildIpv6TcpSeg(c, flags, c.sndNxt, c.rcvNxt, payload, payloadLen, withMss)
        : BuildIpv4TcpSeg(c, flags, c.sndNxt, c.rcvNxt, payload, payloadLen, withMss);
    std::string writeError;
    {
        std::lock_guard<std::mutex> writeLock(g_tunWriteMu);
        WriteAll(tunFd, pkt.data(), pkt.size(), writeError);
    }
    uint32_t advance = static_cast<uint32_t>(payloadLen);
    if (flags & kTcpSyn) {
        advance += 1;
    }
    if (flags & kTcpFin) {
        advance += 1;
    }
    c.sndNxt += advance;
}

// Resolve a query against a single upstream over TCP (full, untruncated answer).
std::vector<uint8_t> ForwardDnsQueryTcpOne(const uint8_t *query, size_t len, const std::string &upstreamDnsIp,
    uint16_t port, std::string &error)
{
    std::vector<uint8_t> response;
    if (upstreamDnsIp.empty()) {
        error = "upstream DNS is empty";
        return response;
    }

    const bool isIpv6 = upstreamDnsIp.find(':') != std::string::npos;
    int sock = socket(isIpv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        error = std::string("create upstream tcp socket failed: ") + std::strerror(errno);
        return response;
    }

    sockaddr_in addr4 {};
    sockaddr_in6 addr6 {};
    sockaddr *addr = nullptr;
    socklen_t addrLen = 0;
    if (isIpv6) {
        addr6.sin6_family = AF_INET6;
        addr6.sin6_port = htons(port);
        if (inet_pton(AF_INET6, upstreamDnsIp.c_str(), &addr6.sin6_addr) != 1) {
            close(sock);
            error = "invalid upstream DNS ip";
            return response;
        }
        addr = reinterpret_cast<sockaddr *>(&addr6);
        addrLen = sizeof(addr6);
    } else {
        addr4.sin_family = AF_INET;
        addr4.sin_port = htons(port);
        if (inet_pton(AF_INET, upstreamDnsIp.c_str(), &addr4.sin_addr) != 1) {
            close(sock);
            error = "invalid upstream DNS ip";
            return response;
        }
        addr = reinterpret_cast<sockaddr *>(&addr4);
        addrLen = sizeof(addr4);
    }

    // Non-blocking connect with a bounded timeout so a dead upstream can't hang
    // the reader thread beyond kUpstreamTimeoutSec.
    const int origFlags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, origFlags | O_NONBLOCK);
    const int rc = connect(sock, addr, addrLen);
    if (rc < 0 && errno == EINPROGRESS) {
        pollfd pfd {};
        pfd.fd = sock;
        pfd.events = POLLOUT;
        const int pr = poll(&pfd, 1, kUpstreamTimeoutSec * 1000);
        if (pr <= 0) {
            error = "upstream tcp connect timeout";
            close(sock);
            return response;
        }
        int soErr = 0;
        socklen_t soLen = sizeof(soErr);
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &soErr, &soLen);
        if (soErr != 0) {
            error = std::string("upstream tcp connect failed: ") + std::strerror(soErr);
            close(sock);
            return response;
        }
    } else if (rc < 0) {
        error = std::string("upstream tcp connect failed: ") + std::strerror(errno);
        close(sock);
        return response;
    }
    fcntl(sock, F_SETFL, origFlags);

    timeval timeout {};
    timeout.tv_sec = kUpstreamTimeoutSec;
    timeout.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    std::vector<uint8_t> framed;
    framed.reserve(len + 2);
    framed.push_back(static_cast<uint8_t>((len >> 8) & 0xFF));
    framed.push_back(static_cast<uint8_t>(len & 0xFF));
    framed.insert(framed.end(), query, query + len);
    size_t sentOff = 0;
    while (sentOff < framed.size()) {
        const ssize_t n = send(sock, framed.data() + sentOff, framed.size() - sentOff, 0);
        if (n <= 0) {
            error = std::string("send tcp upstream failed: ") + std::strerror(errno);
            close(sock);
            return response;
        }
        sentOff += static_cast<size_t>(n);
    }

    uint8_t lenBuf[2];
    size_t got = 0;
    while (got < 2) {
        const ssize_t n = recv(sock, lenBuf + got, 2 - got, 0);
        if (n <= 0) {
            error = "recv tcp upstream length failed";
            close(sock);
            return response;
        }
        got += static_cast<size_t>(n);
    }
    const uint16_t respLen = static_cast<uint16_t>((lenBuf[0] << 8) | lenBuf[1]);
    if (respLen == 0) {
        error = "empty tcp upstream response";
        close(sock);
        return response;
    }

    response.resize(respLen);
    got = 0;
    while (got < respLen) {
        const ssize_t n = recv(sock, response.data() + got, respLen - got, 0);
        if (n <= 0) {
            error = "recv tcp upstream body failed";
            close(sock);
            response.clear();
            return response;
        }
        got += static_cast<size_t>(n);
    }
    close(sock);
    error.clear();
    return response;
}

// Resolve over TCP, failing over to each upstream in order until one answers.
std::vector<uint8_t> ForwardDnsQueryTcp(const uint8_t *query, size_t len, const std::vector<std::string> &upstreams,
    uint16_t port, std::string &error)
{
    if (upstreams.empty()) {
        error = "no upstream DNS configured";
        return {};
    }
    std::vector<uint8_t> response;
    for (const std::string &upstream : upstreams) {
        std::string attemptError;
        response = ForwardDnsQueryTcpOne(query, len, upstream, port, attemptError);
        if (!response.empty()) {
            error.clear();
            return response;
        }
        error = attemptError;
    }
    return response;
}

void SendTcpDnsResponse(int tunFd, TcpConn &c, const std::vector<uint8_t> &dnsResponse)
{
    std::vector<uint8_t> stream;
    stream.reserve(dnsResponse.size() + 2);
    stream.push_back(static_cast<uint8_t>((dnsResponse.size() >> 8) & 0xFF));
    stream.push_back(static_cast<uint8_t>(dnsResponse.size() & 0xFF));
    stream.insert(stream.end(), dnsResponse.begin(), dnsResponse.end());

    const size_t pathMax = c.isIpv6 ? static_cast<size_t>(1400 - 60) : static_cast<size_t>(1400 - 40);
    size_t maxSeg = c.cliMss > 0 ? std::min<size_t>(c.cliMss, pathMax) : pathMax;
    if (maxSeg == 0) {
        maxSeg = 536;
    }
    size_t off = 0;
    while (off < stream.size()) {
        const size_t chunk = std::min(maxSeg, stream.size() - off);
        const bool last = off + chunk >= stream.size();
        const uint8_t flags = static_cast<uint8_t>(kTcpAck | (last ? kTcpPsh : 0));
        SendTcpSeg(tunFd, c, flags, stream.data() + off, chunk, false);
        off += chunk;
    }
}

void HandleTcpDnsQuery(int tunFd, TcpConn &c, const std::vector<uint8_t> &message)
{
    const DnsQuestion question = ParseDnsQuestion(message.data(), message.size());
    if (!question.valid) {
        return;
    }

    std::shared_ptr<const std::vector<RuleEntry>> rules;
    std::string queryLogPath;
    std::vector<std::string> upstreams;
    bool fullMode = false;
    uint16_t aghDnsPort = 0;
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        rules = g_state.activeRules;
        queryLogPath = g_state.queryLogPath;
        upstreams = g_state.upstreamDnsIps;
        fullMode = g_state.fullMode;
        aghDnsPort = g_state.aghDnsPort;
    }

    // Full mode forwards everything to the embedded AdGuardHome engine (which
    // performs all matching); lightweight mode matches locally and may block.
    const MatchResult match = (!fullMode && rules)
        ? MatchDomain(question.name, question.qtype, *rules)
        : MatchResult {};
    const std::vector<std::string> tcpUpstreams = fullMode ? std::vector<std::string>{"127.0.0.1"} : upstreams;
    const uint16_t tcpPort = fullMode ? aghDnsPort : static_cast<uint16_t>(53);
    const bool useCache = !fullMode;

    std::vector<uint8_t> dnsResponse;
    std::string source = "upstream";
    std::string responseError;
    if (match.blocked) {
        source = "blocked";
        dnsResponse = BuildBlockedDnsResponse(message.data(), message.size(), question);
    } else {
        const bool cacheHit = useCache &&
            TryGetCachedDnsResponse(question, message.data(), message.size(), dnsResponse);
        if (useCache) {
            std::lock_guard<std::mutex> lock(g_state.mu);
            if (cacheHit) {
                g_state.dnsCacheHits++;
            } else {
                g_state.dnsCacheMisses++;
            }
        }
        if (cacheHit) {
            source = "cache";
        } else {
            dnsResponse = ForwardDnsQueryTcp(message.data(), message.size(), tcpUpstreams, tcpPort, responseError);
            if (useCache && !dnsResponse.empty()) {
                StoreDnsResponseCache(question, dnsResponse);
            }
        }
    }

    if (dnsResponse.empty()) {
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.lastError = responseError;
        LogError("==/vpn_native/tcp_dns_error/ domain=%{public}s err=%{public}s", question.name.c_str(),
            responseError.c_str());
        return;
    }

    SendTcpDnsResponse(tunFd, c, dnsResponse);
    LogDnsEvent(queryLogPath, question.name, question.qtype, match.blocked, match.matchedRule, source,
        message.size(), dnsResponse.size());
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.lastQueryDomain = question.name;
        g_state.lastMatchedRule = match.matchedRule;
        g_state.loggedQueries++;
        if (match.blocked) {
            g_state.blockedQueries++;
        } else {
            g_state.allowedQueries++;
        }
    }
}

void ProcessTcpInbound(int tunFd, TcpConn &c)
{
    for (;;) {
        if (c.inbound.size() < 2) {
            return;
        }
        const uint16_t msgLen = static_cast<uint16_t>((c.inbound[0] << 8) | c.inbound[1]);
        if (msgLen == 0) {
            c.inbound.erase(c.inbound.begin(), c.inbound.begin() + 2);
            continue;
        }
        if (c.inbound.size() < static_cast<size_t>(msgLen) + 2) {
            return;
        }
        const std::vector<uint8_t> message(c.inbound.begin() + 2, c.inbound.begin() + 2 + msgLen);
        c.inbound.erase(c.inbound.begin(), c.inbound.begin() + 2 + msgLen);
        HandleTcpDnsQuery(tunFd, c, message);
    }
}

void HandleTcpPacket(int tunFd, const TcpSegmentView &v)
{
    const int64_t nowMs = NowMs();
    PruneIdleTcpConns(nowMs);

    const std::string key = BuildTcpKey(v);
    auto it = g_tcpConns.find(key);

    if (v.flags & kTcpRst) {
        if (it != g_tcpConns.end()) {
            g_tcpConns.erase(it);
        }
        return;
    }

    // New connection: reply to the SYN with SYN-ACK (advertising our MSS).
    if ((v.flags & kTcpSyn) && !(v.flags & kTcpAck)) {
        TcpConn conn;
        conn.isIpv6 = v.isIpv6;
        conn.cliAddr4 = v.srcAddr4;
        conn.srvAddr4 = v.dstAddr4;
        conn.cliAddr6 = v.srcAddr6;
        conn.srvAddr6 = v.dstAddr6;
        conn.cliPort = v.srcPort;
        conn.srvPort = v.dstPort;
        conn.rcvNxt = v.seq + 1;
        conn.sndNxt = NextTcpIsn();
        conn.cliMss = v.mss > 0 ? v.mss : 536;
        conn.lastActiveMs = nowMs;
        g_tcpConns[key] = std::move(conn);
        SendTcpSeg(tunFd, g_tcpConns[key], static_cast<uint8_t>(kTcpSyn | kTcpAck), nullptr, 0, true);
        return;
    }

    if (it == g_tcpConns.end()) {
        return;  // unknown, non-SYN segment: ignore
    }
    TcpConn &c = it->second;
    c.lastActiveMs = nowMs;

    if (v.flags & kTcpAck) {
        if (!c.established && v.ack == c.sndNxt) {
            c.established = true;
        }
        if (c.ourFin && c.clientFin && v.ack == c.sndNxt) {
            g_tcpConns.erase(it);
            return;
        }
    }

    if (v.payloadLen > 0) {
        if (v.seq == c.rcvNxt) {
            c.inbound.insert(c.inbound.end(), v.payload, v.payload + v.payloadLen);
            c.rcvNxt += static_cast<uint32_t>(v.payloadLen);
            SendTcpSeg(tunFd, c, kTcpAck, nullptr, 0, false);
            ProcessTcpInbound(tunFd, c);
        } else {
            // Duplicate or out-of-order (no loss on a local TUN): just re-ACK.
            SendTcpSeg(tunFd, c, kTcpAck, nullptr, 0, false);
        }
    }

    // Client half-close. The query was processed synchronously above, so any
    // response has already been sent and it is safe to close our side too.
    if ((v.flags & kTcpFin) && (v.seq + static_cast<uint32_t>(v.payloadLen) == c.rcvNxt)) {
        c.rcvNxt += 1;
        c.clientFin = true;
        SendTcpSeg(tunFd, c, kTcpAck, nullptr, 0, false);
        if (!c.ourFin) {
            SendTcpSeg(tunFd, c, static_cast<uint8_t>(kTcpFin | kTcpAck), nullptr, 0, false);
            c.ourFin = true;
        }
    }
}

void HandleDnsPacket(int tunFd, const uint8_t *packet, size_t len)
{
    const TcpSegmentView tcp = ParseTcpSegment(packet, len);
    if (tcp.valid && tcp.dstPort == 53) {
        HandleTcpPacket(tunFd, tcp);
        return;
    }

    const Ipv4UdpPacketView view4 = ParseIpv4UdpPacket(packet, len);
    const Ipv6UdpPacketView view6 = ParseIpv6UdpPacket(packet, len);

    bool isIpv6 = false;
    const uint8_t *dnsPayload = nullptr;
    size_t dnsLen = 0;
    if (view4.valid && view4.dstPort == 53 && view4.dnsPayload != nullptr && view4.dnsLen > 0) {
        dnsPayload = view4.dnsPayload;
        dnsLen = view4.dnsLen;
    } else if (view6.valid && view6.dstPort == 53 && view6.dnsPayload != nullptr && view6.dnsLen > 0) {
        isIpv6 = true;
        dnsPayload = view6.dnsPayload;
        dnsLen = view6.dnsLen;
    } else {
        return;
    }

    const DnsQuestion question = ParseDnsQuestion(dnsPayload, dnsLen);
    if (!question.valid) {
        return;
    }

    std::shared_ptr<const std::vector<RuleEntry>> rules;
    std::string queryLogPath;
    std::vector<std::string> upstreams;
    bool fullMode = false;
    uint16_t aghDnsPort = 0;
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        rules = g_state.activeRules;
        queryLogPath = g_state.queryLogPath;
        upstreams = g_state.upstreamDnsIps;
        fullMode = g_state.fullMode;
        aghDnsPort = g_state.aghDnsPort;
    }

    // Full mode forwards every query to the embedded AdGuardHome engine, which
    // performs all matching; lightweight mode matches locally and may block.
    const MatchResult match = (!fullMode && rules)
        ? MatchDomain(question.name, question.qtype, *rules)
        : MatchResult {};

    if (match.blocked) {
        // Blocked responses are synthesized locally (no network), so answer them
        // inline on the reader thread instead of paying a queue hop.
        const std::vector<uint8_t> dnsResponse = BuildBlockedDnsResponse(dnsPayload, dnsLen, question);
        if (dnsResponse.empty()) {
            std::lock_guard<std::mutex> lock(g_state.mu);
            g_state.lastError = "failed to synthesize blocked DNS response";
            LogError("==/vpn_native/dns_error/ domain=%{public}s err=%{public}s", question.name.c_str(),
                g_state.lastError.c_str());
            return;
        }

        const std::vector<uint8_t> responsePacket = isIpv6
            ? BuildIpv6UdpResponse(view6, dnsResponse)
            : BuildIpv4UdpResponse(view4, dnsResponse);
        std::string writeError;
        bool written = false;
        {
            std::lock_guard<std::mutex> writeLock(g_tunWriteMu);
            written = WriteAll(tunFd, responsePacket.data(), responsePacket.size(), writeError);
        }
        if (!written) {
            std::lock_guard<std::mutex> lock(g_state.mu);
            g_state.lastError = writeError;
            LogError("==/vpn_native/write_error/ domain=%{public}s err=%{public}s", question.name.c_str(),
                writeError.c_str());
            return;
        }

        LogDnsEvent(queryLogPath, question.name, question.qtype, true, match.matchedRule, "blocked", dnsLen,
            dnsResponse.size());
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.lastQueryDomain = question.name;
        g_state.lastMatchedRule = match.matchedRule;
        g_state.loggedQueries++;
        g_state.blockedQueries++;
        return;
    }

    // Not blocked: hand the upstream round-trip to the worker pool so the reader
    // thread can immediately drain the next packet instead of stalling here.
    ForwardTask task;
    task.tunFd = tunFd;
    task.isIpv6 = isIpv6;
    task.view4 = view4;
    task.view4.dnsPayload = nullptr;  // points into the reusable reader buffer
    task.view6 = view6;
    task.view6.dnsPayload = nullptr;
    task.query.assign(dnsPayload, dnsPayload + dnsLen);
    task.question = question;
    task.matchedRule = fullMode ? "full-mode" : match.matchedRule;
    task.upstreams = fullMode ? std::vector<std::string>{"127.0.0.1"} : upstreams;
    task.upstreamPort = fullMode ? aghDnsPort : static_cast<uint16_t>(53);
    task.useCache = !fullMode;
    task.queryLogPath = queryLogPath;
    EnqueueForwardTask(std::move(task));
}

void ReaderLoop(int tunFd)
{
    uint8_t buffer[65536];
    int stopFd = -1;
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        stopFd = g_state.stopEventFd;
    }
    pollfd pfds[2] {};
    pfds[0].fd = tunFd;
    pfds[0].events = POLLIN;
    pfds[1].fd = stopFd;
    pfds[1].events = POLLIN;
    const nfds_t pollCount = stopFd >= 0 ? 2 : 1;
    // With a stop eventfd the poll can sleep for long stretches (the eventfd
    // wakes it on stop; 30s is only a safety net). Without one, fall back to
    // the short timeout so stopRequested is still observed promptly.
    const int pollTimeoutMs = stopFd >= 0 ? 30000 : 200;

    for (;;) {
        {
            std::lock_guard<std::mutex> lock(g_state.mu);
            if (g_state.stopRequested) {
                break;
            }
        }

        const int ready = poll(pfds, pollCount, pollTimeoutMs);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            std::lock_guard<std::mutex> lock(g_state.mu);
            if (!g_state.stopRequested) {
                g_state.lastError = std::string("tun poll failed: ") + std::strerror(errno);
                LogError("==/vpn_native/poll_error/ %{public}s", g_state.lastError.c_str());
            }
            break;
        }
        if (ready == 0) {
            continue;
        }
        if (pfds[1].revents != 0) {
            continue;  // stop signal: the top-of-loop check exits
        }
        if (pfds[0].revents == 0) {
            continue;
        }

        const ssize_t readBytes = read(tunFd, buffer, sizeof(buffer));
        if (readBytes > 0) {
            {
                std::lock_guard<std::mutex> lock(g_state.mu);
                UpdatePacketStatsLocked(g_state, buffer, readBytes);
                // First packets confirm the relay is alive (cheap, bounded);
                // the steady-state every-50 counter line is verbose-only.
                if (g_state.totalPackets <= 5
                    || (g_verboseLog.load(std::memory_order_relaxed) && g_state.totalPackets % 50 == 0)) {
                    LogInfo("==/vpn_native/packets/ total=%{public}llu bytes=%{public}llu dns=%{public}llu"
                        " ipv4=%{public}llu ipv6=%{public}llu",
                        static_cast<unsigned long long>(g_state.totalPackets),
                        static_cast<unsigned long long>(g_state.totalBytes),
                        static_cast<unsigned long long>(g_state.dnsPackets),
                        static_cast<unsigned long long>(g_state.ipv4Packets),
                        static_cast<unsigned long long>(g_state.ipv6Packets));
                }
            }
            HandleDnsPacket(tunFd, buffer, static_cast<size_t>(readBytes));
            continue;
        }

        if (readBytes == 0) {
            break;
        }

        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
            continue;
        }

        std::lock_guard<std::mutex> lock(g_state.mu);
        if (!g_state.stopRequested) {
            g_state.lastError = std::string("tun read failed: ") + std::strerror(errno);
            LogError("==/vpn_native/read_error/ %{public}s", g_state.lastError.c_str());
        }
        break;
    }

    // Ownership of tunFd stays with Stop/StartDnsFilter so the forward workers
    // can keep writing to it until they are joined and the fd is closed once.
    LogInfo("==/vpn_native/reader_exit/ fd=%{public}d", tunFd);
    std::lock_guard<std::mutex> lock(g_state.mu);
    g_state.running = false;
}

void ResetStatsLocked(StatsState &state, int fd, const std::string &dnsServerIp, const std::string &upstreamDnsIp,
    const std::string &rulesPath, const std::string &queryLogPath, uint32_t dnsCacheTtlSeconds)
{
    state.running = true;
    state.stopRequested = false;
    state.tunFd = fd;
    state.startedAtMs = NowMs();
    state.totalPackets = 0;
    state.totalBytes = 0;
    state.ipv4Packets = 0;
    state.ipv6Packets = 0;
    state.tcpPackets = 0;
    state.udpPackets = 0;
    state.dnsPackets = 0;
    state.allowedQueries = 0;
    state.blockedQueries = 0;
    state.loggedQueries = 0;
        state.dnsCacheHits = 0;
        state.dnsCacheMisses = 0;
    state.lastQueryDomain.clear();
    state.lastMatchedRule.clear();
    state.lastError.clear();
    state.dnsServerIp = dnsServerIp;
    state.upstreamDnsIps = ParseUpstreamList(upstreamDnsIp);
    state.rulesPath = rulesPath;
    state.queryLogPath = queryLogPath;
    state.activeRules = std::make_shared<const std::vector<RuleEntry>>(LoadRulesSnapshot(rulesPath));
    state.dnsCacheTtlSeconds = dnsCacheTtlSeconds;
    state.dnsResponseCache.clear();
    g_tcpConns.clear();
}

std::string StopDnsFilter()
{
    std::thread reader;
    std::thread dnsServer;
    std::thread dnsUdp;
    int listenToClose = -1;
    int udpToClose = -1;
    int stopEventToClose = -1;
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.stopRequested = true;
        g_state.running = false;
        reader = std::move(g_state.worker);
        dnsServer = std::move(g_state.dnsServerThread);
        dnsUdp = std::move(g_state.dnsServerUdpThread);
        listenToClose = g_state.dnsServerListenFd;
        g_state.dnsServerListenFd = -1;
        udpToClose = g_state.dnsServerUdpFd;
        g_state.dnsServerUdpFd = -1;
        // Wake the reader's long poll right away; the fd itself is closed only
        // after the reader has been joined (it still polls on it until exit).
        stopEventToClose = g_state.stopEventFd;
        g_state.stopEventFd = -1;
        if (stopEventToClose >= 0) {
            const uint64_t one = 1;
            (void)write(stopEventToClose, &one, sizeof(one));
        }
    }
    // Close the TCP listening socket first so the accept loop unblocks and exits.
    // The UDP loop instead exits via its SO_RCVTIMEO wakeup observing
    // stopRequested, so its socket is closed after the loop is joined. In-flight
    // connection/query handler threads are detached; they observe stopRequested
    // between queries (or time out) and finish on their own.
    if (listenToClose >= 0) {
        shutdown(listenToClose, SHUT_RDWR);
        close(listenToClose);
    }
    if (reader.joinable()) {
        reader.join();
    }
    if (stopEventToClose >= 0) {
        close(stopEventToClose);
    }
    if (dnsServer.joinable()) {
        dnsServer.join();
    }
    if (dnsUdp.joinable()) {
        dnsUdp.join();
    }
    if (udpToClose >= 0) {
        close(udpToClose);
    }

    // Join the forward workers before touching the TUN fd: one of them may still
    // be writing an upstream response back to it.
    StopForwardPool();

    int fdToClose = -1;
    bool wasFullMode = false;
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        fdToClose = g_state.tunFd;
        g_state.tunFd = -1;
        g_state.activeRules.reset();
        g_state.dnsResponseCache.clear();
        g_tcpConns.clear();
        wasFullMode = g_state.fullMode;
        g_state.fullMode = false;
        g_state.aghDnsPort = 0;
    }
    if (fdToClose >= 0) {
        close(fdToClose);
    }
    // Stop the embedded AdGuardHome engine only after the reader and forward
    // workers have been joined, so no in-flight query is still forwarding to it.
    if (wasFullMode) {
        StopAdGuardHome();
        LogInfo("%{public}s", "==/vpn_native/agh_stopped/");
    }
    LogInfo("%{public}s", "==/vpn_native/stop/");
    return {};
}

std::string StartDnsFilter(int fd, const std::string &dnsServerIp, const std::string &upstreamDnsIp,
    const std::string &rulesPath, const std::string &queryLogPath, uint32_t dnsCacheTtlSeconds)
{
    if (fd < 0) {
        return "invalid tun fd";
    }
    if (dnsServerIp.empty()) {
        return "dns server ip is required";
    }
    if (upstreamDnsIp.empty()) {
        return "upstream dns ip is required";
    }
    if (rulesPath.empty()) {
        return "rules path is required";
    }
    if (queryLogPath.empty()) {
        return "query log path is required";
    }

    LogInfo("==/vpn_native/start/ fd=%{public}d dns=%{public}s upstream=%{public}s rules=%{public}s query=%{public}s cache_ttl=%{public}u",
        fd, dnsServerIp.c_str(), upstreamDnsIp.c_str(), rulesPath.c_str(), queryLogPath.c_str(), dnsCacheTtlSeconds);
    StopDnsFilter();

    const int dupFd = dup(fd);
    if (dupFd < 0) {
        return std::string("dup tun fd failed: ") + std::strerror(errno);
    }
    if (fcntl(dupFd, F_SETFL, O_NONBLOCK) < 0) {
        close(dupFd);
        return std::string("set tun fd nonblocking failed: ") + std::strerror(errno);
    }

    StartForwardPool();
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        ResetStatsLocked(g_state, dupFd, dnsServerIp, upstreamDnsIp, rulesPath, queryLogPath, dnsCacheTtlSeconds);
        g_state.stopEventFd = eventfd(0, EFD_NONBLOCK);
        g_state.worker = std::thread(ReaderLoop, dupFd);
    }

    LogInfo("==/vpn_native/reader_started/ dup_fd=%{public}d", dupFd);
    return {};
}

// Start full mode: boot the embedded AdGuardHome engine (which binds a loopback
// DNS listener on aghDnsPort and performs all filtering/upstream/caching), then
// run the TUN reader as a thin relay that forwards every DNS query to it.
std::string StartFullDnsFilter(int fd, const std::string &dnsServerIp, const std::string &aghConfigPath,
    const std::string &aghWorkDir, const std::string &aghLogPath, uint16_t aghDnsPort,
    const std::string &queryLogPath, bool aghWebEnabled)
{
    if (fd < 0) {
        return "invalid tun fd";
    }
    if (dnsServerIp.empty()) {
        return "dns server ip is required";
    }
    if (aghConfigPath.empty()) {
        return "adguardhome config path is required";
    }
    if (aghWorkDir.empty()) {
        return "adguardhome work dir is required";
    }
    if (aghDnsPort == 0) {
        return "adguardhome dns port is required";
    }

    LogInfo("==/vpn_native/start_full/ fd=%{public}d dns=%{public}s agh_cfg=%{public}s agh_dir=%{public}s agh_port=%{public}u query=%{public}s",
        fd, dnsServerIp.c_str(), aghConfigPath.c_str(), aghWorkDir.c_str(), static_cast<unsigned>(aghDnsPort),
        queryLogPath.c_str());

    StopDnsFilter();

    // Start AdGuardHome before taking over the TUN; StartEmbedded binds the DNS
    // listener synchronously, so once this returns the loopback port is ready.
    // A bad config is surfaced here instead of leaving a half-started filter.
    const std::string aghErr = StartAdGuardHome(aghConfigPath, aghWorkDir, aghLogPath, aghWebEnabled);
    if (!aghErr.empty()) {
        LogError("==/vpn_native/agh_start_error/ %{public}s", aghErr.c_str());
        return std::string("adguardhome start failed: ") + aghErr;
    }
    LogInfo("==/vpn_native/agh_started/ port=%{public}u", static_cast<unsigned>(aghDnsPort));

    const int dupFd = dup(fd);
    if (dupFd < 0) {
        StopAdGuardHome();
        return std::string("dup tun fd failed: ") + std::strerror(errno);
    }
    if (fcntl(dupFd, F_SETFL, O_NONBLOCK) < 0) {
        close(dupFd);
        StopAdGuardHome();
        return std::string("set tun fd nonblocking failed: ") + std::strerror(errno);
    }

    StartForwardPool();
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        // No local rules in full mode (AGH owns filtering); upstream points at
        // the loopback AGH DNS listener and the C++ cache is disabled per-query.
        // The app jsonl path is deliberately empty: the UI ingests AdGuardHome's
        // own querylog in full mode, so the relay writing dns_queries.jsonl too
        // would be a second per-query disk write that nothing reads.
        ResetStatsLocked(g_state, dupFd, dnsServerIp, "127.0.0.1", "", "", 0);
        g_state.fullMode = true;
        g_state.aghDnsPort = aghDnsPort;
        g_state.stopEventFd = eventfd(0, EFD_NONBLOCK);
        g_state.worker = std::thread(ReaderLoop, dupFd);
    }

    LogInfo("==/vpn_native/reader_started_full/ dup_fd=%{public}d", dupFd);
    return {};
}

// Start "DNS server / coexist" mode: boot the embedded AdGuardHome engine as a
// standalone loopback DNS server on 127.0.0.1:aghDnsPort WITHOUT creating a VPN
// or taking over a TUN. Another app (e.g. a proxy/VPN client) can then point its
// DNS upstream at this port, so device-wide DNS filtering and a separate VPN can
// coexist. There is no reader thread and no forward pool here: AdGuardHome owns
// the socket and does all serving. Teardown goes through StopDnsFilter(), which
// stops AdGuardHome whenever fullMode is set.
std::string StartAghServerOnly(const std::string &aghConfigPath, const std::string &aghWorkDir,
    const std::string &aghLogPath, uint16_t aghDnsPort, bool aghWebEnabled)
{
    if (aghConfigPath.empty()) {
        return "adguardhome config path is required";
    }
    if (aghWorkDir.empty()) {
        return "adguardhome work dir is required";
    }
    if (aghDnsPort == 0) {
        return "adguardhome dns port is required";
    }

    LogInfo("==/vpn_native/start_agh_server_only/ agh_cfg=%{public}s agh_dir=%{public}s agh_port=%{public}u",
        aghConfigPath.c_str(), aghWorkDir.c_str(), static_cast<unsigned>(aghDnsPort));

    StopDnsFilter();

    // StartEmbedded binds the DNS listener synchronously, so once this returns the
    // loopback port is ready. A bad config surfaces here instead of leaving a
    // half-started server behind.
    const std::string aghErr = StartAdGuardHome(aghConfigPath, aghWorkDir, aghLogPath, aghWebEnabled);
    if (!aghErr.empty()) {
        LogError("==/vpn_native/agh_start_error/ %{public}s", aghErr.c_str());
        return std::string("adguardhome start failed: ") + aghErr;
    }
    LogInfo("==/vpn_native/agh_server_only_started/ port=%{public}u", static_cast<unsigned>(aghDnsPort));

    // No TUN fd, no reader thread, no forward pool. We only mark state so
    // getStats() reports running and StopDnsFilter() stops AdGuardHome on teardown.
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        ResetStatsLocked(g_state, -1, "127.0.0.1", "127.0.0.1", "", "", 0);
        g_state.fullMode = true;
        g_state.aghDnsPort = aghDnsPort;
    }
    return {};
}

// Reads exactly len bytes from fd into buf. Returns false on EOF, error, or
// (with SO_RCVTIMEO set) an idle timeout.
bool ReadExactly(int fd, uint8_t *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        const ssize_t n = read(fd, buf + off, len - off);
        if (n > 0) {
            off += static_cast<size_t>(n);
            continue;
        }
        if (n == 0) {
            return false; // peer closed
        }
        if (errno == EINTR) {
            continue;
        }
        return false; // error or recv timeout (EAGAIN/EWOULDBLOCK)
    }
    return true;
}

// Resolves one DNS query message (no transport framing) through the lightweight
// engine: parse the question, match local rules (block) or serve from cache /
// forward upstream over UDP, update stats and the query log. Returns the DNS
// response bytes, or empty on parse/forward failure. Shared by the TCP and UDP
// coexist listeners. Upstream is UDP on purpose: on HarmonyOS an app's UDP egress
// to public resolvers works, while outbound TCP/53 may be blocked.
std::vector<uint8_t> ResolveDnsMessage(const std::vector<uint8_t> &message)
{
    const DnsQuestion question = ParseDnsQuestion(message.data(), message.size());
    if (!question.valid) {
        return {};
    }

    std::shared_ptr<const std::vector<RuleEntry>> rules;
    std::string queryLogPath;
    std::vector<std::string> upstreams;
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        rules = g_state.activeRules;
        queryLogPath = g_state.queryLogPath;
        upstreams = g_state.upstreamDnsIps;
    }

    const MatchResult match = rules
        ? MatchDomain(question.name, question.qtype, *rules)
        : MatchResult {};

    std::vector<uint8_t> dnsResponse;
    std::string source = "upstream";
    std::string responseError;
    if (match.blocked) {
        source = "blocked";
        dnsResponse = BuildBlockedDnsResponse(message.data(), message.size(), question);
    } else {
        const bool cacheHit =
            TryGetCachedDnsResponse(question, message.data(), message.size(), dnsResponse);
        {
            std::lock_guard<std::mutex> lock(g_state.mu);
            if (cacheHit) {
                g_state.dnsCacheHits++;
            } else {
                g_state.dnsCacheMisses++;
            }
        }
        if (cacheHit) {
            source = "cache";
        } else {
            dnsResponse = ForwardDnsQuery(message.data(), message.size(), upstreams,
                static_cast<uint16_t>(53), responseError);
            if (!dnsResponse.empty()) {
                StoreDnsResponseCache(question, dnsResponse);
            }
        }
    }

    if (dnsResponse.empty()) {
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.lastError = responseError;
        LogError("==/vpn_native/lw_dns_error/ domain=%{public}s err=%{public}s", question.name.c_str(),
            responseError.c_str());
        return {};
    }

    LogDnsEvent(queryLogPath, question.name, question.qtype, match.blocked, match.matchedRule, source,
        message.size(), dnsResponse.size());
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.lastQueryDomain = question.name;
        g_state.lastMatchedRule = match.matchedRule;
        g_state.loggedQueries++;
        if (match.blocked) {
            g_state.blockedQueries++;
        } else {
            g_state.allowedQueries++;
        }
    }
    return dnsResponse;
}

// Handles one accepted DNS-over-TCP connection: reads length-prefixed (RFC 7766)
// query messages until the client closes, the server stops, or the socket goes
// idle, replying to each. Runs on its own detached thread.
void LwDnsServerConnLoop(int connFd)
{
    timeval tv {};
    tv.tv_sec = 30;
    tv.tv_usec = 0;
    setsockopt(connFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    for (;;) {
        {
            std::lock_guard<std::mutex> lock(g_state.mu);
            if (g_state.stopRequested) {
                break;
            }
        }
        uint8_t lenBuf[2];
        if (!ReadExactly(connFd, lenBuf, 2)) {
            break;
        }
        const uint16_t msgLen = static_cast<uint16_t>((lenBuf[0] << 8) | lenBuf[1]);
        if (msgLen == 0 || msgLen > 4096) {
            break;
        }
        std::vector<uint8_t> query(msgLen);
        if (!ReadExactly(connFd, query.data(), msgLen)) {
            break;
        }

        const std::vector<uint8_t> response = ResolveDnsMessage(query);
        if (response.empty()) {
            break;
        }
        std::vector<uint8_t> out;
        out.reserve(response.size() + 2);
        out.push_back(static_cast<uint8_t>((response.size() >> 8) & 0xFF));
        out.push_back(static_cast<uint8_t>(response.size() & 0xFF));
        out.insert(out.end(), response.begin(), response.end());
        std::string writeError;
        if (!WriteAll(connFd, out.data(), out.size(), writeError)) {
            break;
        }
    }
    close(connFd);
    g_lwConnCount.fetch_sub(1);
}

// Accept loop for the lightweight DNS-over-TCP server. Exits when StopDnsFilter
// closes the listening socket (accept fails).
void LwDnsServerAcceptLoop(int listenFd)
{
    LogInfo("==/vpn_native/lw_dns_accept_loop/ fd=%{public}d", listenFd);
    for (;;) {
        sockaddr_in cli {};
        socklen_t cliLen = sizeof(cli);
        const int connFd = accept(listenFd, reinterpret_cast<sockaddr *>(&cli), &cliLen);
        if (connFd < 0) {
            if (errno == EINTR) {
                continue;
            }
            break; // listening socket closed by StopDnsFilter
        }
        {
            std::lock_guard<std::mutex> lock(g_state.mu);
            if (g_state.stopRequested) {
                close(connFd);
                break;
            }
        }
        if (g_lwConnCount.load() >= kLwMaxDnsConns) {
            close(connFd);
            continue;
        }
        g_lwConnCount.fetch_add(1);
        std::thread(LwDnsServerConnLoop, connFd).detach();
    }
    LogInfo("%{public}s", "==/vpn_native/lw_dns_accept_exit/");
}

// Serve loop for the lightweight DNS-over-UDP listener. Receives a raw query
// datagram (no 2-byte length prefix, unlike TCP), then resolves it on a detached
// worker through the shared matcher/cache/upstream and replies to the sender from
// the bound socket. The blocking recvfrom uses SO_RCVTIMEO so the loop can notice
// stopRequested and exit; StopDnsFilter closes the socket after joining it.
void LwDnsServerUdpLoop(int udpFd)
{
    LogInfo("==/vpn_native/lw_dns_udp_loop/ fd=%{public}d", udpFd);
    for (;;) {
        {
            std::lock_guard<std::mutex> lock(g_state.mu);
            if (g_state.stopRequested) {
                break;
            }
        }
        uint8_t buffer[2048];
        sockaddr_in cli {};
        socklen_t cliLen = sizeof(cli);
        const ssize_t received = recvfrom(udpFd, buffer, sizeof(buffer), 0,
            reinterpret_cast<sockaddr *>(&cli), &cliLen);
        if (received <= 0) {
            if (received < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
                continue;  // recv timeout / interrupt: re-check stopRequested
            }
            if (received < 0) {
                break;  // socket closed or hard error
            }
            continue;  // empty datagram
        }
        if (g_lwUdpInflight.load() >= kLwMaxUdpInflight) {
            continue;  // under flood: drop and let the client retry
        }
        g_lwUdpInflight.fetch_add(1);
        std::vector<uint8_t> query(buffer, buffer + received);
        std::thread([udpFd, query = std::move(query), cli, cliLen]() {
            const std::vector<uint8_t> response = ResolveDnsMessage(query);
            if (!response.empty()) {
                sendto(udpFd, response.data(), response.size(), 0,
                    reinterpret_cast<const sockaddr *>(&cli), cliLen);
            }
            g_lwUdpInflight.fetch_sub(1);
        }).detach();
    }
    LogInfo("%{public}s", "==/vpn_native/lw_dns_udp_exit/");
}

// Start "DNS server / coexist" mode with the lightweight engine: bind matching
// DNS listeners on bindIp:port over both TCP and UDP (no VPN, no TUN) and resolve
// each query through the local matcher + UDP upstream. A separate proxy/VPN app
// can point its DNS upstream at tcp:// or udp://bindIp:port. The UDP listener is
// best effort (a UDP bind failure leaves the TCP server fully functional).
// Teardown goes through StopDnsFilter().
std::string StartLwDnsServer(const std::string &bindIp, uint16_t port, const std::string &upstreamDnsIp,
    const std::string &rulesPath, const std::string &queryLogPath, uint32_t dnsCacheTtlSeconds)
{
    if (bindIp.empty()) {
        return "bind ip is required";
    }
    if (port == 0) {
        return "port is required";
    }
    if (rulesPath.empty()) {
        return "rules path is required";
    }
    if (queryLogPath.empty()) {
        return "query log path is required";
    }

    LogInfo("==/vpn_native/start_lw_dns_server/ bind=%{public}s port=%{public}u upstream=%{public}s rules=%{public}s",
        bindIp.c_str(), static_cast<unsigned>(port), upstreamDnsIp.c_str(), rulesPath.c_str());

    StopDnsFilter();

    const int listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (listenFd < 0) {
        return std::string("socket failed: ") + std::strerror(errno);
    }
    int one = 1;
    setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, bindIp.c_str(), &addr.sin_addr) != 1) {
        close(listenFd);
        return "invalid bind ip";
    }
    if (bind(listenFd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
        const std::string e = std::string("bind failed: ") + std::strerror(errno);
        close(listenFd);
        return e;
    }
    if (listen(listenFd, 64) < 0) {
        const std::string e = std::string("listen failed: ") + std::strerror(errno);
        close(listenFd);
        return e;
    }

    // Companion UDP listener on the same ip:port. Best effort: if it can't be
    // created/bound, log and carry on with TCP only so existing clients keep
    // working.
    int udpFd = socket(AF_INET, SOCK_DGRAM, 0);
    if (udpFd >= 0) {
        int udpReuse = 1;
        setsockopt(udpFd, SOL_SOCKET, SO_REUSEADDR, &udpReuse, sizeof(udpReuse));
        // Periodic wakeups so the recv loop can observe stopRequested and exit.
        timeval udpTimeout {};
        udpTimeout.tv_sec = 1;
        udpTimeout.tv_usec = 0;
        setsockopt(udpFd, SOL_SOCKET, SO_RCVTIMEO, &udpTimeout, sizeof(udpTimeout));
        sockaddr_in udpAddr {};
        udpAddr.sin_family = AF_INET;
        udpAddr.sin_port = htons(port);
        if (inet_pton(AF_INET, bindIp.c_str(), &udpAddr.sin_addr) != 1
            || bind(udpFd, reinterpret_cast<sockaddr *>(&udpAddr), sizeof(udpAddr)) < 0) {
            LogError("==/vpn_native/lw_dns_udp_bind_error/ %{public}s", std::strerror(errno));
            close(udpFd);
            udpFd = -1;
        }
    } else {
        LogError("==/vpn_native/lw_dns_udp_socket_error/ %{public}s", std::strerror(errno));
    }

    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        // -1 fd: no TUN. Seed the resolver state (rules/upstream/query log) the
        // same way the lightweight TUN path does; fullMode stays false.
        ResetStatsLocked(g_state, -1, bindIp, upstreamDnsIp, rulesPath, queryLogPath, dnsCacheTtlSeconds);
        g_state.fullMode = false;
        g_state.dnsServerListenFd = listenFd;
        g_state.dnsServerThread = std::thread(LwDnsServerAcceptLoop, listenFd);
        if (udpFd >= 0) {
            g_state.dnsServerUdpFd = udpFd;
            g_state.dnsServerUdpThread = std::thread(LwDnsServerUdpLoop, udpFd);
        }
    }
    LogInfo("==/vpn_native/lw_dns_server_started/ port=%{public}u udp=%{public}d",
        static_cast<unsigned>(port), udpFd >= 0 ? 1 : 0);
    return {};
}

// Hot-swap the active rule set without tearing down the VPN or the reader
// thread. The fresh snapshot is parsed off-lock and then published atomically,
// so in-flight queries keep matching against a consistent rule list.
std::string ReloadDnsRules(const std::string &rulesPath)
{
    if (rulesPath.empty()) {
        return "rules path is required";
    }

    auto fresh = std::make_shared<const std::vector<RuleEntry>>(LoadRulesSnapshot(rulesPath));
    const size_t count = fresh->size();
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.rulesPath = rulesPath;
        g_state.activeRules = std::move(fresh);
    }
    LogInfo("==/vpn_native/rules_reloaded/ rules=%{public}s count=%{public}zu", rulesPath.c_str(), count);
    return {};
}

// Switch the upstream resolver live. The DNS cache is flushed because cached
// answers may have been resolved by the previous (e.g. geographically distant)
// upstream and could carry suboptimal CDN routing.
std::string SetUpstreamDns(const std::string &upstreamDnsIp)
{
    std::vector<std::string> upstreams = ParseUpstreamList(upstreamDnsIp);
    if (upstreams.empty()) {
        return "upstream dns ip is required";
    }
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.upstreamDnsIps = std::move(upstreams);
        g_state.dnsResponseCache.clear();
    }
    LogInfo("==/vpn_native/upstream_set/ upstream=%{public}s", upstreamDnsIp.c_str());
    return {};
}

std::string GetStatsJson()
{
    std::lock_guard<std::mutex> lock(g_state.mu);
    std::ostringstream out;
    out << '{'
        << "\"running\":" << (g_state.running ? "true" : "false") << ','
        << "\"tunFd\":" << g_state.tunFd << ','
        << "\"startedAtMs\":" << g_state.startedAtMs << ','
        << "\"totalPackets\":" << g_state.totalPackets << ','
        << "\"totalBytes\":" << g_state.totalBytes << ','
        << "\"ipv4Packets\":" << g_state.ipv4Packets << ','
        << "\"ipv6Packets\":" << g_state.ipv6Packets << ','
        << "\"tcpPackets\":" << g_state.tcpPackets << ','
        << "\"udpPackets\":" << g_state.udpPackets << ','
        << "\"dnsPackets\":" << g_state.dnsPackets << ','
        << "\"allowedQueries\":" << g_state.allowedQueries << ','
        << "\"blockedQueries\":" << g_state.blockedQueries << ','
        << "\"loggedQueries\":" << g_state.loggedQueries << ','
            << "\"dnsCacheHits\":" << g_state.dnsCacheHits << ','
            << "\"dnsCacheMisses\":" << g_state.dnsCacheMisses << ','
        << "\"lastQueryDomain\":\"" << EscapeJson(g_state.lastQueryDomain) << "\"," 
        << "\"lastMatchedRule\":\"" << EscapeJson(g_state.lastMatchedRule) << "\"," 
        << "\"lastError\":\"" << EscapeJson(g_state.lastError) << "\""
        << '}';
    return out.str();
}

napi_value JsStartDnsFilter(napi_env env, napi_callback_info info)
{
    size_t argc = 6;
    napi_value argv[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 6) {
        return MakeUtf8(env, "tun fd, dns server ip, upstream dns ip, rules path, query log path, and cache ttl are required");
    }

    int32_t fd = -1;
    std::string dnsServerIp;
    std::string upstreamDnsIp;
    std::string rulesPath;
    std::string queryLogPath;
    int32_t dnsCacheTtlSeconds = 0;
    if (!ReadArgInt32(env, argv[0], fd)) {
        return MakeUtf8(env, "invalid tun fd");
    }
    if (!ReadArgString(env, argv[1], dnsServerIp) || dnsServerIp.empty()) {
        return MakeUtf8(env, "invalid dns server ip");
    }
    if (!ReadArgString(env, argv[2], upstreamDnsIp) || upstreamDnsIp.empty()) {
        return MakeUtf8(env, "invalid upstream dns ip");
    }
    if (!ReadArgString(env, argv[3], rulesPath) || rulesPath.empty()) {
        return MakeUtf8(env, "invalid rules path");
    }
    if (!ReadArgString(env, argv[4], queryLogPath) || queryLogPath.empty()) {
        return MakeUtf8(env, "invalid query log path");
    }
    if (!ReadArgInt32(env, argv[5], dnsCacheTtlSeconds) || dnsCacheTtlSeconds < 0) {
        return MakeUtf8(env, "invalid dns cache ttl");
    }

    return ReturnErrOrUndefined(env,
        StartDnsFilter(fd, dnsServerIp, upstreamDnsIp, rulesPath, queryLogPath,
            static_cast<uint32_t>(dnsCacheTtlSeconds)));
}

napi_value JsStartFullDnsFilter(napi_env env, napi_callback_info info)
{
    size_t argc = 8;
    napi_value argv[8] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 7) {
        return MakeUtf8(env,
            "tun fd, dns server ip, agh config path, agh work dir, agh log path, agh dns port, and query log path are required");
    }

    int32_t fd = -1;
    std::string dnsServerIp;
    std::string aghConfigPath;
    std::string aghWorkDir;
    std::string aghLogPath;
    int32_t aghDnsPort = 0;
    std::string queryLogPath;
    if (!ReadArgInt32(env, argv[0], fd)) {
        return MakeUtf8(env, "invalid tun fd");
    }
    if (!ReadArgString(env, argv[1], dnsServerIp) || dnsServerIp.empty()) {
        return MakeUtf8(env, "invalid dns server ip");
    }
    if (!ReadArgString(env, argv[2], aghConfigPath) || aghConfigPath.empty()) {
        return MakeUtf8(env, "invalid agh config path");
    }
    if (!ReadArgString(env, argv[3], aghWorkDir) || aghWorkDir.empty()) {
        return MakeUtf8(env, "invalid agh work dir");
    }
    if (!ReadArgString(env, argv[4], aghLogPath)) {
        return MakeUtf8(env, "invalid agh log path");
    }
    if (!ReadArgInt32(env, argv[5], aghDnsPort) || aghDnsPort <= 0 || aghDnsPort > 65535) {
        return MakeUtf8(env, "invalid agh dns port");
    }
    if (!ReadArgString(env, argv[6], queryLogPath) || queryLogPath.empty()) {
        return MakeUtf8(env, "invalid query log path");
    }
    // Optional trailing flag; defaults to no web dashboard (battery).
    bool aghWebEnabled = false;
    if (argc >= 8) {
        (void)ReadArgBool(env, argv[7], aghWebEnabled);
    }

    return ReturnErrOrUndefined(env,
        StartFullDnsFilter(fd, dnsServerIp, aghConfigPath, aghWorkDir, aghLogPath,
            static_cast<uint16_t>(aghDnsPort), queryLogPath, aghWebEnabled));
}

napi_value JsStartAghServerOnly(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value argv[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 4) {
        return MakeUtf8(env, "agh config path, agh work dir, agh log path, and agh dns port are required");
    }

    std::string aghConfigPath;
    std::string aghWorkDir;
    std::string aghLogPath;
    int32_t aghDnsPort = 0;
    if (!ReadArgString(env, argv[0], aghConfigPath) || aghConfigPath.empty()) {
        return MakeUtf8(env, "invalid agh config path");
    }
    if (!ReadArgString(env, argv[1], aghWorkDir) || aghWorkDir.empty()) {
        return MakeUtf8(env, "invalid agh work dir");
    }
    if (!ReadArgString(env, argv[2], aghLogPath)) {
        return MakeUtf8(env, "invalid agh log path");
    }
    if (!ReadArgInt32(env, argv[3], aghDnsPort) || aghDnsPort <= 0 || aghDnsPort > 65535) {
        return MakeUtf8(env, "invalid agh dns port");
    }
    // Optional trailing flag; defaults to no web dashboard (battery).
    bool aghWebEnabled = false;
    if (argc >= 5) {
        (void)ReadArgBool(env, argv[4], aghWebEnabled);
    }

    return ReturnErrOrUndefined(env,
        StartAghServerOnly(aghConfigPath, aghWorkDir, aghLogPath, static_cast<uint16_t>(aghDnsPort), aghWebEnabled));
}

napi_value JsStartLwDnsServer(napi_env env, napi_callback_info info)
{
    size_t argc = 6;
    napi_value argv[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 6) {
        return MakeUtf8(env,
            "bind ip, port, upstream dns, rules path, query log path, and cache ttl are required");
    }

    std::string bindIp;
    int32_t port = 0;
    std::string upstreamDnsIp;
    std::string rulesPath;
    std::string queryLogPath;
    int32_t cacheTtl = 0;
    if (!ReadArgString(env, argv[0], bindIp) || bindIp.empty()) {
        return MakeUtf8(env, "invalid bind ip");
    }
    if (!ReadArgInt32(env, argv[1], port) || port <= 0 || port > 65535) {
        return MakeUtf8(env, "invalid port");
    }
    if (!ReadArgString(env, argv[2], upstreamDnsIp) || upstreamDnsIp.empty()) {
        return MakeUtf8(env, "invalid upstream dns");
    }
    if (!ReadArgString(env, argv[3], rulesPath) || rulesPath.empty()) {
        return MakeUtf8(env, "invalid rules path");
    }
    if (!ReadArgString(env, argv[4], queryLogPath) || queryLogPath.empty()) {
        return MakeUtf8(env, "invalid query log path");
    }
    if (!ReadArgInt32(env, argv[5], cacheTtl) || cacheTtl < 0) {
        return MakeUtf8(env, "invalid cache ttl");
    }

    return ReturnErrOrUndefined(env,
        StartLwDnsServer(bindIp, static_cast<uint16_t>(port), upstreamDnsIp, rulesPath, queryLogPath,
            static_cast<uint32_t>(cacheTtl)));
}

napi_value JsStopDnsFilter(napi_env env, napi_callback_info info)
{
    (void)info;
    return ReturnErrOrUndefined(env, StopDnsFilter());
}

napi_value JsReloadDnsRules(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return MakeUtf8(env, "rules path is required");
    }

    std::string rulesPath;
    if (!ReadArgString(env, argv[0], rulesPath) || rulesPath.empty()) {
        return MakeUtf8(env, "invalid rules path");
    }
    return ReturnErrOrUndefined(env, ReloadDnsRules(rulesPath));
}

napi_value JsSetUpstreamDns(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return MakeUtf8(env, "upstream dns ip is required");
    }

    std::string upstreamDnsIp;
    if (!ReadArgString(env, argv[0], upstreamDnsIp) || upstreamDnsIp.empty()) {
        return MakeUtf8(env, "invalid upstream dns ip");
    }
    return ReturnErrOrUndefined(env, SetUpstreamDns(upstreamDnsIp));
}

napi_value JsGetStats(napi_env env, napi_callback_info info)
{
    (void)info;
    return MakeUtf8(env, GetStatsJson());
}

// Toggles the per-query / packet-counter hilog lines (default off, see
// g_verboseLog). Safe to call at any time, including while a filter runs.
napi_value JsSetNativeVerboseLog(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    bool enabled = false;
    if (argc >= 1) {
        (void)napi_get_value_bool(env, argv[0], &enabled);
    }
    g_verboseLog.store(enabled, std::memory_order_relaxed);
    LogInfo("==/vpn_native/verbose_log/ enabled=%{public}d", enabled ? 1 : 0);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// Smoke test for full mode: confirms the prebuilt AdGuardHome .so links and
// loads inside this NAPI module by returning its version string.
napi_value JsAghVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    return MakeUtf8(env, AdGuardHomeVersionString());
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"startDnsFilter", nullptr, JsStartDnsFilter, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startFullDnsFilter", nullptr, JsStartFullDnsFilter, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startAghServerOnly", nullptr, JsStartAghServerOnly, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startLwDnsServer", nullptr, JsStartLwDnsServer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopDnsFilter", nullptr, JsStopDnsFilter, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reloadDnsRules", nullptr, JsReloadDnsRules, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setUpstreamDns", nullptr, JsSetUpstreamDns, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStats", nullptr, JsGetStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setNativeVerboseLog", nullptr, JsSetNativeVerboseLog, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"aghVersion", nullptr, JsAghVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

}  // namespace

static napi_module vpnClientBridgeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "vpnclientbridge",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterVpnClientBridgeModule(void)
{
    napi_module_register(&vpnClientBridgeModule);
}
