import AVFoundation
import AppKit
import SwiftUI

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.previewLayer.session = session
    }
}

final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configurePreviewLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePreviewLayer()
    }

    private func configurePreviewLayer() {
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer = previewLayer
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
