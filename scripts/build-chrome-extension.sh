#!/usr/bin/env bash
# 兼容旧入口：与 build-browser-extensions.sh 相同，一次性打包 Chrome / Edge / Firefox 并生成 Chrome .crx。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$ROOT/scripts/build-browser-extensions.sh"
