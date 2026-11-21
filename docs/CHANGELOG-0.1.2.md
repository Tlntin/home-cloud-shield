# 更新日志 / Changelog — v0.1.2

## [0.1.2] - 2026-11-22

### 中文

#### 新增与优化

- **全量 VPN（实验，默认开启）**。即使应用跳过域名查询、直接联网，栖云盾也会自动记录连接，方便了解应用的联网情况。有需要时，可通过 IP 规则手动拦截指定连接。轻量和完整模式都支持。在「仅代理」中勾选应用后，可在「调试日志」查看连接记录。
- **DNS 白名单与 IPv6 屏蔽**。所选应用可只解析指定域名。设置中可以分别屏蔽 IPv6 解析和阻断 IPv6 连接。
- **应用接续、手动同步与配置备份**。同步和导入导出覆盖 DNS 白名单、IP 拦截规则、全量 VPN 与两个 IPv6 开关。系统接续成功后会退出源端页面。
- **便捷导入**。快速导入可读取文件或剪贴板。
- **开源授权**。「关于」中可离线查看许可证全文和全量 VPN 内核的版权说明。

GitHub 附件为未签名 HAP，可自行签名后安装。

### English

#### Added and improved

- **Full VPN (experimental, on by default)** automatically records connections even when apps skip DNS lookups, so you can see how your apps connect to the network. You can also add IP rules to block specific connections. Both DNS engines support it. Select apps in selected-app mode to see their connections in the debug log.
- **DNS allowlist and IPv6 blocking** let selected apps resolve listed domains and let you control IPv6 DNS lookups and IPv6 connections independently.
- **App continuation, manual sync, and configuration backup** carry the DNS allowlist, IP blocking rules, full VPN setting, and both IPv6 switches. The source screen exits after system app continuation succeeds.
- **Quick import** accepts files and clipboard contents.
- **Open source notices** in About include offline license texts and copyright notices for the full VPN core.

The GitHub asset is an unsigned HAP that you can sign before installing.

历史记录 / Previous changelog: [v0.1.1](./CHANGELOG-0.1.1.md)

[0.1.2]: https://github.com/Tlntin/home-cloud-shield/compare/v0.1.0...v0.1.2
