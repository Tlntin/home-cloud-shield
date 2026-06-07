# 更新日志 / Changelog

本文档记录 `栖云盾 / home_cloud_shield` 各版本的主要变更，中英双语。
This file records the notable changes of `栖云盾 / home_cloud_shield` in both Chinese and English.

格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
The format is based on [Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

---

## [0.0.3] - 2026-06-07

相对 `v0.0.2` 的变更。/ Changes since `v0.0.2`.

### 中文

#### 新增

- **双过滤引擎**：新增「完整模式」（内置 `AdGuardHome` 过滤内核），与「轻量级模式」可在**首页下拉切换**；轻量级仍为默认。
- **完整模式专属能力**（仅在完整引擎运行时生效）：
  - **服务屏蔽**：一键屏蔽常见服务（YouTube、TikTok 等），清单来自 AdGuardHome 官方 `servicelist.go`，可点击查看每个服务的具体域名规则（支持长按复制）。
  - **在线规则订阅**：订阅公共 DNS 拦截列表，内置推荐规则库（AdGuard DNS filter、AdAway、anti-AD、OISD、HaGeZi、Peter Lowe's、StevenBlack、1Hosts 等）。
  - **DNS 重写**：将域名解析到自定义应答。
  - **DNS 高级设置**：拦截方式、上游模式、缓存、DNSSEC、限速。
  - **AdGuardHome 管理面板**：通过外部系统浏览器打开。
- **自定义上游 DNS**：支持填写多条上游，内置预设（AliDNS / DNSPod / Baidu / AdGuard）。
- **免责声明**：新增简体中文 / English / 繁體中文三语免责声明（左对齐弹窗）。

#### 优化

- **全新现代化 UI**：白卡片 Hero + 中心状态圆圈、首页引擎下拉切换、配置页概览统计（本地 + 订阅）、推荐规则库可折叠、快速导入菜单（文件 / URL / 在线库）。
- **设置页重构**为更紧凑的分组卡片（语言 / 过滤规则 / 上游 DNS / 缓存 / 日志 / 调试）；语言置于顶部；完整模式专属项在轻量引擎下置灰并给出提示；移除设置页内的完整引擎开关（已统一到首页）。
- **「我的」页**改为分组式布局（外观 / 功能 / 后台保活 / 关于）+ 分段式主题切换。
- **调试日志**从首页移入「高级设置」。
- 停止过滤时增加「停止中…」过渡态：按钮立即置灰、隐藏「重启过滤」，避免误以为未停止。
- DNS 请求日志分页优化。
- 概览「已启用规则 / 本地·订阅」统计同时计入在线订阅。

#### 修复

- 修复应用内切换语言后，部分设置页 / 我的页的标题与标签不会立即刷新（需返回重进）的问题；现在切换语言即时生效，无需重启。

### English

#### Added

- **Dual filtering engine**: a new **Full mode** (embedded `AdGuardHome` filtering core) alongside the **Lightweight mode**, switchable from a **dropdown on the home page**; lightweight remains the default.
- **Full-mode-only capabilities** (effective only while the full engine is running):
  - **Blocked services**: one-tap block common services (YouTube, TikTok, etc.); the list is derived from AdGuardHome's official `servicelist.go`, and you can tap a service to view its actual domain rules (long-press to copy).
  - **Online rule subscriptions**: subscribe to public DNS blocklists, with a recommended library (AdGuard DNS filter, AdAway, anti-AD, OISD, HaGeZi, Peter Lowe's, StevenBlack, 1Hosts, etc.).
  - **DNS rewrites**: resolve domains to custom answers.
  - **Advanced DNS**: blocking mode, upstream mode, cache, DNSSEC, rate limit.
  - **AdGuardHome dashboard**: opens in the external system browser.
- **Custom upstream DNS**: multiple upstreams plus built-in presets (AliDNS / DNSPod / Baidu / AdGuard).
- **Disclaimer**: a new tri-lingual (Simplified Chinese / English / Traditional Chinese) disclaimer (left-aligned sheet).

#### Improved

- **Brand-new modern UI**: white-card hero with a central status circle, home-page engine dropdown, config overview stats (local + subscriptions), a collapsible recommended-list library, and a quick-import menu (file / URL / online library).
- **Settings page reworked** into more compact grouped cards (Language / Filtering / Upstream DNS / Cache / Logs / Debug); Language moved to the top; full-mode-only items are greyed out under the lightweight engine with a hint; the full-engine toggle was removed from Settings (now unified on the home page).
- **Me page** reorganized into grouped sections (Appearance / Features / Background / About) with a segmented theme control.
- **Debug log** moved from the home page into Advanced Settings.
- Added a "Stopping…" transitional state when stopping the filter: the button greys out immediately and the "Restart" button is hidden, so it no longer looks like it failed to stop.
- DNS request log pagination optimized.
- The "Enabled rules / Local·Subs" overview stats now also count online subscriptions.

#### Fixed

- Fixed an issue where some Settings / Me page titles and labels did not refresh immediately after switching the in-app language (previously required leaving and re-entering the page); language switching now takes effect instantly without a restart.

---

## [0.0.2] - 2026-04-18

首个公开标记版本（基线）。/ First publicly tagged release (baseline).

### 中文

- 基于本地 VPN 的轻量级 DNS 过滤、AdGuard 风格规则的导入 / 编辑 / 启停 / 导出。
- DNS 请求、命中规则、域名统计与调试日志可视化。
- 自定义上游 DNS、DNS 缓存时长设置、独立的高级设置页。
- 主页底部双击返回退出、保活与多语言资源等基础能力。
- 保留 GPL 对应源码、第三方声明与 `AdGuardHome` OHOS 移植工程。

### English

- Lightweight local-VPN-based DNS filtering with import / edit / enable / export of AdGuard-style rules.
- Visibility of DNS requests, matched rules, domain stats, and debug logs.
- Custom upstream DNS, DNS cache TTL settings, and a dedicated Advanced Settings page.
- Double-back-to-exit on main tabs, keep-alive, and localization resources.
- Keeps GPL source, third-party notices, and the `AdGuardHome` OHOS porting project.

[0.0.3]: https://github.com/Tlntin/home-cloud-shield/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/Tlntin/home-cloud-shield/releases/tag/v0.0.2
