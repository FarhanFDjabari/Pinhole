//
//  PinholeFrameStream.swift
//  The transport half of the network source: connect, read, reassemble,
//  reconnect. Split out of PinholeNetworkProducer — and kept free of UIKit — so
//  the connection lifecycle can be exercised against a real socket on macOS,
//  where the interesting cases (a daemon that dies mid-frame, a stream that
//  desyncs, a client that reconnects) are otherwise unreachable in a test.
//
//  Image decoding stays with the caller, injected as `decoder`.
//

import CoreVideo
import Foundation
import Network

final class PinholeFrameStream {

    /// Turns a JPEG payload into a pixel buffer at the frame's dimensions.
    /// Returning nil drops that one frame; framing is unaffected, because the
    /// payload has already been delimited by the header.
    typealias Decoder = (Data, Int, Int) -> CVPixelBuffer?

    var onFrame: ((CVPixelBuffer, Double) -> Void)?

    private let host: String
    private let port: UInt16
    private let reconnectDelay: TimeInterval
    private let decoder: Decoder
    private let queue = DispatchQueue(label: "com.pinholekit.network")

    // Every one of these is touched only on `queue`. start() and stop() hop onto
    // it rather than mutating from the caller's thread, so a stop() racing an
    // in-flight receive cannot tear the connection state.
    private var connection: NWConnection?
    private var frames = PinholeFrameBuffer()
    private var stopped = false

    init(host: String,
         port: UInt16,
         reconnectDelay: TimeInterval = 1,
         decoder: @escaping Decoder) {
        self.host = host
        self.port = port
        self.reconnectDelay = reconnectDelay
        self.decoder = decoder
    }

    func start() {
        queue.async {
            self.stopped = false
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel()
            self.connection = nil
        }
    }

    private func connect() {
        guard !stopped, let port = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.queue.async { self.receive() }
            case .failed, .cancelled:
                self.queue.async { self.scheduleReconnect() }
            case .waiting:
                // Nothing listening yet — pinholed not started, or restarting
                // between sources. Network would retry on a schedule of its own
                // that can stall on a refused loopback connection, so drop this
                // attempt and re-dial on the cadence configured here.
                self.queue.async { self.connection?.cancel() }
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        connection = nil
        // The tail of an interrupted frame must not be read as the head of the
        // first frame of the next connection.
        frames.reset()
        queue.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self, !self.stopped, self.connection == nil else { return }
            self.connect()
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.frames.append(data)
                guard self.drainFrames() else {
                    // Desynced: nothing to resync to, so drop the connection and
                    // let the state handler bring it back.
                    self.connection?.cancel()
                    return
                }
            }
            if error != nil || isComplete {
                self.scheduleReconnect()
                return
            }
            self.receive()
        }
    }

    /// Returns false once the stream has desynced and the connection is done.
    private func drainFrames() -> Bool {
        while true {
            let frame: PinholeFrameBuffer.Frame?
            do {
                frame = try frames.nextFrame()
            } catch {
                return false
            }
            guard let frame else { return true }

            guard let pixelBuffer = decoder(frame.payload, frame.header.width, frame.header.height)
            else { continue }
            onFrame?(pixelBuffer, frame.header.timestamp)
        }
    }
}
