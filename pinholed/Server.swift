//
//  Server.swift
//  Part of pinholed — see main.swift.
//

import AVFoundation
import CoreImage
import Foundation
import Network

// MARK: - Frame broadcast

final class FrameServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "pinholed.server")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var frames = 0

    init(port: UInt16) throws {
        // Deliberately not allowLocalEndpointReuse: a second daemon should be
        // rejected outright, not quietly bind alongside the first.
        let parameters = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "pinholed", code: 1)
        }
        listener = try NWListener(using: parameters, on: nwPort)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("client connected")
                case .failed, .cancelled:
                    self.queue.async { self.connections[ObjectIdentifier(connection)] = nil }
                    print("client disconnected")
                default:
                    break
                }
            }
            self.queue.async { self.connections[ObjectIdentifier(connection)] = connection }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    func broadcast(_ data: Data) {
        queue.async {
            self.frames += 1
            if self.frames % 60 == 0 { print("sent \(self.frames) frames") }
            for connection in self.connections.values where connection.state == .ready {
                connection.send(content: data, completion: .idempotent)
            }
        }
    }
}
