class Pinhole < Formula
  desc "Camera for the iOS Simulator, which has none"
  homepage "https://github.com/FarhanFDjabari/Pinhole"
  url "https://github.com/FarhanFDjabari/Pinhole/archive/refs/tags/0.1.3.tar.gz"
  sha256 "3c385214bf076762cf0a6da740e3370c0d5a1be066e79d0022b815b3e16ba954"
  license "MIT"

  # Built from source rather than shipped as a cask on purpose. Pinhole is
  # ad-hoc signed, and notarizing would need a paid Apple Developer account —
  # the one thing this project sets out not to require. A downloaded ad-hoc
  # bundle is quarantined and Gatekeeper rejects it; a locally built one is
  # never quarantined at all, so building here sidesteps the problem entirely.
  depends_on xcode: ["15.0", :build]
  depends_on macos: :sonoma

  def install
    ENV["PINHOLE_NO_APP_SYNC"] = "1"
    system "./scripts/build-menubar.sh"
    prefix.install ".build-dev/Pinhole.app"
  end

  def caveats
    <<~CAVEATS
      Pinhole is a menu bar app. Link it into /Applications so Spotlight and
      `open -a Pinhole` can find it:

        ln -sfn #{opt_prefix}/Pinhole.app /Applications/Pinhole.app

      Then launch it:

        open -a Pinhole

      On first launch it asks for camera access. Approve it, or the daemon
      exits immediately whenever the source is the Mac camera.
    CAVEATS
  end

  test do
    assert_predicate prefix/"Pinhole.app/Contents/MacOS/Pinhole", :executable?
    assert_predicate prefix/"Pinhole.app/Contents/MacOS/pinholed", :executable?
    # The daemon answers --help without a camera, a socket, or a window server.
    assert_match "usage: pinholed", shell_output("#{prefix}/Pinhole.app/Contents/MacOS/pinholed --help")
  end
end
