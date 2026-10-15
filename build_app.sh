#!/usr/bin/env bash
# 编译并打包成 AdbQuick.app。
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
./make_icon.sh

APP="AdbQuick.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp AdbQuick "$APP/Contents/MacOS/AdbQuick"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp assets/orchestration.html "$APP/Contents/Resources/orchestration.html"

codesign --force --sign - "$APP" 2>/dev/null || true

echo "Built: $PWD/$APP"
