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

cat >"$DIST/Edge扩展安装说明.txt" <<'TXT'
Microsoft Edge（Chromium）可使用 KeyNest-Edge.zip，或与 Chrome 相同的 KeyNest-Chrome.zip（扩展格式一致）。

【加载已解压】
1. 打开 edge://extensions
2. 开启左下角「开发人员模式」
3. 点击「加载解压缩的扩展」→ 选择解压后的 KeyNest 文件夹（勿只选零散文件）

安装后请保持本机 KeyNest 桌面端已解锁并开启「桥接」。
TXT

cat >"$DIST/Firefox扩展安装说明.txt" <<'TXT'
【临时加载 · 调试】
1. 解压 KeyNest-Firefox.zip，得到 KeyNest 文件夹
2. 打开 about:debugging#/runtime/this-firefox
3. 「临时载入扩展」→ 选择 KeyNest 文件夹内的 manifest.json（或选择文件夹，依 Firefox 版本界面为准）

【正式发布】需通过 Firefox Add-ons（AMO）签名；本地临时载入每次重启浏览器可能需重新加载。

安装后请保持本机 KeyNest 桌面端已解锁并开启「桥接」。
TXT

cat >"$DIST/Safari扩展安装说明.txt" <<'TXT'
Safari 扩展需使用 Xcode 将 Web Extension 包装为 App Extension（macOS 仅支持此分发方式）。

【从本仓库生成 Xcode 工程】（需在 macOS 上安装 Xcode / Command Line Tools）
在仓库根目录执行：
  bash scripts/convert-safari-extension.sh

或用命令行手动：
  xcrun safari-web-extension-converter browser/safari-extension \\
    --swift --macos-only --copy-resources \\
    --project-location browser/safari-extension-build

随后在 Xcode 中打开生成的工程，选择 KeyNest 扩展 Scheme 编译运行；首次需在 Safari → 开发 → 允许无效扩展（或使用开发者证书签名后在 App Store Connect / 公证流程分发）。

详见 Apple 文档：Safari Web Extensions。

脚本会先同步 browser/chrome-extension 中的 .js / .html 到 browser/safari-extension。
TXT

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
