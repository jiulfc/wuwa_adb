#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
OUTPUT_DIR="$SCRIPT_DIR/tmp"
OUTPUT="$OUTPUT_DIR/$(date '+%Y_%m_%d_%H_%M_%S').jpg"
SCREENSHOT=$(mktemp "${TMPDIR:-/tmp}/adbquick-circle.XXXXXX")
trap 'rm -f "$SCREENSHOT"' EXIT

command -v adb >/dev/null 2>&1 || {
    echo "adb was not found in PATH" >&2
    exit 1
}

mkdir -p "$OUTPUT_DIR"
adb exec-out screencap -p > "$SCREENSHOT"
test -s "$SCREENSHOT" || {
    echo "adb returned an empty screenshot" >&2
    exit 1
}

sips --cropToHeightWidth 72 72 --cropOffset 1270 1270 \
    --setProperty format jpeg "$SCREENSHOT" --out "$OUTPUT" >/dev/null

echo "$OUTPUT"
