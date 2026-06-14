import AppKit
import JianLuCore
import SwiftUI

@MainActor
final class RecordingControlBarWindowController {
    private let panel: NSPanel

    init(overlayService: OverlayService) {
        let screenFrame = Self.screenFrame(for: overlayService.recordingRegion)
        let width: CGFloat = min(780, max(560, screenFrame.width - 80))
        let height: CGFloat = 58
        let rect = NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height - 58,
            width: width,
            height: height
        )

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

    private func movePanel(by translation: CGSize) {
        guard let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x += translation.width
        frame.origin.y -= translation.height
        frame.origin.x = min(max(screenFrame.minX + 12, frame.origin.x), screenFrame.maxX - frame.width - 12)
        frame.origin.y = min(max(screenFrame.minY + 12, frame.origin.y), screenFrame.maxY - frame.height - 12)
        panel.setFrame(frame, display: true)
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
