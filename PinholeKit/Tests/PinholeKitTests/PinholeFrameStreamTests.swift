//
//  PinholeFrameStreamTests.swift
//  The network source against a real loopback socket: what happens when the
//  peer chunks a frame oddly, sends something that is not a frame, drops the
//  connection mid-stream, or goes away entirely.
//

import CoreVideo
import Foundation
import XCTest
@testable import PinholeKit

final class PinholeFrameStreamTests: XCTestCase {

    private var server: TestFrameServer!
    private var stream: PinholeFrameStream!
    private var collector: FrameCollector!

    override func setUpWithError() throws {
        try super.setUpWithError()
        collector = FrameCollector()
        server = try TestFrameServer()
        try server.start()
    }

    override func tearDown() {
        stream?.stop()
        server?.stop()
        stream = nil
        server = nil
        collector = nil
        super.tearDown()
    }

    /// Short reconnect delay throughout: the production default is a second, and
    /// the behaviour under test is the retry itself, not its spacing.
    private func makeStream(reconnectDelay: TimeInterval = 0.05,
                            port: UInt16? = nil) -> PinholeFrameStream {
        let stream = PinholeFrameStream(host: "127.0.0.1",
                                        port: port ?? server.port,
                                        reconnectDelay: reconnectDelay,
                                        decoder: TestPixelBuffer.decoder)
        stream.onFrame = { [weak self] buffer, timestamp in
            self?.collector.record(buffer, timestamp)
        }
        return stream
    }

    // MARK: - Delivery

    func testFramesArriveInOrderWithTheirTimestampsAndDimensions() {
        stream = makeStream()
        stream.start()
        XCTAssertTrue(server.waitForConnections(1))

        for (index, timestamp) in [0.0, 0.033, 0.066].enumerated() {
            server.send(wireFrame(marker: UInt8(index + 1), width: 640, height: 360, timestamp: timestamp))
        }

        XCTAssertTrue(collector.waitForFrames(3), "expected 3 frames, got \(collector.frames.count)")
        XCTAssertEqual(collector.timestamps, [0.0, 0.033, 0.066])
        XCTAssertTrue(collector.frames.allSatisfy { $0.width == 640 && $0.height == 360 })
    }

    func testFrameSplitAcrossSeparateWritesIsReassembled() {
        stream = makeStream()
        stream.start()
        XCTAssertTrue(server.waitForConnections(1))

        let frame = wireFrame(payloadSize: 4096, timestamp: 7.5)
        server.send(frame.prefix(PinholeWire.headerSize + 100))
        collector.expectNoMoreFrames(than: 0, within: 0.2)
        server.send(frame.suffix(from: PinholeWire.headerSize + 100))

        XCTAssertTrue(collector.waitForFrames(1))
        XCTAssertEqual(collector.timestamps, [7.5])
    }

    func testUndecodablePayloadDropsOnlyThatFrame() {
        // A corrupt JPEG is a lost frame, not a lost stream: the header already
        // delimited the payload, so the next frame is unaffected.
        stream = makeStream()
        stream.start()
        XCTAssertTrue(server.waitForConnections(1))

        server.send(wireFrame(marker: TestPixelBuffer.undecodableMarker, timestamp: 1.0))
        server.send(wireFrame(marker: 0x02, timestamp: 2.0))

        XCTAssertTrue(collector.waitForFrames(1))
        collector.expectNoMoreFrames(than: 1)
        XCTAssertEqual(collector.timestamps, [2.0], "the good frame after the bad one must still arrive")
    }

    func testEveryFrameSurvivesAStreamWrittenOneByteAtATime() {
        stream = makeStream()
        stream.start()
        XCTAssertTrue(server.waitForConnections(1))

        let timestamps = [1.0, 2.0, 3.0]
        var bytes = Data()
        for (index, timestamp) in timestamps.enumerated() {
            bytes += wireFrame(marker: UInt8(index + 1), payloadSize: 12, timestamp: timestamp)
        }
        for byte in bytes { server.send(Data([byte])) }

        XCTAssertTrue(collector.waitForFrames(3))
        XCTAssertEqual(collector.timestamps, timestamps)
    }

    // MARK: - Reconnect

    func testReconnectsAfterThePeerDropsTheConnection() {
        stream = makeStream()
        stream.start()
        XCTAssertTrue(server.waitForConnections(1))
        server.send(wireFrame(timestamp: 1.0))
        XCTAssertTrue(collector.waitForFrames(1))

        server.dropClients()

        XCTAssertTrue(server.waitForConnections(2), "client should dial back in")
        server.send(wireFrame(timestamp: 2.0))
        XCTAssertTrue(collector.waitForFrames(2))
        XCTAssertEqual(collector.timestamps, [1.0, 2.0])
    }

