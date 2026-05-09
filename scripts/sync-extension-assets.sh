#!/usr/bin/env bash
# 将 chrome-extension 中的脚本与页面同步到 Edge / Firefox / Safari 目录（各目录仅 manifest 不同）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/browser/chrome-extension"

sync_one() {
  local dest="$1"
  mkdir -p "$dest"
  for f in content.js credential-fill.js popup.js popup.html; do
    cp -f "$SRC/$f" "$dest/$f"
  done
}

sync_one "$ROOT/browser/edge-extension"
sync_one "$ROOT/browser/firefox-extension"
sync_one "$ROOT/browser/safari-extension"
echo "已同步扩展资源 → edge-extension、firefox-extension、safari-extension"
