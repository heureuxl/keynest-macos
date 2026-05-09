#!/usr/bin/env bash
# 同步 Web 资源后调用 Apple 官方工具生成 Safari Web Extension 的 Xcode 工程。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/sync-extension-assets.sh"

EXT="$ROOT/browser/safari-extension"
OUT="${SAFARI_PROJECT_OUT:-$ROOT/browser/safari-extension-build}"

if ! xcrun --find safari-web-extension-converter >/dev/null 2>&1; then
  echo "错误: 未找到 safari-web-extension-converter，请安装 Xcode 或 Xcode Command Line Tools。" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> 生成 Safari Web Extension Xcode 工程 → $OUT"
xcrun safari-web-extension-converter "$EXT" \
  --swift \
  --macos-only \
  --copy-resources \
  --project-location "$OUT"

echo "完成。请用 Xcode 打开 $OUT 下的工程并编译运行扩展目标。"
