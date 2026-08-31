//
//  pinholed — macOS frame server for PinholeKit.
//
//  Captures the Mac's webcam (or loops a video/image file) and serves JPEG
//  frames over TCP on 127.0.0.1. The iOS Simulator shares the host network
//  stack, so an app linking PinholeKit reaches this with
//  PinholeSource.network(host: "127.0.0.1", port: 47009).
//
//  Plain userspace networking — no system extension, no entitlements, no SIP
//  changes. Build with scripts/build-pinholed.sh.
//
//  Usage:
//    pinholed                          # default webcam, 1280x720, 30fps
//    pinholed --file ~/clip.mov        # loop a video file instead
//    pinholed --port 47009 --fps 24 --width 1280 --height 720
//    pinholed --list                   # show available capture devices
//

import AVFoundation
import CoreImage
import Foundation
import Network

struct Options {
    var port: UInt16 = PinholeWire.defaultPort
    var fps: Int = 30
    var width: Int = 1280
    var height: Int = 720
    var file: URL?
    var image: URL?
    var pattern = false
    var qr: String?
    var deviceName: String?
    var quality: Double = 0.7
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    while let arg = args.first {
        args.removeFirst()
        func value() -> String? { args.isEmpty ? nil : args.removeFirst() }
        switch arg {
        case "--port": options.port = value().flatMap { UInt16($0) } ?? options.port
        case "--fps": options.fps = value().flatMap { Int($0) } ?? options.fps
        case "--width": options.width = value().flatMap { Int($0) } ?? options.width
        case "--height": options.height = value().flatMap { Int($0) } ?? options.height
        case "--quality": options.quality = value().flatMap { Double($0) } ?? options.quality
        case "--file": options.file = value().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        case "--image": options.image = value().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        case "--pattern": options.pattern = true
        case "--qr": options.qr = value()
        case "--device": options.deviceName = value()
        case "--list":
            listDevices()
            exit(0)
        case "-h", "--help":
            print("""
            usage: pinholed [source] [options]
              sources:  (default: webcam)
                --pattern            animated colour bars, no camera needed
                --qr TEXT            generated QR code
                --image PATH         a still
                --file PATH          looped video
                --device NAME        pick a camera by name
              options:
                --port N  --fps N  --width N  --height N  --quality 0..1
                --list               show capture devices
            """)
            exit(0)
        default:
            FileHandle.standardError.write("unknown argument: \(arg)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return options
}

func listDevices() {
    let session = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
        mediaType: .video, position: .unspecified)
    for device in session.devices {
        print("\(device.localizedName)  [\(device.uniqueID)]")
    }
    if session.devices.isEmpty { print("no video capture devices found") }
}

/// Camera access needs an embedded Info.plist carrying NSCameraUsageDescription
/// (see scripts/build-pinholed.sh) — without it macOS denies silently.
func ensureCameraAccess() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        return
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        print("requesting camera access — approve the macOS prompt")
        AVCaptureDevice.requestAccess(for: .video) { granted = $0; semaphore.signal() }
        semaphore.wait()
        if granted { return }
    default:
        break
    }
    FileHandle.standardError.write("camera access denied — enable pinholed in System Settings → Privacy & Security → Camera\n".data(using: .utf8)!)
    exit(1)
}

setvbuf(stdout, nil, _IOLBF, 0)
let options = parseOptions()
let server: FrameServer
do {
    server = try FrameServer(port: options.port)
    try server.start()
} catch {
    FileHandle.standardError.write("failed to listen on port \(options.port): \(error)\n".data(using: .utf8)!)
    exit(1)
}
print("pinholed listening on 127.0.0.1:\(options.port)  (\(options.width)x\(options.height) @ \(options.fps)fps)")

var cameraSource: CameraSource?
var fileSource: FileSource?
var stillSource: StillSource?
var patternSource: PatternSource?
var parentWatchdog: DispatchSourceTimer?
do {
    let needsCamera = options.file == nil && options.image == nil && !options.pattern && options.qr == nil
    if needsCamera { ensureCameraAccess() }

    if options.pattern {
        let source = PatternSource(options: options) { server.broadcast($0) }
        source.run()
        patternSource = source
    } else if let payload = options.qr {
        let size = CGSize(width: options.width, height: options.height)
        guard let code = QRFrame.image(payload: payload, size: size),
              let frame = jpeg(from: code, size: size, quality: options.quality) else {
            throw NSError(domain: "pinholed", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "cannot render QR code"])
        }
        print("streaming QR code: \(payload)")
        let source = StillSource(frame: frame, options: options) { server.broadcast($0) }
        source.run()
        stillSource = source
    } else if let image = options.image {
        let source = try StillSource.image(at: image, options: options) { server.broadcast($0) }
        source.run()
        stillSource = source
    } else if let file = options.file {
        let source = FileSource(url: file, options: options) { server.broadcast($0) }
        source.run()
        fileSource = source
    } else {
        let source = try CameraSource(options: options) { server.broadcast($0) }
        source.run()
        cameraSource = source
    }
} catch {
    FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
_ = cameraSource
_ = fileSource
_ = stillSource
_ = patternSource

// Pinhole.app runs this as a child. If the app dies without terminating us, the
// port stays held and the next launch silently competes with a zombie — so
// watch for reparenting to launchd and exit.
let parent = getppid()
if parent != 1 {
    let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pinholed.watchdog"))
    watchdog.schedule(deadline: .now() + 1, repeating: 1)
    watchdog.setEventHandler {
        if getppid() != parent { exit(0) }
    }
    watchdog.resume()
    parentWatchdog = watchdog
}

print("Ctrl-C to stop.")
RunLoop.main.run()
