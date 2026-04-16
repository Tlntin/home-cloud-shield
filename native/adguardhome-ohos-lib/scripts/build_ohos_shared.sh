#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGH_DIR="$ROOT_DIR/third_party/AdGuardHome"
OUT_DIR="$ROOT_DIR/ohos/prebuilt/openharmony-arm64"
APP_ROOT=""

usage() {
  cat <<'EOF'
Usage:
  ./native/adguardhome-ohos-lib/scripts/build_ohos_shared.sh [--app-root <path>]
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

mkdir -p "$OUT_DIR"

echo "[build] root    => $AGH_DIR"
echo "[build] output  => $OUT_DIR/libadguardhome_ohos.so"

pushd "$AGH_DIR" >/dev/null
GOTOOLCHAIN="${GOTOOLCHAIN:-local}" GOOS="${GOOS:-openharmony}" GOARCH="${GOARCH:-arm64}" CGO_ENABLED="${CGO_ENABLED:-1}" \
  go build -tags ohos_c_shared -buildmode=c-shared -o "$OUT_DIR/libadguardhome_ohos.so" .
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
