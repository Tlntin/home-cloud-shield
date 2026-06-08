# 更新日志 / Changelog — v0.0.4

本文档记录 `栖云盾 / home_cloud_shield` v0.0.4 的主要变更，中英双语。
This file records the notable changes of `栖云盾 / home_cloud_shield` v0.0.4 in both Chinese and English.

格式参考 [Keep a Changelog](https://keepachangelog.com/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
The format is based on [Keep a Changelog](https://keepachangelog.com/) and the project adheres to [Semantic Versioning](https://semver.org/).

历史版本见 [`CHANGELOG-0.0.3.md`](./CHANGELOG-0.0.3.md)。/ Older versions are in [`CHANGELOG-0.0.3.md`](./CHANGELOG-0.0.3.md).

---

## [0.0.4] - 2026-06-08

相对 `v0.0.3` 的变更。/ Changes since `v0.0.3`.

### 中文

#### 新增

- **DNS 代理共存模式**（首页「纯 DNS 代理」）：**不开启 VPN**，把过滤引擎作为本地 DNS 服务器运行，从而与其他 VPN / 代理 App **共存**（响应 [issue #1](https://github.com/Tlntin/home-cloud-shield/issues/1)）。在你的代理软件里把 DNS 上游设为 `tcp://127.0.0.1:<端口>` 即可边代理边过滤。轻量级与完整两种引擎都支持此模式；建议开启「后台保活」以维持后台运行。
  - 受 HarmonyOS 限制，跨 App 仅 **TCP** 回环可用（UDP 不可用），因此对端代理需支持 `tcp://` 形式的 DNS 上游（如 mihomo / clash-meta、sing-box）。
- **首页两轴选择**：新增「网络模式」分段控件（**VPN 模式 / 纯 DNS 代理**），与「引擎」（轻量 / 完整）下拉相互正交；主启动按钮随所选模式切换。
- **自定义 DNS 代理端口**（设置页，默认 `5354`）。
- **自定义 AdGuardHome 管理面板端口**（设置页，默认 `3000`，仅完整引擎）。
- **端口冲突自动跳过**：启动时若所选端口被占用，自动顺延到下一个空闲端口，并提示实际使用的端口。

### English

#### Added

- **DNS proxy coexistence mode** ("DNS Proxy" on the home page): run the filtering engine as a **local DNS server without a VPN**, so it can **coexist with another VPN / proxy app** (addresses [issue #1](https://github.com/Tlntin/home-cloud-shield/issues/1)). Point your proxy app's DNS upstream at `tcp://127.0.0.1:<port>` to filter while proxying. Both the lightweight and full engines support this mode; enabling "Background keep-alive" is recommended so it keeps running in the background.
  - Due to a HarmonyOS limitation, only **TCP** loopback works across apps (UDP does not), so the peer proxy must support a `tcp://` DNS upstream (e.g. mihomo / clash-meta, sing-box).
- **Two-axis selection on the home page**: a new **Network mode** segmented control (**VPN Mode / DNS Proxy**), orthogonal to the **Engine** (Lightweight / Full) dropdown; the primary button follows the selected mode.
- **Configurable DNS proxy port** (Settings, default `5354`).
- **Configurable AdGuardHome panel port** (Settings, default `3000`, full engine only).
- **Automatic port-conflict skip**: if the chosen port is busy at start, it advances to the next free port and shows the port actually in use.

---

[0.0.4]: https://github.com/Tlntin/home-cloud-shield/compare/v0.0.3...v0.0.4
