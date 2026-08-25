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
        frozenScreen: CGImage? = nil,
        onStart: @escaping (RecordingRegion) -> Void,
        onCancel: @escaping () -> Void,
        onFinish: ((CGImage) -> Void)? = nil,
        onCopy: ((CGImage) -> Void)? = nil,
        onSave: ((CGImage) -> Void)? = nil
    ) {
        hide()

        let screen = preferredScreen()
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let displayID = screen?.displayID ?? 0
        let model = CaptureRegionSelectionModel(
            displayID: displayID,
            screenSize: screenFrame.size,
            initialRegion: initialRegion?.displayID == displayID ? initialRegion : nil,
            windowCandidates: purpose == .screenshot ? windowCandidates(for: screen, screenFrame: screenFrame) : [],
            purpose: purpose,
            frozenScreen: frozenScreen,
            onStart: onStart,
            onCancel: onCancel,
            onFinish: onFinish,
            onCopy: onCopy,
            onSave: onSave
        )

        let panel = KeyablePanel(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.title = purpose.windowTitle
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.onCancel = { [weak model] in
            model?.dismissSelectionOrCancel()
        }
        panel.onDelete = { [weak model] in
            model?.deleteSelectedMarkup()
        }
        panel.onNudge = { [weak model] dx, dy in
            model?.nudgeSelectedMarkup(dx: dx, dy: dy)
        }
        panel.onConfirm = { [weak model] in
            model?.confirmDefaultAction()
        }
        panel.onMouseMoved = { [weak model] point in
            model?.updateWindowHover(at: point)
        }
        panel.contentView = NSHostingView(rootView: CaptureRegionSelectionView(model: model))

        self.model = model
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.updateWindowHover(at: panelLocalMousePoint(screenFrame: screenFrame))
    }

    func confirmSelection() {
        model?.confirmDefaultAction()
    }

    func beginCapturePhase() {
        model?.beginCapturing()
    }

    func hideForCapture() {
        panel?.orderOut(nil)
    }

    func beginEditing(image: CGImage) {
        model?.beginEditing(image: image)
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The point size of the display a region belongs to — needed to crop the frozen
    /// full-screen still (points) down to the selection (pixels).
    func pointSize(forDisplayID displayID: UInt32) -> CGSize? {
        NSScreen.screens.first { $0.displayID == displayID }?.frame.size
    }

    func preferredFullScreenRegion() -> RecordingRegion? {
        guard let screen = preferredScreen() else { return nil }
        return RecordingRegion(
            displayID: screen.displayID,
            x: 0,
            y: 0,
            width: screen.frame.width,
            height: screen.frame.height
        )
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

    private func panelLocalMousePoint(screenFrame: CGRect) -> CGPoint {
        let pointer = NSEvent.mouseLocation
        return CGPoint(
            x: pointer.x - screenFrame.minX,
            y: screenFrame.maxY - pointer.y
        )
    }

    private func windowCandidates(for screen: NSScreen?, screenFrame: CGRect) -> [CaptureWindowCandidate] {
        guard screen != nil else { return [] }
        let screenRect = CGRect(origin: .zero, size: screenFrame.size)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windows.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowID = window[kCGWindowNumber as String] as? UInt32,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != getpid(),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double,
                  let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double,
                  width >= 80,
                  height >= 60 else {
                return nil
            }

            let title = (window[kCGWindowName as String] as? String)
                ?? (window[kCGWindowOwnerName as String] as? String)
                ?? "窗口"
            let rect = CGRect(
                x: x - screenFrame.minX,
                y: y,
                width: width,
                height: height
            ).intersection(screenRect)
            guard rect.width >= 80, rect.height >= 60 else { return nil }
            return CaptureWindowCandidate(id: windowID, rect: rect, title: title)
        }
    }
}

private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?
    var onDelete: (() -> Void)?
    /// Arrow-key nudge of the selected markup, in editor points.
    var onNudge: ((CGFloat, CGFloat) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func mouseMoved(with event: NSEvent) {
        let location = event.locationInWindow
        onMouseMoved?(
            CGPoint(
                x: location.x,
                y: frame.height - location.y
            )
        )
        super.mouseMoved(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // These only reach the panel when nothing else wants them, so typing into the
        // inline text field still gets its own Delete and arrow keys.
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53:
            onCancel?()
        case 36, 76:
            onConfirm?()
        case 51, 117:
            onDelete?()
        case 123:
            onNudge?(-step, 0)
        case 124:
            onNudge?(step, 0)
        case 125:
            onNudge?(0, step)
        case 126:
            onNudge?(0, -step)
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
