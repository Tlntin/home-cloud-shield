#!/usr/bin/env bash
# Convenience wrapper for building libadguardhome_ohos.so from Windows via WSL:
#   wsl -d Ubuntu-20.04 -u tlntin -- bash native/adguardhome-ohos-lib/scripts/wsl_build.sh
# Encodes this machine's toolchain locations (see TOOLCHAIN.md / memory):
# patched Go and the Linux OHOS NDK live in tlntin's WSL home.
set -euo pipefail

export GOROOT=/home/tlntin/frp_ohos/ohos_golang_go
export PATH="$GOROOT/bin:$PATH"
export OHOS_NDK=/home/tlntin/frp_ohos/command-line-tools/sdk/default/openharmony/native
export GOOS=openharmony
export GOARCH=arm64
export CGO_ENABLED=1
export GOTOOLCHAIN=local
# WSL NAT mode cannot reach the Windows-side localhost proxy; use the CN mirror.
export GOPROXY=https://goproxy.cn,direct

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

go version
"$SCRIPT_DIR/build_ohos_shared.sh" --app-root "$APP_ROOT"
