import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let panel: NSPanel

    init(overlayService: OverlayService, cameraSession: AVCaptureSession) {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.contentView = NSHostingView(
            rootView: RecordingOverlayView(overlay: overlayService, cameraSession: cameraSession)
        )
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
