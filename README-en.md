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
- [Changelog](#changelog)
- [Overview](#overview)
- [Filtering Engine Status](#filtering-engine-status)
- [Screenshots](#screenshots)
- [Features](#features)
- [Current Limitations](#current-limitations)
- [Good Fit For](#good-fit-for)
- [Not a Good Fit For](#not-a-good-fit-for)
- [Roadmap](#roadmap)
- [Disclaimer](#disclaimer)
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

## Changelog

Current version: **v0.0.4**. The latest bilingual changelog is in [`docs/CHANGELOG-0.0.4.md`](./docs/CHANGELOG-0.0.4.md); older versions are in [`docs/CHANGELOG-0.0.3.md`](./docs/CHANGELOG-0.0.3.md).

## Overview

The current application bundle name is `com.tlntin.home_cloud_shield`, and the product name shown in the UI is **栖云盾**.

Based on the current project structure and implemented pages, the project focuses on the following capabilities:

- Intercept DNS requests through a local VPN
- Filter and allow traffic using AdGuard-compatible rules
- Import, edit, save, and export rule files
- Display DNS requests, matched rules, domain rankings, and debug logs
- Keep an in-app open-source notice page for release compliance

## Filtering Engine Status

The app now supports **two filtering engines**, switchable directly from a **dropdown on the home page**:

- **Lightweight mode (default)**: uses the lightweight DNS filtering implementation in `entry/src/main/cpp/vpnclient_bridge.cpp`, prioritizing lower power usage and faster response for mobile background operation.
- **Full mode (AdGuardHome)**: wires in the ported `AdGuardHome` filtering core from `native/adguardhome-ohos-lib/` for broader rule compatibility, and unlocks **blocked services, online rule subscriptions, DNS rewrites, advanced DNS settings, and the AdGuardHome dashboard**; it is more resource-intensive and can be enabled on demand.

> For power usage and mobile suitability, the default remains the lightweight mode; full mode is wired in as an optional engine and is still being polished. Subscriptions, rewrites, advanced DNS, and the dashboard only take effect while the full engine is running.

### Network mode: VPN / DNS proxy (coexists with another VPN)

Besides the engine, the home page also lets you switch the **network mode** (orthogonal to the engine choice):

- **VPN mode (default)**: routes device-wide DNS traffic through a local VPN.
- **DNS proxy mode**: runs the filtering engine as a **local DNS server without a VPN** (`127.0.0.1`, TCP only), so it can **coexist with another VPN / proxy app**. Point your proxy app's DNS upstream at `tcp://127.0.0.1:<port>` to filter while proxying; the port is configurable in Settings and auto-advances to the next free port when busy.

> Across apps, UDP loopback on HarmonyOS is **unreliable** (in testing it works without Wi-Fi but usually fails on Wi-Fi), whereas **TCP loopback always works**; for reliability, point the peer proxy at a `tcp://` DNS upstream (e.g. `mihomo` / `clash-meta`, `sing-box`). Enabling "Background keep-alive" is also recommended so it keeps running in the background.

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

| Home | Config | Me | Settings |
| --- | --- | --- | --- |
| ![Home](./images/home.jpg) | ![Config](./images/configs.jpg) | ![Me](./images/me.jpg) | ![Settings](./images/settings.jpg) |

## Features

- **Dual filtering engine**: lightweight / full (AdGuardHome), switchable from a dropdown on the home page.
- **Network mode (coexists with another VPN)**: VPN mode / DNS proxy mode, switchable via a segmented control on the home page. DNS proxy mode uses no VPN and runs the filtering engine as a local DNS server (`tcp://127.0.0.1:<port>`) for other proxy apps to use; the port is configurable in Settings and auto-advances on conflict.
- **Local DNS filtering**: routes DNS traffic through a local VPN or a pure DNS proxy.
- **Rule management**: supports importing, editing, enabling, and exporting AdGuard-style DNS rules.
- **Full-mode-only capabilities**: blocked services (one-tap block common services, with tap-to-view of the actual domain rules), online rule subscriptions (with a recommended list library), DNS rewrites, advanced DNS settings (blocking mode / upstream mode / cache / DNSSEC / rate limit), and the AdGuardHome dashboard (opens in the system browser).
- **Custom upstream DNS**: multiple upstreams plus built-in presets (AliDNS / DNSPod / Baidu / AdGuard).
- **Log visibility**: shows recent DNS requests, matched rules, domain stats, and debug logs.
- **Modern UI**: white-card hero, config overview stats (local + subscriptions), grouped Settings / Me pages, light/dark theme, and **instant in-app language switching**.
- **Background keep-alive**: audio / location keep-alive and auto-start filtering.
- **Native bridge integration**: connects the OpenHarmony app layer with lower-level logic through `C/C++ + NAPI`.
- **Localization**: built-in Simplified Chinese, English, and Traditional Chinese; switching takes effect instantly.
- **Open-source release readiness**: keeps GPL-related source code, third-party notices, and submodule metadata in the repository.

## Current Limitations

- The current filtering capability focuses on **DNS domain filtering**, not a full network proxy stack or the complete `AdGuardHome` feature set.
- Rule compatibility is currently **partial AdGuard-style DNS rule compatibility**, not full syntax coverage.
- Because the project depends on a local VPN extension and native bridge integration, validation on a **physical HarmonyOS device** is currently recommended.
- Full mode (`AdGuardHome`) is wired in as an **optional engine**, but it is more resource-intensive, so the default remains the lightweight mode; full mode is still being polished.

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

- **Done**: lightweight / full (AdGuardHome) dual engine, rule management, log visibility, online subscriptions / DNS rewrites / advanced DNS settings, the modern UI, and instant in-app localization.
- **Near term**: keep polishing full-mode stability and power usage, and add clearer rule-compatibility notes and build-artifact documentation.
- **Mid to long term**: further align the capabilities of the lightweight and full modes, and improve the mobile background experience and release flow.

> Per-version details are in [`docs/CHANGELOG-0.0.4.md`](./docs/CHANGELOG-0.0.4.md) (and [`docs/CHANGELOG-0.0.3.md`](./docs/CHANGELOG-0.0.3.md)).

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

## Disclaimer

- This app is an on-device **DNS filtering tool**. The built-in "blocked services" list is derived from the `AdGuardHome` open-source project (`servicelist.go`); online subscriptions and recommended lists are **third-party open-source lists** provided "as is", and may over- or under-block.
- Whether to enable filtering, which services to block, and which lists to subscribe to are **entirely your own decisions and responsibility**. Use it only on **devices/networks you are authorized to manage**, and never for any unlawful purpose.
- The authors provide no warranty and are not liable for any service disruption, data loss, or other damage arising from use of this app.
- This app is open source under `GPL-3.0-only`. **On first launch you must read and accept this disclaimer before using the app**; declining exits the app. You can re-read it anytime via "Me → About → Disclaimer".

## Open Source and License

This repository is distributed under `GPL-3.0-only`.

The main reason is that the repository contains a ported and modified variant of `AdGuardHome`, distributed together with the application project. See the following files for details:

- `LICENSE`
- `THIRD_PARTY_NOTICES.md`

The app also keeps open-source notice resources for release verification:

- `entry/src/main/ets/pages/OpenSourceLicense.ets`
- `entry/src/main/resources/rawfile/adguard_open_source_licenses.txt`
