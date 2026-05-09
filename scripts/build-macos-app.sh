#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="KeyNest"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/App/Info.plist" 2>/dev/null || echo "0.1.0")"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
APP_BUNDLE="$OUT_DIR/${APP_NAME}.app"
DMG_PATH="$OUT_DIR/${APP_NAME}-${VERSION}.dmg"
BUILD="${BUILD:-release}"

if [[ -f "$ROOT/App/app-icon-1024.png" ]]; then
  echo "==> 生成 AppIcon.icns（来自 App/app-icon-1024.png）"
  bash "$ROOT/scripts/build-icns.sh"
fi

echo "==> swift build -c $BUILD"
swift build -c "$BUILD"

BIN_DIR="$(swift build -c "$BUILD" --show-bin-path)"
EXEC_SRC="$BIN_DIR/$APP_NAME"

if [[ ! -x "$EXEC_SRC" ]]; then
  echo "找不到可执行文件: $EXEC_SRC" >&2
  exit 1
fi

echo "==> 组装 $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$EXEC_SRC" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cp "$ROOT/App/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

mkdir -p "$APP_BUNDLE/Contents/Resources"
if [[ -f "$ROOT/App/AppIcon.icns" ]]; then
  cp "$ROOT/App/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
  # Finder / Dock 读取的是 CFBundleIconFile → AppIcon.icns，文件名需一致（区分大小写）
  ICON_BYTES=$(wc -c <"$APP_BUNDLE/Contents/Resources/AppIcon.icns")
  echo "已装入图标 Resources/AppIcon.icns (${ICON_BYTES} 字节)"
else
  echo "错误: 缺少 $ROOT/App/AppIcon.icns；请先放置 App/app-icon-1024.png 并运行 scripts/build-icns.sh" >&2
  exit 1
fi

echo "==> 临时签名（本地运行；分发请换开发者证书）"
if ! codesign --force --deep --sign - "$APP_BUNDLE"; then
  echo "警告: codesign 失败，可能影响图标与门禁显示。" >&2
fi

echo "完成: $APP_BUNDLE"

if [[ "${MAKE_DMG:-}" == "1" ]]; then
  echo "==> 制作 DMG（左侧 ${APP_NAME}.app → 拖入右侧「应用程序」）"
  # 卷名带版本，避免与已挂载的卷冲突；关闭 DMG 后安装卷名不影响最终用户
  VOLNAME="${APP_NAME}-${VERSION}"
  TEMP_SPARSE="$OUT_DIR/${APP_NAME}-rw-temp.sparseimage"
  rm -f "$TEMP_SPARSE" "$DMG_PATH"

  # SPARSE 可读写；复制 .app 与 .DS_Store 布局后再压成只读 DMG
  hdiutil create -size 220m -type SPARSE -fs HFS+ -volname "$VOLNAME" -ov "$TEMP_SPARSE"

  echo "==> 挂载并复制内容"
  ATTACH_PLIST=$(hdiutil attach -readwrite -nobrowse -noverify -noautoopen -plist "$TEMP_SPARSE" 2>&1) || true
  VOLUME_PATH=$(printf '%s' "$ATTACH_PLIST" | /usr/bin/python3 -c "
import plistlib, sys
raw = sys.stdin.buffer.read()
d = plistlib.loads(raw)
for e in d.get('system-entities') or []:
    mp = e.get('mount-point')
    if mp:
        print(mp)
        break
")
  if [[ -z "$VOLUME_PATH" || ! -d "$VOLUME_PATH" ]]; then
    echo "错误: 无法解析 DMG 挂载路径。原始输出：" >&2
    echo "$ATTACH_PLIST" >&2
    rm -f "$TEMP_SPARSE"
    exit 1
  fi
  echo "挂载点: $VOLUME_PATH"

  ditto "$APP_BUNDLE" "$VOLUME_PATH/${APP_NAME}.app"
  ln -sf /Applications "$VOLUME_PATH/Applications"

  # 简短说明（文件名用 ASCII，避免 AppleScript 按名定位失败）
  printf '%s\n' "【安装】用鼠标把左侧「${APP_NAME}」图标拖到右侧「应用程序」里，" \
    "不要只在 DMG 里双击（那样不会装到本机）。" \
    "装好后在访达边栏点「应用程序」，或按 Command+Shift+A 打开应用程序文件夹，即可找到 ${APP_NAME}。" \
    "" \
    "若提示来自未知开发者：系统设置 → 隐私与安全性 → 仍要打开。" \
    >"$VOLUME_PATH/INSTALL.txt"

  if [[ -f "$ROOT/App/dmg-background.png" ]]; then
    mkdir -p "$VOLUME_PATH/.background"
    cp "$ROOT/App/dmg-background.png" "$VOLUME_PATH/.background/background.png"
  else
    echo "警告: 未找到 $ROOT/App/dmg-background.png，将不使用自定义背景" >&2
  fi

  sync
  sleep 2

  echo "==> Finder 窗口（背景图 + 图标布局，需本机图形会话）"
  osascript - "$VOLUME_PATH" "$VOLNAME" "$APP_NAME" <<'APPLESCRIPT' || echo "（Finder 布局跳过，请手动整理窗口亦可）"
on run argv
	set volPath to item 1 of argv
	set volName to item 2 of argv
	set appBase to item 3 of argv
	set appItem to appBase & ".app"
	set bgPath to volPath & "/.background/background.png"
	tell application "Finder"
		tell disk volName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set the bounds of container window to {400, 100, 1000, 500}
			set viewOptions to the icon view options of container window
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to 100
			try
				set label position of viewOptions to bottom
			end try
			try
				set bgFile to POSIX file bgPath
				set background picture of viewOptions to bgFile
			end try
			try
				set position of item appItem of container window to {120, 175}
				set position of item "Applications" of container window to {435, 175}
				set position of item "INSTALL.txt" of container window to {205, 325}
			end try
			close
			open
			update without registering applications
			delay 1
		end tell
	end tell
end run
APPLESCRIPT

  sync
  sleep 1

  echo "==> 卸载并压缩为 UDZO"
  hdiutil detach "$VOLUME_PATH" || hdiutil detach "$VOLUME_PATH" -force
  hdiutil convert "$TEMP_SPARSE" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH"
  rm -f "$TEMP_SPARSE"
  echo "完成: $DMG_PATH"
fi

if [[ "${BUILD_CHROME_EXT:-}" == "1" ]]; then
  echo "==> 浏览器扩展（Chrome / Edge / Firefox：.zip；Chrome 另 .crx）"
  bash "$ROOT/scripts/build-chrome-extension.sh"
fi
