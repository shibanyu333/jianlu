import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import JianLuCore
@preconcurrency import ScreenCaptureKit
import SwiftUI

@MainActor
final class OverlayService: ObservableObject {
    @Published var cameraFrame: NormalizedRect = .defaultCameraFrame
    @Published var cameraShape: CameraFrameShape = .circle
    @Published var cameraVisible = true
    @Published var selectedTool: AnnotationTool?
    @Published var zoomMagnification: Double = 1.8
    @Published var zoomClickModeEnabled = false
    @Published var isTransientZoomActive = false
    @Published var currentZoomFocus = NormalizedPoint(x: 0.5, y: 0.5)
    @Published var zoomPreviewImage: CGImage?
    @Published var annotations: [AnnotationEvent] = []
    @Published var currentStrokePoints: [StrokePoint] = []
    @Published var isPaused = false
    @Published var recordingRegion: RecordingRegion?

    private(set) var events: [EffectEvent] = []
    private var recordingStartedAt: Date?
    private var overlayWindow: OverlayWindowController?
    private var controlBarWindow: RecordingControlBarWindowController?
    private var onStop: (() -> Void)?
    private var onTogglePause: (() -> Void)?
    private var zoomPreviewTimer: Timer?
    private var isCapturingZoomPreview = false
    private var lastRecordedZoomFocus = NormalizedPoint(x: 0.5, y: 0.5)
    private var lastZoomFocusRecordTime: TimeInterval = 0

    var currentRecordingTime: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    func beginRecording(
        cameraSession: AVCaptureSession,
        cameraEnabled: Bool,
        recordingRegion: RecordingRegion?,
        onStop: @escaping () -> Void,
        onTogglePause: @escaping () -> Void
    ) {
        recordingStartedAt = Date()
        cameraVisible = cameraEnabled
        isPaused = false
        selectedTool = nil
        zoomMagnification = max(1.2, zoomMagnification)
        zoomClickModeEnabled = false
        isTransientZoomActive = false
        currentZoomFocus = NormalizedPoint(x: 0.5, y: 0.5)
        zoomPreviewImage = nil
        stopZoomPreviewTimer()
        self.recordingRegion = recordingRegion
        self.onStop = onStop
        self.onTogglePause = onTogglePause
        annotations = []
        currentStrokePoints = []
        events = []
        recordCameraLayout()
        show(cameraSession: cameraSession)
    }

    func endRecording() {
        recordingStartedAt = nil
        isPaused = false
        zoomClickModeEnabled = false
        isTransientZoomActive = false
        zoomPreviewImage = nil
        stopZoomPreviewTimer()
        recordingRegion = nil
        onStop = nil
        onTogglePause = nil
        hide()
    }

    func show(cameraSession: AVCaptureSession) {
        if overlayWindow == nil {
            overlayWindow = OverlayWindowController(overlayService: self, cameraSession: cameraSession)
        }
        if controlBarWindow == nil {
            controlBarWindow = RecordingControlBarWindowController(overlayService: self)
        }
        overlayWindow?.show()
        controlBarWindow?.show()
    }

    func hide() {
        overlayWindow?.hide()
        controlBarWindow?.hide()
        overlayWindow = nil
        controlBarWindow = nil
    }

    func toggleCameraVisibility() {
        cameraVisible.toggle()
        recordCameraLayout()
    }

    func toggleCameraShape() {
        cameraShape = cameraShape == .circle ? .square : .circle
        recordCameraLayout()
    }

    func setPaused(_ isPaused: Bool) {
        self.isPaused = isPaused
    }

    func requestStop() {
        onStop?()
    }

    func requestTogglePause() {
        onTogglePause?()
    }

    func updateCameraFrame(_ frame: NormalizedRect) {
        cameraFrame = clamp(frame)
    }

    func finishCameraFrameChange() {
        recordCameraLayout()
    }

    func adjustZoom(by delta: Double) {
        zoomMagnification = min(3, max(1.2, zoomMagnification + delta))
    }

    func toggleClickZoomMode() {
        zoomClickModeEnabled.toggle()
        if !zoomClickModeEnabled {
            endTransientZoom()
        }
    }

    func beginHoldZoom() {
        beginTransientZoom()
    }

    func endHoldZoom() {
        endTransientZoom()
    }

    func beginClickZoom() {
        guard zoomClickModeEnabled else { return }
        beginTransientZoom()
    }

    func endClickZoom() {
        guard zoomClickModeEnabled else { return }
        endTransientZoom()
    }

    private func beginTransientZoom() {
        guard recordingStartedAt != nil, !isTransientZoomActive else { return }
        isTransientZoomActive = true
        let focus = normalizedMouseFocus()
        currentZoomFocus = focus
        lastRecordedZoomFocus = focus
        lastZoomFocusRecordTime = currentRecordingTime
        appendZoomEvent(magnification: zoomMagnification, focus: focus)
        refreshZoomPreview()
        startZoomPreviewTimer()
    }

    private func endTransientZoom() {
        guard recordingStartedAt != nil, isTransientZoomActive else { return }
        isTransientZoomActive = false
        stopZoomPreviewTimer()
        let focus = normalizedMouseFocus()
        currentZoomFocus = focus
        zoomPreviewImage = nil
        appendZoomEvent(magnification: 1, focus: focus)
    }

    func selectTool(_ tool: AnnotationTool?) {
        selectedTool = selectedTool == tool ? nil : tool
    }

