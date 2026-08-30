//
//  SimCamPixelBuffer.swift
//  CVPixelBuffer creation and drawing helpers shared by the frame producers.
//

import CoreGraphics
import CoreImage
import CoreVideo
import UIKit

enum SimCamPixelBuffer {

    static func make(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &buffer)
        return buffer
    }

    /// Draws into a locked BGRA buffer. The context keeps Core Graphics'
    /// bottom-left origin so CGImages land upright; text drawing flips
    /// locally (see SimCamTestPatternProducer).
    static func draw(into buffer: CVPixelBuffer, _ body: (CGContext, CGSize) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base, width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        body(context, CGSize(width: width, height: height))
    }

    /// Aspect-fill render of `image` into a new buffer of `size`.
    static func buffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        guard let buffer = make(width: Int(size.width), height: Int(size.height)),
              let cgImage = image.cgImage else { return nil }
        draw(into: buffer) { context, canvas in
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(origin: .zero, size: canvas))
            let scale = max(canvas.width / CGFloat(cgImage.width), canvas.height / CGFloat(cgImage.height))
            let drawSize = CGSize(width: CGFloat(cgImage.width) * scale, height: CGFloat(cgImage.height) * scale)
            context.draw(cgImage, in: CGRect(
                x: (canvas.width - drawSize.width) / 2,
                y: (canvas.height - drawSize.height) / 2,
                width: drawSize.width, height: drawSize.height))
        }
        return buffer
    }

    static func image(from buffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func qrImage(_ payload: String, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
            filter.setValue(payload.data(using: .utf8), forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            guard let output = filter.outputImage else { return }
            let side = min(size.width, size.height) * 0.7
            let scale = side / output.extent.width
            let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return }
            UIImage(cgImage: cgImage).draw(in: CGRect(
                x: (size.width - side) / 2, y: (size.height - side) / 2,
                width: side, height: side))
        }
    }
}
