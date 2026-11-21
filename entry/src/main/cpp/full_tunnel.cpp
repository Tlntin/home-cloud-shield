#include "full_tunnel.h"

#include <condition_variable>
#include <dlfcn.h>
#include <mutex>
#include <thread>
#include <unistd.h>

#include "libadguardhome_ohos.h"

#ifdef HAVE_APP_TUNNEL
extern "C" int hev_socks5_tunnel_main_from_str(const unsigned char *, unsigned int, int);
extern "C" void hev_socks5_tunnel_quit();
extern "C" void shield_tun_set_ready_callback(void (*)());
#endif

namespace {
struct TunnelCore {
    void *relay = dlopen("libadguardhome_ohos.so", RTLD_NOW | RTLD_LOCAL);
#ifdef HAVE_APP_TUNNEL
    decltype(&hev_socks5_tunnel_main_from_str) run = hev_socks5_tunnel_main_from_str;
    decltype(&hev_socks5_tunnel_quit) quit = hev_socks5_tunnel_quit;
    decltype(&shield_tun_set_ready_callback) setReady = shield_tun_set_ready_callback;
#else
    int (*run)(const unsigned char *, unsigned int, int) = nullptr;
    void (*quit)() = nullptr;
    void (*setReady)(void (*)()) = nullptr;
#endif
    char *(*startRelay)(char *, char *, int, int) =
        relay ? reinterpret_cast<decltype(startRelay)>(dlsym(relay, "ShieldTunnelStart")) : nullptr;
    void (*stopRelay)() =
        relay ? reinterpret_cast<decltype(stopRelay)>(dlsym(relay, "ShieldTunnelStop")) : nullptr;
    char *(*validateRules)(char *) =
        relay ? reinterpret_cast<decltype(validateRules)>(dlsym(relay, "ShieldTunnelValidateRules")) : nullptr;
};

const TunnelCore &Core()
{
    static const TunnelCore core;
    return core;
}

std::mutex controlMutex;
std::mutex stateMutex;
std::condition_variable stateChanged;
std::thread worker;
bool ready = false;
bool exited = false;
int exitCode = 0;

void OnReady()
{
    std::lock_guard<std::mutex> lock(stateMutex);
    ready = true;
    stateChanged.notify_all();
}

std::string TakeGoString(char *raw)
{
    if (!raw) {
        return {};
    }
    const std::string value(raw);
    AdGuardHomeFreeCString(raw);
    return value;
}
}

bool FullTunnelAvailable()
{
    const auto &core = Core();
    return core.run && core.quit && core.setReady && core.startRelay && core.stopRelay && core.validateRules;
}

bool FullTunnelRunning()
{
    std::lock_guard<std::mutex> lock(stateMutex);
    return ready && !exited;
}

std::string ValidateFullTunnelRules(const std::string &rules)
{
    if (!Core().validateRules) {
        return "The app tunnel relay is unavailable.";
    }
    return TakeGoString(Core().validateRules(const_cast<char *>(rules.c_str())));
}

std::string StartFullTunnel(int fd, const std::string &ipv4, const std::string &ipv6,
    uint16_t dnsPort, bool blockIPv6, const std::string &rules, const std::string &logPath)
{
    std::lock_guard<std::mutex> control(controlMutex);
    if (!FullTunnelAvailable() || worker.joinable()) {
        return "The app tunnel core is unavailable or already running.";
    }
    const int ownedFd = dup(fd);
    if (ownedFd < 0) {
        return "Could not duplicate the app tunnel file descriptor.";
    }
    const auto &core = Core();
    const std::string relay = TakeGoString(core.startRelay(const_cast<char *>(rules.c_str()),
        const_cast<char *>(logPath.c_str()), dnsPort, blockIPv6 ? 1 : 0));
    const auto separator = relay.find('\n');
    if (separator == std::string::npos) {
        close(ownedFd);
        return relay.empty() ? "Could not start the app tunnel relay." : relay;
    }
    const std::string config = "tunnel:\n  mtu: 1400\n  ipv4: " + ipv4 + "\n  ipv6: '" + ipv6 +
        "'\nsocks5:\n  address: 127.0.0.1\n  port: " + relay.substr(0, separator) +
        "\n  udp: udp\n  username: shield\n  password: '" + relay.substr(separator + 1) +
        "'\nmisc:\n  log-level: error\n  connect-timeout: 5000\n  read-write-timeout: 600000\n  limit-nofile: 0\n";
    std::unique_lock<std::mutex> lock(stateMutex);
    ready = false;
    exited = false;
    core.setReady(OnReady);
    try {
        worker = std::thread([config, ownedFd]() {
            const int result = Core().run(reinterpret_cast<const unsigned char *>(config.data()),
                static_cast<unsigned int>(config.size()), ownedFd);
            close(ownedFd);
            std::lock_guard<std::mutex> guard(stateMutex);
            exitCode = result;
            exited = true;
            stateChanged.notify_all();
        });
    } catch (...) {
        close(ownedFd);
        core.setReady(nullptr);
        core.stopRelay();
        return "Could not start the app tunnel worker.";
    }
    stateChanged.wait(lock, [] { return ready || exited; });
    if (!exited) {
        return {};
    }
    const int result = exitCode;
    lock.unlock();
    worker.join();
    core.setReady(nullptr);
    core.stopRelay();
    return "App tunnel core exited with code " + std::to_string(result) + ".";
}

void StopFullTunnel()
{
    std::lock_guard<std::mutex> control(controlMutex);
    if (!worker.joinable()) {
        return;
    }
    const auto &core = Core();
    if (FullTunnelRunning()) {
        core.quit();
    }
    worker.join();
    core.setReady(nullptr);
    core.stopRelay();
}
