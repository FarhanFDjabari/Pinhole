#!/usr/bin/env bash
#
# build-menubar.sh — build SimCam.app, the menu bar front end for simcamd.
#
# The daemon ships inside the app bundle and runs as its child, so macOS
# attributes camera access to SimCam. A bare command-line tool has no TCC
# identity of its own — the grant lands on whichever terminal launched it,
# which is why running simcamd by hand is awkward to authorize.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

"$REPO_ROOT/scripts/build-simcamd.sh" > /dev/null

APP="$REPO_ROOT/.build-dev/SimCam.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp SimCamMenuBar/Info.plist "$APP/Contents/Info.plist"
cp SimCamMenuBar/SimCam.icns "$APP/Contents/Resources/SimCam.icns"
cp "$REPO_ROOT/.build-dev/simcamd" "$APP/Contents/MacOS/simcamd"

swiftc -O -parse-as-library \
    -target arm64-apple-macos14.0 \
    SimCamMenuBar/SimCamMenuBarApp.swift \
    SimCamMenuBar/DaemonController.swift \
    SimCamMenuBar/MenuContent.swift \
    SimCamMenuBar/ControlPanelView.swift \
    SimCamMenuBar/PreviewClient.swift \
    SimCamKit/Sources/SimCamKit/SimCamWire.swift \
    -o "$APP/Contents/MacOS/SimCam"

# Sign inner executable first, then the bundle.
codesign --force --sign - "$APP/Contents/MacOS/simcamd"
codesign --force --sign - "$APP"

echo "✅ built $APP"

# Keep the installed copy in step with the build — the camera grant follows the
# code signature, not the path, so replacing it does not re-prompt.
if [[ -d /Applications/SimCam.app ]]; then
    pkill -f "/Applications/SimCam.app/Contents/MacOS/SimCam" 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/SimCam.app
    cp -R "$APP" /Applications/SimCam.app
    echo "✅ installed /Applications/SimCam.app"
    echo "   open -a SimCam"
else
    echo "   open $APP   (copy it to /Applications to install)"
fi
