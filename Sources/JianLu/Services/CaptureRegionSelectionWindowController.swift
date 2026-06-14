import AppKit
import JianLuCore
import SwiftUI

@MainActor
final class CaptureRegionSelectionWindowController {
    private var panel: NSPanel?
    private var model: CaptureRegionSelectionModel?

    func show(
        initialRegion: RecordingRegion?,
        purpose: CaptureRegionSelectionPurpose = .recording,
        onStart: @escaping (RecordingRegion) -> Void,
        onCancel: @escaping () -> Void
    ) {
        hide()

        let screen = preferredScreen()
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let displayID = screen?.displayID ?? 0
        let model = CaptureRegionSelectionModel(
            displayID: displayID,
            screenSize: screenFrame.size,
            initialRegion: initialRegion?.displayID == displayID ? initialRegion : nil,
            purpose: purpose,
            onStart: onStart,
            onCancel: onCancel
        )

        let panel = KeyablePanel(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.title = "选择录制区域"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.onCancel = { [weak model] in
            model?.cancel()
        }
        panel.onConfirm = { [weak model] in
            model?.confirmSelection()
        }
        panel.contentView = NSHostingView(rootView: CaptureRegionSelectionView(model: model))

        self.model = model
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func confirmSelection() {
        model?.confirmSelection()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    private func preferredScreen() -> NSScreen? {
        let pointerLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointerLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCancel?()
        case 36, 76:
            onConfirm?()
        default:
            super.keyDown(with: event)
        }
    }
}

private extension NSScreen {
    var displayID: UInt32 {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    }
}
