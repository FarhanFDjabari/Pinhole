//
//  PinholeSession.swift
//  Simulator-only stand-in for AVCaptureSession. Produces real CMSampleBuffers
//  from a chosen source so capture pipelines can be exercised where the iOS
//  Simulator exposes no camera devices at all (AVCaptureDevice discovery
//  returns an empty list there, host webcams included).
//

import Foundation
import CoreMedia
import CoreVideo
import UIKit

@MainActor
public protocol PinholeSampleBufferDelegate: AnyObject {
    /// Mirrors the body of AVCaptureVideoDataOutputSampleBufferDelegate's
    /// captureOutput(_:didOutput:from:). AVCaptureConnection cannot be
    /// constructed without real input ports, so the connection argument is
    /// dropped rather than faked.
    func pinhole(_ session: PinholeSession, didOutput sampleBuffer: CMSampleBuffer)
}

public enum PinholeSource {
    /// Animated colour bars with a moving sweep and frame counter.
    case testPattern
    case image(UIImage)
    /// Looped video file. Audio track ignored.
    case video(URL)
    /// Generated QR code carrying `payload`, centred on white.
    case qr(String)
    /// Live frames from pinholed on the host. Simulator shares the host network
    /// stack, so 127.0.0.1 reaches the Mac directly.
    case network(host: String, port: UInt16)
}

/// Frames are always delivered on the main actor, whichever thread the
/// underlying producer runs on.
@MainActor
public final class PinholeSession {

    public weak var delegate: PinholeSampleBufferDelegate?
    public private(set) var isRunning = false
    public let frameSize: CGSize
    public let frameRate: Int

    /// Preview views subscribe here; keyed by token so they can detach.
    private var observers: [UUID: (CMSampleBuffer) -> Void] = [:]
    private var producer: PinholeFrameProducer?
    private var latestPixelBuffer: CVPixelBuffer?
    private var formatDescription: CMFormatDescription?
    private let source: PinholeSource

    public init(source: PinholeSource,
                frameSize: CGSize = CGSize(width: 1280, height: 720),
                frameRate: Int = 30) {
        self.source = source
        self.frameSize = frameSize
        self.frameRate = frameRate
    }

    deinit { producer?.stop() }

    public func startRunning() {
        guard !isRunning else { return }
        isRunning = true
        let producer = Self.makeProducer(for: source, size: frameSize, fps: frameRate)
        // The network producer reads on its own queue, so hop before touching
        // any session state.
        producer.onFrame = { [weak self] pixelBuffer, timestamp in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.emit(pixelBuffer, at: timestamp) }
            } else {
                DispatchQueue.main.async { self?.emit(pixelBuffer, at: timestamp) }
            }
        }
        self.producer = producer
        producer.start()
    }

    public func stopRunning() {
        guard isRunning else { return }
        isRunning = false
        producer?.stop()
        producer = nil
    }

    /// Stand-in for AVCapturePhotoOutput.capturePhoto — hands back the most
    /// recent frame. Completion runs on the main queue.
    public func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        completion(latestPixelBuffer.flatMap { PinholePixelBuffer.image(from: $0) })
    }

    public func addFrameObserver(_ handler: @escaping (CMSampleBuffer) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeFrameObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func emit(_ pixelBuffer: CVPixelBuffer, at timestamp: Double) {
        latestPixelBuffer = pixelBuffer
        let handlers = Array(observers.values)

        guard let sampleBuffer = makeSampleBuffer(pixelBuffer, timestamp: timestamp) else { return }
        delegate?.pinhole(self, didOutput: sampleBuffer)
        handlers.forEach { $0(sampleBuffer) }
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, timestamp: Double) -> CMSampleBuffer? {
        if formatDescription == nil ||
            !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var description: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
            formatDescription = description
        }
        guard let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: 1_000_000),
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }

    private static func makeProducer(for source: PinholeSource, size: CGSize, fps: Int) -> PinholeFrameProducer {
        switch source {
        case .testPattern:
            return PinholeTestPatternProducer(size: size, fps: fps)
        case .image(let image):
            return PinholeStillProducer(image: image, size: size, fps: fps)
        case .qr(let payload):
            return PinholeStillProducer(image: PinholePixelBuffer.qrImage(payload, size: size), size: size, fps: fps)
        case .video(let url):
            return PinholeVideoProducer(url: url, size: size, fps: fps)
        case .network(let host, let port):
            return PinholeNetworkProducer(host: host, port: port)
        }
    }
}

protocol PinholeFrameProducer: AnyObject {
    var onFrame: ((CVPixelBuffer, Double) -> Void)? { get set }
    func start()
    func stop()
}
