//
//  PinholeNetworkProducer.swift
//  Reads PinholeWire frames from pinholed running on the host Mac. The Simulator
//  shares the host's network stack, so 127.0.0.1 is the Mac itself.
//
//  Transport lives in PinholeFrameStream; this is the UIKit half, decoding JPEG
//  payloads into pixel buffers.
//

// UIKit-only. Gated so the package still builds on macOS, where the
// wire and framing types are unit-tested without a simulator.
#if canImport(UIKit)

import CoreVideo
import Foundation
import UIKit

final class PinholeNetworkProducer: PinholeFrameProducer {
    var onFrame: ((CVPixelBuffer, Double) -> Void)? {
        get { stream.onFrame }
        set { stream.onFrame = newValue }
    }

    private let stream: PinholeFrameStream

    init(host: String, port: UInt16) {
        stream = PinholeFrameStream(host: host, port: port) { payload, width, height in
            guard let image = UIImage(data: payload) else { return nil }
            return PinholePixelBuffer.buffer(
                from: image,
                size: CGSize(width: width, height: height))
        }
    }

    func start() { stream.start() }
    func stop() { stream.stop() }
}

#endif
