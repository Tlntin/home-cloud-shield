# 更新日志 / Changelog — v0.1.2

## [0.1.2] - 2026-11-22

### 中文

#### 新增与优化

- **分应用全量 VPN（实验）**。在「仅代理」模式下接管所选应用的 IPv4 和 IPv6 TCP、UDP 连接。轻量和完整 DNS 引擎均可使用，支持按 IP 或 IP 加端口拦截，并可在调试日志查看连接记录。
- **DNS 白名单与 IPv6 屏蔽**。所选应用可只解析指定域名。设置中可以分别屏蔽 IPv6 解析和阻断 IPv6 连接。
- **应用接续、手动同步与配置备份**。同步和导入导出覆盖 DNS 白名单、IP 拦截规则、全量 VPN 与两个 IPv6 开关。系统接续成功后会退出源端页面。
- **便捷导入**。快速导入可读取文件或剪贴板。
- **开源授权**。「关于」中可离线查看许可证全文和全量 VPN 内核的版权说明。

GitHub 附件为未签名 HAP，可自行签名后安装。

### English

#### Added and improved

- **Full VPN for selected apps (experimental)** routes IPv4 and IPv6 TCP and UDP connections for selected apps. It works with both DNS engines, supports blocking by IP or IP and port, and records connections in the debug log.
- **DNS allowlist and IPv6 blocking** let selected apps resolve listed domains and let you control IPv6 DNS lookups and IPv6 connections independently.
- **App continuation, manual sync, and configuration backup** carry the DNS allowlist, IP blocking rules, full VPN setting, and both IPv6 switches. The source screen exits after system app continuation succeeds.
- **Quick import** accepts files and clipboard contents.
- **Open source notices** in About include offline license texts and copyright notices for the full VPN core.

The GitHub asset is an unsigned HAP that you can sign before installing.

历史记录 / Previous changelog: [v0.1.1](./CHANGELOG-0.1.1.md)

[0.1.2]: https://github.com/Tlntin/home-cloud-shield/compare/v0.1.0...v0.1.2
