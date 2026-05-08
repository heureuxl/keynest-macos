#!/usr/bin/env bash
# 从 App/app-icon-1024.png 生成 App/AppIcon.icns（需 Xcode 自带的 sips、iconutil）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/App/app-icon-1024.png"
ICONSET="$ROOT/App/AppIcon.iconset"
OUT="$ROOT/App/AppIcon.icns"
[[ -f "$SRC" ]] || { echo "缺少 $SRC" >&2; exit 1; }
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
TMP="$ICONSET/_src.png"
cp "$SRC" "$TMP"
sips -z 16 16 "$TMP" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$TMP" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$TMP" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$TMP" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$TMP" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$TMP" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$TMP" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$TMP" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$TMP" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$TMP" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
rm -f "$TMP"
iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"
echo "已生成 $OUT"
