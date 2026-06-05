#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGH_DIR="$ROOT_DIR/third_party/AdGuardHome"
EMBED_DIR="$ROOT_DIR/ohos/embed"
OUT_DIR="$ROOT_DIR/ohos/prebuilt/openharmony-arm64"
APP_ROOT=""

usage() {
  cat <<'EOF'
Usage:
  ./native/adguardhome-ohos-lib/scripts/build_ohos_shared.sh [--app-root <path>]

Builds libadguardhome_ohos.so (OpenHarmony arm64, c-shared) from the pinned
AdGuardHome submodule plus the OHOS embedding/export sources in ohos/embed/.

Required toolchain (see TOOLCHAIN.md):
  - PATH must point at the OpenHarmony patched Go (>= go1.24.5, supports
    GOOS=openharmony), e.g. ohos_golang_go.
  - A C cross-compiler for OHOS arm64 (CGO_ENABLED=1).  Either export CC/CXX/AR
    yourself, or set OHOS_NDK to the SDK "native" dir and they are derived as:
      CC  = $OHOS_NDK/llvm/bin/aarch64-unknown-linux-ohos-clang
      CXX = $OHOS_NDK/llvm/bin/aarch64-unknown-linux-ohos-clang++
      AR  = $OHOS_NDK/llvm/bin/llvm-ar
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-root)
      [[ $# -ge 2 ]] || { echo "--app-root requires a value" >&2; exit 1; }
      APP_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# The AdGuardHome submodule must be checked out.
if [[ ! -f "$AGH_DIR/go.mod" ]]; then
  echo "[build] AdGuardHome submodule not found at $AGH_DIR" >&2
  echo "[build] run: git submodule update --init --recursive" >&2
  exit 1
fi

# The OHOS embedding/export sources live in this repo (outside the submodule)
# so the corresponding source is tracked and the build is reproducible.
for f in main_ohos_c_shared.go embed_ohos.go; do
  [[ -f "$EMBED_DIR/$f" ]] || { echo "[build] missing custom source: $EMBED_DIR/$f" >&2; exit 1; }
done

# Inject the custom sources into the otherwise-pristine submodule, and remove
# them again on exit so the submodule working tree stays clean.
INJECTED_EXPORT="$AGH_DIR/main_ohos_c_shared.go"
INJECTED_EMBED="$AGH_DIR/internal/home/embed_ohos.go"
cleanup_injected() { rm -f "$INJECTED_EXPORT" "$INJECTED_EMBED"; }
trap cleanup_injected EXIT

cp "$EMBED_DIR/main_ohos_c_shared.go" "$INJECTED_EXPORT"
cp "$EMBED_DIR/embed_ohos.go" "$INJECTED_EMBED"

# The full-mode web admin (AdGuardHome dashboard) is served from the embedded
# frontend at build/static (//go:embed build in main.go). It is a generated
# artifact; build it once with Node before building the .so:
#   cd "$AGH_DIR/client" && npm ci && npm run build-prod
# If absent, the .so still works for DNS filtering but the web dashboard 404s.
if [[ ! -f "$AGH_DIR/build/static/index.html" ]]; then
  echo "[build] WARNING: $AGH_DIR/build/static/index.html missing" >&2
  echo "[build] WARNING: the AdGuardHome web dashboard will NOT be available." >&2
  echo "[build] WARNING: build it with: (cd $AGH_DIR/client && npm ci && npm run build-prod)" >&2
fi

# Derive the OHOS C cross-compiler from OHOS_NDK when CC is not set explicitly.
if [[ -z "${CC:-}" && -n "${OHOS_NDK:-}" ]]; then
  export CC="$OHOS_NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
  export CXX="$OHOS_NDK/llvm/bin/aarch64-unknown-linux-ohos-clang++"
  export AR="$OHOS_NDK/llvm/bin/llvm-ar"
fi

mkdir -p "$OUT_DIR"

echo "[build] root    => $AGH_DIR"
echo "[build] embed   => $EMBED_DIR"
echo "[build] CC      => ${CC:-<from environment / go default>}"
echo "[build] output  => $OUT_DIR/libadguardhome_ohos.so"

pushd "$AGH_DIR" >/dev/null
# Set DT_SONAME so the consuming module records a basename (not the absolute
# build path) in DT_NEEDED; the dynamic loader then resolves it from the app's
# packaged lib dir.  Go c-shared uses external linking (cgo), so -extldflags
# reaches the OHOS clang/lld.
GOTOOLCHAIN="${GOTOOLCHAIN:-local}" GOOS="${GOOS:-openharmony}" GOARCH="${GOARCH:-arm64}" CGO_ENABLED="${CGO_ENABLED:-1}" \
  go build -tags ohos_c_shared -buildmode=c-shared \
    -ldflags "-X github.com/AdguardTeam/AdGuardHome/internal/version.version=v0.107.64 -extldflags=-Wl,-soname,libadguardhome_ohos.so" \
    -o "$OUT_DIR/libadguardhome_ohos.so" .
popd >/dev/null

echo "[ok] generated:"
echo "  - $OUT_DIR/libadguardhome_ohos.so"
echo "  - $OUT_DIR/libadguardhome_ohos.h"

if [[ -n "$APP_ROOT" ]]; then
  install -D -m 0644 "$OUT_DIR/libadguardhome_ohos.so" "$APP_ROOT/entry/src/main/libs/arm64-v8a/libadguardhome_ohos.so"
  install -D -m 0644 "$OUT_DIR/libadguardhome_ohos.h" "$APP_ROOT/entry/src/main/cpp/include/libadguardhome_ohos.h"
  echo "[ok] copied:"
  echo "  - $APP_ROOT/entry/src/main/libs/arm64-v8a/libadguardhome_ohos.so"
  echo "  - $APP_ROOT/entry/src/main/cpp/include/libadguardhome_ohos.h"
fi
