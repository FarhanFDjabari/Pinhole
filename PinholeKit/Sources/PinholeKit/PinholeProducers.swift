//
//  PinholeProducers.swift
//  Local frame producers: animated test pattern, still image (also backs the
//  QR source), and looped video file playback.
//

import AVFoundation
import CoreVideo
import UIKit

/// Drives `tick()` at a fixed rate off a display link.
class PinholeTimedProducer: NSObject, PinholeFrameProducer {
    var onFrame: ((CVPixelBuffer, Double) -> Void)?

    let size: CGSize
    let fps: Int
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0

    init(size: CGSize, fps: Int) {
        self.size = size
        self.fps = fps
    }

    func start() {
        guard displayLink == nil else { return }
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFramesPerSecond = fps
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step() {
        let elapsed = CACurrentMediaTime() - startTime
        if let buffer = frame(at: elapsed) {
            onFrame?(buffer, elapsed)
        }
    }

    /// Subclass hook.
    func frame(at time: Double) -> CVPixelBuffer? { nil }
}

final class PinholeStillProducer: PinholeTimedProducer {
    private var cached: CVPixelBuffer?
    private let image: UIImage

    init(image: UIImage, size: CGSize, fps: Int) {
        self.image = image
        super.init(size: size, fps: fps)
    }

    override func frame(at time: Double) -> CVPixelBuffer? {
        if cached == nil {
            cached = PinholePixelBuffer.buffer(from: image, size: size)
        }
        return cached
    }
}

final class PinholeTestPatternProducer: PinholeTimedProducer {
    private var frameCount = 0

    private static let bars: [UIColor] = [
        .white, .yellow, .cyan, .green, .magenta, .red, .blue, .darkGray
    ]

    override func frame(at time: Double) -> CVPixelBuffer? {
        guard let buffer = PinholePixelBuffer.make(width: Int(size.width), height: Int(size.height)) else {
            return nil
        }
        frameCount += 1
        let count = frameCount

        PinholePixelBuffer.draw(into: buffer) { context, canvas in
            let barWidth = canvas.width / CGFloat(Self.bars.count)
            for (index, color) in Self.bars.enumerated() {
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: CGFloat(index) * barWidth, y: 0, width: barWidth, height: canvas.height))
            }

            // Sweep proves the stream is live rather than a frozen still.
            let sweepX = CGFloat(time.truncatingRemainder(dividingBy: 3) / 3) * canvas.width
            context.setFillColor(UIColor.black.withAlphaComponent(0.65).cgColor)
            context.fill(CGRect(x: sweepX, y: 0, width: 8, height: canvas.height))

            UIGraphicsPushContext(context)
            let text = String(format: "Pinhole  frame %d  %.1fs", count, time)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: canvas.height * 0.06, weight: .bold),
                .foregroundColor: UIColor.black,
                .backgroundColor: UIColor.white
            ]
            context.translateBy(x: 0, y: canvas.height)
            context.scaleBy(x: 1, y: -1)
            text.draw(at: CGPoint(x: 16, y: canvas.height * 0.82), withAttributes: attributes)
            UIGraphicsPopContext()
        }
        return buffer
    }
}

final class PinholeVideoProducer: NSObject, PinholeFrameProducer {
    var onFrame: ((CVPixelBuffer, Double) -> Void)?

    private let url: URL
    private let size: CGSize
    private let fps: Int
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0

    init(url: URL, size: CGSize, fps: Int) {
        self.url = url
        self.size = size
        self.fps = fps
    }

    func start() {
        guard displayLink == nil else { return }
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        self.output = output

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(
            self, selector: #selector(loop), name: .AVPlayerItemDidPlayToEndTime, object: item)
        player.play()
        self.player = player

        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFramesPerSecond = fps
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        displayLink?.invalidate()
        displayLink = nil
        player?.pause()
        player = nil
        output = nil
    }

    @objc private func loop() {
        player?.seek(to: .zero)
        player?.play()
    }

    @objc private func step() {
        guard let output, let player else { return }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        else { return }
        _ = player
        onFrame?(buffer, CACurrentMediaTime() - startTime)
    }
}
