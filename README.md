# 栖云盾 / home_cloud_shield

[简体中文](./README.md) | [English](./README-en.md)

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

- [项目概览](#项目概览)
- [应用截图](#应用截图)
- [功能特性](#功能特性)
- [仓库结构](#仓库结构)
- [快速开始](#快速开始)
- [构建说明](#构建说明)
- [开源与许可证](#开源与许可证)

## 项目概览

应用当前包名为 `com.tlntin.home_cloud_shield`，应用名称为 **栖云盾**。

从工程结构与现有页面设计来看，项目主要围绕以下能力展开：

- 通过本地 VPN 接管 DNS 请求
- 以 AdGuard 兼容规则进行过滤与放行
- 提供规则导入、编辑、保存与导出能力
- 展示 DNS 请求、命中规则、域名排行与调试日志
- 保留开源授权页，便于发布时同步许可证材料

## 应用截图

| 首页 | 配置页 | 我的 |
| --- | --- | --- |
| ![首页](https://pic1.imgdb.cn/item/69e08bc076462006f3fdcab6.jpg) | ![配置页](https://pic1.imgdb.cn/item/69e08ba376462006f3fdca49.jpg) | ![我的](https://pic1.imgdb.cn/item/69e08b9876462006f3fdca32.jpg) |

## 功能特性

- **本地 DNS 过滤**：基于本地 VPN 模式接管 DNS 流量。
- **规则管理**：支持导入、编辑、启停、导出兼容 AdGuard 风格的 DNS 规则。
- **日志可视化**：查看最近 DNS 请求、命中规则、域名统计与调试日志。
- **原生桥接**：通过 `C/C++ + NAPI` 连接 OpenHarmony 应用层与底层处理逻辑。
- **多语言基础**：应用内已具备简体中文、English、繁體中文相关语言资源。
- **开源分发准备**：仓库保留 GPL 相关源码、第三方说明与子模块信息。

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

## 开源与许可证

本仓库按 `GPL-3.0-only` 发布。

主要原因是仓库中包含基于 `AdGuardHome` 的移植与修改版本，并与应用工程一起分发。完整许可证见：

- `LICENSE`
- `THIRD_PARTY_NOTICES.md`

应用内还保留了开源授权说明页与相关资源，用于后续发布校对：

- `entry/src/main/ets/pages/OpenSourceLicense.ets`
- `entry/src/main/resources/rawfile/adguard_open_source_licenses.txt`
