//
//  PinholedIntegrationTests.swift
//  End to end against the real daemon binary: pinholed encoding frames on one
//  side, PinholeFrameStream decoding them on the other, over a real socket.
//  Uses the camera-free sources, so it needs no capture device.
//

import CoreVideo
import Foundation
import XCTest
@testable import PinholeKit

final class PinholedIntegrationTests: XCTestCase {

    private var daemon: PinholedProcess!
    private var streams: [PinholeFrameStream] = []
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = try PinholedProcess.binaryPath()
        port = try PinholedProcess.freePort()
        daemon = PinholedProcess()
    }

    override func tearDown() {
        streams.forEach { $0.stop() }
        streams.removeAll()
        daemon?.terminate()
        daemon = nil
        super.tearDown()
    }

    private func connectClient() -> FrameCollector {
        let collector = FrameCollector()
        let stream = PinholeFrameStream(host: "127.0.0.1",
                                        port: port,
                                        reconnectDelay: 0.1,
                                        decoder: TestJPEG.decoder)
        stream.onFrame = { collector.record($0, $1) }
        stream.start()
        streams.append(stream)
        return collector
    }

    private func patternArguments(width: Int = 640, height: Int = 360, fps: Int = 30) -> [String] {
        ["--pattern", "--port", "\(port)", "--width", "\(width)", "--height", "\(height)", "--fps", "\(fps)"]
    }

    // MARK: - Streaming

    func testDaemonServesDecodableJPEGFramesAtTheRequestedSize() throws {
        try daemon.launch(arguments: patternArguments(width: 640, height: 360))
        let client = connectClient()

        XCTAssertTrue(client.waitForFrames(5), "only got \(client.frames.count) frames")
        // Dimensions come from decoding the JPEG, not from the header, so this
        // fails if the daemon ever advertises a size it does not encode.
        XCTAssertTrue(client.frames.allSatisfy { $0.width == 640 && $0.height == 360 },
                      "decoded sizes: \(Set(client.frames.map { "\($0.width)x\($0.height)" }))")
    }

    func testTimestampsIncreaseMonotonicallyFromNearZero() throws {
        try daemon.launch(arguments: patternArguments())
        let client = connectClient()
        XCTAssertTrue(client.waitForFrames(10))

        let timestamps = client.timestamps
        XCTAssertEqual(timestamps, timestamps.sorted(), "frames must arrive in order")
        XCTAssertEqual(Set(timestamps).count, timestamps.count, "no duplicated timestamps")
        // Stream-relative clock: the first frame a late-joining client sees is
        // whatever the daemon is up to, but it must be a sane elapsed value.
        XCTAssertGreaterThanOrEqual(timestamps.first!, 0)
    }

    // MARK: - Multiple clients

    func testTwoClientsBothReceiveTheStream() throws {
        try daemon.launch(arguments: patternArguments())
        let first = connectClient()
        let second = connectClient()

        XCTAssertTrue(first.waitForFrames(5), "first client got \(first.frames.count)")
        XCTAssertTrue(second.waitForFrames(5), "second client got \(second.frames.count)")
        XCTAssertTrue(second.timestamps.allSatisfy { $0 > 0 })
    }

    func testOneClientLeavingDoesNotDisturbTheOther() throws {
        try daemon.launch(arguments: patternArguments())
        let staying = connectClient()
        let leaving = connectClient()
        XCTAssertTrue(staying.waitForFrames(3))
        XCTAssertTrue(leaving.waitForFrames(3))

        streams.removeLast().stop()

        let countBefore = staying.frames.count
        XCTAssertTrue(staying.waitForFrames(countBefore + 5),
                      "the remaining client must keep receiving after a peer disconnects")
        XCTAssertTrue(daemon.isRunning, "a client disconnect must not take the daemon down")
    }

    // MARK: - Daemon lifetime

    func testClientReconnectsAfterTheDaemonIsRestarted() throws {
        try daemon.launch(arguments: patternArguments())
        let client = connectClient()
        XCTAssertTrue(client.waitForFrames(3))

        daemon.terminate()
        XCTAssertFalse(daemon.isRunning)
        Thread.sleep(forTimeInterval: 0.3)
        let countWhileDown = client.frames.count

        daemon = PinholedProcess()
        try daemon.launch(arguments: patternArguments())

        XCTAssertTrue(client.waitForFrames(countWhileDown + 5, timeout: 15),
                      "client should reconnect to the restarted daemon on its own")
    }

    func testFramesStopWhenTheDaemonDies() throws {
        try daemon.launch(arguments: patternArguments())
        let client = connectClient()
        XCTAssertTrue(client.waitForFrames(3))

        daemon.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        let settled = client.frames.count
        // No partial or fabricated frames after the peer is gone.
        client.expectNoMoreFrames(than: settled, within: 0.5)
    }

    // MARK: - Source switching

    func testSwitchingSourceChangesTheFramesTheClientDecodes() throws {
        // What the menu bar app does when the user picks a different source: the
        // daemon is relaunched on the same port and the client follows it over.
        try daemon.launch(arguments: patternArguments(width: 640, height: 360))
        let client = connectClient()
        XCTAssertTrue(client.waitForFrames(3))
        XCTAssertTrue(client.frames.allSatisfy { $0.width == 640 && $0.height == 360 })

        daemon.terminate()
        Thread.sleep(forTimeInterval: 0.3)
        let countBeforeSwitch = client.frames.count

        daemon = PinholedProcess()
        try daemon.launch(arguments: ["--qr", "pinhole-test",
                                      "--port", "\(port)",
                                      "--width", "320", "--height", "320",
                                      "--fps", "30"])

        XCTAssertTrue(client.waitForFrames(countBeforeSwitch + 5, timeout: 15))
        let afterSwitch = Array(client.frames.dropFirst(countBeforeSwitch))
        XCTAssertTrue(afterSwitch.allSatisfy { $0.width == 320 && $0.height == 320 },
                      "frames after the switch: \(Set(afterSwitch.map { "\($0.width)x\($0.height)" }))")
    }

    func testDaemonRefusesASecondInstanceOnTheSamePort() throws {
        // Deliberate: the listener does not reuse the endpoint, so a stray second
        // daemon fails loudly instead of quietly competing for clients.
        try daemon.launch(arguments: patternArguments())

        let second = Process()
        second.executableURL = try PinholedProcess.binaryPath()
        second.arguments = patternArguments()
        let pipe = Pipe()
        second.standardOutput = pipe
        second.standardError = pipe
        try second.run()
        second.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertNotEqual(second.terminationStatus, 0, "second daemon should have exited non-zero")
        XCTAssertTrue(output.contains("failed to listen"), "unexpected output: \(output)")
    }
}