    func undoLastAnnotation() {
        guard let removed = annotations.popLast() else { return }
        events.removeAll { event in
            if case .annotation(let annotation) = event {
                return annotation.id == removed.id
            }
            return false
        }
    }

    func clearAllAnnotations() {
        annotations = []
        currentStrokePoints = []
        events.removeAll { event in
            if case .annotation = event {
                return true
            }
            return false
        }
    }

    func beginStroke(at point: NormalizedPoint) {
        guard selectedTool != nil else { return }
        currentStrokePoints = [StrokePoint(time: currentRecordingTime, point: point)]
    }

    func appendStrokePoint(_ point: NormalizedPoint) {
        guard selectedTool != nil, !currentStrokePoints.isEmpty else { return }
        currentStrokePoints.append(StrokePoint(time: currentRecordingTime, point: point))
    }

    func finishStroke() {
        guard let selectedTool, currentStrokePoints.count >= 2 else {
            currentStrokePoints = []
            return
        }

        let event = AnnotationEvent(
            time: currentStrokePoints.first?.time ?? currentRecordingTime,
            tool: selectedTool,
            points: currentStrokePoints,
            colorHex: selectedTool == .highlight ? "#FFD43B" : "#FF3B30",
            lineWidth: selectedTool == .highlight ? 18 : 5
        )
        annotations.append(event)
        events.append(.annotation(event))
        currentStrokePoints = []
    }

    private func recordCameraLayout() {
        let event = CameraLayoutEvent(
            time: currentRecordingTime,
            frame: cameraFrame,
            shape: cameraShape,
            isVisible: cameraVisible
        )
        events.append(.cameraLayout(event))
    }

    private func appendZoomEvent(magnification: Double, focus: NormalizedPoint) {
        events.append(
            .zoom(
                ZoomEvent(
                    time: currentRecordingTime,
                    magnification: magnification,
                    focus: focus
                )
            )
        )
    }

    private func startZoomPreviewTimer() {
        stopZoomPreviewTimer()
        let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshZoomPreview()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        zoomPreviewTimer = timer
    }

    private func stopZoomPreviewTimer() {
        zoomPreviewTimer?.invalidate()
        zoomPreviewTimer = nil
    }

    private func refreshZoomPreview() {
        guard recordingStartedAt != nil, isTransientZoomActive else {
            zoomPreviewImage = nil
            return
        }

        let focus = normalizedMouseFocus()
        currentZoomFocus = focus
        requestZoomPreviewImage()

        let elapsed = currentRecordingTime - lastZoomFocusRecordTime
        if elapsed >= 0.14, focus.distance(to: lastRecordedZoomFocus) > 0.015 {
            appendZoomEvent(magnification: zoomMagnification, focus: focus)
            lastRecordedZoomFocus = focus
            lastZoomFocusRecordTime = currentRecordingTime
        }
    }

    private func requestZoomPreviewImage() {
        guard !isCapturingZoomPreview, let rect = zoomPreviewSourceRect() else { return }
        guard #available(macOS 15.2, *) else {
            zoomPreviewImage = nil
            return
        }

        isCapturingZoomPreview = true
        SCScreenshotManager.captureImage(in: rect) { [weak self] image, _ in
            Task { @MainActor [weak self] in
                self?.isCapturingZoomPreview = false
                guard self?.isTransientZoomActive == true else { return }
                self?.zoomPreviewImage = image
            }
        }
    }

    private func zoomPreviewSourceRect() -> CGRect? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            return nil
        }

        let previewSize = CGSize(width: 260, height: 180)
        let width = min(screen.frame.width, max(60, previewSize.width / max(1.2, CGFloat(zoomMagnification))))
        let height = min(screen.frame.height, max(48, previewSize.height / max(1.2, CGFloat(zoomMagnification))))
        let mouseX = mouse.x - screen.frame.minX
        let mouseYFromTop = screen.frame.maxY - mouse.y
        return CGRect(
            x: screen.frame.minX + min(max(0, mouseX - width / 2), max(0, screen.frame.width - width)),
            y: screen.frame.minY + min(max(0, mouseYFromTop - height / 2), max(0, screen.frame.height - height)),
            width: width,
            height: height
        )
    }

    private func clamp(_ frame: NormalizedRect) -> NormalizedRect {
        let minSize = 0.08
        let maxSize = 0.45
        let width = min(maxSize, max(minSize, frame.width))
        let height = min(maxSize, max(minSize, frame.height))
        return NormalizedRect(
            x: min(max(0, frame.x), 1 - width),
            y: min(max(0, frame.y), 1 - height),
            width: width,
            height: height
        )
    }

    private func normalizedMouseFocus() -> NormalizedPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let capture = recordingRegion?.isUsable == true
            ? CGRect(
                x: recordingRegion?.x ?? 0,
                y: recordingRegion?.y ?? 0,
                width: recordingRegion?.width ?? screenFrame.width,
                height: recordingRegion?.height ?? screenFrame.height
            )
            : CGRect(origin: .zero, size: screenFrame.size)

        let xInScreen = mouse.x - screenFrame.minX
        let yFromTop = screenFrame.maxY - mouse.y
        return NormalizedPoint(
            x: min(max(0, (xInScreen - capture.minX) / max(1, capture.width)), 1),
            y: min(max(0, (yFromTop - capture.minY) / max(1, capture.height)), 1)
        )
    }
}

private extension NormalizedPoint {
    func distance(to other: NormalizedPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}
