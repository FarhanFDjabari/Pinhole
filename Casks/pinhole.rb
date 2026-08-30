cask "pinhole" do
  version "0.1.2"
  sha256 "5978eadf728c34593fde68c958faa566a3a9e1def082f290471c4b47ac35d0a9"

  url "https://github.com/FarhanFDjabari/Pinhole/releases/download/#{version}/Pinhole.zip"
  name "Pinhole"
  desc "Camera for the iOS Simulator, which has none"
  homepage "https://github.com/FarhanFDjabari/Pinhole"

  depends_on macos: :sonoma

  app "Pinhole.app"

  # Ad-hoc signed, not notarized, so Gatekeeper rejects a quarantined copy.
  # Install with --no-quarantine, or build from source. See the README.
  caveats <<~CAVEATS
    Pinhole is ad-hoc signed rather than notarized, so a downloaded copy is
    blocked by Gatekeeper. If you did not install with --no-quarantine:

      brew install --cask --no-quarantine pinhole

    or clear the flag on the installed app:

      xattr -dr com.apple.quarantine "#{appdir}/Pinhole.app"

    On first launch Pinhole asks for camera access. Approve it, or the daemon
    exits immediately when the source is the Mac camera.
  CAVEATS

  zap trash: [
    "~/Library/Preferences/com.local.pinhole.plist",
  ]
end
