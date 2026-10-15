#!/usr/bin/env bash
# 从 assets/icon.png 生成 assets/AppIcon.icns（含圆角处理，圆角半径约 22% 宽度）。
set -euo pipefail
cd "$(dirname "$0")"

ICON="assets/icon.png"
OUT="assets/AppIcon.icns"

if [[ ! -f "$ICON" ]]; then
    echo "缺少 $ICON"
    exit 1
fi

# 源图或脚本有更新时重新生成。
if [[ -f "$OUT" && "$OUT" -nt "$ICON" && "$OUT" -nt "$0" ]]; then
    echo "AppIcon.icns 已是最新"
    exit 0
fi

if ! command -v magick >/dev/null 2>&1; then
    echo "缺少 ImageMagick（magick 命令），无法处理圆角。请先安装：brew install imagemagick"
    exit 1
fi

W=$(magick identify -format "%w" "$ICON")
H=$(magick identify -format "%h" "$ICON")
# 圆角半径 = 宽度的 22%（接近 macOS 图标比例）。
R=$((W * 22 / 100))
# 图标内容缩放比例（%）：macOS 图标内容不应铺满画布，需留透明边距，内容约占 80%。
ART_SCALE=80

ROUNDED=".icon-rounded.png"
TMP_ROUND=".icon-rounded-full.png"
# 第一步：先给满幅图标套圆角（顺序不能反）。
magick "$ICON" -alpha set \
  \( -size "${W}x${H}" xc:none -fill white -draw "roundrectangle 0,0,$((W-1)),$((H-1)),$R,$R" \) \
  -compose DstIn -composite "$TMP_ROUND"
# 第二步：再缩放居中，四周留透明边距。
magick "$TMP_ROUND" -resize "${ART_SCALE}%" \
  -gravity center -background none -extent "${W}x${H}" "$ROUNDED"
rm -f "$TMP_ROUND"

ICONSET=".AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

sips -z 16 16     "$ROUNDED" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$ROUNDED" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ROUNDED" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$ROUNDED" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ROUNDED" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$ROUNDED" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ROUNDED" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$ROUNDED" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ROUNDED" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ROUNDED" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET" "$ROUNDED"
echo "Generated: $OUT"
