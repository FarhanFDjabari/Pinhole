#!/usr/bin/env bash
#
# build-pinholed.sh — build the macOS frame server for PinholeKit.
#
# Ordinary userspace binary: no entitlements, no system extension, no SIP
# changes. Requires camera access, which macOS prompts for on first run.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT="$REPO_ROOT/.build-dev/pinholed"
mkdir -p "$(dirname "$OUT")"

# The Info.plist must be embedded in the binary: macOS denies camera access
# outright (no prompt, no error) to a command-line tool with no
# NSCameraUsageDescription. Ad-hoc signing gives TCC a stable identity so the
# grant survives rebuilds.
swiftc -O \
    pinholed/main.swift \
    pinholed/Server.swift \
    pinholed/Feeds.swift \
    PinholeKit/Sources/PinholeKit/PinholeWire.swift \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker pinholed/Info.plist \
    -o "$OUT"

codesign --force --sign - "$OUT"

echo "✅ built $OUT"
