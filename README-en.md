# home_cloud_shield / Qiyun Shield

[简体中文](./README.md) | [English](./README-en.md)

![OpenHarmony](https://img.shields.io/badge/OpenHarmony-App-blue)
![ArkTS](https://img.shields.io/badge/ArkTS-C%2B%2B%20Bridge-6f42c1)
![AdGuardHome](https://img.shields.io/badge/AdGuardHome-v0.107.64-2ea44f)
![License](https://img.shields.io/badge/License-GPL--3.0--only-red)

`home_cloud_shield` is a local DNS filtering experiment project targeting **HarmonyOS 6.0+**, built with **DevEco Studio**. The app intercepts DNS traffic through a local VPN, combines **AdGuard-style rules** with native bridge capabilities, and is used to validate DNS filtering, rule management, logging, and GPL-compliant source distribution workflows on HarmonyOS.

This repository currently keeps the following parts together:

- OpenHarmony / ArkTS application project
- C/C++ / NAPI native bridge code
- OHOS porting project for AdGuardHome
- Upstream source submodule and build scripts

This layout helps keep the build chain reproducible and makes it easier to prepare GPL-related source releases and distribution materials.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Repository Layout](#repository-layout)
- [Quick Start](#quick-start)
- [Build Notes](#build-notes)
- [Open Source and License](#open-source-and-license)
- [Additional Notes](#additional-notes)

## Overview

The current application bundle name is `com.tlntin.home_cloud_shield`, and the product name shown in the UI is **栖云盾**.

Based on the current project structure and implemented pages, the project focuses on the following capabilities:

- Intercept DNS requests through a local VPN
- Filter and allow traffic using AdGuard-compatible rules
- Import, edit, save, and export rule files
- Display DNS requests, matched rules, domain rankings, and debug logs
- Keep an in-app open-source notice page for release compliance

## Features

- **Local DNS filtering**: routes DNS traffic through a local VPN workflow.
- **Rule management**: supports importing, editing, enabling, and exporting AdGuard-style DNS rules.
- **Log visibility**: shows recent DNS requests, matched rules, domain stats, and debug logs.
- **Native bridge integration**: connects the OpenHarmony app layer with lower-level logic through `C/C++ + NAPI`.
- **Localization foundation**: the app already includes language resources for Simplified Chinese, English, and Traditional Chinese.
- **Open-source release readiness**: keeps GPL-related source code, third-party notices, and submodule metadata in the repository.

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
git clone --recurse-submodules <repo-url>
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

For more build details, see:

- `native/adguardhome-ohos-lib/README.md`

## Open Source and License

This repository is distributed under `GPL-3.0-only`.

The main reason is that the repository contains a ported and modified variant of `AdGuardHome`, distributed together with the application project. See the following files for details:

- `LICENSE`
- `THIRD_PARTY_NOTICES.md`

The app also keeps open-source notice resources for release verification:

- `entry/src/main/ets/pages/OpenSourceLicense.ets`
- `entry/src/main/resources/rawfile/adguard_open_source_licenses.txt`

## Additional Notes

- If `libadguardhome_ohos.so` is later shipped in a release package, update the in-app notices and release notes at the same time so the binary stays aligned with the corresponding source version.
- When publishing a source archive or download instructions, include `.gitmodules` and the submodule initialization steps to avoid incomplete source delivery.
- The repository is currently more focused on experimentation and engineering organization; some capabilities are still evolving.
- This document is provided for engineering and open-source release preparation and does not constitute formal legal advice.