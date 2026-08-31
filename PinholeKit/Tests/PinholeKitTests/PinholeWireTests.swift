//
//  PinholeWireTests.swift
//  Header encoding and parsing, at the boundary where bytes from a socket
//  become a frame. Every input here is untrusted by definition.
//

import XCTest
@testable import PinholeKit

final class PinholeWireTests: XCTestCase {

    // MARK: - Round trip

    func testEncodedHeaderRoundTripsEveryField() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let encoded = PinholeWire.encode(jpeg: jpeg, width: 1920, height: 1080, timestamp: 12.5)

        guard case .header(let header) = PinholeWire.parseHeader(encoded) else {
            return XCTFail("expected a header")
        }
        XCTAssertEqual(header.payloadLength, jpeg.count)
        XCTAssertEqual(header.width, 1920)
        XCTAssertEqual(header.height, 1080)
        XCTAssertEqual(header.timestamp, 12.5)
        XCTAssertEqual(encoded.count, PinholeWire.headerSize + jpeg.count)
        XCTAssertEqual(encoded.suffix(jpeg.count), jpeg)
    }

    func testTimestampSurvivesBitExact() {
        // Float64 over the wire: fractional and long-running values must not be
        // rounded, or playback timing drifts against the daemon's clock.
        for timestamp in [0.0, 0.0333333333333333, 1.0 / 3.0, 86_400.123456789, 1e-9] {
            let encoded = PinholeWire.encode(jpeg: Data(), width: 2, height: 2, timestamp: timestamp)
            guard case .header(let header) = PinholeWire.parseHeader(encoded) else {
                return XCTFail("expected a header for \(timestamp)")
            }
            XCTAssertEqual(header.timestamp.bitPattern, timestamp.bitPattern)
        }
    }

    func testMagicIsLittleEndianPHF1() {
        let encoded = PinholeWire.encode(jpeg: Data(), width: 1, height: 1, timestamp: 0)
        XCTAssertEqual([UInt8](encoded.prefix(4)), [0x31, 0x46, 0x48, 0x50])
    }

    // MARK: - Malformed and truncated input

    func testEveryTruncationOfAHeaderIsIncompleteNotInvalid() {
        let encoded = PinholeWire.encode(jpeg: Data([1, 2, 3]), width: 4, height: 4, timestamp: 1)
        for length in 0..<PinholeWire.headerSize {
            XCTAssertEqual(PinholeWire.parseHeader(encoded.prefix(length)), .incomplete,
                           "\(length) bytes should read as incomplete, not corrupt")
        }
    }

    func testWrongMagicIsInvalid() {
        var encoded = PinholeWire.encode(jpeg: Data([1, 2, 3]), width: 4, height: 4, timestamp: 1)
        encoded[0] = 0x00
        XCTAssertEqual(PinholeWire.parseHeader(encoded), .invalid)
    }

    func testAllZeroHeaderIsInvalid() {
        XCTAssertEqual(PinholeWire.parseHeader(Data(repeating: 0, count: 64)), .invalid)
    }

    func testPayloadLengthPastTheCapIsRejected() {
        // An unbounded length is an allocation primitive for anything that can
        // write to the port: 0xFFFFFFFF asks the client to buffer 4 GB.
        var header = [UInt8](PinholeWire.encode(jpeg: Data(), width: 4, height: 4, timestamp: 0))
        header[4...7] = [0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertEqual(PinholeWire.parseHeader(Data(header)), .invalid)
        XCTAssertNil(PinholeWire.decodeHeader(Data(header)))
    }

    func testPayloadLengthAtTheCapIsAccepted() {
        var header = [UInt8](PinholeWire.encode(jpeg: Data(), width: 4, height: 4, timestamp: 0))
        let cap = UInt32(PinholeWire.maxPayloadLength)
        header[4...7] = [UInt8(cap & 0xFF), UInt8((cap >> 8) & 0xFF),
                         UInt8((cap >> 16) & 0xFF), UInt8((cap >> 24) & 0xFF)]
        guard case .header(let parsed) = PinholeWire.parseHeader(Data(header)) else {
            return XCTFail("the cap itself must still be a legal length")
        }
        XCTAssertEqual(parsed.payloadLength, PinholeWire.maxPayloadLength)
    }
}
