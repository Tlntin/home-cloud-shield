# 更新日志 / Changelog — v0.0.6

本文档记录 `栖云盾 / home_cloud_shield` v0.0.6 的主要变更，中英双语。
This file records the notable changes of `栖云盾 / home_cloud_shield` v0.0.6 in both Chinese and English.

格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
The format is based on [Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

历史版本见 [`CHANGELOG-0.0.5.md`](./CHANGELOG-0.0.5.md)。/ Older versions are in [`CHANGELOG-0.0.5.md`](./CHANGELOG-0.0.5.md).

---

## [0.0.6] - 2026-06-11

相对 `v0.0.5` 的变更。/ Changes since `v0.0.5`.

### 中文

#### 新增

- **服务断开自动重启**：VPN / 纯 DNS 代理在后台被系统回收或异常退出时，App 会自动尝试重新拉起服务（指数退避 5s → 60s，最多 5 次，期间状态栏有提示；连续失败后停止并提示手动重启）。手动停止或切换网络模式不会触发自动重启。

#### 修复

- **DNS 查询记录达到几万条时打开 App 严重卡顿甚至闪退**：修了三处性能问题——
  - 首页统计不再每次刷新都对 SQLite 做全表 `COUNT / SUM` 聚合，改为**增量计数器 + 持久化存储（Preferences）**：摄取新日志时顺带累加，重启直接恢复，启动零扫描；
  - 日志文件改为**按字节偏移只读新增尾部**，不再每 1.2 秒读取整个文件（此前文件可达数 MB）；
  - 请求列表 / 域名排行的 SQL 查询改为**按需 + 限流**：列表查询仅在面板打开且有变化时执行，排行窗口（2000 条）仅在有新数据且距上次 ≥5 秒时刷新。空闲时每个刷新周期几乎零开销。
- **完整引擎（AdGuardHome）下 App 看不到新查询记录、与管理面板不同步**：AdGuardHome 默认把查询日志攒在内存（满 1000 条才写入文件），面板读内存所以实时、App 读文件所以一直为空。现在生成的配置改为**每条记录立即落盘**，App 列表几秒内即可跟上面板；同时日志文件改为 24 小时轮转以控制体积（记录已复制进 App 自己的数据库，不丢历史）。
- **启动与运行时卡顿**：调试日志预览此前每 1.2 秒读取整个 `debug.log`（默认不轮转、可积累到数 MB），启动首帧前也要全量读一次；现改为只读文件**末尾 16 KB**，并在内容无变化时跳过界面刷新。

#### 变更

- **统计口径**：首页「总数 / 已放行 / 已拦截 / 流量」为**自上次「清空 DNS 请求」以来的累计值**；日志保留期清理旧记录不再使统计数字回落。「最近 DNS 请求」列表仍只展示数据库中实际保留的记录，因此列表行数可能少于统计总数。
- 由于上述口径差异（且面板按 AdGuardHome 自身的时间窗口统计），App 与 AdGuardHome 面板的计数不要求完全一致，属正常现象。

### English

#### Added

- **Auto-restart for dropped services**: when the VPN / DNS-proxy service is reclaimed by the system in the background or exits unexpectedly, the app now restarts it automatically (exponential backoff 5s → 60s, up to 5 attempts, with status hints; gives up with a "restart manually" notice after repeated failures). Manual stops and network-mode switches never trigger a restart.

#### Fixed

- **Severe lag, even crashes, opening the app with tens of thousands of DNS records**: three performance issues fixed —
  - home-page stats no longer run a full-table `COUNT / SUM` over SQLite on every refresh; they are now **incremental counters persisted in Preferences**, bumped while ingesting new log lines and restored instantly on relaunch with zero scanning;
  - log files are now read **incrementally by byte offset** (only the appended tail), instead of re-reading the whole multi-MB file every 1.2 s;
  - request-list / domain-leaderboard SQL is now **on-demand and rate-limited**: list queries only run while the sheet is open and something changed; the 2000-row leaderboard window refreshes only when new rows arrived and at most every 5 s. Idle refresh ticks are now nearly free.
- **No new query records in the app (out of sync with the dashboard) on the full engine (AdGuardHome)**: AdGuardHome buffers its query log in memory by default (flushing to file only every 1000 entries); the dashboard reads memory so it looks live, while the app reads the file and stayed empty. The generated config now **flushes every entry to disk immediately**, so the app's list catches up with the dashboard within seconds; the log file also rotates every 24 h to bound its size (records are already copied into the app's own database, so no history is lost).
- **Launch and steady-state jank**: the debug-log preview used to re-read the entire `debug.log` (never rotated by default, can grow to several MB) every 1.2 s — including once before the first frame. It now reads only the **trailing 16 KB** and skips the UI update when nothing changed.

#### Changed

- **Stats semantics**: the home "total / allowed / blocked / traffic" numbers are now **cumulative since the last "Clear DNS requests"**; retention pruning of old records no longer decreases them. The "Recent DNS requests" list still shows only what is actually retained in the database, so its row count can be lower than the totals.
- Because of this (and because the dashboard counts within AdGuardHome's own time window), the app's counters and the AdGuardHome dashboard are not expected to match exactly; this is normal.

---

[0.0.6]: https://github.com/Tlntin/home-cloud-shield/compare/v0.0.5...v0.0.6
