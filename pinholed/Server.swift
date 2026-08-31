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

    /// Blocks until the listener is actually bound. NWListener does not fail at
    /// init when the port is taken — it reports .failed asynchronously — so
    /// without this a second daemon prints "listening", serves nobody, and
    /// counts frames it is broadcasting into the void.
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        var bindError: NWError?
        var isBound = false

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                isBound = true
                ready.signal()
            case .failed(let error):
                guard !isBound else {
                    // Lost the socket after serving — nothing left to serve on.
                    FileHandle.standardError.write("listener failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
                bindError = error
                ready.signal()
            default:
                break
            }
        }

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

        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "pinholed", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "listener never came up"])
        }
        if let bindError { throw bindError }
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
