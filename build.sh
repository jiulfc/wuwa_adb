#!/usr/bin/env bash
# 编译 AdbQuick 可执行文件。
set -euo pipefail
cd "$(dirname "$0")"

SRC_DIR="Sources"
OUT="AdbQuick"
# Clang 模块缓存绑定绝对路径，搬迁项目后使用独立缓存。
CACHE=".clangcache/$(printf '%s' "$PWD" | shasum -a 256 | cut -d ' ' -f 1)"
mkdir -p "$CACHE"

swiftc \
  -module-cache-path "$PWD/$CACHE" \
  -O \
  -o "$OUT" \
  "$SRC_DIR"/*.swift

echo "Built: $PWD/$OUT"
