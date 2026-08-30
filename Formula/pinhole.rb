class Pinhole < Formula
  desc "Camera for the iOS Simulator, which has none"
  homepage "https://github.com/FarhanFDjabari/Pinhole"
  url "https://github.com/FarhanFDjabari/Pinhole/archive/refs/tags/0.1.4.tar.gz"
  sha256 "5d89763a8bd8f2ba09d02a6fb1dcf44772b2d6c3aa6ccc915dc084f9a8f2dee0"
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
      Pinhole is a menu bar app. Copy it into /Applications:

        cp -R #{opt_prefix}/Pinhole.app /Applications/Pinhole.app
        open -a Pinhole

      Copy rather than symlink: Spotlight indexes real bundles, not symlinks,
      and does not index the Cellar at all, so a symlinked app never appears in
      the Spotlight menu.

      The copy does not follow `brew upgrade`. After upgrading, repeat it:

        rm -rf /Applications/Pinhole.app
        cp -R #{opt_prefix}/Pinhole.app /Applications/Pinhole.app

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
