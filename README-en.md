# home_cloud_shield / Qiyun Shield

[简体中文](./README.md) | [English](./README-en.md)

<p align="center">
	<img src="./images/readme_banner_en.png" alt="Qiyun Shield - HarmonyOS 6.0+ only" width="760" />
</p>

![OpenHarmony](https://img.shields.io/badge/OpenHarmony-App-blue)
![ArkTS](https://img.shields.io/badge/ArkTS-C%2B%2B%20Bridge-6f42c1)
![AdGuardHome](https://img.shields.io/badge/AdGuardHome-v0.107.64-2ea44f)
![License](https://img.shields.io/badge/License-GPL--3.0--only-red)

`home_cloud_shield` is a local DNS filtering experiment project targeting **HarmonyOS 6.0+**, built with **DevEco Studio**. The app intercepts DNS traffic through a local VPN, combines **AdGuard-style rules** with native bridge capabilities, and is used to validate DNS filtering, rule management, logging, and GPL-compliant source distribution workflows on HarmonyOS.

Project URL: <https://github.com/Tlntin/home-cloud-shield>

This repository currently keeps the following parts together:

- OpenHarmony / ArkTS application project
- C/C++ / NAPI native bridge code
- OHOS porting project for AdGuardHome
- Upstream source submodule and build scripts

This layout helps keep the build chain reproducible and makes it easier to prepare GPL-related source releases and distribution materials.

## Table of Contents

- [Get a Build](#get-a-build)
- [Overview](#overview)
- [Filtering Engine Status](#filtering-engine-status)
- [Screenshots](#screenshots)
- [Features](#features)
- [Current Limitations](#current-limitations)
- [Good Fit For](#good-fit-for)
- [Not a Good Fit For](#not-a-good-fit-for)
- [Roadmap](#roadmap)
- [Repository Layout](#repository-layout)
- [Quick Start](#quick-start)
- [Build Notes](#build-notes)
- [Open Source and License](#open-source-and-license)

## Get a Build

- Releases: <https://github.com/Tlntin/home-cloud-shield/releases>
- Repository: <https://github.com/Tlntin/home-cloud-shield>

If you only want to try the current version, it is recommended to download a package from the Releases page first. If you want to validate the native bridge, rule engine, or the porting toolchain, follow the build steps below instead.

### Recommended install tool

**Auto-Installer**

**Download:** [Link](https://github.com/likuai2010/auto-installer/releases/latest)

Auto-Installer is a free, cross-platform HarmonyOS app deployment and debugging tool. **If you download packages directly from Releases, this is the recommended tool for installation.**

- [Guide document](https://github.com/Zitann/HarmonyOS-Haps/raw/refs/heads/main/assets/guide.pdf)
- [Video tutorial](https://www.bilibili.com/video/BV1hkZ7YnEMd/)

Of course, you can also build and install the app directly with **DevEco Studio**.

### Release package notes

- Package names in Releases usually reflect the **module name / build artifact type / signing state**.
- A file name such as `entry-default-unsigned.hap` usually means an **unsigned HAP** built from the `entry` module.
- An `unsigned` package is more suitable for build verification, workflow validation, or checking artifacts before secondary signing. Whether it can be installed directly depends on your device environment and signing setup.
- If signed or distribution-ready artifacts are provided later, the instructions on the Releases page should be treated as the source of truth.

## Overview

The current application bundle name is `com.tlntin.home_cloud_shield`, and the product name shown in the UI is **栖云盾**.

Based on the current project structure and implemented pages, the project focuses on the following capabilities:

- Intercept DNS requests through a local VPN
- Filter and allow traffic using AdGuard-compatible rules
- Import, edit, save, and export rule files
- Display DNS requests, matched rules, domain rankings, and debug logs
- Keep an in-app open-source notice page for release compliance

## Filtering Engine Status

At runtime, the app currently uses the **lightweight DNS filtering implementation** in `entry/src/main/cpp/vpnclient_bridge.cpp`, rather than the full `AdGuardHome` runtime.

The `native/adguardhome-ohos-lib/` directory is currently kept mainly for the following purposes:

- preserving the OHOS porting project and build chain for `AdGuardHome`
- validating that the shared library can be built
- preparing for possible future integration of a full filtering engine

For now, the app does **not** directly enable the full `AdGuardHome` library as its default filtering engine, mainly due to concerns around **power usage, resource cost, and mobile-device suitability**.

The long-term plan is to support two modes:

- **Lightweight mode**: continue using the current C/C++ implementation, prioritizing lower power usage and faster response for mobile background operation
- **Full mode**: try integrating the complete `AdGuardHome` filtering capability when the trade-offs become acceptable

### Compatibility scope of the current lightweight engine

The current implementation is **partially compatible with AdGuard-style DNS rules** for DNS domain filtering scenarios, but it is **not a full `AdGuardHome`-compatible engine**.

Currently supported rule capabilities include:

- `@@` allowlist rules
- domain suffix rules such as `||example.com`
- DNS-domain-related usage of prefix/start-match rules such as `|example.com` and `|https://...`
- basic handling of the `^` separator / boundary semantics
- simple wildcard matching with `*` and `*.`
- `hosts`-style rules such as `0.0.0.0 example.com`, `127.0.0.1 example.com`, `:: example.com`, and `::1 example.com`
- `$important`
- `$badfilter`
- `A` / `AAAA` restrictions via `$dnstype=`

The following are not currently adopted or not fully supported:

- the full `AdGuardHome` filtering core
- browser-side cosmetic or injection rules such as `##`, `#@#`, and `#$#`
- more advanced syntax combinations beyond the scope of the current DNS domain matcher

So the more accurate description of this project today is: a **HarmonyOS local DNS filtering experiment that supports part of the AdGuard-style DNS rule set**.

## Screenshots

| Home | Config | Me |
| --- | --- | --- |
| ![Home](./images/home.jpg) | ![Config](./images/configs.jpg) | ![Me](./images/me.jpg) |

## Features

- **Local DNS filtering**: routes DNS traffic through a local VPN workflow.
- **Rule management**: supports importing, editing, enabling, and exporting AdGuard-style DNS rules.
- **Log visibility**: shows recent DNS requests, matched rules, domain stats, and debug logs.
- **Native bridge integration**: connects the OpenHarmony app layer with lower-level logic through `C/C++ + NAPI`.
- **Localization foundation**: the app already includes language resources for Simplified Chinese, English, and Traditional Chinese.
- **Open-source release readiness**: keeps GPL-related source code, third-party notices, and submodule metadata in the repository.

## Current Limitations

- The current filtering capability focuses on **DNS domain filtering**, not a full network proxy stack or the complete `AdGuardHome` feature set.
- Rule compatibility is currently **partial AdGuard-style DNS rule compatibility**, not full syntax coverage.
- Because the project depends on a local VPN extension and native bridge integration, validation on a **physical HarmonyOS device** is currently recommended.
- `native/adguardhome-ohos-lib/` is currently kept mainly for porting and build validation, and is not yet wired in as the app's default runtime filtering core.

## Good Fit For

- validating whether **local-VPN-based DNS interception** works well on HarmonyOS
- experimenting with the basic compatibility of **AdGuard-style DNS rules** in a lightweight mobile implementation
- studying the **ArkTS ↔ C/C++ ↔ NAPI** native bridge architecture
- organizing a reproducible open-source release chain for **GPL source, third-party notices, porting code, and distribution materials**

## Not a Good Fit For

- expecting a drop-in **full AdGuardHome product experience** like on desktop or router deployments
- expecting complete support for all **AdGuard syntax, cosmetic filtering, script injection, or advanced rule combinations**
- needing a mature and stable **full proxy, firewall, or enterprise-grade network policy platform**
- expecting a fully consumer-ready distribution flow with no need to understand signing or device environment details

## Roadmap

- **Near term**: continue improving the lightweight DNS filtering engine, rule management UX, log visibility, and real-device stability.
- **Mid term**: add clearer rule-compatibility notes, better build artifact documentation, and more complete release instructions.
- **Mid to long term**: evaluate the cost/benefit of integrating the full `AdGuardHome` filtering capability on HarmonyOS.
- **Target shape**: support two filtering modes in parallel:
	- **Lightweight mode**: optimized for lower power usage, mobile background operation, and fast response.
	- **Full mode**: optimized for broader rule compatibility and more complete filtering behavior.

## Repository Layout

```text
home_cloud_shield/
├── AppScope/                          # App-level configuration
├── entry/                             # Main OpenHarmony application module
│   ├── src/main/cpp/                  # C/C++ / NAPI native bridge
│   ├── src/main/ets/                  # ArkTS pages and abilities
│   └── src/main/resources/            # resources, i18n, rawfiles, etc.
├── native/
│   └── adguardhome-ohos-lib/          # OHOS porting project for AdGuardHome
│       ├── scripts/                   # build and upstream sync scripts
│       └── third_party/AdGuardHome/   # upstream AdGuardHome submodule
├── LICENSE
├── THIRD_PARTY_NOTICES.md
└── README.md
```

### Key Directories

- `entry/`: main OpenHarmony application project.
- `entry/src/main/ets/pages/`: app pages such as the dashboard and open-source notice page.
- `entry/src/main/cpp/`: native bridge implementation used by the app.
- `native/adguardhome-ohos-lib/`: OHOS shared-library port of AdGuardHome.
- `native/adguardhome-ohos-lib/third_party/AdGuardHome/`: upstream `AdGuardHome` source imported as a git submodule.

## Quick Start

### 1. Fetch the full source tree

For a fresh clone, fetch submodules together with the repository:

```bash
git clone --recurse-submodules https://github.com/Tlntin/home-cloud-shield.git
```

If you already cloned the repository without submodules, run:

```bash
git submodule update --init --recursive
```

> The `AdGuardHome` submodule is currently pinned to `v0.107.64` so it stays aligned with the OHOS adaptation scripts in this repository.

### 2. Open the project

Open the repository root in **DevEco Studio** and build it there:

- workspace root: `home_cloud_shield`
- main module: `entry`

## Build Notes

### App build

This project targets **HarmonyOS 6.0+** and should be built with **DevEco Studio**. The workspace already includes useful tasks:

- Minimum compatible SDK / API version: `HarmonyOS 6.0.0(20)`
- Target SDK / API version: `HarmonyOS 6.1.0(23)`
- It is recommended to use a **DevEco Studio** installation with the `HarmonyOS 6.1.0(23)` SDK installed for building and debugging.
- Because the project includes a local VPN extension and native bridge integration, it is currently recommended to run and validate it on a **HarmonyOS 6.0+ physical device**. Emulator support has not been verified yet.

- `栖云盾: 构建 entry HAP`
- `栖云盾: 安装并启动到设备(自动识别)`
- `栖云盾: 构建 + 安装并启动`

### Native library build

The AdGuardHome OHOS shared-library scripts are located at:

- `native/adguardhome-ohos-lib/scripts/build_ohos_shared.sh`
- `native/adguardhome-ohos-lib/scripts/update_third_party_adguardhome.sh`

For SO library build details, see:

- [`native/adguardhome-ohos-lib/README.md`](./native/adguardhome-ohos-lib/README.md)

## Open Source and License

This repository is distributed under `GPL-3.0-only`.

The main reason is that the repository contains a ported and modified variant of `AdGuardHome`, distributed together with the application project. See the following files for details:

- `LICENSE`
- `THIRD_PARTY_NOTICES.md`

The app also keeps open-source notice resources for release verification:

- `entry/src/main/ets/pages/OpenSourceLicense.ets`
- `entry/src/main/resources/rawfile/adguard_open_source_licenses.txt`
