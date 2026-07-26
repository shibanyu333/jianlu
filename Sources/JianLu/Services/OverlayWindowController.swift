import AppKit
import Combine
import JianLuCore
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let panel: NSPanel
    private weak var overlayService: OverlayService?
    private var cancellables: Set<AnyCancellable> = []
    private var pointerTimer: Timer?
    private var isCapturingMouseInteraction = false
    private var isClickZoomPollingActive = false
    private var lastPressedMouseButtons = 0

    init(overlayService: OverlayService, cameraService: CameraCaptureService) {
        self.overlayService = overlayService
        let screenFrame = Self.screenFrame(for: overlayService.recordingRegion)
        panel = KeyableRecordingPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.title = "录制标注层"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = NSHostingView(
            rootView: RecordingOverlayView(overlay: overlayService, cameraService: cameraService)
        )

        let refreshPointerCapture: () -> Void = { [weak self] in
            self?.refreshPointerCapture()
        }

        overlayService.$selectedTool
            .receive(on: RunLoop.main)
            .sink { _ in refreshPointerCapture() }
            .store(in: &cancellables)
        overlayService.$cameraFrame
            .receive(on: RunLoop.main)
            .sink { _ in refreshPointerCapture() }
            .store(in: &cancellables)
        overlayService.$cameraVisible
            .receive(on: RunLoop.main)
            .sink { _ in refreshPointerCapture() }
            .store(in: &cancellables)
        overlayService.$recordingRegion
            .receive(on: RunLoop.main)
            .sink { _ in refreshPointerCapture() }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPointerCapture()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    func show() {
        panel.orderFrontRegardless()
        // Seed the button state so a button that happened to be held while the
        // overlay appeared isn't read as a fresh click-to-zoom press.
        lastPressedMouseButtons = NSEvent.pressedMouseButtons
        refreshPointerCapture()
    }

    func hide() {
        if isClickZoomPollingActive {
            overlayService?.endClickZoom()
            isClickZoomPollingActive = false
        }
        pointerTimer?.invalidate()
        pointerTimer = nil
        panel.orderOut(nil)
    }

    private func refreshPointerCapture() {
        guard panel.isVisible else { return }

        let pressedMouseButtons = NSEvent.pressedMouseButtons
        let leftMouseIsDown = pressedMouseButtons & 1 == 1
        if !leftMouseIsDown {
            isCapturingMouseInteraction = false
        }

        let cursorPoint = NSEvent.mouseLocation
        // The configured button runs first: enabling its zoom clears the toolbar
        // click-zoom mode, and the click-zoom pass below must see that new state.
        handleZoomButtonPolling(pressedMouseButtons: pressedMouseButtons, cursorPoint: cursorPoint)
        lastPressedMouseButtons = pressedMouseButtons
        handleClickZoomPolling(leftMouseIsDown: leftMouseIsDown, cursorPoint: cursorPoint)
        let shouldCapture = shouldCaptureMouse(at: cursorPoint)
        if shouldCapture && leftMouseIsDown {
            isCapturingMouseInteraction = true
        }

        panel.ignoresMouseEvents = !(shouldCapture || isCapturingMouseInteraction)
    }

    /// Toggle the zoom on the press edge of the user's configured mouse button
    /// (default 鼠标中键). Only the button *state* is polled, so the click still goes
    /// through to whatever app is under the cursor — 简录 never swallows it.
    private func handleZoomButtonPolling(pressedMouseButtons: Int, cursorPoint: CGPoint) {
        guard let overlayService else { return }

        let mask = overlayService.zoomMouseButton.pressedButtonMask
        guard mask != 0 else { return }
        let isDown = pressedMouseButtons & mask != 0
        let wasDown = lastPressedMouseButtons & mask != 0
        guard isDown, !wasDown, !overlayService.isPaused else { return }
        // A 鼠标左键 assignment must not hijack annotation drawing: while a tool is
        // active the left click belongs to the annotation canvas.
        if overlayService.zoomMouseButton == .left, overlayService.selectedTool != nil { return }

        let captureRect = captureRectInScreenCoordinates()
        guard captureRect.contains(cursorPoint),
              !isOverOwnInteractiveUI(at: cursorPoint, captureRect: captureRect) else {
            return
        }
        overlayService.toggleMouseButtonZoom()
    }

    private func handleClickZoomPolling(leftMouseIsDown: Bool, cursorPoint: CGPoint) {
        guard let overlayService else { return }

        let captureRect = captureRectInScreenCoordinates()
        let shouldZoom = (overlayService.zoomClickModeEnabled || overlayService.zoomShortcutActive)
            && !overlayService.isPaused
            && leftMouseIsDown
            && captureRect.contains(cursorPoint)
            && !isOverOwnInteractiveUI(at: cursorPoint, captureRect: captureRect)
        guard shouldZoom != isClickZoomPollingActive else { return }

        isClickZoomPollingActive = shouldZoom
        if shouldZoom {
            overlayService.beginClickZoom()
        } else {
            overlayService.endClickZoom()
        }
    }

    /// Whether the click lands on the app's own interactive overlay chrome — the
    /// camera bubble (which the user drags/resizes) or the floating control bar.
    /// Clicks there must not also fire click-to-zoom, which previously caused the
    /// recording to lurch toward the cursor whenever the presenter moved the bubble
    /// or pressed a control-bar button.
    private func isOverOwnInteractiveUI(at screenPoint: CGPoint, captureRect: CGRect) -> Bool {
        guard let overlayService else { return false }

        if overlayService.cameraVisible,
           cameraRectInScreenCoordinates(captureRect: captureRect).contains(screenPoint) {
            return true
        }
        if let controlBarFrame = overlayService.controlBarScreenFrame(),
           controlBarFrame.contains(screenPoint) {
            return true
        }
        return false
    }

    private func shouldCaptureMouse(at screenPoint: CGPoint) -> Bool {
        guard let overlayService else { return false }

        let captureRect = captureRectInScreenCoordinates()
        if !overlayService.isPaused, overlayService.selectedTool != nil, captureRect.contains(screenPoint) {
            return true
        }

        if overlayService.cameraVisible, cameraRectInScreenCoordinates(captureRect: captureRect).contains(screenPoint) {
            return true
        }

        return false
    }

    private func captureRectInScreenCoordinates() -> CGRect {
        let contentSize = panel.frame.size
        let contentRect = overlayService?.captureRect(in: contentSize) ?? CGRect(origin: .zero, size: contentSize)
        return CGRect(
            x: panel.frame.minX + contentRect.minX,
            y: panel.frame.maxY - contentRect.maxY,
            width: contentRect.width,
            height: contentRect.height
        )
    }

    private func cameraRectInScreenCoordinates(captureRect: CGRect) -> CGRect {
        guard let overlayService else { return .zero }

        // Same shared geometry the overlay draws the bubble with, so the draggable /
        // zoom-excluded area lines up with the bubble the presenter actually sees.
        // Deriving it from the raw normalized frame made the hit rect shorter than the
        // drawn bubble on wide regions, so the lower part of the avatar could not be
        // dragged and clicking it fired click-to-zoom instead.
        let bubble = overlayService.cameraFrame.cameraBubbleRect(
            in: captureRect.size,
            shape: overlayService.cameraShape
        )
        return CGRect(
            x: captureRect.minX + bubble.minX,
            y: captureRect.maxY - bubble.maxY,
            width: bubble.width,
            height: bubble.height
        ).insetBy(dx: -8, dy: -8)
    }

    private static func screenFrame(for recordingRegion: RecordingRegion?) -> NSRect {
        guard let recordingRegion,
              let screen = NSScreen.screens.first(where: { $0.displayID == recordingRegion.displayID }) else {
            return NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        }
        return screen.frame
    }
}

private final class KeyableRecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension NSScreen {
    var displayID: UInt32 {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    }
}
