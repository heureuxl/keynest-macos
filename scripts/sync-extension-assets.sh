#!/usr/bin/env bash
# 将 chrome-extension 中的脚本与页面同步到 Edge / Firefox / Safari 目录（各目录仅 manifest 不同）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/browser/chrome-extension"

CHROME_MANIFEST="$SRC/manifest.json"

sync_one() {
  local dest="$1"
  mkdir -p "$dest"
  for f in password-plain.js password-hook.js content.js credential-fill.js popup.js popup.html; do
    cp -f "$SRC/$f" "$dest/$f"
  done
  if [[ -f "$dest/manifest.json" ]]; then
    python3 - <<'PY' "$CHROME_MANIFEST" "$dest/manifest.json"
import json, sys
chrome_path, dest_path = sys.argv[1], sys.argv[2]
with open(chrome_path, "r", encoding="utf-8") as f:
    chrome = json.load(f)
ver = chrome.get("version")
with open(dest_path, "r", encoding="utf-8") as f:
    m = json.load(f)
if ver:
    m["version"] = ver
want = ["password-plain.js", "password-hook.js", "credential-fill.js", "content.js"]
for cs in m.get("content_scripts", []):
    js = cs.get("js", [])
    if "credential-fill.js" in js or "content.js" in js:
        cs["js"] = want
with open(dest_path, "w", encoding="utf-8") as f:
    json.dump(m, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
  fi
}

sync_one "$ROOT/browser/edge-extension"
sync_one "$ROOT/browser/firefox-extension"
sync_one "$ROOT/browser/safari-extension"
echo "已同步扩展资源 → edge-extension、firefox-extension、safari-extension"
