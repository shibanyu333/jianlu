import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import JianLuCore
import os
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
    private var screenFrameProvider: (() -> CGImage?)?
    private var zoomPreviewTimer: Timer?
    private var zoomSnapshotInFlight = false
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
        zoomSnapshotInFlight = false
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
        zoomSnapshotInFlight = false
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
        setCameraVisibility(!cameraVisible)
    }

    func setCameraVisibility(_ isVisible: Bool) {
        guard cameraVisible != isVisible else { return }
        cameraVisible = isVisible
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

    func prewarmZoomPreview() {
        guard recordingStartedAt != nil, !isPaused else { return }
        requestZoomPreviewImage(allowsInactiveFallback: true)
        if zoomPreviewImage != nil {
            logger.info("Live zoom preview prewarmed")
        }
    }

    func toggleClickZoomMode() {
        guard !isPaused else {
            zoomClickModeEnabled = false
            endTransientZoom()
            return
        }
        zoomClickModeEnabled.toggle()
        if zoomClickModeEnabled {
            selectedTool = nil
            currentStrokePoints = []
        }
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
        guard zoomClickModeEnabled, isMouseInsideRecordingRegion() else { return }
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
        appendZoomEvent(magnification: 1, focus: focus)
        logger.info("Live zoom ended")
    }

    func selectTool(_ tool: AnnotationTool?) {
        selectedTool = selectedTool == tool ? nil : tool
        if selectedTool != nil {
            zoomClickModeEnabled = false
            endTransientZoom()
        }
    }

    func undoLastAnnotation() {
        guard !isPaused else { return }
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

    private func requestZoomPreviewImage(allowsInactiveFallback: Bool = false) {
        if let latestFrame = screenFrameProvider?() {
            zoomPreviewImage = latestFrame
            didLogMissingZoomFrame = false
            return
        }

        requestFallbackZoomSnapshot(allowsInactiveAssignment: allowsInactiveFallback)
        if zoomPreviewImage == nil, !didLogMissingZoomFrame {
            didLogMissingZoomFrame = true
            logger.warning("Live zoom has no screen frame yet")
        }
    }

    private func requestFallbackZoomSnapshot(allowsInactiveAssignment: Bool = false) {
        guard !zoomSnapshotInFlight else { return }

        zoomSnapshotInFlight = true
        let region = recordingRegion
        Task { [weak self] in
            do {
                let image = try await Self.captureFallbackZoomImage(region: region)
                guard let self else { return }
                self.zoomSnapshotInFlight = false
                guard self.recordingStartedAt != nil,
                      self.isTransientZoomActive || allowsInactiveAssignment else { return }
                self.zoomPreviewImage = image
                self.didLogMissingZoomFrame = false
            } catch {
                guard let self else { return }
                self.zoomSnapshotInFlight = false
                self.logger.warning("Fallback zoom snapshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    private static func captureFallbackZoomImage(region: RecordingRegion?) async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let display = display(in: content, matching: region) else {
            throw CaptureServiceError.noDisplay
        }

        let excludedWindows = content.windows.filter { window in
            window.owningApplication?.processID == getpid()
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let configuration = SCStreamConfiguration()
        configureFallbackSnapshot(configuration, display: display, region: region)
        configuration.showsCursor = true
        configuration.showMouseClicks = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    @MainActor
    private static func configureFallbackSnapshot(
        _ configuration: SCStreamConfiguration,
        display: SCDisplay,
        region: RecordingRegion?
    ) {
        guard let region, region.isUsable else {
            configuration.width = max(80, display.width)
            configuration.height = max(80, display.height)
            return
        }

        let displayPointSize = pointSize(for: display)
        let sourceRect = region.screenCaptureSourceRect(
            displayPointWidth: displayPointSize.width,
            displayPointHeight: displayPointSize.height
        )
        let outputSize = region.screenCaptureOutputSize(
            displayPixelWidth: Double(display.width),
            displayPixelHeight: Double(display.height),
            displayPointWidth: displayPointSize.width,
            displayPointHeight: displayPointSize.height
        )
        configuration.sourceRect = CGRect(
            x: sourceRect.minX,
            y: sourceRect.minY,
            width: sourceRect.width,
            height: sourceRect.height
        )
        configuration.width = max(80, Int(outputSize.width.rounded()))
        configuration.height = max(80, Int(outputSize.height.rounded()))
    }

    private static func display(in content: SCShareableContent, matching region: RecordingRegion?) -> SCDisplay? {
        guard let region else {
            return content.displays.first
        }
        return content.displays.first { $0.displayID == region.displayID } ?? content.displays.first
    }

    @MainActor
    private static func pointSize(for display: SCDisplay) -> CGSize {
        let screen = NSScreen.screens.first { $0.displayID == display.displayID }
        return screen?.frame.size ?? CGSize(width: display.width, height: display.height)
    }

    private func screenForCurrentCapture(mouseLocation: CGPoint) -> NSScreen? {
        if let recordingRegion,
           let screen = NSScreen.screens.first(where: { $0.displayID == recordingRegion.displayID }) {
            return screen
        }
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
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
        let screen = screenForCurrentCapture(mouseLocation: mouse)
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        return ZoomLensGeometry.normalizedFocus(
            mouseLocation: mouse,
            screenFrame: screenFrame,
            recordingRegion: recordingRegion
        )
    }

    private func isMouseInsideRecordingRegion() -> Bool {
        let mouse = NSEvent.mouseLocation
        let screen = screenForCurrentCapture(mouseLocation: mouse)
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)

        guard let recordingRegion, recordingRegion.isUsable else {
            return screenFrame.contains(mouse)
        }

        let minX = screenFrame.minX + recordingRegion.x
        let maxY = screenFrame.maxY - recordingRegion.y
        let captureRect = CGRect(
            x: minX,
            y: maxY - recordingRegion.height,
            width: recordingRegion.width,
            height: recordingRegion.height
        )
        return captureRect.contains(mouse)
    }
}

private extension NormalizedPoint {
    func distance(to other: NormalizedPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

private extension NSScreen {
    var displayID: UInt32 {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    }
}
