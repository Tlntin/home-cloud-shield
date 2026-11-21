# Third Party Notices

## 1. AdGuard Home

- Project: https://github.com/AdguardTeam/AdGuardHome
- License: GNU General Public License v3.0
- Source location in this repository: `native/adguardhome-ohos-lib/third_party/AdGuardHome/`
- Usage: Used as the upstream basis for the OpenHarmony shared-library migration included in this repository.

## 2. OpenHarmony

- Project: https://gitee.com/openharmony
- License: Apache License 2.0
- Usage: Application framework, VPN Extension APIs, file APIs, UI runtime, media APIs, and build toolchain.

## 3. Full VPN tunnel

Builds that include the OpenHarmony TUN core bundle the following components.
The build script copies the upstream copyright and license texts into the HAP
and the in-app open source notices display them offline.

| Component | License | Upstream |
| --- | --- | --- |
| hev-socks5-tunnel 2.9.0 | MIT | https://github.com/heiher/hev-socks5-tunnel |
| hev-socks5-core | MIT | https://github.com/heiher/hev-socks5-core |
| hev-task-system | MIT | https://github.com/heiher/hev-task-system |
| lwIP | BSD 3-Clause | https://github.com/heiher/lwip |
| yaml (HEV fork) | MIT | https://github.com/heiher/yaml |
| LibYAML 0.2.5 | MIT | https://github.com/yaml/libyaml/tree/0.2.5 |

The pinned source and build steps are in `native/adguardhome-ohos-lib/scripts/build_tun_ohos.sh`.

## 4. Project-local native bridge

- Location: `entry/src/main/cpp/`
- Usage: NAPI bridge between ArkTS and local native DNS/VPN handling code.

## Notes

This file is an informational notice for source distribution convenience. Refer to the root `LICENSE` file and the upstream projects for the complete and authoritative license texts.
