#!/usr/bin/env bash
set -euo pipefail

app_root="$(cd "$1" && pwd)"
license_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../licenses" && pwd)"
llvm="${OHOS_NDK:?Set OHOS_NDK to the OpenHarmony native SDK}/llvm/bin"
cc="$llvm/aarch64-unknown-linux-ohos-clang"
flags="--target=aarch64-linux-ohos --sysroot=$OHOS_NDK/sysroot -fPIC -O2"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

git -c advice.detachedHead=false -c http.version=HTTP/1.1 clone --quiet --branch 2.9.0 --depth 1 \
  --recurse-submodules --shallow-submodules https://github.com/heiher/hev-socks5-tunnel.git "$work/src"
cd "$work/src"
test "$(git rev-parse HEAD)" = 99cd2d5d5dfc9b21038e977808e59a0b90b38fa0

# Signal readiness after initialization has created the shutdown pipe. This lets
# the VPN stop or reconfigure immediately without racing the worker startup.
sed -i '/^#include "hev-main.h"/a\
static void (*shield_tun_ready)(void);\n\
void shield_tun_set_ready_callback (void (*callback)(void))\n\
{\n\
    shield_tun_ready = callback;\n\
}' src/hev-main.c
sed -i '/^    hev_socks5_tunnel_run ();/i\    if (shield_tun_ready)\n        shield_tun_ready ();' src/hev-main.c
grep -q 'static void (\*shield_tun_ready)' src/hev-main.c

# This library runs in an app process that already has its own descriptor limit.
sed -i 's/^    res = set_limit_nofile (nofile);/    res = nofile > 0 ? set_limit_nofile (nofile) : 0;/' src/hev-main.c

make -j4 static CC="$cc" AR="$llvm/llvm-ar" RANLIB="$llvm/llvm-ranlib" CFLAGS="$flags"
mapfile -t libs < <(find . -type f -name '*.a' ! -name libhev-socks5-tunnel.a)
"$cc" $flags -shared -Wl,--no-undefined,-soname,libhevsocks5tun.so -o "$work/libhevsocks5tun.so" \
  -Wl,--whole-archive bin/libhev-socks5-tunnel.a -Wl,--no-whole-archive "${libs[@]}" -lpthread
write_notice() {
  local title="$1" license="$2" source="$3" notice="$4"
  printf '\n%s\n%s\n%s\n\n' "$title" "$license" "$source"
  cat "$notice"
}

{
  write_notice 'hev-socks5-tunnel 2.9.0' MIT https://github.com/heiher/hev-socks5-tunnel License
  write_notice hev-socks5-core MIT https://github.com/heiher/hev-socks5-core src/core/License
  write_notice hev-task-system MIT https://github.com/heiher/hev-task-system third-part/hev-task-system/License
  write_notice lwIP BSD-3-Clause https://github.com/heiher/lwip third-part/lwip/License
  write_notice 'yaml (HEV fork)' MIT https://github.com/heiher/yaml third-part/yaml/License
  write_notice 'LibYAML 0.2.5' MIT https://github.com/yaml/libyaml "$license_dir/libyaml-0.2.5.txt"
} > "$work/licenses.txt"
install -D -m 0644 "$work/libhevsocks5tun.so" "$app_root/entry/src/main/libs/arm64-v8a/libhevsocks5tun.so"
install -D -m 0644 "$work/licenses.txt" "$app_root/entry/src/main/resources/rawfile/hevsocks5tun-licenses.txt"
