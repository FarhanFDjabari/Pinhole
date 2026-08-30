//
//  DaemonController.swift
//  Runs the bundled `simcamd` and tracks what it reports.
//
//  The daemon is a child of this app, so macOS attributes its camera access to
//  SimCam rather than to whichever terminal launched it — which is what makes
//  the permission grantable at all for a command-line tool.
//

import AVFoundation
import Foundation

@MainActor
final class DaemonController: ObservableObject {

    enum Feed: Equatable {
        case pattern
        case webcam(device: String?)
        case video(URL)
        case still(URL)
        case qr(String)

        var label: String {
            switch self {
            case .pattern: return "Test Pattern"
            case .webcam(let device): return device ?? "Mac Camera"
            case .video(let url): return url.lastPathComponent
            case .still(let url): return url.lastPathComponent
            case .qr: return "QR Code"
            }
        }

        var needsCamera: Bool {
            if case .webcam = self { return true }
            return false
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var status = "Stopped"
    @Published private(set) var clientCount = 0
    @Published private(set) var framesSent = 0
    @Published private(set) var devices: [String] = []
    @Published private(set) var lastError: String?

    @Published var feed: Feed = .webcam(device: nil) { didSet { persist(); restartIfRunning() } }
    @Published var fps = 30 { didSet { persist(); restartIfRunning() } }
    @Published var resolution = Resolution.hd720 { didSet { persist(); restartIfRunning() } }

    enum Resolution: String, CaseIterable, Identifiable {
        case sd360 = "640x360"
        case hd720 = "1280x720"
        case hd1080 = "1920x1080"

        var id: String { rawValue }

        var dimensions: (width: Int, height: Int) {
            switch self {
            case .sd360: return (640, 360)
            case .hd720: return (1280, 720)
            case .hd1080: return (1920, 1080)
            }
        }
    }

    static let port = 47009

    private var process: Process?
    /// Restoring assigns the published properties, and every `didSet` persists.
    /// Without this the first assignment writes the *default* feed back over
    /// the stored one before the stored one is read.
    private var isRestoring = false
    private let defaults = UserDefaults.standard

    init() {
        restoreFeed()
        refreshDevices()
        // Launch is the trigger. `MenuBarExtra` builds its content only when the
        // menu is opened, so anything hung off the menu view would wait for a
        // click the user shouldn't have to make.
        start()
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil, let executable = Self.daemonURL else {
            lastError = "simcamd is missing from the app bundle"
            return
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments()

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self?.consume(text) }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
        }

        do {
            try process.run()
        } catch {
            lastError = error.localizedDescription
            return
        }

        self.process = process
        isRunning = true
        clientCount = 0
        framesSent = 0
        lastError = nil
        status = "Starting…"
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        handleTermination()
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    private func restartIfRunning() {
        guard isRunning, !isRestoring else { return }
        stop()
        start()
    }

    private func handleTermination() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        isRunning = false
        clientCount = 0
        if lastError == nil { status = "Stopped" }
    }

    private func arguments() -> [String] {
        let size = resolution.dimensions
        var arguments = ["--fps", String(fps), "--width", String(size.width), "--height", String(size.height)]
        switch feed {
        case .pattern:
            arguments.append("--pattern")
        case .webcam(let device):
            if let device { arguments += ["--device", device] }
        case .video(let url):
            arguments += ["--file", url.path]
        case .still(let url):
            arguments += ["--image", url.path]
        case .qr(let payload):
            arguments += ["--qr", payload]
        }
        return arguments
    }

    /// Ports SimulatorCamera's "Run Diagnostics" — everything you'd otherwise
    /// check by hand when frames aren't arriving.
    func diagnostics() -> String {
        let camera: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = "granted"
        case .denied: camera = "DENIED — System Settings → Privacy & Security → Camera → SimCam"
        case .restricted: camera = "restricted by policy"
        case .notDetermined: camera = "not yet requested"
        @unknown default: camera = "unknown"
        }

        return """
        SimCam diagnostics

        daemon:      \(isRunning ? "running" : "stopped")
        status:      \(status)
        port:        \(Self.port)
        clients:     \(clientCount)
        frames sent: \(framesSent)
        source:      \(feed.label)
        format:      \(resolution.rawValue) @ \(fps)fps
        camera:      \(camera)
        devices:     \(devices.isEmpty ? "none found" : devices.joined(separator: ", "))
        binary:      \(Self.daemonURL?.path ?? "MISSING from app bundle")
        error:       \(lastError ?? "none")

        In the iOS app, set the scheme environment variable
        SIMCAM_SOURCE=network and link SimCamKit to every app target.
        """
    }

    // MARK: - Daemon output

    private func consume(_ text: String) {
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("capturing:") || line.hasPrefix("streaming") {
                status = line
            } else if line.contains("client connected") {
                clientCount += 1
                status = "Streaming"
            } else if line.contains("client disconnected") {
                clientCount = max(0, clientCount - 1)
            } else if line.contains("camera access denied") {
                lastError = "Camera access denied — enable SimCam in System Settings → Privacy & Security → Camera"
                status = "Camera denied"
            } else if let range = line.range(of: "sent "), line.contains(" frames") {
                let digits = line[range.upperBound...].prefix { $0.isNumber }
                framesSent = Int(digits) ?? framesSent
            } else if line.contains("failed to listen") {
                lastError = "Port \(Self.port) is already in use — another simcamd is running"
            }
        }
    }

    // MARK: - Devices

    func refreshDevices() {
        devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.map(\.localizedName)
    }

    // MARK: - Persistence

    private func persist() {
        guard !isRestoring else { return }
        defaults.set(fps, forKey: "fps")
        switch feed {
        case .webcam(let device):
            defaults.set("webcam", forKey: "feedKind")
            defaults.set(device, forKey: "feedDevice")
        case .video(let url):
            defaults.set("video", forKey: "feedKind")
            defaults.set(url.path, forKey: "feedPath")
        case .still(let url):
            defaults.set("still", forKey: "feedKind")
            defaults.set(url.path, forKey: "feedPath")
        case .pattern:
            defaults.set("pattern", forKey: "feedKind")
        case .qr(let payload):
            defaults.set("qr", forKey: "feedKind")
            defaults.set(payload, forKey: "feedQR")
        }
        defaults.set(resolution.rawValue, forKey: "resolution")
    }

    private func restoreFeed() {
        isRestoring = true
        defer { isRestoring = false }

        if let stored = defaults.object(forKey: "fps") as? Int { fps = stored }
        if let stored = defaults.string(forKey: "resolution").flatMap(Resolution.init(rawValue:)) {
            resolution = stored
        }
        let path = defaults.string(forKey: "feedPath") ?? ""
        switch defaults.string(forKey: "feedKind") {
        case "video" where !path.isEmpty: feed = .video(URL(fileURLWithPath: path))
        case "still" where !path.isEmpty: feed = .still(URL(fileURLWithPath: path))
        case "pattern": feed = .pattern
        case "qr": feed = .qr(defaults.string(forKey: "feedQR") ?? "https://simcam.local")
        default: feed = .webcam(device: defaults.string(forKey: "feedDevice"))
        }
    }

    private static var daemonURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "simcamd")
            ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("simcamd")
    }
}
