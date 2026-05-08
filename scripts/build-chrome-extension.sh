#!/usr/bin/env bash
# 打包 Chrome 扩展：生成单个 .crx（可拖入 chrome://extensions）及备用 .zip（解压后仅一个文件夹）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT_SRC="$ROOT/browser/chrome-extension"
DIST="$ROOT/dist"
mkdir -p "$DIST"

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

ZIP_OUT="$DIST/KeyNest-Chrome.zip"
CRX_OUT="$DIST/KeyNest-Chrome.crx"
PEM_SRC="$ROOT/browser/chrome-extension.pem"
CRX_BUILD="$ROOT/browser/chrome-extension.crx"

echo "==> 生成 Chrome 扩展 zip（解压后仅「KeyNest」一个文件夹，内含全部文件）"
STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
mkdir -p "$STAGE/KeyNest"
rsync -a --exclude '*.zip' --exclude '*.pem' --exclude '*.crx' "$EXT_SRC/" "$STAGE/KeyNest/"
(
  cd "$STAGE"
  rm -f "$ZIP_OUT"
  zip -qr "$ZIP_OUT" KeyNest
)
echo "完成: $ZIP_OUT"

cat >"$DIST/Chrome扩展安装说明.txt" <<'TXT'
【方式一 · 单个安装包（推荐）】KeyNest-Chrome.crx
1. 用 Chrome 打开 chrome://extensions
2. 打开右上角「开发者模式」
3. 将 KeyNest-Chrome.crx 拖入该页面（或双击 crx 并按提示允许）

【方式二 · 解压包】KeyNest-Chrome.zip
1. 解压 zip，得到名为 KeyNest 的一个文件夹（请勿只拷贝零散文件）
2. chrome://extensions 打开「开发者模式」→「加载已解压的扩展程序」→ 选中解压出的 KeyNest 文件夹

安装后请保持本机 KeyNest 桌面端已解锁并开启「桥接」。
TXT

if [[ -n "$CHROME" ]]; then
  echo "==> 使用 Chrome 打包 .crx（单文件，无需暴露源码文件夹）"
  rm -f "$CRX_BUILD"
  if [[ -f "$PEM_SRC" ]]; then
    "$CHROME" --pack-extension="$EXT_SRC" --pack-extension-key="$PEM_SRC" \
      --no-first-run --no-default-browser-check 2>/dev/null || true
  else
    "$CHROME" --pack-extension="$EXT_SRC" \
      --no-first-run --no-default-browser-check 2>/dev/null || true
    if [[ -f "$ROOT/browser/chrome-extension.pem" ]]; then
      echo "已生成签名密钥（仅本地打包用）: $ROOT/browser/chrome-extension.pem"
      echo "（可将该 pem 保留在同一路径以便下次增量打包；勿泄露给不信任方）"
    fi
  fi
  if [[ -f "$CRX_BUILD" ]]; then
    mv -f "$CRX_BUILD" "$CRX_OUT"
    echo "完成: $CRX_OUT"
  else
    echo "警告: 未能生成 .crx（部分 Chrome 版本需图形环境）。请在本机打开 Chrome，菜单「扩展程序 → 打包扩展程序」手动打包，或仅使用上面的 zip。" >&2
  fi
else
  echo "警告: 未找到 Google Chrome / Chromium，已跳过 .crx；请安装 Chrome 后重新运行本脚本，或只用 zip。" >&2
fi

echo "说明文件: $DIST/Chrome扩展安装说明.txt"
