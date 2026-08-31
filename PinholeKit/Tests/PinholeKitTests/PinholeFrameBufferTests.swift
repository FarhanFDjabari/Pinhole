//
//  PinholeFrameBufferTests.swift
//  Reassembly of a TCP byte stream into frames. TCP guarantees ordering and
//  delivery but nothing about chunk boundaries, so the split points below are
//  the realistic adversary, not an artificial one.
//

import XCTest
@testable import PinholeKit

final class PinholeFrameBufferTests: XCTestCase {

    private func frame(_ marker: UInt8, size: Int = 8, timestamp: Double) -> Data {
        PinholeWire.encode(jpeg: Data(repeating: marker, count: size),
                           width: 320, height: 240, timestamp: timestamp)
    }

    // MARK: - Framing

    func testSingleFrameIsYieldedThenBufferDrains() throws {
        var buffer = PinholeFrameBuffer()
        buffer.append(frame(0xAB, timestamp: 1.0))

        let decoded = try XCTUnwrap(try buffer.nextFrame())
        XCTAssertEqual(decoded.payload, Data(repeating: 0xAB, count: 8))
        XCTAssertEqual(decoded.header.timestamp, 1.0)
        XCTAssertNil(try buffer.nextFrame())
        XCTAssertEqual(buffer.bufferedByteCount, 0)
    }

    func testTwoFramesInOneReadAreYieldedInOrder() throws {
        var buffer = PinholeFrameBuffer()
        buffer.append(frame(0x01, timestamp: 1.0) + frame(0x02, timestamp: 2.0))

        let first = try XCTUnwrap(try buffer.nextFrame())
        let second = try XCTUnwrap(try buffer.nextFrame())
        XCTAssertEqual(first.payload.first, 0x01)
        XCTAssertEqual(second.payload.first, 0x02)
        XCTAssertNil(try buffer.nextFrame())
    }

    func testPartialFrameYieldsNothingUntilItCompletes() throws {
        let whole = frame(0x7F, size: 64, timestamp: 3.5)
        var buffer = PinholeFrameBuffer()

        buffer.append(whole.prefix(PinholeWire.headerSize + 10))
        XCTAssertNil(try buffer.nextFrame(), "a header without its payload is not a frame")

        buffer.append(whole.suffix(from: PinholeWire.headerSize + 10))
        let decoded = try XCTUnwrap(try buffer.nextFrame())
        XCTAssertEqual(decoded.payload, Data(repeating: 0x7F, count: 64))
    }

    func testStreamSplitOneByteAtATimeRebuildsEveryFrameInOrder() throws {
        // The worst chunking the transport can hand over: no read ever contains
        // a whole header, let alone a whole frame.
        let timestamps = [0.0, 0.033, 0.066, 0.1]
        var stream = Data()
        for (index, timestamp) in timestamps.enumerated() {
            stream += frame(UInt8(index + 1), size: 16, timestamp: timestamp)
        }

        var buffer = PinholeFrameBuffer()
        var decoded: [PinholeFrameBuffer.Frame] = []
        for byte in stream {
            buffer.append(Data([byte]))
            while let next = try buffer.nextFrame() { decoded.append(next) }
        }

        XCTAssertEqual(decoded.count, timestamps.count)
        XCTAssertEqual(decoded.map(\.header.timestamp), timestamps)
        XCTAssertEqual(decoded.map { $0.payload.first }, [1, 2, 3, 4])
        XCTAssertTrue(decoded.allSatisfy { $0.payload.count == 16 })
    }

    func testZeroLengthPayloadIsAFrameAndDoesNotStallTheLoop() throws {
        var buffer = PinholeFrameBuffer()
        buffer.append(PinholeWire.encode(jpeg: Data(), width: 1, height: 1, timestamp: 9.0)
                      + frame(0x05, timestamp: 10.0))

        let empty = try XCTUnwrap(try buffer.nextFrame())
        XCTAssertEqual(empty.payload.count, 0)
        let next = try XCTUnwrap(try buffer.nextFrame())
        XCTAssertEqual(next.header.timestamp, 10.0)
    }

    // MARK: - Desync

    func testGarbageAfterAGoodFrameThrowsRatherThanStalling() throws {
        // Regression: while-let over a nil-on-both-causes decode treated a bad
        // magic as "need more bytes", so the reader waited forever on a healthy
        // connection and the buffer grew without bound.
        var buffer = PinholeFrameBuffer()
        buffer.append(frame(0x11, timestamp: 1.0) + Data(repeating: 0xEE, count: 128))

        XCTAssertNotNil(try buffer.nextFrame(), "the intact frame still comes through")
        XCTAssertThrowsError(try buffer.nextFrame()) { error in
            XCTAssertTrue(error is PinholeFrameBuffer.DesyncError)
        }
    }

    func testOversizedPayloadLengthThrowsInsteadOfBuffering() {
        var header = [UInt8](PinholeWire.encode(jpeg: Data(), width: 4, height: 4, timestamp: 0))
        header[4...7] = [0xFF, 0xFF, 0xFF, 0xFF]

        var buffer = PinholeFrameBuffer()
        buffer.append(Data(header))
        XCTAssertThrowsError(try buffer.nextFrame()) { error in
            XCTAssertTrue(error is PinholeFrameBuffer.DesyncError)
        }
    }

    func testDesyncIsReportedOnEveryCallNotJustTheFirst() {
        var buffer = PinholeFrameBuffer()
        buffer.append(Data(repeating: 0xEE, count: 64))
        XCTAssertThrowsError(try buffer.nextFrame())
        XCTAssertThrowsError(try buffer.nextFrame(), "a desynced buffer must not heal itself")
    }

    // MARK: - Reconnect

    func testResetDropsAPartialFrameSoTheNextStreamStartsClean() throws {
        let whole = frame(0x22, size: 32, timestamp: 5.0)
        var buffer = PinholeFrameBuffer()

        buffer.append(whole.prefix(PinholeWire.headerSize + 4))
        XCTAssertNil(try buffer.nextFrame())

        // What a reconnect does: the tail of the interrupted frame would
        // otherwise be parsed as the head of the first frame of the new stream.
        buffer.reset()
        XCTAssertEqual(buffer.bufferedByteCount, 0)

        buffer.append(frame(0x33, timestamp: 0.0))
        let decoded = try XCTUnwrap(try buffer.nextFrame())
        XCTAssertEqual(decoded.payload.first, 0x33)
        XCTAssertEqual(decoded.header.timestamp, 0.0)
    }

    func testResetClearsADesyncedBuffer() throws {
        var buffer = PinholeFrameBuffer()
        buffer.append(Data(repeating: 0xEE, count: 64))
        XCTAssertThrowsError(try buffer.nextFrame())

        buffer.reset()
        buffer.append(frame(0x44, timestamp: 2.0))
        let decoded = try XCTUnwrap(try buffer.nextFrame())
        XCTAssertEqual(decoded.payload.first, 0x44)
    }
}
