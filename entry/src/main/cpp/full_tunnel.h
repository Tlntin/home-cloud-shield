#pragma once

#include <cstdint>
#include <string>

bool FullTunnelAvailable();
bool FullTunnelRunning();
std::string ValidateFullTunnelRules(const std::string &rules);
std::string StartFullTunnel(int fd, const std::string &ipv4, const std::string &ipv6,
    uint16_t dnsPort, bool blockIPv6, const std::string &rules, const std::string &logPath);
void StopFullTunnel();
