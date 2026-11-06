#!/usr/bin/env bash
# Compile the AdbQuick executable.
set -euo pipefail
cd "$(dirname "$0")"

SRC_DIR="Sources"
OUT="AdbQuick"
# Clang module caches bind to absolute paths, so use a separate cache after relocating the project.
CACHE=".clangcache/$(printf '%s' "$PWD" | shasum -a 256 | cut -d ' ' -f 1)"
mkdir -p "$CACHE"

swiftc \
  -module-cache-path "$PWD/$CACHE" \
  -O \
  -o "$OUT" \
  "$SRC_DIR"/*.swift

echo "Built: $PWD/$OUT"
