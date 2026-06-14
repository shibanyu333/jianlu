import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import JianLuCore
import os
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
    private var screenFrameProvider: (() -> CGImage?)?
    private var zoomPreviewTimer: Timer?
    private var didLogMissingZoomFrame = false
    private var lastRecordedZoomFocus = NormalizedPoint(x: 0.5, y: 0.5)
    private var lastZoomFocusRecordTime: TimeInterval = 0
    private let logger = Logger(subsystem: "com.local.JianLu", category: "Zoom")

    var currentRecordingTime: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    func beginRecording(
        cameraSession: AVCaptureSession,
        cameraEnabled: Bool,
        recordingRegion: RecordingRegion?,
        screenFrameProvider: @escaping () -> CGImage?,
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
        self.screenFrameProvider = screenFrameProvider
        didLogMissingZoomFrame = false
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
        screenFrameProvider = nil
        didLogMissingZoomFrame = false
        hide()
    }

    func alignRecordingClock(to startedAt: Date) {
        recordingStartedAt = startedAt
        lastZoomFocusRecordTime = 0
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
        if isPaused {
            endTransientZoom()
            currentStrokePoints = []
        }
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
        guard !isPaused else {
            zoomClickModeEnabled = false
            endTransientZoom()
            return
        }
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
        guard recordingStartedAt != nil, !isPaused, !isTransientZoomActive else { return }
        isTransientZoomActive = true
        let focus = normalizedMouseFocus()
        currentZoomFocus = focus
        lastRecordedZoomFocus = focus
        lastZoomFocusRecordTime = currentRecordingTime
        appendZoomEvent(magnification: zoomMagnification, focus: focus)
        refreshZoomPreview()
        startZoomPreviewTimer()
        logger.info("Live zoom began")
    }

    private func endTransientZoom() {
        guard recordingStartedAt != nil, isTransientZoomActive else { return }
        isTransientZoomActive = false
        stopZoomPreviewTimer()
        let focus = normalizedMouseFocus()
        currentZoomFocus = focus
        zoomPreviewImage = nil
        appendZoomEvent(magnification: 1, focus: focus)
        logger.info("Live zoom ended")
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
        guard !isPaused else { return }
        annotations = []
        currentStrokePoints = []
        events.append(.annotationClear(AnnotationClearEvent(time: currentRecordingTime)))
    }

    func beginStroke(at point: NormalizedPoint) {
        guard selectedTool != nil, !isPaused else { return }
        currentStrokePoints = [StrokePoint(time: currentRecordingTime, point: point)]
    }

    func appendStrokePoint(_ point: NormalizedPoint) {
        guard selectedTool != nil, !isPaused, !currentStrokePoints.isEmpty else { return }
        currentStrokePoints.append(StrokePoint(time: currentRecordingTime, point: point))
    }

    func finishStroke() {
        guard !isPaused else {
            currentStrokePoints = []
            return
        }
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
        guard recordingStartedAt != nil, !isPaused, isTransientZoomActive else {
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
        zoomPreviewImage = screenFrameProvider?()
        if zoomPreviewImage == nil, !didLogMissingZoomFrame {
            didLogMissingZoomFrame = true
            logger.warning("Live zoom has no screen frame yet")
        }
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
        return ZoomLensGeometry.normalizedFocus(
            mouseLocation: mouse,
            screenFrame: screenFrame,
            recordingRegion: recordingRegion
        )
    }
}

private extension NormalizedPoint {
    func distance(to other: NormalizedPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}
