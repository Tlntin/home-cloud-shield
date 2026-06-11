# 栖云盾 / home_cloud_shield

[简体中文](./README.md) | [English](./README-en.md)

<p align="center">
	<img src="./images/readme_banner_zh.png" alt="栖云盾 - 仅支持鸿蒙 6.0+" width="760" />
</p>

![OpenHarmony](https://img.shields.io/badge/OpenHarmony-App-blue)
![ArkTS](https://img.shields.io/badge/ArkTS-C%2B%2B%20Bridge-6f42c1)
![AdGuardHome](https://img.shields.io/badge/AdGuardHome-v0.107.64-2ea44f)
![Version](https://img.shields.io/badge/Version-v0.0.6-orange)
![License](https://img.shields.io/badge/License-GPL--3.0--only-red)

`栖云盾` 是一个面向 **HarmonyOS 6.0+** 的本地 DNS 过滤应用：通过**本地 VPN** 或**纯 DNS 代理**接管 DNS 流量，按 **AdGuard 风格规则**拦截广告与跟踪域名，内置**轻量级 / 完整（AdGuardHome）双过滤引擎**。

项目地址：<https://github.com/Tlntin/home-cloud-shield> ｜ 当前版本：**v0.0.6**（[更新日志](#更新日志)）

## 目录

- [核心特性](#核心特性)
- [应用截图](#应用截图)
- [获取与安装](#获取与安装)
- [更新日志](#更新日志)
- [引擎与网络模式](#引擎与网络模式)
- [规则兼容范围](#规则兼容范围)
- [当前限制](#当前限制)
- [免责声明](#免责声明)
- [快速开始与构建](#快速开始与构建)
- [开源与许可证](#开源与许可证)
- [你可能感兴趣的其它 App](#你可能感兴趣的其它-app)

## 核心特性

- **双过滤引擎**：轻量级（默认，低功耗）/ 完整（AdGuardHome 内核），首页下拉一键切换。
- **双网络模式**：VPN 模式（接管全设备 DNS）/ 纯 DNS 代理模式（不占用 VPN，**可与其他 VPN / 代理 App 共存**）。
- **Wi-Fi 下同样有效**：自动捕获 Wi-Fi 下发的解析器与常见公共 DNS，Wi-Fi ↔ 蜂窝切换时自动适配（v0.0.5 修复）。
- **规则管理**：导入 / 编辑 / 启停 / 导出 AdGuard 风格 DNS 规则。
- **完整模式专属**：服务屏蔽（一键屏蔽常见服务）、在线规则订阅（含推荐规则库）、DNS 重写、DNS 高级设置（拦截方式 / 上游模式 / 缓存 / DNSSEC / 限速）、AdGuardHome 管理面板。
- **日志与统计**：DNS 查询日志基于 SQLite 持久存储，「已放行 / 已拦截」跨重启累计，卡片点击直达对应筛选列表，另有域名排行与调试日志。
- **其他**：自定义上游 DNS（含 AliDNS / DNSPod / Baidu / AdGuard 预设）、后台保活、深浅色主题、简中 / English / 繁中三语即时切换。

## 应用截图

| 首页 | 配置页 | 我的 | 设置页 |
| --- | --- | --- | --- |
| ![首页](./images/home.jpg) | ![配置页](./images/configs.jpg) | ![我的](./images/me.jpg) | ![设置页](./images/settings.jpg) |

## 获取与安装

直接从 **Releases** 获取安装包：<https://github.com/Tlntin/home-cloud-shield/releases>

也可以从第三方应用站获取：<https://sydxky.cn/detail.php?id=575>

推荐使用 [小白调试助手（Auto-Installer）](https://github.com/likuai2010/auto-installer/releases/latest) 或 [HO-Kit](https://sydxky.cn/hokit.php) 安装；也可以用 **DevEco Studio** 自行构建（见[快速开始与构建](#快速开始与构建)）。

<details>
<summary>小白调试助手使用教程</summary>

小白调试助手是一款免费、跨平台的鸿蒙应用开发调试工具，适合直接安装 Releases 中的安装包。

- [下载教程文档（PDF）](https://github.com/Zitann/HarmonyOS-Haps/raw/refs/heads/main/assets/guide.pdf)
- [视频教程（Bilibili）](https://www.bilibili.com/video/BV1hkZ7YnEMd/)

</details>

<details>
<summary>Release 包命名说明</summary>

- 安装包文件名通常体现 **模块名 / 构建产物类型 / 签名状态**。
- 类似 `entry-default-unsigned.hap` 的文件表示 `entry` 模块的 **未签名 HAP**，更适合用于产物校验或二次签名前检查；能否直接安装取决于设备环境与签名配置。
- 以 Releases 页面的说明为准。

</details>

## 更新日志

当前版本 **v0.0.6**（2026-06-11），主要变更：

- **修复 DNS 记录达到几万条时打开 App 卡顿甚至闪退**：统计改为增量计数器持久化、日志只读新增尾部、列表查询按需限流。
- **修复完整引擎（AdGuardHome）下 App 看不到新查询记录**：查询日志改为每条立即落盘，App 列表与管理面板保持同步。
- **修复启动时状态闪变「已启动 → 已停止 → 已启动」**：忽略上次会话遗留的幽灵状态，自动启动时首屏直接显示「自动启动中…」。
- **新增服务断开自动重启**：后台 VPN / DNS 代理被系统回收后自动拉起（指数退避，最多 5 次）。

完整变更（中英双语）：[v0.0.6](./docs/CHANGELOG-0.0.6.md) ｜ [v0.0.5](./docs/CHANGELOG-0.0.5.md) ｜ [v0.0.4](./docs/CHANGELOG-0.0.4.md) ｜ [v0.0.3 及更早](./docs/CHANGELOG-0.0.3.md)

## 引擎与网络模式

首页提供两个相互独立的开关：**过滤引擎**（下拉）与**网络模式**（分段控件）。

### 过滤引擎

- **轻量级模式（默认）**：自研 DNS 过滤实现（`entry/src/main/cpp/vpnclient_bridge.cpp`），优先保证常驻运行的功耗与响应速度。
- **完整模式（AdGuardHome）**：接入 `native/adguardhome-ohos-lib/` 移植的 AdGuardHome 过滤内核，规则兼容性更完整，并解锁服务屏蔽、在线订阅、DNS 重写、高级设置与管理面板；相对更耗资源，按需开启。

### 网络模式

- **VPN 模式（默认）**：通过本地 VPN 接管全设备 DNS 流量。
- **纯 DNS 代理模式**：**不开启 VPN**，把过滤引擎作为本地 DNS 服务器（`127.0.0.1`，TCP / UDP 均支持）运行，从而**与其他 VPN / 代理 App 共存**。在你的代理软件里把 DNS 上游设为 `tcp://127.0.0.1:<端口>` 即可边代理边过滤；端口可在设置页自定义（默认 `5354`），被占用时自动顺延到下一个空闲端口。

<details>
<summary>纯 DNS 代理模式：TCP / UDP 怎么选</summary>

- 跨 App 的 **UDP 回环**在 HarmonyOS 上**并不可靠**：实测未连 Wi-Fi 时可用，连 Wi-Fi 时系统会把 App 的 UDP socket 绑定到 Wi-Fi 网卡，回环应答收不到；而 **TCP 回环始终可用**。
- 因此建议对端代理（如 `mihomo` / `clash-meta`、`sing-box`）使用 `tcp://127.0.0.1:<端口>` 形式的 DNS 上游。
- 若想用 `udp://127.0.0.1:<端口>`：自 v0.0.5 起轻量级与完整引擎都监听 UDP，但请**断开 Wi-Fi（改用蜂窝网络）**使用。
- 建议同时开启「后台保活」以维持后台运行。

</details>

## 规则兼容范围

轻量级引擎**部分兼容 AdGuard 风格 DNS 规则**，适合 DNS 域名过滤场景，但不等同于完整 AdGuardHome 语法覆盖；完整引擎直接使用 AdGuardHome 内核，兼容性以上游为准。

<details>
<summary>轻量级引擎已支持 / 未支持的语法</summary>

已支持：

- `@@` 白名单规则
- `||example.com` 域名后缀匹配
- `|example.com`、`|https://...` 前缀 / 起始匹配中的 DNS 域名相关用法
- `^` 分隔 / 截断语义的基础处理
- `*`、`*.` 形式的简单通配匹配
- `0.0.0.0 example.com`、`127.0.0.1 example.com`、`:: example.com`、`::1 example.com` 等 `hosts` 风格规则
- `$important`、`$badfilter`
- `$dnstype=` 中的 `A` / `AAAA` 限制

未支持：

- 元素隐藏、页面注入等浏览器侧规则（`##`、`#@#`、`#$#` 等）
- 超出当前 DNS 域名匹配器范围的复杂规则组合与高级语法

</details>

## 当前限制

- 过滤能力聚焦 **DNS 域名过滤**，并非完整网络层代理或防火墙。
- 依赖本地 VPN 扩展与原生桥接，推荐在 **HarmonyOS 6.0+ 真机**上运行验证，模拟器支持情况未验证。
- 完整模式（AdGuardHome）相对更耗资源，仍在持续打磨，默认保持轻量级模式。

<details>
<summary>适用 / 暂不适用场景</summary>

适用：

- 验证 HarmonyOS 上本地 VPN / 纯 DNS 代理接管 DNS 的可行性。
- 实验 AdGuard 风格 DNS 规则在移动端轻量实现中的兼容性。
- 研究 ArkTS ↔ C/C++ ↔ NAPI 原生桥接，以及 Go 项目（AdGuardHome）向 OHOS 的移植。
- 整理 GPL 对应源码、第三方声明与开源发布链路。

暂不适用：

- 期望直接等同于桌面 / 路由器环境中的完整 AdGuardHome 成品体验。
- 期望完整支持所有 AdGuard 语法、浏览器元素隐藏、脚本注入或复杂策略组合。
- 需要成熟稳定的全量代理、防火墙或企业级网络策略平台。

</details>

## 免责声明

- 本应用是运行在本机的 **DNS 过滤工具**。内置「服务屏蔽」清单来自 `AdGuardHome` 开源项目（`servicelist.go`）；在线订阅与推荐规则库均为**第三方开源列表**，按「现状」提供，可能存在误拦截或漏拦截。
- 是否启用过滤、屏蔽哪些服务、订阅哪些列表，**均由你自行决定并承担相应后果**。请仅在你**有权管理的设备 / 网络**上使用，请勿用于任何非法用途。
- 作者不提供任何担保，且不对因使用本应用造成的服务不可用、数据丢失或其他损失承担责任。
- 本应用基于 `GPL-3.0-only` 开源。**首次启动需阅读并同意本免责声明后方可使用**；如不同意将退出应用。应用内「我的 → 关于 → 免责声明」可随时再次查看。

## 快速开始与构建

### 1. 获取完整源码（含子模块）

```bash
git clone --recurse-submodules https://github.com/Tlntin/home-cloud-shield.git
# 若已普通克隆过：
git submodule update --init --recursive
```

> `AdGuardHome` 子模块固定到 `v0.107.64`，与仓库内的 OHOS 适配脚本保持一致。

### 2. 用 DevEco Studio 打开并构建

打开仓库根目录（根工程 `home_cloud_shield`，主模块 `entry`）：

- 最低兼容 SDK：`HarmonyOS 6.0.0(20)`；目标 SDK：`HarmonyOS 6.1.0(23)`。
- 推荐使用已安装 `HarmonyOS 6.1.0(23)` SDK 的 DevEco Studio 编译调试，并在真机上验证。

<details>
<summary>原生库（AdGuardHome OHOS 共享库）构建</summary>

相关脚本位于：

- `native/adguardhome-ohos-lib/scripts/build_ohos_shared.sh`
- `native/adguardhome-ohos-lib/scripts/update_third_party_adguardhome.sh`

构建细节见 [`native/adguardhome-ohos-lib/README.md`](./native/adguardhome-ohos-lib/README.md)。

</details>

<details>
<summary>仓库结构</summary>

```text
home_cloud_shield/
├── AppScope/                          # 应用级配置
├── entry/                             # OpenHarmony 主应用模块
│   ├── src/main/cpp/                  # C/C++ / NAPI 原生桥接（轻量级引擎）
│   ├── src/main/ets/                  # ArkTS 页面与能力实现
│   └── src/main/resources/            # 资源、多语言、rawfile 等
├── native/
│   └── adguardhome-ohos-lib/          # AdGuardHome 的 OHOS 移植工程
│       ├── scripts/                   # 构建与上游同步脚本
│       └── third_party/AdGuardHome/   # 上游 AdGuardHome 子模块
├── docs/                              # 各版本更新日志
├── LICENSE
├── THIRD_PARTY_NOTICES.md
└── README.md
```

</details>

## 开源与许可证

本仓库按 `GPL-3.0-only` 发布（仓库包含基于 `AdGuardHome` 的移植与修改版本，并与应用工程一起分发）。完整许可证见 [`LICENSE`](./LICENSE) 与 [`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md)；应用内「开源授权」页同步保留了相关说明。

## 你可能感兴趣的其它 App

同作者的其它 HarmonyOS 应用：

| 应用 | 一句话介绍 | 链接 |
| --- | --- | --- |
| **听澜盒** | 连接私人 Navidrome 音乐服务器的智能播放器：每日更新的丰富个性化推荐，支持下载与边下边播、元数据缓存减少在线请求、多服务器智能切换 | [官网](https://music.http5.cn/) ｜ [应用商店](https://appgallery.huawei.com/app/detail?id=com.tlntin.sonawave&channelId=SHARE&source=appshare) |
| **frp 助手** | 鸿蒙版 frp 内网穿透工具：多配置导入、一键启停、实时日志，数据全部保留在本地 | [官网](https://frp.http5.cn/) ｜ [应用商店](https://appgallery.huawei.com/app/detail?id=com.tlntin.frp&channelId=SHARE&source=appshare) |
| **栖云盒** | 鸿蒙端的 Home Assistant 管理应用，随时随地掌控你的智能家居 | [应用商店](https://appgallery.huawei.com/app/detail?id=com.tlntin.homecloudbox&channelId=SHARE&source=appshare) |
