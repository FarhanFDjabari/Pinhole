//
//  Feeds.swift
//  Part of pinholed — see main.swift.
//

import AppKit
import AVFoundation
import CoreImage
import Foundation
import Network

// MARK: - Sources

let ciContext = CIContext()

func jpeg(from ciImage: CIImage, size: CGSize, quality: Double) -> Data? {
    let scaleX = size.width / ciImage.extent.width
    let scaleY = size.height / ciImage.extent.height
    let scale = max(scaleX, scaleY)
    let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let cropRect = CGRect(
        x: scaled.extent.midX - size.width / 2,
        y: scaled.extent.midY - size.height / 2,
        width: size.width, height: size.height)
    let cropped = scaled.cropped(to: cropRect).transformed(
        by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
    return ciContext.jpegRepresentation(
        of: cropped,
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
}

final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let options: Options
    private let onFrame: (Data) -> Void
    private let start = Date()

    init(options: Options, onFrame: @escaping (Data) -> Void) throws {
        self.options = options
        self.onFrame = onFrame
        super.init()

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified)
        let device: AVCaptureDevice?
        if let name = options.deviceName {
            device = discovery.devices.first { $0.localizedName.localizedCaseInsensitiveContains(name) }
        } else {
            device = discovery.devices.first
        }
        guard let device else {
            throw NSError(domain: "pinholed", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no video capture device (try --list, or --file to stream a video)"])
        }
        print("capturing: \(device.localizedName)")

        session.beginConfiguration()
        session.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "pinholed", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot add camera input"])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "pinholed.capture"))
        guard session.canAddOutput(output) else {
            throw NSError(domain: "pinholed", code: 4, userInfo: [NSLocalizedDescriptionKey: "cannot add video output"])
        }
        session.addOutput(output)
        session.commitConfiguration()
    }

    func run() { session.startRunning() }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: options.width, height: options.height)
        guard let data = jpeg(from: CIImage(cvPixelBuffer: imageBuffer), size: size, quality: options.quality) else {
            return
        }
        onFrame(PinholeWire.encode(jpeg: data, width: options.width, height: options.height,
                                  timestamp: Date().timeIntervalSince(start)))
    }
}

final class FileSource {
    private let options: Options
    private let onFrame: (Data) -> Void
    private let url: URL
    private let start = Date()
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var timer: DispatchSourceTimer?

    init(url: URL, options: Options, onFrame: @escaping (Data) -> Void) {
        self.url = url
        self.options = options
        self.onFrame = onFrame
    }

    func run() {
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        self.output = output

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                player.seek(to: .zero)
                player.play()
            }
        player.play()
        self.player = player
        print("streaming file: \(url.lastPathComponent)")

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pinholed.file"))
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(options.fps))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard let output else { return }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        else { return }
        let size = CGSize(width: options.width, height: options.height)
        guard let data = jpeg(from: CIImage(cvPixelBuffer: buffer), size: size, quality: options.quality) else {
            return
        }
        onFrame(PinholeWire.encode(jpeg: data, width: options.width, height: options.height,
                                  timestamp: Date().timeIntervalSince(start)))
    }
}

/// A still, re-sent at the frame rate so a client that joins late still gets a
/// picture. Encoded once — the bytes never change.
final class StillSource {
    private let frame: Data
    private let options: Options
    private let onFrame: (Data) -> Void
    private let start = Date()
    private var timer: DispatchSourceTimer?

    init(frame: Data, options: Options, onFrame: @escaping (Data) -> Void) {
        self.frame = frame
        self.options = options
        self.onFrame = onFrame
    }

    static func image(at url: URL, options: Options, onFrame: @escaping (Data) -> Void) throws -> StillSource {
        guard let source = CIImage(contentsOf: url) else {
            throw NSError(domain: "pinholed", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "cannot read image at \(url.path)"])
        }
        let size = CGSize(width: options.width, height: options.height)
        guard let frame = jpeg(from: source, size: size, quality: options.quality) else {
            throw NSError(domain: "pinholed", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "cannot encode image at \(url.path)"])
        }
        print("streaming image: \(url.lastPathComponent)")
        return StillSource(frame: frame, options: options, onFrame: onFrame)
    }

    func run() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pinholed.still"))
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(options.fps))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.onFrame(PinholeWire.encode(jpeg: self.frame, width: self.options.width,
                                           height: self.options.height,
                                           timestamp: Date().timeIntervalSince(self.start)))
        }
        timer.resume()
        self.timer = timer
    }
}

/// Animated colour bars with a sweep and a frame counter — the zero-setup
/// source. Ports SimulatorCamera's test pattern, which lived inside its
/// CMIOExtension.
final class PatternSource {
    private let options: Options
    private let onFrame: (Data) -> Void
    private let start = Date()
    private var timer: DispatchSourceTimer?
    private var frames = 0

    private static let bars: [CGColor] = [
        CGColor(gray: 1, alpha: 1),
        CGColor(red: 1, green: 1, blue: 0, alpha: 1),
        CGColor(red: 0, green: 1, blue: 1, alpha: 1),
        CGColor(red: 0, green: 1, blue: 0, alpha: 1),
        CGColor(red: 1, green: 0, blue: 1, alpha: 1),
        CGColor(red: 1, green: 0, blue: 0, alpha: 1),
        CGColor(red: 0, green: 0, blue: 1, alpha: 1),
        CGColor(gray: 0.3, alpha: 1),
    ]

    init(options: Options, onFrame: @escaping (Data) -> Void) {
        self.options = options
        self.onFrame = onFrame
    }

    func run() {
        print("streaming test pattern")
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pinholed.pattern"))
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(options.fps))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let width = options.width
        let height = options.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        frames += 1
        let elapsed = Date().timeIntervalSince(start)

        let barWidth = CGFloat(width) / CGFloat(Self.bars.count)
        for (index, color) in Self.bars.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: CGFloat(index) * barWidth, y: 0, width: barWidth, height: CGFloat(height)))
        }

        let sweepX = CGFloat(elapsed.truncatingRemainder(dividingBy: 3) / 3) * CGFloat(width)
        context.setFillColor(CGColor(gray: 0, alpha: 0.65))
        context.fill(CGRect(x: sweepX, y: 0, width: 8, height: CGFloat(height)))

        let label = String(format: "Pinhole  frame %d  %.1fs", frames, elapsed)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: CGFloat(height) * 0.06, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 8, y: CGFloat(height) * 0.10, width: CGFloat(width) * 0.62, height: CGFloat(height) * 0.09))
        context.textPosition = CGPoint(x: 16, y: CGFloat(height) * 0.12)
        CTLineDraw(line, context)

        guard let image = context.makeImage(),
              let data = jpeg(from: CIImage(cgImage: image),
                              size: CGSize(width: width, height: height),
                              quality: options.quality)
        else { return }

        onFrame(PinholeWire.encode(jpeg: data, width: width, height: height, timestamp: elapsed))
    }
}

/// A generated QR code, centred on white. Ports SimulatorCamera's QRSource —
/// scanning without holding a phone up to a screen.
enum QRFrame {
    static func image(payload: String, size: CGSize) -> CIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(payload.data(using: .utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }

        let side = min(size.width, size.height) * 0.7
        let scale = side / code.extent.width
        let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centred = scaled.transformed(by: CGAffineTransform(
            translationX: (size.width - side) / 2,
            y: (size.height - side) / 2))

        let white = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
        return centred.composited(over: white)
    }
}
