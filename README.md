# 栖云盾 / home_cloud_shield

[简体中文](./README.md) | [English](./README-en.md)

<p align="center">
	<img src="./images/readme_banner_zh.png" alt="栖云盾 - 仅支持鸿蒙 6.0+" width="760" />
</p>

![OpenHarmony](https://img.shields.io/badge/OpenHarmony-App-blue)
![ArkTS](https://img.shields.io/badge/ArkTS-C%2B%2B%20Bridge-6f42c1)
![AdGuardHome](https://img.shields.io/badge/AdGuardHome-v0.107.64-2ea44f)
![License](https://img.shields.io/badge/License-GPL--3.0--only-red)

`栖云盾` 是一个面向 **HarmonyOS 6.0+** 的本地 DNS 过滤实验项目，使用 **DevEco Studio** 编译。应用通过本地 VPN 接管 DNS 流量，结合 **AdGuard 风格规则** 与原生桥接能力，用于验证 HarmonyOS 端的 DNS 拦截、规则管理、日志观察与开源合规分发流程。

项目地址：<https://github.com/Tlntin/home-cloud-shield>

当前仓库同时保留了：

- OpenHarmony / ArkTS 应用工程
- C/C++ / NAPI 原生桥接代码
- AdGuardHome 的 OHOS 移植工程
- 上游源码子模块与构建脚本

便于持续整理可复现构建链路，以及 GPL 对应源码与发布材料。

## 目录

- [获取体验包](#获取体验包)
- [更新日志](#更新日志)
- [项目概览](#项目概览)
- [过滤引擎现状](#过滤引擎现状)
- [应用截图](#应用截图)
- [功能特性](#功能特性)
- [当前限制](#当前限制)
- [适用场景](#适用场景)
- [暂不适用场景](#暂不适用场景)
- [开发路线](#开发路线)
- [免责声明](#免责声明)
- [仓库结构](#仓库结构)
- [快速开始](#快速开始)
- [构建说明](#构建说明)
- [开源与许可证](#开源与许可证)

## 获取体验包

- Releases：<https://github.com/Tlntin/home-cloud-shield/releases>
- 仓库主页：<https://github.com/Tlntin/home-cloud-shield>

如果你只是想先体验当前版本，建议优先从 Releases 页面获取现成安装包；如果你希望验证原生桥接、规则引擎或后续移植链路，再按下文说明自行构建。

### 安装工具

**小白调试助手**

**下载链接：**[Link](https://github.com/likuai2010/auto-installer/releases/latest)

小白调试助手（Auto-Installer）是一款免费、跨平台的鸿蒙应用开发调试工具。**如果你是直接下载 Releases 中的安装包，推荐优先使用这个工具安装。**

- [点击下载教程文档](https://github.com/Zitann/HarmonyOS-Haps/raw/refs/heads/main/assets/guide.pdf)
- [点击查看视频教程](https://www.bilibili.com/video/BV1hkZ7YnEMd/)

当然，你也可以直接使用 **DevEco Studio** 自行构建并安装。

### Release 包说明

- Releases 中的安装包文件名通常会体现 **模块名 / 构建产物类型 / 签名状态**。
- 若出现类似 `entry-default-unsigned.hap` 的文件名，一般表示这是 `entry` 模块生成的 **未签名 HAP**。
- `unsigned` 包更适合用于构建产物校验、流程验证或二次签名前检查；是否可直接安装，取决于你的设备环境与签名配置。
- 如果后续发布已签名或更适合分发的构建产物，建议优先以 Releases 页面的说明为准。

## 更新日志

当前版本：**v0.0.4**。最新中英双语更新日志见 [`docs/CHANGELOG-0.0.4.md`](./docs/CHANGELOG-0.0.4.md)；历史版本见 [`docs/CHANGELOG-0.0.3.md`](./docs/CHANGELOG-0.0.3.md)。

## 项目概览

应用当前包名为 `com.tlntin.home_cloud_shield`，应用名称为 **栖云盾**。

从工程结构与现有页面设计来看，项目主要围绕以下能力展开：

- 通过本地 VPN 接管 DNS 请求
- 以 AdGuard 兼容规则进行过滤与放行
- 提供规则导入、编辑、保存与导出能力
- 展示 DNS 请求、命中规则、域名排行与调试日志
- 保留开源授权页，便于发布时同步许可证材料

## 过滤引擎现状

当前应用已支持**双过滤引擎**，可在**首页直接下拉切换**：

- **轻量级模式（默认）**：使用 `entry/src/main/cpp/vpnclient_bridge.cpp` 中的轻量级 DNS 过滤实现，优先保证移动端常驻运行的功耗与响应速度。
- **完整模式（AdGuardHome）**：接入 `native/adguardhome-ohos-lib/` 移植的 `AdGuardHome` 过滤内核，提供更完整的规则兼容性，并解锁**服务屏蔽、在线规则订阅、DNS 重写、DNS 高级设置、AdGuardHome 管理面板**等能力；相对更耗资源，按需开启。

> 出于功耗与移动端场景适配考虑，默认仍为轻量级模式；完整模式作为可选项已经接入，仍在持续打磨。其中订阅、重写、高级 DNS、管理面板等能力仅在完整引擎运行时生效。

### 网络模式：VPN / 纯 DNS 代理（可与其他 VPN 共存）

除了引擎，首页还可切换**网络模式**（与引擎选择相互正交）：

- **VPN 模式（默认）**：通过本地 VPN 接管全设备 DNS 流量。
- **纯 DNS 代理模式**：**不开启 VPN**，把过滤引擎作为本地 DNS 服务器（`127.0.0.1`，仅 TCP）运行，从而**与其他 VPN / 代理 App 共存**。在你的代理软件里把 DNS 上游设为 `tcp://127.0.0.1:<端口>` 即可边代理边过滤；端口可在设置页自定义，被占用时会自动顺延到下一个空闲端口。

> 跨 App 的 UDP 回环在 HarmonyOS 上**并不可靠**（实测未连 WiFi 时可用、连 WiFi 时通常失效），而 **TCP 回环始终可用**；为稳定起见建议对端代理使用 `tcp://` 形式的 DNS 上游（如 `mihomo` / `clash-meta`、`sing-box`）。
>
> 若想用 UDP：**完整引擎（AdGuardHome）**才监听 UDP，可在代理里填 `udp://127.0.0.1:<端口>`，且请**断开 WiFi（改用蜂窝网络）**——连 WiFi 时系统会把 App 的 UDP socket 绑定到 WiFi 网卡、回环应答收不到，无 WiFi 时则可用；轻量级引擎目前仅 TCP。另建议开启「后台保活」以维持后台运行。

### 当前轻量级规则引擎的兼容范围

当前实现是**部分兼容 AdGuard 风格 DNS 规则**，适合 DNS 域名过滤场景，但**不是完整兼容 `AdGuardHome`**。

已支持的主要能力：

- `@@` 白名单规则
- `||example.com` 这类域名后缀匹配规则
- `|example.com`、`|https://...` 这类前缀/起始匹配规则中的 DNS 域名相关用法
- `^` 分隔/截断语义的基础处理
- `*`、`*.` 形式的简单通配匹配
- `0.0.0.0 example.com`、`127.0.0.1 example.com`、`:: example.com`、`::1 example.com` 等 `hosts` 风格规则
- `$important`
- `$badfilter`
- `$dnstype=` 中的 `A` / `AAAA` 限制

当前未采用或未完整支持的部分包括：

- 完整 `AdGuardHome` 过滤内核能力
- 元素隐藏、页面注入等浏览器侧规则，例如 `##`、`#@#`、`#$#`
- 超出当前 DNS 域名匹配器范围的复杂规则组合与高级语法

因此，当前项目更准确的定位是：**兼容部分 AdGuard 风格 DNS 规则的 HarmonyOS 本地 DNS 过滤实验项目**。

## 应用截图

| 首页 | 配置页 | 我的 | 设置页 |
| --- | --- | --- | --- |
| ![首页](./images/home.jpg) | ![配置页](./images/configs.jpg) | ![我的](./images/me.jpg) | ![设置页](./images/settings.jpg) |

## 功能特性

- **双过滤引擎**：轻量级 / 完整（AdGuardHome），首页一键下拉切换。
- **网络模式（与其他 VPN 共存）**：VPN 模式 / 纯 DNS 代理模式，首页分段切换。纯 DNS 代理模式不占用 VPN，将过滤引擎作为本地 DNS 服务器（`tcp://127.0.0.1:<端口>`）供其他代理 App 接入；端口可在设置页自定义，冲突时自动顺延。
- **本地 DNS 过滤**：通过本地 VPN 或纯 DNS 代理接管 DNS 流量。
- **规则管理**：支持导入、编辑、启停、导出兼容 AdGuard 风格的 DNS 规则。
- **完整模式专属能力**：服务屏蔽（一键屏蔽常见服务，可点开查看具体域名规则）、在线规则订阅（含推荐规则库）、DNS 重写、DNS 高级设置（拦截方式 / 上游模式 / 缓存 / DNSSEC / 限速）、AdGuardHome 管理面板（外部浏览器打开）。
- **自定义上游 DNS**：支持填写多条上游与内置预设（AliDNS / DNSPod / Baidu / AdGuard）。
- **日志可视化**：查看最近 DNS 请求、命中规则、域名统计与调试日志。
- **现代化界面**：白卡片 Hero、配置页概览统计（本地 + 订阅）、分组式设置 / 我的页、深浅色主题、应用内**即时切换语言**。
- **后台保活**：音频 / 定位保活与自动启动过滤。
- **原生桥接**：通过 `C/C++ + NAPI` 连接 OpenHarmony 应用层与底层处理逻辑。
- **多语言**：内置简体中文、English、繁體中文，切换即时生效。
- **开源分发准备**：仓库保留 GPL 相关源码、第三方说明与子模块信息。

## 当前限制

- 当前过滤能力聚焦 **DNS 域名过滤**，并非完整网络层代理或完整 `AdGuardHome` 能力。
- 当前规则兼容性为**部分 AdGuard 风格 DNS 规则兼容**，不等同于完整语法覆盖。
- 由于项目依赖本地 VPN 扩展与原生桥接，当前更推荐在 **HarmonyOS 真机** 上验证。
- 完整模式（`AdGuardHome`）已作为**可选引擎**接入，但相对更耗资源，默认仍为轻量级模式；完整模式仍在持续打磨。

## 适用场景

- 想验证 **HarmonyOS 上本地 VPN 接管 DNS** 的可行性。
- 想实验 **AdGuard 风格 DNS 规则** 在移动端轻量实现中的基本兼容性。
- 想研究 **ArkTS ↔ C/C++ ↔ NAPI** 的原生桥接方式。
- 想整理 **GPL 对应源码、第三方声明、移植工程与分发材料** 的开源发布链路。

## 暂不适用场景

- 期望它直接等同于桌面/路由器环境中的 **完整 AdGuardHome 成品体验**。
- 期望完整支持所有 **AdGuard 语法、浏览器元素隐藏、脚本注入或复杂策略组合**。
- 需要成熟稳定的 **全量代理、防火墙、企业级网络策略平台**。
- 需要“开箱即用、无需理解签名与设备环境”的最终消费级分发体验。

## 开发路线

- **已完成**：轻量级 / 完整（AdGuardHome）双引擎、规则管理、日志可视化、在线订阅 / DNS 重写 / DNS 高级设置、现代化 UI 与应用内即时多语言。
- **近期**：持续打磨完整模式的稳定性与功耗、补充规则兼容说明与构建产物文档。
- **中长期**：进一步对齐轻量级与完整模式的能力，优化移动端常驻体验与发布流程。

> 各版本详细变更见 [`docs/CHANGELOG-0.0.4.md`](./docs/CHANGELOG-0.0.4.md)（及 [`docs/CHANGELOG-0.0.3.md`](./docs/CHANGELOG-0.0.3.md)）。

## 仓库结构

```text
home_cloud_shield/
├── AppScope/                          # 应用级配置
├── entry/                             # OpenHarmony 主应用模块
│   ├── src/main/cpp/                  # C/C++ / NAPI 原生桥接
│   ├── src/main/ets/                  # ArkTS 页面与能力实现
│   └── src/main/resources/            # 资源、多语言、rawfile 等
├── native/
│   └── adguardhome-ohos-lib/          # AdGuardHome 的 OHOS 移植工程
│       ├── scripts/                   # 构建与上游同步脚本
│       └── third_party/AdGuardHome/   # 上游 AdGuardHome 子模块
├── LICENSE
├── THIRD_PARTY_NOTICES.md
└── README.md
```

### 关键目录

- `entry/`：OpenHarmony 应用工程主体。
- `entry/src/main/ets/pages/`：应用页面，例如主页与开源授权页。
- `entry/src/main/cpp/`：当前应用使用的原生桥接实现。
- `native/adguardhome-ohos-lib/`：AdGuardHome 的 OHOS 共享库移植工程。
- `native/adguardhome-ohos-lib/third_party/AdGuardHome/`：以上游 `AdGuardHome` 作为 git submodule 引入的源码目录。

## 快速开始

### 1. 获取完整源码

首次克隆时，建议直接连同子模块一起拉取：

```bash
git clone --recurse-submodules https://github.com/Tlntin/home-cloud-shield.git
```

如果已经普通克隆过仓库，请继续执行：

```bash
git submodule update --init --recursive
```

> 当前 `AdGuardHome` 子模块固定到 `v0.107.64`，用于与本仓库内的 OHOS 适配脚本保持一致。

### 2. 打开工程

请使用 **DevEco Studio** 打开仓库根目录进行编译：

- 根工程：`home_cloud_shield`
- 主模块：`entry`

## 构建说明

### 应用构建

当前项目面向 **HarmonyOS 6.0+**，可使用 **DevEco Studio** 按标准工程方式编译。工作区已提供常用任务：

- 最低兼容 SDK / API Version：`HarmonyOS 6.0.0(20)`
- 目标 SDK / API Version：`HarmonyOS 6.1.0(23)`
- 推荐使用已安装 `HarmonyOS 6.1.0(23)` SDK 的 **DevEco Studio** 版本进行编译与调试。
- 由于项目包含本地 VPN 扩展与原生桥接能力，当前建议在 **HarmonyOS 6.0+ 真机**上运行和验证，模拟器支持情况暂未验证。

- `栖云盾: 构建 entry HAP`
- `栖云盾: 安装并启动到设备(自动识别)`
- `栖云盾: 构建 + 安装并启动`

### 原生库构建

AdGuardHome OHOS 共享库相关脚本位于：

- `native/adguardhome-ohos-lib/scripts/build_ohos_shared.sh`
- `native/adguardhome-ohos-lib/scripts/update_third_party_adguardhome.sh`

SO 库构建细节请直接查看：

- [`native/adguardhome-ohos-lib/README.md`](./native/adguardhome-ohos-lib/README.md)

## 免责声明

- 本应用是运行在本机的 **DNS 过滤工具**。内置「服务屏蔽」清单来自 `AdGuardHome` 开源项目（`servicelist.go`）；在线订阅与推荐规则库均为**第三方开源列表**，按「现状」提供，可能存在误拦截或漏拦截。
- 是否启用过滤、屏蔽哪些服务、订阅哪些列表，**均由你自行决定并承担相应后果**。请仅在你**有权管理的设备 / 网络**上使用，请勿用于任何非法用途。
- 作者不提供任何担保，且不对因使用本应用造成的服务不可用、数据丢失或其他损失承担责任。
- 本应用基于 `GPL-3.0-only` 开源。**首次启动需阅读并同意本免责声明后方可使用**；如不同意将退出应用。应用内「我的 → 关于 → 免责声明」可随时再次查看。

## 开源与许可证

本仓库按 `GPL-3.0-only` 发布。

主要原因是仓库中包含基于 `AdGuardHome` 的移植与修改版本，并与应用工程一起分发。完整许可证见：

- `LICENSE`
- `THIRD_PARTY_NOTICES.md`

应用内还保留了开源授权说明页与相关资源，用于后续发布校对：

- `entry/src/main/ets/pages/OpenSourceLicense.ets`
- `entry/src/main/resources/rawfile/adguard_open_source_licenses.txt`
