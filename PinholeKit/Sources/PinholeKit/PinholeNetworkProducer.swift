//
//  PinholeNetworkProducer.swift
//  Reads PinholeWire frames from pinholed running on the host Mac. The Simulator
//  shares the host's network stack, so 127.0.0.1 is the Mac itself.
//

import CoreVideo
import Foundation
import Network
import UIKit

final class PinholeNetworkProducer: PinholeFrameProducer {
    var onFrame: ((CVPixelBuffer, Double) -> Void)?

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.pinholekit.network")
    private var connection: NWConnection?
    private var buffer = Data()
    private var stopped = false

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        connection?.cancel()
        connection = nil
    }

    private func connect() {
        guard !stopped, let port = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.scheduleReconnect()
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
        buffer.removeAll(keepingCapacity: false)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.stopped, self.connection == nil else { return }
            self.connect()
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainFrames()
            }
            if error != nil || isComplete {
                self.scheduleReconnect()
                return
            }
            self.receive()
        }
    }

    private func drainFrames() {
        while let header = PinholeWire.decodeHeader(buffer) {
            let total = PinholeWire.headerSize + header.payloadLength
            guard buffer.count >= total else { return }
            let payload = buffer.subdata(in: PinholeWire.headerSize..<total)
            buffer.removeSubrange(0..<total)

            guard let image = UIImage(data: payload),
                  let pixelBuffer = PinholePixelBuffer.buffer(
                    from: image,
                    size: CGSize(width: header.width, height: header.height))
            else { continue }
            onFrame?(pixelBuffer, header.timestamp)
        }
    }
}
