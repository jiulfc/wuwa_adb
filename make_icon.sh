#!/usr/bin/env bash
# Generate assets/AppIcon.icns from assets/icon.png (with rounded corners, radius ~22% of the width).
set -euo pipefail
cd "$(dirname "$0")"

ICON="assets/icon.png"
OUT="assets/AppIcon.icns"

if [[ ! -f "$ICON" ]]; then
    echo "Missing: $ICON"
    exit 1
fi

# Regenerate when the source image or this script has been updated.
if [[ -f "$OUT" && "$OUT" -nt "$ICON" && "$OUT" -nt "$0" ]]; then
    echo "AppIcon.icns is already up to date"
    exit 0
fi

if ! command -v magick >/dev/null 2>&1; then
    echo "Missing ImageMagick (magick command), cannot round corners. Install it first: brew install imagemagick"
    exit 1
fi

W=$(magick identify -format "%w" "$ICON")
H=$(magick identify -format "%h" "$ICON")
# Corner radius = 22% of the width (close to macOS icon proportions).
R=$((W * 22 / 100))
# Icon content scale (%): macOS icon content should not fill the canvas; leave a transparent margin, with content at ~80%.
ART_SCALE=80

ROUNDED=".icon-rounded.png"
TMP_ROUND=".icon-rounded-full.png"
# Step 1: apply rounded corners to the full-bleed icon (the order must not be reversed).
magick "$ICON" -alpha set \
  \( -size "${W}x${H}" xc:none -fill white -draw "roundrectangle 0,0,$((W-1)),$((H-1)),$R,$R" \) \
  -compose DstIn -composite "$TMP_ROUND"
# Step 2: then scale and center, leaving a transparent margin on all sides.
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
