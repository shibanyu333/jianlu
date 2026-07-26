import AVFoundation
import AppKit
import SwiftUI

struct CameraPreviewView: View {
    let session: AVCaptureSession
    let processedImage: CGImage?

    var body: some View {
        // `Color.clear` owns the layout and the camera images ride along as overlays.
        // An aspect-FILLED 16:9 camera frame is wider than the bubble box, and a plain
        // ZStack adopts its largest child's size — that made the whole view 16:9, so the
        // "圆形" clip shape was drawn as a wide ellipse that spilled outside the square
        // bubble, while the export still masked a true circle. Overlays never resize
        // their base, so the bubble now keeps exactly the box
        // `NormalizedRect.cameraBubbleRect(in:shape:)` hands it.
        Color.clear
            .overlay {
                CameraPreviewLayerView(session: session)
            }
            .overlay {
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
        Self.lockMirroring(on: view.previewLayer)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.previewLayer.session = session
        Self.lockMirroring(on: nsView.previewLayer)
    }

    /// Force the same explicit mirroring the recording output uses
    /// (`isVideoMirrored = true`). Otherwise the preview relies on the layer's
    /// automatic front-camera mirroring, which disagrees with the recorded/exported
    /// frames for external or non-front cameras.
    private static func lockMirroring(on layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
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
