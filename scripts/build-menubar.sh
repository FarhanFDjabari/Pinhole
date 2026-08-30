#!/usr/bin/env bash
#
# build-menubar.sh — build Pinhole.app, the menu bar front end for pinholed.
#
# The daemon ships inside the app bundle and runs as its child, so macOS
# attributes camera access to Pinhole. A bare command-line tool has no TCC
# identity of its own — the grant lands on whichever terminal launched it,
# which is why running pinholed by hand is awkward to authorize.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

"$REPO_ROOT/scripts/build-pinholed.sh" > /dev/null

APP="$REPO_ROOT/.build-dev/Pinhole.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp PinholeMenuBar/Info.plist "$APP/Contents/Info.plist"
cp PinholeMenuBar/Pinhole.icns "$APP/Contents/Resources/Pinhole.icns"
cp "$REPO_ROOT/.build-dev/pinholed" "$APP/Contents/MacOS/pinholed"

swiftc -O -parse-as-library \
    -target arm64-apple-macos14.0 \
    PinholeMenuBar/PinholeMenuBarApp.swift \
    PinholeMenuBar/DaemonController.swift \
    PinholeMenuBar/MenuContent.swift \
    PinholeMenuBar/ControlPanelView.swift \
    PinholeMenuBar/PreviewClient.swift \
    PinholeKit/Sources/PinholeKit/PinholeWire.swift \
    -o "$APP/Contents/MacOS/Pinhole"

# Sign inner executable first, then the bundle.
codesign --force --sign - "$APP/Contents/MacOS/pinholed"
codesign --force --sign - "$APP"

echo "✅ built $APP"

# Keep the installed copy in step with the build — the camera grant follows the
# code signature, not the path, so replacing it does not re-prompt.
if [[ -d /Applications/Pinhole.app ]]; then
    pkill -f "/Applications/Pinhole.app/Contents/MacOS/Pinhole" 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Pinhole.app
    cp -R "$APP" /Applications/Pinhole.app
    echo "✅ installed /Applications/Pinhole.app"
    echo "   open -a Pinhole"
else
    echo "   open $APP   (copy it to /Applications to install)"
fi
