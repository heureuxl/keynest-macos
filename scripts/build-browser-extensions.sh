#!/usr/bin/env bash
# 同步共享资源后打包 Chrome / Edge / Firefox 扩展 zip；Chrome 另生成 .crx（若本机有 Chrome）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
mkdir -p "$DIST"

bash "$ROOT/scripts/sync-extension-assets.sh"

CHROME=""
for c in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
  if [[ -x "$c" ]]; then
    CHROME="$c"
    break
  fi
done

PEM_SRC="$ROOT/browser/chrome-extension.pem"
CRX_BUILD="$ROOT/browser/chrome-extension.crx"
EXT_CHROME="$ROOT/browser/chrome-extension"
EXT_EDGE="$ROOT/browser/edge-extension"
EXT_FF="$ROOT/browser/firefox-extension"

zip_folder() {
  local src_dir="$1"
  local zip_path="$2"
  local inner_name="$3"
  local stage
  stage="$(mktemp -d)"
  mkdir -p "$stage/$inner_name"
  rsync -a --exclude '*.zip' --exclude '*.pem' --exclude '*.crx' "$src_dir/" "$stage/$inner_name/"
  rm -f "$zip_path"
  ( cd "$stage" && zip -qr "$zip_path" "$inner_name" )
  rm -rf "$stage"
}

echo "==> KeyNest-Chrome.zip"
zip_folder "$EXT_CHROME" "$DIST/KeyNest-Chrome.zip" "KeyNest"

echo "==> KeyNest-Edge.zip"
zip_folder "$EXT_EDGE" "$DIST/KeyNest-Edge.zip" "KeyNest"

echo "==> KeyNest-Firefox.zip"
zip_folder "$EXT_FF" "$DIST/KeyNest-Firefox.zip" "KeyNest"

# UTF-8 中文安装说明（带 BOM），源码见 scripts/extension-install-notes/
rm -f "$DIST"/*.txt
NOTES_DIR="$ROOT/scripts/extension-install-notes"
MANIFEST="$NOTES_DIR/notes-manifest.json"
if ! command -v python3 >/dev/null 2>&1; then
  echo "错误: 需要 python3 以根据 notes-manifest.json 生成安装说明。" >&2
  exit 1
fi
python3 - "$NOTES_DIR" "$MANIFEST" "$DIST" <<'PY'
import json, pathlib, sys
notes_dir, manifest_path, dist = map(pathlib.Path, sys.argv[1:4])
entries = json.loads(manifest_path.read_text(encoding="utf-8"))["files"]
bom = "\ufeff".encode("utf-8")
for e in entries:
    src = notes_dir / e["src"]
    dest = dist / e["dest"]
    dest.write_bytes(bom + src.read_text(encoding="utf-8").encode("utf-8"))
PY

if [[ -n "$CHROME" ]]; then
  echo "==> 使用 Chrome 打包 KeyNest-Chrome.crx（来源目录：chrome-extension）"
  rm -f "$CRX_BUILD"
  if [[ -f "$PEM_SRC" ]]; then
    "$CHROME" --pack-extension="$EXT_CHROME" --pack-extension-key="$PEM_SRC" \
      --no-first-run --no-default-browser-check 2>/dev/null || true
  else
    "$CHROME" --pack-extension="$EXT_CHROME" \
      --no-first-run --no-default-browser-check 2>/dev/null || true
    if [[ -f "$ROOT/browser/chrome-extension.pem" ]]; then
      echo "已生成签名密钥（仅本地打包用）: $ROOT/browser/chrome-extension.pem"
      echo "（可将该 pem 保留在同一路径以便下次增量打包；勿泄露给不信任方）"
    fi
  fi
  if [[ -f "$CRX_BUILD" ]]; then
    mv -f "$CRX_BUILD" "$DIST/KeyNest-Chrome.crx"
    echo "完成: $DIST/KeyNest-Chrome.crx"
  else
    echo "警告: 未能生成 .crx（部分 Chrome 版本需图形环境）。请在本机 Chrome「扩展程序 → 打包扩展程序」手动打包。" >&2
  fi
else
  echo "警告: 未找到 Chrome/Chromium，已跳过 .crx。" >&2
fi

echo "完成。产物目录: ${DIST}（含 *.zip、安装说明 *.txt、可选 KeyNest-Chrome.crx）"
