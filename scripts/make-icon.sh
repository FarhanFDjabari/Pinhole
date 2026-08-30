#!/usr/bin/env bash
#
# make-icon.sh — regenerate PinholeMenuBar/Pinhole.icns and assets/icon.png
# from make-icon.swift. Only needed when the artwork changes; both outputs are
# checked in, so an ordinary build never runs this.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swift scripts/make-icon.swift "$WORK/icon-1024.png" > /dev/null

ICONSET="$WORK/Pinhole.iconset"
mkdir -p "$ICONSET"
# No 512x512@2x. That one 1024px slice is 532K — more than half the .icns on
# its own, because the gradients dither and PNG cannot compress the noise. It
# only ever renders in Finder's largest icon size and Get Info, where macOS
# upscaling the 512px slice is fine. The Dock and menu bar never reach for it,
# and consumers of the Swift package carry this file in their checkout.
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512"; do
    set -- $spec
    sips -z "$1" "$1" "$WORK/icon-1024.png" --out "$ICONSET/icon_$2.png" > /dev/null
done

iconutil -c icns "$ICONSET" -o PinholeMenuBar/Pinhole.icns
echo "✅ wrote PinholeMenuBar/Pinhole.icns"

# The README shows the same artwork at width 128, so 256px is the @2x asset.
mkdir -p assets
sips -z 256 256 "$WORK/icon-1024.png" --out assets/icon.png > /dev/null
echo "✅ wrote assets/icon.png"
