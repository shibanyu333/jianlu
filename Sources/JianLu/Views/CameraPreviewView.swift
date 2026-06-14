import AVFoundation
import AppKit
import SwiftUI

struct CameraPreviewView: View {
    let session: AVCaptureSession
    let processedImage: CGImage?

    var body: some View {
        ZStack {
            CameraPreviewLayerView(session: session)

            if let processedImage {
                Image(decorative: processedImage, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .clipped()
    }
}

private struct CameraPreviewLayerView: NSViewRepresentable {
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
