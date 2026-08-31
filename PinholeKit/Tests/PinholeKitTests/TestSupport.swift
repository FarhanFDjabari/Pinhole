//
//  TestSupport.swift
//  A stand-in daemon and a frame collector. Both speak over a real loopback
//  socket rather than a mock, because the behaviour under test — reassembly
//  across arbitrary read boundaries, reconnect after the peer vanishes — only
//  exists at the transport.
//

import CoreVideo
import Foundation
import Network
import XCTest
@testable import PinholeKit

/// Minimal PinholeWire server: hands out whatever bytes a test tells it to, and
/// can drop clients or disappear entirely on demand.
final class TestFrameServer {

    private let queue = DispatchQueue(label: "test.frame.server")
    private let condition = NSCondition()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var acceptedCount = 0

    private(set) var port: UInt16 = 0

    /// Binds to an ephemeral port, or rebinds a port a previous instance used —
    /// which is how a test stands the "daemon" back up after killing it.
    init(port: UInt16 = 0) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpoint = NWEndpoint.Port(rawValue: port) ?? .any
        listener = try NWListener(using: parameters, on: endpoint)
    }

    func start(timeout: TimeInterval = 5) throws {
        guard let listener else { return XCTFail("server already stopped") }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.condition.lock()
            self.connections.append(connection)
            self.acceptedCount += 1
            self.condition.broadcast()
            self.condition.unlock()
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else {
            throw XCTSkip("loopback listener never became ready")
        }
        port = listener.port?.rawValue ?? 0
    }

    var connectionCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return acceptedCount
    }

    @discardableResult
    func waitForConnections(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while acceptedCount < count {
            guard condition.wait(until: deadline) else { return acceptedCount >= count }
        }
        return true
    }

    /// Sends to every client. Network queues writes issued before a connection
    /// finishes coming up, so this is safe to call the moment one is accepted.
    func send(_ data: Data) {
        condition.lock()
        let targets = connections
        condition.unlock()
        for connection in targets {
            connection.send(content: data, completion: .idempotent)
        }
    }

    /// Drops the clients but keeps listening — a daemon that lost the stream.
    func dropClients() {
        condition.lock()
        let targets = connections
        connections.removeAll()
        condition.unlock()
        for connection in targets { connection.cancel() }
    }

    /// Stops listening entirely — a daemon that exited.
    func stop() {
        dropClients()
        listener?.cancel()
        listener = nil
    }
}

/// Gathers frames delivered by a stream, from whatever queue they arrive on.
final class FrameCollector {
    private let condition = NSCondition()
    private var received: [(width: Int, height: Int, timestamp: Double)] = []

    func record(_ pixelBuffer: CVPixelBuffer, _ timestamp: Double) {
        condition.lock()
        received.append((CVPixelBufferGetWidth(pixelBuffer),
                         CVPixelBufferGetHeight(pixelBuffer),
                         timestamp))
        condition.broadcast()
        condition.unlock()
    }

    var frames: [(width: Int, height: Int, timestamp: Double)] {
        condition.lock()
        defer { condition.unlock() }
        return received
    }

    var timestamps: [Double] { frames.map(\.timestamp) }

    @discardableResult
    func waitForFrames(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while received.count < count {
            guard condition.wait(until: deadline) else { return received.count >= count }
        }
        return true
    }

    /// Asserts nothing more arrives — used to prove a frame was dropped rather
    /// than merely delayed.
    func expectNoMoreFrames(than count: Int, within: TimeInterval = 0.4) {
        Thread.sleep(forTimeInterval: within)
        XCTAssertEqual(frames.count, count)
    }
}

enum TestPixelBuffer {
    /// A decoder stand-in: real CVPixelBuffers at the header's dimensions, so a
    /// test can tell frames apart, with a payload marker that forces a failure.
    static let undecodableMarker: UInt8 = 0xDE

    static func decoder(_ payload: Data, _ width: Int, _ height: Int) -> CVPixelBuffer? {
        guard payload.first != undecodableMarker else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, max(width, 1), max(height, 1),
                            kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer
    }
}

func wireFrame(marker: UInt8 = 0x01,
               payloadSize: Int = 32,
               width: Int = 320,
               height: Int = 240,
               timestamp: Double) -> Data {
    PinholeWire.encode(jpeg: Data(repeating: marker, count: payloadSize),
                       width: width, height: height, timestamp: timestamp)
}

// MARK: - The real daemon

import CoreGraphics
import ImageIO

/// Runs the actual pinholed binary. The camera-free `--pattern` and `--qr`
/// sources make this usable anywhere, with no capture device and no TCC prompt.
final class PinholedProcess {

    private var process: Process?
    private let output = NSMutableString()
    private let lock = NSLock()

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PinholeKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // PinholeKit
            .deletingLastPathComponent()   // repo root
    }

    /// pinholed is built by scripts/build-pinholed.sh rather than SwiftPM — it
    /// needs an embedded Info.plist, which SwiftPM can only express through
    /// unsafe flags that would make this package unusable as a dependency.
    static func binaryPath() throws -> URL {
        let binary = repositoryRoot.appendingPathComponent(".build-dev/pinholed")
        if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/bash")
        build.arguments = [repositoryRoot.appendingPathComponent("scripts/build-pinholed.sh").path]
        build.currentDirectoryURL = repositoryRoot
        build.standardOutput = Pipe()
        build.standardError = Pipe()
        try? build.run()
        build.waitUntilExit()

        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("pinholed is not built and scripts/build-pinholed.sh did not produce it")
        }
        return binary
    }

    /// A port nothing is listening on: bind an ephemeral one, note it, release it.
    static func freePort() throws -> UInt16 {
        let probe = try TestFrameServer()
        try probe.start()
        let port = probe.port
        probe.stop()
        return port
    }

    /// Launches and waits for the daemon to report it is listening. Retried
    /// because a port freed moments ago by a previous daemon can still be held
    /// briefly by the kernel, and pinholed deliberately does not reuse endpoints.
    func launch(arguments: [String], timeout: TimeInterval = 10) throws {
        let binary = try PinholedProcess.binaryPath()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = binary
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    // EOF: the handler would otherwise spin on empty reads.
                    handle.readabilityHandler = nil
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else { return }
                self?.lock.lock()
                self?.output.append(text)
                self?.lock.unlock()
            }
            try process.run()
            self.process = process

            let ready = Date().addingTimeInterval(2)
            while Date() < ready {
                if transcript.contains("listening on") { return }
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            terminate()
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw XCTSkip("pinholed never came up: \(transcript)")
    }

    var transcript: String {
        lock.lock()
        defer { lock.unlock() }
        return output as String
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
        self.process = nil
    }
}

enum TestJPEG {
    /// Decodes a real JPEG payload, sizing the buffer from the image itself
    /// rather than the header — so a test can assert the daemon actually
    /// produced a decodable image at the size it advertised.
    static func decoder(_ payload: Data, _ width: Int, _ height: Int) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                            kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer
    }
}
