# 更新日志 / Changelog — v0.1.0

本文档记录 `栖云盾 / home_cloud_shield` v0.1.0 的主要变更，中英双语。
This file records the notable changes of `栖云盾 / home_cloud_shield` v0.1.0 in both Chinese and English.

格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
The format is based on [Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

历史版本见 [`CHANGELOG-0.0.9.md`](./CHANGELOG-0.0.9.md)。/ Older versions are in [`CHANGELOG-0.0.9.md`](./CHANGELOG-0.0.9.md)。

---

## [0.1.0] - 2026-10-07

相对 `v0.0.9` 的变更。本版本主题：**全新沉浸式界面、分应用代理与数据传输保活**。
Changes since `v0.0.9`. Theme of this release: **a new immersive UI, per-app routing, and data-transfer keep-alive**.

### 中文

#### 新增

- **分应用代理**（我的 → 「分应用代理」，仅 VPN 模式）：按应用决定是否经过 DNS 过滤，提供三种模式：
  - **关闭**（默认）：所有应用都经过 DNS 过滤，与以前一致。
  - **白名单**：列表中已启用的应用**不经过** DNS 过滤，其余应用照常过滤。
  - **仅代理**：**只有**列表中已启用的应用经过 DNS 过滤，其余应用全部直连。
  - 右上角 **+** 添加应用：可从「快捷项」选择 26 个常见应用（包名均已在真机核对），也可手动填写包名并自定义名称；每个应用可单独启停或删除，最多 255 个。
  - **修改后自动生效**：无需手动重启过滤，VPN 会自动重建一次（网络短暂中断约 1 秒）。
  - 本应用自身始终不经过自己的 VPN，避免 DNS 回环；纯 DNS 代理模式下页面会提示设置不生效。
  - **纳入配置导入 / 导出**：导出的 JSON 在 `app` 段新增 `appSplitMode` 与 `appSplitApps`；导入时模式直接覆盖，应用列表按包名合并去重，运行中导入同样自动生效。
- **数据传输保活**（我的 → 「后台保活」）：在音频保活、定位保活之外新增第三种长时任务。开启后通知栏以**实况窗**显示运行状态与已拦截 / 已放行数，每 60 秒刷新一次进度。首次开启会请求通知权限；**默认关闭**。

#### 变更

- **沉浸式标题栏 + 滚动动态模糊**：各页面标题栏与状态栏融为一体，内容滚到标题栏下方时逐渐模糊（HarmonyOS 6.1 / API 23 及以上为沉浸式渐变模糊）；返回键、菜单键使用系统玻璃材质。
- **设置页、分应用页改为独立子页面**，支持系统返回键与侧滑返回。
- **配置页精简**：原来的大标题卡片改为标题栏右上角的 **+**（快速导入），再点一次收起。
- **错误提示**改为悬浮在标题栏下方，点击即可关闭，不再挤压页面内容。
- 「设置」入口的说明文字更新为实际包含的内容（语言、上游 DNS、缓存与日志、配置备份）。

#### 升级注意

- 分应用代理默认关闭，升级后过滤行为与 v0.0.9 一致。
- 数据传输保活需要持续的网络传输，DNS 流量较小时系统可能先暂停、再取消该任务（取消时「后台保活」卡片会提示）；建议与音频或定位保活同时开启。
- 系统推送、托管给系统的后台下载等由系统服务代发的流量，不受分应用规则控制。

### English

#### Added

- **Per-app routing** (Me → "Per-app routing", VPN mode only): decide per app whether it goes through DNS filtering, with three modes:
  - **Off** (default): every app is filtered, as before.
  - **Bypass**: enabled apps in the list **skip** DNS filtering; all other apps are filtered as usual.
  - **Only**: **only** the enabled apps in the list are filtered; every other app connects directly.
  - Tap **+** at the top right to add an app: pick from 26 common apps in "Quick pick" (bundle names verified on a real device) or enter a bundle name manually with an optional display name; each entry can be toggled or deleted, up to 255 apps.
  - **Changes apply automatically**: no manual restart needed — the VPN is rebuilt once (a ~1 s network blip).
  - This app never routes through its own VPN, avoiding a DNS loop; in pure DNS-proxy mode the page notes that the settings have no effect.
  - **Included in config import / export**: the exported JSON's `app` section gains `appSplitMode` and `appSplitApps`; on import the mode is overwritten and apps are merged by bundle name, applying live even while running.
- **Data-transfer keep-alive** (Me → "Background keep-alive"): a third continuous-task mode alongside audio and location keep-alive. When enabled, a **live-view** notification shows the running state with Blocked / Allowed counts, refreshing its progress every 60 s. Asks for notification permission the first time; **off by default**.

#### Changed

- **Immersive title bar with scroll-driven blur**: the title bar blends into the status bar and content scrolling beneath it is progressively blurred (immersive gradient blur on HarmonyOS 6.1 / API 23+); back and menu buttons use the system glass material.
- **Settings and per-app routing are now separate sub pages**, with system back and swipe-back support.
- **Leaner config page**: the large header card is replaced by a **+** (quick import) in the title bar; tap again to collapse.
- **Error banner** now floats just below the title bar and is dismissed with a tap, instead of pushing the page content down.
- The "Settings" entry description now lists what's actually inside (language, upstream DNS, cache & logs, backup).

#### Upgrade notes

- Per-app routing is off by default, so filtering behaves exactly as in v0.0.9 after upgrading.
- Data-transfer keep-alive expects ongoing traffic; with light DNS traffic the system may suspend and then cancel the task (the "Background keep-alive" card says so when that happens). Pair it with audio or location keep-alive.
- Traffic sent on an app's behalf by system services (system push, downloads handed to the system) is not covered by per-app rules.

---

[0.1.0]: https://github.com/Tlntin/home-cloud-shield/compare/v0.0.9...v0.1.0
