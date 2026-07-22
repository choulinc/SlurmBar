#!/usr/bin/env bash
#
# Generate AppIcon.icns from the 1024x1024 master artwork.
#
#     ./scripts/make-app-icon.sh [output.icns]
#
# macOS wants every size baked into one .icns; `sips` resizes and `iconutil` packs. The master
# must have transparent corners — a baked-in background renders as an opaque square in Finder
# instead of the rounded app-icon shape.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="${ICON_MASTER:-$REPO_ROOT/design/icon/SlurmBar App Icon — 1024@1x.png}"
OUTPUT="${1:-$REPO_ROOT/out/AppIcon.icns}"

if [[ ! -f "$MASTER" ]]; then
    echo "error: icon master not found at $MASTER" >&2
    exit 1
fi

WIDTH="$(sips -g pixelWidth "$MASTER" | awk '/pixelWidth/{print $2}')"
if [[ "$WIDTH" != "1024" ]]; then
    echo "warning: master is ${WIDTH}px wide; 1024 is expected for a full icon set." >&2
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

# name:pixels — @2x entries are the same pixel size as the next point size up.
for spec in \
    16x16:16 16x16@2x:32 \
    32x32:32 32x32@2x:64 \
    128x128:128 128x128@2x:256 \
    256x256:256 256x256@2x:512 \
    512x512:512 512x512@2x:1024
do
    name="${spec%%:*}"
    size="${spec##*:}"
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${name}.png" >/dev/null 2>&1
done

mkdir -p "$(dirname "$OUTPUT")"
iconutil --convert icns "$ICONSET" --output "$OUTPUT"

echo "Built $OUTPUT ($(wc -c < "$OUTPUT" | tr -d ' ') bytes) from $(basename "$MASTER")"
