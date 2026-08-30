//
//  PreviewClient.swift
//  Renders what the Simulator is actually receiving.
//
//  Rather than tapping the capture pipeline inside the app, this connects to
//  the daemon as an ordinary client on the same socket the Simulator uses — so
//  the preview shows the real stream, wire format included, not a parallel
//  rendering of it.
//

import AppKit
import Foundation
import Network

@MainActor
final class PreviewClient: ObservableObject {

    @Published private(set) var frame: NSImage?
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var isConnected = false

    private let queue = DispatchQueue(label: "com.local.simcam.preview")
    private var connection: NWConnection?
    private var buffer = Data()
    private var stopped = true
    private var frameTimes: [Date] = []

    func start(port: Int) {
        guard stopped else { return }
        stopped = false
        connect(port: port)
    }

    func stop() {
        stopped = true
        connection?.cancel()
        connection = nil
        isConnected = false
        frame = nil
        measuredFPS = 0
    }

    private func connect(port: Int) {
        guard !stopped, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.receive()
                case .failed, .cancelled:
                    self.isConnected = false
                    self.retry(port: port)
                default:
                    break
                }
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func retry(port: Int) {
        guard !stopped else { return }
        connection = nil
        buffer.removeAll(keepingCapacity: false)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped, self.connection == nil else { return }
                self.connect(port: port)
            }
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drain()
                }
                if error != nil || isComplete {
                    self.isConnected = false
                    self.retry(port: DaemonController.port)
                    return
                }
                self.receive()
            }
        }
    }

    private func drain() {
        while let header = SimCamWire.decodeHeader(buffer) {
            let total = SimCamWire.headerSize + header.payloadLength
            guard buffer.count >= total else { return }
            let payload = buffer.subdata(in: SimCamWire.headerSize..<total)
            buffer.removeSubrange(0..<total)
            if let image = NSImage(data: payload) { frame = image }
            recordFrameTime()
        }
    }

    private func recordFrameTime() {
        let now = Date()
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 1 }
        measuredFPS = Double(frameTimes.count)
    }
}
