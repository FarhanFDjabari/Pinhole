//
//  PinholeFrameBuffer.swift
//  The framing half of the network reader, split out from PinholeNetworkProducer
//  so it can be tested without a socket, a camera, or UIKit: TCP hands over an
//  arbitrarily chunked byte stream, and turning that back into whole frames is
//  where the interesting failure modes live.
//

import Foundation

/// Accumulates bytes off the wire and yields whole frames in arrival order.
struct PinholeFrameBuffer {

    struct Frame: Equatable {
        let header: PinholeWire.Header
        let payload: Data
    }

    /// Thrown once the stream stops being PinholeWire. Not recoverable in place:
    /// the caller drops the connection and reconnects.
    struct DesyncError: Error {}

    private var buffer = Data()

    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next whole frame, or nil when more bytes are needed.
    mutating func nextFrame() throws -> Frame? {
        switch PinholeWire.parseHeader(buffer) {
        case .incomplete:
            return nil
        case .invalid:
            throw DesyncError()
        case .header(let header):
            let total = PinholeWire.headerSize + header.payloadLength
            guard buffer.count >= total else { return nil }
            let payload = buffer.subdata(in: PinholeWire.headerSize..<total)
            buffer.removeSubrange(0..<total)
            return Frame(header: header, payload: payload)
        }
    }

    /// Drops any partial frame. Used on reconnect, where the remainder of an
    /// interrupted frame would otherwise be read as the head of the next one.
    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
