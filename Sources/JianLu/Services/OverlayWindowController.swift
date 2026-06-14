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

        let leftMouseIsDown = NSEvent.pressedMouseButtons & 1 == 1
        if !leftMouseIsDown {
            isCapturingMouseInteraction = false
        }

        let cursorPoint = NSEvent.mouseLocation
        handleClickZoomPolling(leftMouseIsDown: leftMouseIsDown, cursorPoint: cursorPoint)
        let shouldCapture = shouldCaptureMouse(at: cursorPoint)
        if shouldCapture && leftMouseIsDown {
            isCapturingMouseInteraction = true
        }

        panel.ignoresMouseEvents = !(shouldCapture || isCapturingMouseInteraction)
    }

    private func handleClickZoomPolling(leftMouseIsDown: Bool, cursorPoint: CGPoint) {
        guard let overlayService else { return }

        let captureRect = captureRectInScreenCoordinates()
        let shouldZoom = (overlayService.zoomClickModeEnabled || overlayService.zoomShortcutActive)
            && !overlayService.isPaused
            && leftMouseIsDown
            && captureRect.contains(cursorPoint)
        guard shouldZoom != isClickZoomPollingActive else { return }

        isClickZoomPollingActive = shouldZoom
        if shouldZoom {
            overlayService.beginClickZoom()
        } else {
            overlayService.endClickZoom()
        }
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

        let frame = overlayService.cameraFrame
        return CGRect(
            x: captureRect.minX + frame.x * captureRect.width,
            y: captureRect.maxY - (frame.y + frame.height) * captureRect.height,
            width: frame.width * captureRect.width,
            height: frame.height * captureRect.height
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
