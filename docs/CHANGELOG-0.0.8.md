# 更新日志 / Changelog — v0.0.8

本文档记录 `栖云盾 / home_cloud_shield` v0.0.8 的主要变更，中英双语。
This file records the notable changes of `栖云盾 / home_cloud_shield` v0.0.8 in both Chinese and English.

格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
The format is based on [Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

历史版本见 [`CHANGELOG-0.0.7.md`](./CHANGELOG-0.0.7.md)。/ Older versions are in [`CHANGELOG-0.0.7.md`](./CHANGELOG-0.0.7.md).

---

## [0.0.8] - 2026-06-14

相对 `v0.0.7` 的变更。本版本主题：**上游 DNS 支持加密格式（DoH/DoT 等），并按引擎区分能力**。
Changes since `v0.0.7`. Theme of this release: **encrypted upstream DNS (DoH/DoT and more), gated per engine**.

### 中文

#### 新增

- **上游 DNS 支持加密格式（仅完整引擎）**：除 IPv4 / IPv6 外，现可填写 DoH（`https://`）、DoT（`tls://`）、DoQ（`quic://`）、`h3://`、`sdns://`、`tcp://` / `udp://`，以及 `[/domain/]server` 分流语法和带端口的主机名。这些格式交由内置 AdGuardHome 解析。
- **加密 DNS 预设按钮**（设置 → 上游 DNS）：一键填入 AliDNS DoH / DNSPod DoH / AdGuard DoH / AliDNS DoT。
- **按引擎区分支持能力**：轻量引擎为纯 C++ 实现，仅支持纯 IP 明文 DNS（Do53），因此在轻量模式下**加密预设按钮置灰禁用**；若输入框里残留加密上游，会显示橙色提示，点「应用」时给出「轻量模式仅支持 IP，请切换完整模式」的明确报错（而非笼统的格式错误）。

#### 变更 / 修复

- **`bootstrap_dns` 只用纯 IP**：用于解析 DoH/DoT 的主机名，因此两个 AdGuardHome 配置生成处（VPN 模式、DNS 代理模式）都改为只取上游列表里的 IP 子集；当所有上游均为加密格式时，回退到默认解析器（`119.29.29.29`），避免 bootstrap 死锁。
- **完整模式读取上游时保留非 IP 条目**：此前 VPN 扩展读取上游列表会把非 IP 条目静默过滤掉，导致完整模式下 DoH/DoT 无法生效；现仅在轻量模式做 IP-only 过滤。
- **从完整模式切回轻量模式更稳健**：启动 DNS 代理（轻量）前，会把上游自动过滤为纯 IP，避免把残留的 DoH URL 喂给底层 native 引擎而导致解析全部失败。

#### 升级注意

- 之前在**完整模式**下填写的加密上游（DoH/DoT 等），切换到**轻量模式**后会被忽略（轻量仅支持纯 IP），这是预期行为；需要加密上游请使用完整引擎。

### English

#### Added

- **Encrypted upstream DNS (full engine only)**: in addition to IPv4 / IPv6, you can now enter DoH (`https://`), DoT (`tls://`), DoQ (`quic://`), `h3://`, `sdns://`, `tcp://` / `udp://`, plus the `[/domain/]server` per-domain syntax and hostnames with a port. These forms are resolved by the embedded AdGuardHome.
- **Encrypted-DNS preset buttons** (Settings → Upstream DNS): one-tap fill for AliDNS DoH / DNSPod DoH / AdGuard DoH / AliDNS DoT.
- **Capability gated per engine**: the lightweight engine is a pure C++ resolver that only speaks plain Do53, so on lightweight mode the **encrypted presets are greyed out and disabled**; if encrypted upstreams are left in the input, an amber hint appears and tapping "Apply" returns a precise "lightweight mode supports IPs only — switch to full mode" error instead of a generic format error.

#### Changed / Fixed

- **`bootstrap_dns` now uses plain IPs only**: it is what resolves DoH/DoT hostnames, so both AdGuardHome config builders (VPN mode and DNS-proxy mode) keep only the IP subset of the upstream list, falling back to the default resolver (`119.29.29.29`) when every upstream is encrypted — preventing a bootstrap deadlock.
- **Full mode keeps non-IP upstream entries**: the VPN extension used to silently filter out non-IP entries when reading the upstream list, so DoH/DoT never took effect in full mode; IP-only filtering now applies to the lightweight engine only.
- **Safer full → lightweight switch**: before starting the DNS proxy (lightweight), the upstream list is filtered down to plain IPs, so a leftover DoH URL can't be handed to the native engine and break every lookup.

#### Upgrade notes

- Encrypted upstreams (DoH/DoT, etc.) entered in **full mode** are ignored after switching to **lightweight mode** (which supports plain IPs only) — this is intended; use the full engine for encrypted upstreams.

---

[0.0.8]: https://github.com/Tlntin/home-cloud-shield/compare/v0.0.7...v0.0.8
