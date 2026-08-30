# Contributing to Pinhole

Thanks for taking a look. Pinhole is development tooling — small, deliberately
narrow, and easy to hold in your head. Contributions are welcome as long as
they keep it that way.

## Scope

Pinhole feeds frames to an iOS app running in the Simulator, where
`AVCaptureDevice` finds nothing at all. That is the whole job.

**In scope**

- New frame sources on either side (`pinholed` feeds, `PinholeKit` producers)
- Wire-format and performance work
- Control panel and menu bar ergonomics
- Fixes for macOS/Xcode version drift — Apple moves these APIs

**Out of scope**

- Anything that ships in a device build. `PinholeKit` only ever runs behind
  `#if targetEnvironment(simulator)`.
- Becoming a real macOS virtual camera. That needs a CMIOExtension and a paid
  Apple Developer account — see [SimulatorCamera](https://github.com/dautovri/SimulatorCamera),
  which does it properly.
- Third-party dependencies. Both sides are plain Foundation/AVFoundation and
  build with a `swiftc` invocation you can read in one screen.

## Getting set up

You need Xcode with the macOS and iOS Simulator SDKs. Nothing else — no paid
account, no system extension, no SIP changes.

```bash
git clone <your-fork>
cd Pinhole
./scripts/build-menubar.sh        # builds Pinhole.app, and pinholed inside it
```

First run asks for camera access. Approve it.

To work on the daemon alone:

```bash
./scripts/build-pinholed.sh
.build-dev/pinholed --pattern     # colour bars, no camera needed
```

## Layout

| Path | What it is |
|---|---|
| `Package.swift` | Package manifest, at the root so a remote `.package(url:)` can resolve it |
| `PinholeKit/` | Sources of the Swift package linked into the iOS app under test |
| `pinholed/` | macOS frame server — captures, encodes, broadcasts |
| `PinholeMenuBar/` | Menu bar app; runs `pinholed` as a child process |
| `scripts/` | Build and icon generation |

`PinholeWire.swift` lives in `PinholeKit` but is compiled into **both** sides.
Keep it dependency-free beyond Foundation, or the daemon build breaks.

The manifest sits at the repository root rather than in `PinholeKit/` because
SwiftPM resolves a remote package only from a manifest at the root of its
repository — there is no subpath option for a URL dependency. Its target
`path:` points back into `PinholeKit/Sources/PinholeKit`, so sources stay where
the layout above puts them. Do not run `swift build` at the root: it builds for
the host, and these sources import UIKit. Build with
`xcodebuild -scheme PinholeKit -destination 'generic/platform=iOS Simulator'`.

## Changing the wire format

Both ends are built from the same source, so there is no version negotiation
and no compatibility burden — but a stale binary talking to a fresh one fails
silently. If you touch the header layout:

- Bump the magic (`PHF1` → `PHF2`) so mismatched builds reject each other
  instead of decoding garbage
- Update the layout comment at the top of `PinholeWire.swift` **and** the wire
  format table in the README
- Rebuild both sides

## Style

Match what is already there:

- Comments explain **why**, not what. If the code says it, do not repeat it.
- No comments on code you did not change.
- Immutable by default; value semantics where they fit.
- Small files, focused types. Nothing here should need 800 lines.
- Frames reach consumers on the main actor. Producers may run anywhere, but
  hop before touching session state.

## Testing

There is no test suite — this is a tool whose output is a picture, and the
useful check is looking at it. Before opening a PR, verify by hand:

1. `./scripts/build-menubar.sh` succeeds
2. Control panel preview shows live frames for **test pattern**, **Mac camera**,
   **video file**, **image**, and **QR**
3. An iOS Simulator app with `PINHOLE_SOURCE=network` receives those same frames
4. Resolution and frame-rate switching restart the daemon cleanly
5. Quitting the app leaves no orphaned `pinholed` — `pgrep pinholed` is empty

If you add a source, say in the PR which of these you exercised.

## Pull requests

- One concern per PR. Do not mix a fix with a refactor.
- Conventional commit subjects: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`.
- Describe what you verified, using the list above.
- Screenshots for anything that changes the control panel or the icon.

## Reporting bugs

Include your macOS version, Xcode version, and Simulator iOS version — most
breakage here is Apple moving something. Paste **Run Diagnostics** from the
control panel; it carries the camera authorization state, port, client count,
and daemon path, which is usually the whole answer.

## License

By contributing you agree that your work is licensed under the
[MIT License](LICENSE).
