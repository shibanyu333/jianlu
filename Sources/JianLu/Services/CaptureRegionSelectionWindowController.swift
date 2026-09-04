import AppKit
import JianLuCore
import SwiftUI
import UniformTypeIdentifiers

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
        // The controller owns the panel's lifetime; closing it must not also release it.
        panel.isReleasedWhenClosed = false
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

    /// Ask where the screenshot goes. Returns nil when the user cancels, and the editor
    /// is then back exactly as it was, markups and all.
    ///
    /// The overlay is a borderless, transparent, full-screen window at `.screenSaver`
    /// level, and every attempt to show a panel *over* it has failed: a sheet on it
    /// draws without its own background, and raising the panel's own level does not
    /// survive — AppKit resets it when the panel runs modal (measured: the save panel
    /// lands on level 8 while the overlay sits at level 1000). A dialog hidden behind a
    /// full-screen window while still app-modal is the worst outcome of all: it
    /// swallows every click in 简录, so 完成 and 取消 stop working too and the only way
    /// out is force-quitting. So don't compete with the overlay — take it off screen
    /// for as long as the dialog is up.
    func presentSavePanel(suggestedName: String, directory: URL?) -> URL? {
        guard let panel else { return nil }

        let savePanel = NSSavePanel()
        savePanel.title = tr("保存截图", "Save screenshot")
        savePanel.prompt = tr("保存", "Save")
        savePanel.nameFieldLabel = tr("文件名：", "Save As:")
        savePanel.nameFieldStringValue = suggestedName
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        if let directory {
            savePanel.directoryURL = directory
        }

        panel.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        let url = savePanel.runModal() == .OK ? savePanel.url : nil
        if url == nil {
            // Cancelled: the editor comes straight back. On a save it stays off screen,
            // because the caller closes the whole session anyway.
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return url
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
        // Ordering out alone leaves the panel inside `NSApp.windows`, where AppKit is
        // free to put it back on screen the next time 简录 is activated — a full-screen
        // overlay from a finished screenshot reappearing out of nowhere. Close it for
        // good, and let the current event finish before it is deallocated: `hide()`
        // runs from the editor's own buttons.
        guard let panel else {
            model = nil
            return
        }
        self.panel = nil
        model = nil
        panel.close()
        DispatchQueue.main.async {
            withExtendedLifetime(panel) {}
        }
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