    func testHalfDeliveredFrameIsDiscardedAcrossAReconnect() {
        // Regression risk: the tail of an interrupted frame left in the buffer
        // would be parsed as the head of the first frame of the next connection.
        stream = makeStream()
        stream.start()
        XCTAssertTrue(server.waitForConnections(1))

        let interrupted = wireFrame(payloadSize: 2048, timestamp: 9.0)
        server.send(interrupted.prefix(PinholeWire.headerSize + 64))
        collector.expectNoMoreFrames(than: 0, within: 0.2)
        server.dropClients()

        XCTAssertTrue(server.waitForConnections(2))
        server.send(wireFrame(marker: 0x55, width: 800, height: 600, timestamp: 10.0))

        XCTAssertTrue(collector.waitForFrames(1))
        XCTAssertEqual(collector.timestamps, [10.0])
        XCTAssertEqual(collector.frames.first?.width, 800)
    }

    func testDesyncedStreamIsDroppedAndRecoversOnReconnect() {
        // The bug this guards: a bad magic read as "keep buffering" left the
        // client waiting forever on a connection that never closes.
        stream = makeStream()
        stream.start()
        XCTAssertTrue(server.waitForConnections(1))

        server.send(wireFrame(timestamp: 1.0))
        XCTAssertTrue(collector.waitForFrames(1))
        server.send(Data(repeating: 0xEE, count: 256))

        XCTAssertTrue(server.waitForConnections(2), "desync must drop the connection, not stall on it")
        server.send(wireFrame(timestamp: 2.0))
        XCTAssertTrue(collector.waitForFrames(2))
        XCTAssertEqual(collector.timestamps, [1.0, 2.0])
    }

    func testOversizedPayloadLengthDropsTheConnectionInsteadOfBuffering() {
        stream = makeStream()
        stream.start()
        XCTAssertTrue(server.waitForConnections(1))

        var header = [UInt8](wireFrame(timestamp: 1.0).prefix(PinholeWire.headerSize))
        header[4...7] = [0xFF, 0xFF, 0xFF, 0xFF]
        server.send(Data(header))

        XCTAssertTrue(server.waitForConnections(2))
        server.send(wireFrame(timestamp: 3.0))
        XCTAssertTrue(collector.waitForFrames(1))
        XCTAssertEqual(collector.timestamps, [3.0])
    }

    // MARK: - Peer lifetime

    func testKeepsRetryingWhileTheDaemonIsGoneAndResumesWhenItReturns() throws {
        stream = makeStream()
        stream.start()
        XCTAssertTrue(server.waitForConnections(1))
        server.send(wireFrame(timestamp: 1.0))
        XCTAssertTrue(collector.waitForFrames(1))

        // Daemon exits: listener gone, port free.
        let port = server.port
        server.stop()
        Thread.sleep(forTimeInterval: 0.3)

        // Daemon comes back on the same port.
        server = try TestFrameServer(port: port)
        try server.start()

        XCTAssertTrue(server.waitForConnections(1, timeout: 8), "client should still be retrying")
        server.send(wireFrame(timestamp: 2.0))
        XCTAssertTrue(collector.waitForFrames(2))
        XCTAssertEqual(collector.timestamps, [1.0, 2.0])
    }

    func testStopEndsTheStreamAndPreventsFurtherReconnects() {
        stream = makeStream()
        stream.start()
        XCTAssertTrue(server.waitForConnections(1))

        stream.stop()
        Thread.sleep(forTimeInterval: 0.5)
        let connectionsAfterStop = server.connectionCount

        server.send(wireFrame(timestamp: 1.0))
        collector.expectNoMoreFrames(than: 0)
        XCTAssertEqual(server.connectionCount, connectionsAfterStop,
                       "a stopped stream must not dial back in")
    }

    func testConnectingBeforeTheDaemonExistsSucceedsOnceItAppears() throws {
        // Ordinary startup order: the app launches before pinholed is up.
        let port = server.port
        server.stop()
        Thread.sleep(forTimeInterval: 0.2)

        stream = makeStream(port: port)
        stream.start()
        Thread.sleep(forTimeInterval: 0.3)

        server = try TestFrameServer(port: port)
        try server.start()

        XCTAssertTrue(server.waitForConnections(1, timeout: 8))
        server.send(wireFrame(timestamp: 4.0))
        XCTAssertTrue(collector.waitForFrames(1))
        XCTAssertEqual(collector.timestamps, [4.0])
    }
}
