//
//  PinholeWire.swift
//  Frame wire format shared by the iOS client (PinholeKit) and the macOS
//  streaming daemon (pinholed). Compiled into both — keep it dependency-free
//  beyond Foundation so `swiftc` can pull it straight into the daemon.
//
//  Layout, little-endian, 28-byte header followed by payload:
//
//    0  magic      UInt32  'PHF1'
//    4  payloadLen UInt32
//    8  width      UInt32
//   12  height     UInt32
//   16  timestamp  Float64  seconds, monotonic from stream start
//   24  format     UInt8    0 = JPEG
//   25  reserved   3 bytes
//   28  payload    payloadLen bytes
//

import Foundation

public enum PinholeWire {
    public static let magic: UInt32 = 0x50484631  // "PHF1"
    public static let headerSize = 28
    public static let defaultPort: UInt16 = 47009

    public struct Header {
        public let payloadLength: Int
        public let width: Int
        public let height: Int
        public let timestamp: Double

        public init(payloadLength: Int, width: Int, height: Int, timestamp: Double) {
            self.payloadLength = payloadLength
            self.width = width
            self.height = height
            self.timestamp = timestamp
        }
    }

    public static func encode(jpeg: Data, width: Int, height: Int, timestamp: Double) -> Data {
        var out = Data(capacity: headerSize + jpeg.count)
        appendLE(&out, UInt32(magic))
        appendLE(&out, UInt32(jpeg.count))
        appendLE(&out, UInt32(width))
        appendLE(&out, UInt32(height))
        appendLE(&out, timestamp.bitPattern)
        out.append(0)              // format: JPEG
        out.append(contentsOf: [0, 0, 0])
        out.append(jpeg)
        return out
    }

    /// Returns nil when `data` is shorter than a full header or the magic is wrong.
    public static func decodeHeader(_ data: Data) -> Header? {
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data.prefix(headerSize))
        guard readLE32(bytes, 0) == magic else { return nil }
        return Header(
            payloadLength: Int(readLE32(bytes, 4)),
            width: Int(readLE32(bytes, 8)),
            height: Int(readLE32(bytes, 12)),
            timestamp: Double(bitPattern: readLE64(bytes, 16))
        )
    }

    private static func appendLE(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendLE(_ data: inout Data, _ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readLE32(_ b: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(b[offset]) | UInt32(b[offset + 1]) << 8 | UInt32(b[offset + 2]) << 16 | UInt32(b[offset + 3]) << 24
    }

    private static func readLE64(_ b: [UInt8], _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(b[offset + i]) }
        return v
    }
}
