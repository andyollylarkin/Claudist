#!/bin/bash
# Resources/AppIcon-1024.png -> Resources/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=Resources/AppIcon-1024.png
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Built Resources/AppIcon.icns"
