#!/usr/bin/env bash
#
# build-simcamd.sh — build the macOS frame server for SimCamKit.
#
# Ordinary userspace binary: no entitlements, no system extension, no SIP
# changes. Requires camera access, which macOS prompts for on first run.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT="$REPO_ROOT/.build-dev/simcamd"
mkdir -p "$(dirname "$OUT")"

# The Info.plist must be embedded in the binary: macOS denies camera access
# outright (no prompt, no error) to a command-line tool with no
# NSCameraUsageDescription. Ad-hoc signing gives TCC a stable identity so the
# grant survives rebuilds.
swiftc -O \
    simcamd/main.swift \
    simcamd/Server.swift \
    simcamd/Feeds.swift \
    SimCamKit/Sources/SimCamKit/SimCamWire.swift \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker simcamd/Info.plist \
    -o "$OUT"

codesign --force --sign - "$OUT"

echo "✅ built $OUT"
