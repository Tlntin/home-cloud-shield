#include <napi/native_api.h>

#include <algorithm>
#include <arpa/inet.h>
#include <array>
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
#include <sys/socket.h>
#include <sys/time.h>
#include <thread>
#include <unordered_map>
#include <unistd.h>
#include <vector>

#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "vpnbridge"

namespace {

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
    std::string upstreamDnsIp;
    std::string dnsServerIp;
    std::shared_ptr<const std::vector<RuleEntry>> activeRules;
    uint32_t dnsCacheTtlSeconds = 3600;
    std::unordered_map<std::string, DnsCacheEntry> dnsResponseCache;
    std::thread worker;
};

StatsState g_state;

constexpr int kForwardWorkerCount = 8;
constexpr size_t kMaxQueuedForwardTasks = 2048;
constexpr int kUpstreamTimeoutSec = 2;
constexpr int kUpstreamAttempts = 2;

// Serializes writes back to the TUN fd across the reader thread (blocked
// responses) and the forward worker threads (upstream responses).
std::mutex g_tunWriteMu;

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
    std::string upstreamDnsIp;
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

std::vector<uint8_t> ForwardDnsQuery(const uint8_t *query, size_t len, const std::string &upstreamDnsIp, std::string &error)
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
        addr.sin6_port = htons(53);
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
        addr.sin_port = htons(53);
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
    LogInfo("==/vpn_native/dns/ domain=%{public}s qtype=%{public}s action=%{public}s source=%{public}s rule=%{public}s req=%{public}zu resp=%{public}zu",
        domain.c_str(), QuestionTypeName(qtype), blocked ? "blocked" : "allowed", source.c_str(), rule.c_str(),
        requestBytes, responseBytes);
}

// Resolve a filtered-through query upstream (or from cache) and write the
// response back to the TUN device. Runs on a forward worker thread.
void ProcessForwardTask(ForwardTask &task)
{
    std::vector<uint8_t> dnsResponse;
    std::string source = "upstream";
    std::string responseError;

    const bool cacheHit = TryGetCachedDnsResponse(task.question, task.query.data(), task.query.size(), dnsResponse);
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
        dnsResponse = ForwardDnsQuery(task.query.data(), task.query.size(), task.upstreamDnsIp, responseError);
        if (!dnsResponse.empty()) {
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

std::vector<uint8_t> ForwardDnsQueryTcp(const uint8_t *query, size_t len, const std::string &upstreamDnsIp,
    std::string &error)
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
        addr6.sin6_port = htons(53);
        if (inet_pton(AF_INET6, upstreamDnsIp.c_str(), &addr6.sin6_addr) != 1) {
            close(sock);
            error = "invalid upstream DNS ip";
            return response;
        }
        addr = reinterpret_cast<sockaddr *>(&addr6);
        addrLen = sizeof(addr6);
    } else {
        addr4.sin_family = AF_INET;
        addr4.sin_port = htons(53);
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
    std::string upstreamDnsIp;
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        rules = g_state.activeRules;
        queryLogPath = g_state.queryLogPath;
        upstreamDnsIp = g_state.upstreamDnsIp;
    }

    const MatchResult match = rules ? MatchDomain(question.name, question.qtype, *rules) : MatchResult {};

    std::vector<uint8_t> dnsResponse;
    std::string source = "upstream";
    std::string responseError;
    if (match.blocked) {
        source = "blocked";
        dnsResponse = BuildBlockedDnsResponse(message.data(), message.size(), question);
    } else {
        const bool cacheHit = TryGetCachedDnsResponse(question, message.data(), message.size(), dnsResponse);
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
            dnsResponse = ForwardDnsQueryTcp(message.data(), message.size(), upstreamDnsIp, responseError);
            if (!dnsResponse.empty()) {
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
    std::string upstreamDnsIp;
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        rules = g_state.activeRules;
        queryLogPath = g_state.queryLogPath;
        upstreamDnsIp = g_state.upstreamDnsIp;
    }

    const MatchResult match = rules ? MatchDomain(question.name, question.qtype, *rules) : MatchResult {};

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
    task.matchedRule = match.matchedRule;
    task.upstreamDnsIp = upstreamDnsIp;
    task.queryLogPath = queryLogPath;
    EnqueueForwardTask(std::move(task));
}

void ReaderLoop(int tunFd)
{
    uint8_t buffer[65536];
    pollfd pfd {};
    pfd.fd = tunFd;
    pfd.events = POLLIN;

    for (;;) {
        {
            std::lock_guard<std::mutex> lock(g_state.mu);
            if (g_state.stopRequested) {
                break;
            }
        }

        // Wake immediately when a packet arrives; the timeout only bounds how
        // often we re-check the stop flag.
        const int ready = poll(&pfd, 1, 200);
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

        const ssize_t readBytes = read(tunFd, buffer, sizeof(buffer));
        if (readBytes > 0) {
            {
                std::lock_guard<std::mutex> lock(g_state.mu);
                UpdatePacketStatsLocked(g_state, buffer, readBytes);
                if (g_state.totalPackets <= 5 || g_state.totalPackets % 50 == 0) {
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
    state.upstreamDnsIp = upstreamDnsIp;
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
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        g_state.stopRequested = true;
        g_state.running = false;
        reader = std::move(g_state.worker);
    }
    if (reader.joinable()) {
        reader.join();
    }

    // Join the forward workers before touching the TUN fd: one of them may still
    // be writing an upstream response back to it.
    StopForwardPool();

    int fdToClose = -1;
    {
        std::lock_guard<std::mutex> lock(g_state.mu);
        fdToClose = g_state.tunFd;
        g_state.tunFd = -1;
        g_state.activeRules.reset();
        g_state.dnsResponseCache.clear();
        g_tcpConns.clear();
    }
    if (fdToClose >= 0) {
        close(fdToClose);
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
        g_state.worker = std::thread(ReaderLoop, dupFd);
    }

    LogInfo("==/vpn_native/reader_started/ dup_fd=%{public}d", dupFd);
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

napi_value JsGetStats(napi_env env, napi_callback_info info)
{
    (void)info;
    return MakeUtf8(env, GetStatsJson());
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"startDnsFilter", nullptr, JsStartDnsFilter, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopDnsFilter", nullptr, JsStopDnsFilter, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reloadDnsRules", nullptr, JsReloadDnsRules, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStats", nullptr, JsGetStats, nullptr, nullptr, nullptr, napi_default, nullptr},
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
