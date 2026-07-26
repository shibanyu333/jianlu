import AppKit
import JianLuCore
import SwiftUI

@MainActor
final class RecordingControlBarWindowController {
    private let panel: NSPanel

    init(overlayService: OverlayService) {
        let screenFrame = Self.screenFrame(for: overlayService.recordingRegion)
        let rect = Self.controlBarFrame(in: screenFrame)

        panel = ControlBarPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.title = "录制控制栏"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.contentView = NSHostingView(
            rootView: RecordingControlBarView(
                overlay: overlayService,
                onDragBy: { [weak self] translation in
                    self?.movePanel(by: translation)
                }
            )
        )
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// The control bar's on-screen frame, used to keep clicks on it from triggering
    /// click-to-zoom in the recording overlay.
    var windowFrame: CGRect? {
        panel.isVisible ? panel.frame : nil
    }

    private func movePanel(by translation: CGSize) {
        guard let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x += translation.width
        frame.origin.y -= translation.height
        frame.origin.x = min(max(screenFrame.minX + 12, frame.origin.x), screenFrame.maxX - frame.width - 12)
        frame.origin.y = min(max(screenFrame.minY + 12, frame.origin.y), screenFrame.maxY - frame.height - 12)
        panel.setFrame(frame, display: true)
    }

    private static func controlBarFrame(in screenFrame: NSRect) -> NSRect {
        let horizontalInset: CGFloat = 12
        let topInset: CGFloat = 58
        let height: CGFloat = 58
        let availableWidth = max(1, screenFrame.width - horizontalInset * 2)
        let width = min(780, availableWidth)
        let edgeInset = min(horizontalInset, max(0, (screenFrame.width - width) / 2))
        let x = min(
            max(screenFrame.minX + edgeInset, screenFrame.midX - width / 2),
            screenFrame.maxX - width - edgeInset
        )
        let y = min(
            max(screenFrame.minY + edgeInset, screenFrame.maxY - height - topInset),
            screenFrame.maxY - height - edgeInset
        )
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func screenFrame(for recordingRegion: RecordingRegion?) -> NSRect {
        guard let recordingRegion,
              let screen = NSScreen.screens.first(where: { $0.displayID == recordingRegion.displayID }) else {
            return NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        }
        return screen.frame
    }
}

private extension NSScreen {
    var displayID: UInt32 {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    }
}

private final class ControlBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
