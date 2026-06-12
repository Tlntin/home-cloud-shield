# 更新日志 / Changelog — v0.0.7

本文档记录 `栖云盾 / home_cloud_shield` v0.0.7 的主要变更，中英双语。
This file records the notable changes of `栖云盾 / home_cloud_shield` v0.0.7 in both Chinese and English.

格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
The format is based on [Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

历史版本见 [`CHANGELOG-0.0.6.md`](./CHANGELOG-0.0.6.md)。/ Older versions are in [`CHANGELOG-0.0.6.md`](./CHANGELOG-0.0.6.md).

---

## [0.0.7] - 2026-06-12

相对 `v0.0.6` 的变更。本版本主题：**降低长期运行（尤其是完整引擎）的耗电**。
Changes since `v0.0.6`. Theme of this release: **lower battery drain for long-running filtering (especially the full engine)**.

### 中文

#### 新增

- **「Web 管理面板服务」开关**（设置 → 过滤引擎，仅完整引擎）：控制内置 AdGuardHome 是否启动管理面板的 HTTP 服务。**默认关闭**——面板服务（HTTP 监听 + 服务协程，浏览器开着面板时还会周期性轮询 API）是后台耗电来源之一，而多数时候并不需要它。需要查看面板时打开开关即可（过滤会自动重启生效）；关闭时「打开管理面板」入口置灰。
- **native 调试日志开关**（内部）：C++ 过滤层每条 DNS 查询、每 50 个包各打一行系统日志，一天可达数万次调用；现默认静音，仅排查问题时可经接口开启，不影响 App 内的请求记录与调试日志文件。

#### 变更（省电优化）

- **完整引擎去掉重复的逐查询写盘**：此前每条 DNS 查询会被写盘两次（C++ 转发层一次、AdGuardHome 查询日志一次），而完整模式下 App 只读取后者。现在 C++ 层不再写自己的日志文件，每条查询少一次文件操作，App 功能不受影响。
- **后台状态刷新自适应降频**：VPN 服务此前每秒写一次状态文件、全天不停，灭屏待机也在唤醒 CPU 和闪存。现在仅当 App 界面在前台时保持每秒刷新；界面退到后台或灭屏后自动降为约 30 秒一次心跳（状态变化仍即时写入）。回到前台 1~2 秒内恢复实时。
- **界面不可见时暂停轮询**：首页的 1.2 秒刷新循环（读状态/日志、查数据库）在页面退到后台时暂停，回到前台立即恢复并刷新一次。
- **消除空闲唤醒**：TUN 读取线程此前每 200 毫秒醒一次检查停止标志（空闲时每秒 5 次无谓唤醒）；现改为事件通知（eventfd）即时唤醒，空闲时长期休眠。
- **关闭 AdGuardHome 内置统计模块**：App 已维护自己的统计计数，AdGuardHome 的 stats.db 属重复落盘，现固定关闭。副作用：管理面板首页的图表为空（面板的查询日志页不受影响），App 内统计照常。
- **乐观缓存默认开启**（DNS 高级设置 → 乐观缓存）：过期缓存先应答、后台再刷新，减少同步上游请求（即减少蜂窝射频唤醒）。仅影响新安装/未显式设置过的用户；已手动设置过的保留原值。

#### 升级注意

- 升级后 AdGuardHome 管理面板**默认不可访问**（`127.0.0.1:3000` 拒绝连接），这是预期行为；到 设置 → 过滤引擎 打开「Web 管理面板服务」即可恢复。
- 管理面板首页的统计图表因统计模块关闭而显示为空；查看统计请使用 App 首页。

### English

#### Added

- **"Web dashboard service" toggle** (Settings → Filter engine, full engine only): controls whether the embedded AdGuardHome serves its admin dashboard over HTTP. **Off by default** — the dashboard service (HTTP listener + serve goroutines, plus periodic API polling while a browser has the panel open) is a background battery cost that most sessions never use. Flip it on when you need the panel (the filter restarts automatically to apply); while off, the "open dashboard" entries are greyed out.
- **Native debug-log switch** (internal): the C++ filter layer used to emit one system-log line per DNS query plus one per 50 packets — easily tens of thousands of calls a day. It is now silent by default and can be enabled via an interface for troubleshooting; the in-app request records and debug-log file are unaffected.

#### Changed (battery optimizations)

- **Removed duplicate per-query disk writes on the full engine**: each DNS query used to be written to disk twice (once by the C++ relay, once by AdGuardHome's query log), while the app only reads the latter in full mode. The C++ layer no longer writes its own log file there — one fewer file operation per query, no functional change.
- **Adaptive status refresh in the background**: the VPN service used to rewrite its status file every second, around the clock, waking CPU and flash even with the screen off. It now keeps the 1 s cadence only while the app UI is in the foreground, and drops to a ~30 s heartbeat once the UI is hidden (state transitions are still written immediately). Returning to the foreground restores real-time updates within 1–2 s.
- **UI polling pauses while hidden**: the home page's 1.2 s refresh loop (status/log reads, DB queries) now stops when the page leaves the foreground and resumes — with an immediate refresh — when it returns.
- **Idle wakeups eliminated**: the TUN reader thread used to wake every 200 ms just to check a stop flag (5 pointless wakeups per second when idle). It now uses event notification (eventfd) for instant wakeup and sleeps indefinitely while idle.
- **AdGuardHome's built-in statistics module disabled**: the app keeps its own counters, so AdGuardHome's stats.db was redundant disk I/O. Side effect: the dashboard's front-page charts are empty (its query-log page still works); in-app stats are unaffected.
- **Optimistic cache on by default** (Advanced DNS → optimistic cache): answer from an expired cache entry first and refresh in the background, reducing synchronous upstream round-trips (i.e. cellular radio wakeups). Affects fresh installs / unset users only; explicitly saved settings are kept.

#### Upgrade notes

- After upgrading, the AdGuardHome dashboard is **unreachable by default** (`127.0.0.1:3000` refuses connections) — this is intended; enable "Web dashboard service" under Settings → Filter engine to restore it.
- The dashboard's front-page charts are empty because the statistics module is disabled; use the app's home page for stats.

---

[0.0.7]: https://github.com/Tlntin/home-cloud-shield/compare/v0.0.6...v0.0.7
