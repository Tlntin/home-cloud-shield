# 更新日志 / Changelog — v0.0.9

本文档记录 `栖云盾 / home_cloud_shield` v0.0.9 的主要变更，中英双语。
This file records the notable changes of `栖云盾 / home_cloud_shield` v0.0.9 in both Chinese and English.

格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
The format is based on [Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

历史版本见 [`CHANGELOG-0.0.8.md`](./CHANGELOG-0.0.8.md)。/ Older versions are in [`CHANGELOG-0.0.8.md`](./CHANGELOG-0.0.8.md)。

---

## [0.0.9] - 2026-06-15

相对 `v0.0.8` 的变更。本版本主题：**规则订阅的本地化管理、配置导入导出、常驻通知栏与自动上游 DNS**。
Changes since `v0.0.8`. Theme of this release: **local rule-subscription management, config import/export, a persistent stats notification, and automatic upstream DNS**.

### 中文

#### 新增

- **配置导入 / 导出**（配置 → 「💾 配置备份」）：一键导出 / 导入 JSON 配置，兼容「AdGuard 内容拦截」App 的 `adguard.json`（`sources` 订阅、`blocked` 拦截、`allowed` 放行、`redirected` 重写），并扩展为本 App 的超集（含引擎/端口/上游/高级 DNS/本地规则文件等）。导入为**合并去重**，并在导入后自动生效。
- **在线订阅的本地化管理**（配置 → 「📡 我的订阅」）：把订阅从隐藏的弹层提升为配置页上的独立区块，集中查看与管理所有订阅（导入的 + 已订阅的预设）。
  - **订阅即下载到本地并校验**：订阅 / 导入时自动下载列表内容到本地缓存，并校验是否为有效规则列表。下载失败或并非规则列表（例如指向网页的链接）会标记为 **✗ 无法使用**、开关**默认关闭**，且不会进入过滤引擎。
  - **状态一目了然**：每条订阅显示 **✓ N 条规则 / ✗ 无法使用 / ⏳ 下载中**。
  - **点卡片查看订阅内容**：**优先读取本地缓存**（秒开、离线可看），无缓存才联网拉取；查看器内可**一键刷新**（重新下载）或在浏览器打开。
  - **开关 = 启用 / 停用**（停用不会删除），另有独立的 **🗑 删除按钮**（二次确认后才删除）。
  - **「🔄 刷新 / 🩺 检测」**：一键重新下载全部订阅 / 检测可用性并汇总「✓ 可用 · ✗ 不可用」。
  - **推荐规则库同步增强**：可点击卡片查看内容、可直接取消订阅，点「订阅」即下载到缓存。
- **常驻通知栏**：在通知栏常驻显示**已拦截 / 已放行 / 总解析**累计统计（与首页数字一致），刷新间隔可选 1–5 秒；点击通知可进入 App。采用静默通知，不震动、不打扰。**默认关闭**（每隔几秒重发通知会唤醒设备，关闭以省电），需要时在「我的」页打开。
- **自动获取上游 DNS**（设置 → 上游 DNS，仅 VPN 模式）：跟随系统 / 路由器下发的 DNS，利于把内网域名解析到局域网 IP、降低延迟；WiFi ↔ 蜂窝切换时自动更新。**默认关闭**，关闭时回退到手动填写的上游列表。

#### 升级注意

- 升级后已有订阅未必带本地缓存与状态，点「📡 我的订阅」标题栏的 **🔄 刷新** 或 **🩺 检测** 即可重新下载并标记可用性。
- 导入的 `adguard.json` 中 `content://` 等非 http(s) 的订阅无法在线下载，导入时会被跳过并在结果中提示。

### English

#### Added

- **Config import / export** (Config → "💾 Config backup"): one-tap export / import of a JSON config, compatible with the `adguard.json` of the "AdGuard content blocker" app (`sources` subscriptions, `blocked`, `allowed`, `redirected` rewrites), extended into this app's superset (engine / ports / upstream / advanced DNS / local rule files, etc.). Import is a **merge-and-dedupe** and is applied immediately.
- **Local management of online subscriptions** (Config → "📡 My subscriptions"): subscriptions are promoted from a hidden sheet to a dedicated section on the config page, so all of them (imported + subscribed presets) can be viewed and managed in one place.
  - **Subscribing downloads + validates locally**: subscribing / importing fetches the list content into a local cache and checks that it looks like a real rule list. A list that can't be downloaded or isn't a rule list (e.g. a link to a web page) is marked **✗ unusable**, its toggle defaults **off**, and it is excluded from the filter engine.
  - **Status at a glance**: each subscription shows **✓ N rules / ✗ unusable / ⏳ downloading**.
  - **Tap a card to view its content**: reads the **local cache first** (instant, works offline), only fetching live when there's no cache; the viewer offers a one-tap **Refresh** (re-download) and "Open in browser".
  - **Toggle = enable / disable** (disabling never deletes); a separate **🗑 Delete** button removes a list after a confirmation.
  - **"🔄 Refresh / 🩺 Check"**: re-download every subscription / check usability and report "✓ usable · ✗ unusable".
  - **Recommended library upgraded too**: tap a card to view its content, unsubscribe directly, and subscribing downloads to the cache.
- **Persistent stats notification**: keeps a sticky notification showing cumulative **Blocked / Allowed / Total** counts (matching the home page), with a selectable refresh interval (1–5 s); tapping it opens the app. It uses a silent slot — no vibration, no noise. **Off by default** (republishing every few seconds wakes the device, so it's off to save battery) — enable it on the "Me" page when you want it.
- **Automatic upstream DNS** (Settings → Upstream DNS, VPN mode only): follows the system / router DNS, which helps resolve LAN hostnames to local IPs and lowers latency, and updates automatically across Wi-Fi ↔ cellular switches. **Off by default**; falls back to the manual upstream list when off.

#### Upgrade notes

- After upgrading, existing subscriptions may not yet have a local cache or status — tap **🔄 Refresh** or **🩺 Check** in the "📡 My subscriptions" header to re-download them and mark usability.
- `content://` and other non-http(s) subscriptions inside an imported `adguard.json` can't be downloaded and are skipped on import (reported in the result).

---

[0.0.9]: https://github.com/Tlntin/home-cloud-shield/compare/v0.0.8...v0.0.9
