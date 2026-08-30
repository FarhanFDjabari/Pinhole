#!/usr/bin/env bash
#
# make-icon.sh — regenerate SimCamMenuBar/SimCam.icns from make-icon.swift.
# Only needed when the artwork changes; the .icns itself is what builds use.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swift scripts/make-icon.swift "$WORK/icon-1024.png" > /dev/null

ICONSET="$WORK/SimCam.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$WORK/icon-1024.png" --out "$ICONSET/icon_$2.png" > /dev/null
done

iconutil -c icns "$ICONSET" -o SimCamMenuBar/SimCam.icns
echo "✅ wrote SimCamMenuBar/SimCam.icns"
