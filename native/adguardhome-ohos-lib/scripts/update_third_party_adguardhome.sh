#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGH_DIR="$ROOT_DIR/third_party/AdGuardHome"
REF="${1:-v0.107.64}"

if [[ ! -d "$AGH_DIR/.git" ]]; then
  echo "[update] missing git repo: $AGH_DIR" >&2
  echo "[update] please run: git submodule update --init --recursive" >&2
  echo "[update] this project expects third_party/AdGuardHome to be checked out as a git submodule." >&2
  exit 1
fi

pushd "$AGH_DIR" >/dev/null
git fetch --tags origin
git switch --detach "$REF"
popd >/dev/null

echo "[ok] checked out $REF"
