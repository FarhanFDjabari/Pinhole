//
//  PinholePreviewView.swift
//  Stand-in for a view hosting AVCaptureVideoPreviewLayer.
//

import AVFoundation
import UIKit

@MainActor
public final class PinholePreviewView: UIView {

    public override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private weak var session: PinholeSession?
    private var observerToken: UUID?

    /// Matches AVCaptureVideoPreviewLayer.videoGravity semantics.
    public var videoGravity: AVLayerVideoGravity = .resizeAspectFill {
        didSet { displayLayer.videoGravity = videoGravity }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = videoGravity
        backgroundColor = .black
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        displayLayer.videoGravity = videoGravity
        backgroundColor = .black
    }

    deinit {
        if let observerToken, let session {
            MainActor.assumeIsolated { session.removeFrameObserver(observerToken) }
        }
    }

    public func attach(to session: PinholeSession) {
        detach()
        self.session = session
        // PinholeSession already delivers on the main actor.
        observerToken = session.addFrameObserver { [weak self] sampleBuffer in
            self?.enqueue(sampleBuffer)
        }
    }

    public func detach() {
        if let observerToken { session?.removeFrameObserver(observerToken) }
        observerToken = nil
        session = nil
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sampleBuffer)
    }
}
