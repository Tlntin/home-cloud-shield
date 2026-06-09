# 更新日志 / Changelog — v0.0.5

本文档记录 `栖云盾 / home_cloud_shield` v0.0.5 的主要变更，中英双语。
This file records the notable changes of `栖云盾 / home_cloud_shield` v0.0.5 in both Chinese and English.

格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
The format is based on [Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

历史版本见 [`CHANGELOG-0.0.4.md`](./CHANGELOG-0.0.4.md)。/ Older versions are in [`CHANGELOG-0.0.4.md`](./CHANGELOG-0.0.4.md).

---

## [0.0.5] - 2026-06-09

相对 `v0.0.4` 的变更。/ Changes since `v0.0.4`.

### 中文

#### 新增

- **轻量级引擎的 DNS 服务器现已支持 UDP**：纯 DNS 代理模式下，除 `tcp://` 外也可使用 `udp://127.0.0.1:<端口>` 作为上游（此前仅完整引擎支持 UDP）。
- **首页「已放行 / 已拦截」卡片可点击**：点击后直接打开「最近 DNS 请求」并停在对应的筛选标签。

#### 修复

- **连上 Wi-Fi 后过滤 / 拦截失效**：系统与许多应用会把 DNS 直接发往 Wi-Fi 下发的解析器，从而绕过本应用。现在会把这些解析器以及常见公共 DNS 一并纳入捕获，Wi-Fi 下过滤继续生效；并在 Wi-Fi ↔ 蜂窝网络切换时自动适配。
- **「已拦截」有计数、展开列表却为空**：计数与列表此前来自不同的数据来源；现已统一，点开任意筛选都能看到对应记录。
- **完整引擎（AdGuardHome）下 App 看不到查询记录、且「已拦截」恒为 0**：现在直接读取 AdGuardHome 自身的查询日志，并按其过滤结果正确区分「已放行 / 已拦截」（含「屏蔽服务」等拦截）。
- **重启 App 后「已放行」从 0 重新计数**：统计改为持久累计，与总数保持一致、重启不归零（已放行 + 已拦截 = 总数）。
- **纯 DNS 代理模式下打开 AdGuardHome 管理面板出现 404**（如 `dns_info`、`access/list` 等接口）：常驻进程内重启 AdGuardHome 时控制接口未重新注册所致，已修复。
- **完整引擎的缓存命中统计**：此前恒为 0，现已能正确统计。

#### 变更

- **DNS 查询日志改用 SQLite 存储**：计数、分页、筛选与域名统计更快、更准，并跨重启累计。
- **AdGuardHome 管理面板入口统一到设置页**：移除首页的重复入口；完整引擎下 **VPN 模式与纯 DNS 代理模式均可打开**（不再在代理模式下置灰）。
- **域名统计卡片**：将「缓存命中 / 上游解析」改为「已放行 / 已拦截」，更直观（两者之和即解析次数）。

### English

#### Added

- **The lightweight engine's DNS server now supports UDP**: in DNS-proxy mode you can point your proxy at `udp://127.0.0.1:<port>` as well as `tcp://` (previously only the full engine listened on UDP).
- **Tappable "Allowed / Blocked" cards on the home page**: tapping one opens "Recent DNS requests" pre-filtered to that tab.

#### Fixed

- **Filtering / blocking stopped working after joining Wi-Fi**: the system and many apps send DNS straight to the Wi-Fi-provided resolver, bypassing the app. Those resolvers (plus common public DNS) are now captured too, so filtering keeps working on Wi-Fi; it also re-adapts when switching between Wi-Fi and cellular.
- **"Blocked" showed a count but an empty list**: the count and the list came from different sources; they are now unified, so any filter shows its matching records.
- **No DNS records shown (and "Blocked" stuck at 0) on the full engine (AdGuardHome)**: the app now reads AdGuardHome's own query log and classifies allowed / blocked from its result (including "blocked services").
- **"Allowed" reset to 0 after an app restart**: counters now use a persistent cumulative store, consistent with the total and surviving restarts (allowed + blocked = total).
- **404 errors when opening the AdGuardHome panel in DNS-proxy mode** (e.g. `dns_info`, `access/list`): caused by control endpoints not re-registering when AdGuardHome restarts inside the long-lived process; fixed.
- **Cache-hit stats on the full engine**: previously always 0, now counted correctly.

#### Changed

- **DNS query log moved to SQLite storage**: faster, more accurate counts / pagination / filtering and domain stats, accumulated across restarts.
- **AdGuardHome panel entry consolidated to the Settings page**: the duplicate entry on the home page was removed; with the full engine it now opens in **both VPN mode and DNS-proxy mode** (no longer greyed out in proxy mode).
- **Domain stats card**: "cache hits / upstream queries" replaced with "allowed / blocked" (clearer, and the two add up to the resolve count).

---

[0.0.5]: https://github.com/Tlntin/home-cloud-shield/compare/v0.0.4...v0.0.5
