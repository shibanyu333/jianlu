import AppKit
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
    /// The magnification the overlay is currently drawing. Ramps from 1 up to
    /// `zoomMagnification` on the export's curve so the live picture and the exported
    /// video magnify the same region at the same moment.
    @Published var liveZoomDepth: Double = 1
    /// Which mouse button toggles the zoom during a recording (default 鼠标中键).
    /// Mirrored from `RecordingPreferences.zoomMouseButton`.
    @Published var zoomMouseButton: ZoomMouseButton = .middle
    @Published var zoomClickModeEnabled = false
    @Published var zoomFollowModeEnabled = false
    @Published var zoomShortcutActive = false
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
    private var onToggleClickZoomMode: (() -> Void)?
    private var onCameraLayoutChanged: ((NormalizedRect, CameraFrameShape) -> Void)?
    private var screenFrameProvider: (() -> CGImage?)?
    private var zoomPreviewTimer: Timer?
    private var zoomSnapshotInFlight = false
    private var lastFallbackSnapshotRequestTime: TimeInterval = 0
    private var didLogMissingZoomFrame = false
    private var lastRecordedZoomFocus = NormalizedPoint(x: 0.5, y: 0.5)
    private var lastZoomFocusRecordTime: TimeInterval = 0
    private var transientZoomStartedAt: TimeInterval = 0
    private var lastCameraLayoutRecordTime: TimeInterval = -1
    private let cameraLayoutRecordInterval: TimeInterval = 1.0 / 30.0
    private let liveZoomFrameInterval: TimeInterval = 1.0 / 30.0
    private let zoomFocusRecordInterval: TimeInterval = 1.0 / 30.0
    private let zoomFocusRecordDistanceThreshold: Double = 0.003
    private let fallbackZoomSnapshotInterval: TimeInterval = 0.35
    private let logger = Logger(subsystem: "com.local.JianLu", category: "Zoom")

    var currentRecordingTime: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    func beginRecording(
        cameraService: CameraCaptureService,
        cameraEnabled: Bool,
        recordingRegion: RecordingRegion?,
        screenFrameProvider: @escaping () -> CGImage?,
        onStop: @escaping () -> Void,
        onTogglePause: @escaping () -> Void,
        onToggleClickZoomMode: @escaping () -> Void,
        onCameraLayoutChanged: @escaping (NormalizedRect, CameraFrameShape) -> Void
    ) {
        recordingStartedAt = Date()
        cameraVisible = cameraEnabled
        isPaused = false
        selectedTool = nil
        zoomMagnification = max(1.2, zoomMagnification)
        zoomClickModeEnabled = false
        zoomFollowModeEnabled = false
        zoomShortcutActive = false
        isTransientZoomActive = false
        liveZoomDepth = 1
        currentZoomFocus = NormalizedPoint(x: 0.5, y: 0.5)
        zoomPreviewImage = nil
        zoomSnapshotInFlight = false
        lastFallbackSnapshotRequestTime = 0
        stopZoomPreviewTimer()
        self.recordingRegion = recordingRegion
        self.onStop = onStop
        self.onTogglePause = onTogglePause
        self.screenFrameProvider = screenFrameProvider
        didLogMissingZoomFrame = false
        self.onToggleClickZoomMode = onToggleClickZoomMode
        self.onCameraLayoutChanged = onCameraLayoutChanged
        annotations = []
        currentStrokePoints = []
        events = []
        recordCameraLayout()
        show(cameraService: cameraService)
    }

    func endRecording() {
        recordingStartedAt = nil
        isPaused = false
        zoomClickModeEnabled = false
        zoomFollowModeEnabled = false
        zoomShortcutActive = false
        isTransientZoomActive = false
        liveZoomDepth = 1
        zoomPreviewImage = nil
        zoomSnapshotInFlight = false
        lastFallbackSnapshotRequestTime = 0
        stopZoomPreviewTimer()
        recordingRegion = nil
        onStop = nil
        onTogglePause = nil
        onToggleClickZoomMode = nil
        onCameraLayoutChanged = nil
        screenFrameProvider = nil
        didLogMissingZoomFrame = false
        hide()
    }

    func alignRecordingClock(to startedAt: Date) {
        recordingStartedAt = startedAt
        lastZoomFocusRecordTime = 0
    }

    func show(cameraService: CameraCaptureService) {
        if overlayWindow == nil {
            overlayWindow = OverlayWindowController(overlayService: self, cameraService: cameraService)
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

    /// The floating control bar's screen frame (if shown). Exposed so the overlay's
    /// click-to-zoom polling can ignore clicks that land on our own control bar.
    func controlBarScreenFrame() -> CGRect? {
        controlBarWindow?.windowFrame
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
        let allShapes = CameraFrameShape.allCases
        guard let currentIndex = allShapes.firstIndex(of: cameraShape) else {
            setCameraShape(.circle)
            return
        }
        let nextIndex = allShapes.index(after: currentIndex)
        setCameraShape(nextIndex == allShapes.endIndex ? allShapes[0] : allShapes[nextIndex])
    }

    func setCameraShape(_ shape: CameraFrameShape) {
        guard cameraShape != shape else { return }
        cameraShape = shape
        recordCameraLayout()
    }

    func adjustCameraSize(by delta: Double) {
        setCameraSize(cameraFrame.width + delta)
    }

    func setCameraSize(_ size: Double) {
        let frame = cameraFrame.resizedCameraFrame(size: size)
        guard frame != cameraFrame else { return }
        cameraFrame = frame
        recordCameraLayout()
    }

    func setCameraLayout(frame: NormalizedRect, shape: CameraFrameShape) {
        let clampedFrame = clamp(frame)
        guard cameraFrame != clampedFrame || cameraShape != shape else { return }
        cameraFrame = clampedFrame
        cameraShape = shape
        recordCameraLayout()
    }

    func setPaused(_ isPaused: Bool) {
        if isPaused {
            zoomFollowModeEnabled = false
            zoomClickModeEnabled = false
            zoomShortcutActive = false
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

    func requestToggleClickZoomMode() {
        onToggleClickZoomMode?()
    }

    func updateCameraFrame(_ frame: NormalizedRect) {
        cameraFrame = clamp(frame)
        // Record intermediate positions (throttled) so a drag animates smoothly in
        // the exported video instead of teleporting from the start position straight
        // to the drop point. Only the layout event is written here — the default
        // layout is persisted once, on drop, to avoid 30 preference writes/second.
        guard recordingStartedAt != nil, !isPaused else { return }
        let now = currentRecordingTime
        guard now - lastCameraLayoutRecordTime >= cameraLayoutRecordInterval else { return }
        lastCameraLayoutRecordTime = now
        appendCameraLayoutEvent()
    }

    func finishCameraFrameChange() {
        recordCameraLayout()
    }

    func adjustZoom(by delta: Double) {
        zoomMagnification = min(3, max(1.2, zoomMagnification + delta))
        // Persist the magnification change while mid-zoom during a recording so the
        // export reflects it. Previously only cursor-focus movement wrote zoom
        // events, so ⌃⌥⌘=/- adjustments during a hold were silently dropped.
        guard recordingStartedAt != nil, !isPaused, isTransientZoomActive else { return }
        let focus = normalizedMouseFocus()
        currentZoomFocus = focus
        lastRecordedZoomFocus = focus
        lastZoomFocusRecordTime = currentRecordingTime
        updateLiveZoomDepth()
        appendZoomEvent(magnification: zoomMagnification, focus: focus)
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
            zoomFollowModeEnabled = false
            endTransientZoom()
            return
        }
        zoomClickModeEnabled.toggle()
        if zoomClickModeEnabled {
            zoomFollowModeEnabled = false
            selectedTool = nil
            currentStrokePoints = []
            endTransientZoom()
        }
        if !zoomClickModeEnabled {
            endTransientZoom()
        }
    }

    /// Toggled by the configured mouse button (default 鼠标中键, see
    /// `RecordingPreferences.zoomMouseButton`). One click magnifies the region under
    /// the cursor, the next click restores it. It runs through the very same
    /// transient-zoom path the export replays, so the magnified region on screen is
    /// exactly the region in the finished video.
    func toggleMouseButtonZoom() {
        toggleFollowZoomMode()
    }

    func toggleFollowZoomMode() {
        guard !isPaused else {
            zoomFollowModeEnabled = false
            zoomClickModeEnabled = false
            endTransientZoom()
            return
        }

        zoomFollowModeEnabled.toggle()
        if zoomFollowModeEnabled {
            zoomClickModeEnabled = false
            selectedTool = nil
            currentStrokePoints = []
            beginTransientZoom()
        } else {
            endTransientZoom()
        }
    }

    func beginHoldZoom() {
        zoomShortcutActive = true
        beginTransientZoom()
    }

    func endHoldZoom() {
        zoomShortcutActive = false
        if !zoomFollowModeEnabled {
            endTransientZoom()
        }
    }

    func beginClickZoom() {
        guard zoomClickModeEnabled || zoomShortcutActive else { return }
        guard isMouseInsideRecordingRegion() else { return }
        beginTransientZoom()
    }

    func endClickZoom() {
        guard zoomClickModeEnabled || zoomShortcutActive else { return }
        if !zoomFollowModeEnabled, !zoomShortcutActive {
            endTransientZoom()
        }
    }

    private func beginTransientZoom() {
        guard recordingStartedAt != nil, !isPaused, !isTransientZoomActive else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            isTransientZoomActive = true
        }
        let focus = normalizedMouseFocus()
        currentZoomFocus = focus
        lastRecordedZoomFocus = focus
        lastZoomFocusRecordTime = currentRecordingTime
        transientZoomStartedAt = currentRecordingTime
        updateLiveZoomDepth()
        appendZoomEvent(magnification: zoomMagnification, focus: focus)
        currentZoomFocus = focus
        refreshZoomPreview()
        startZoomPreviewTimer()
        logger.info("Live zoom began")
    }

    private func endTransientZoom() {
        guard recordingStartedAt != nil, isTransientZoomActive else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            isTransientZoomActive = false
        }
        stopZoomPreviewTimer()
        liveZoomDepth = 1
        let focus = normalizedMouseFocus()
        currentZoomFocus = focus
        appendZoomEvent(magnification: 1, focus: focus)
        logger.info("Live zoom ended")
    }

    /// Follow the export's ramp-in curve while a zoom is open so the overlay never
    /// shows a magnification the exported frame at that timestamp will not have.
    private func updateLiveZoomDepth() {
        let elapsed = max(0, currentRecordingTime - transientZoomStartedAt)
        liveZoomDepth = ExportZoomTimeline.rampedDepth(target: zoomMagnification, elapsed: elapsed)
    }

    func selectTool(_ tool: AnnotationTool?) {
        selectedTool = selectedTool == tool ? nil : tool
        if selectedTool != nil {
            zoomFollowModeEnabled = false
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
        onCameraLayoutChanged?(cameraFrame, cameraShape)
        appendCameraLayoutEvent()
        if recordingStartedAt != nil {
            lastCameraLayoutRecordTime = currentRecordingTime
        }
    }

    private func appendCameraLayoutEvent() {
        guard recordingStartedAt != nil else { return }
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
        let timer = Timer(timeInterval: liveZoomFrameInterval, repeats: true) { [weak self] _ in
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
        updateLiveZoomDepth()
        requestZoomPreviewImage()

        let elapsed = currentRecordingTime - lastZoomFocusRecordTime
        if elapsed >= zoomFocusRecordInterval,
           focus.distance(to: lastRecordedZoomFocus) > zoomFocusRecordDistanceThreshold {
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
        let now = currentRecordingTime
        guard allowsInactiveAssignment || now - lastFallbackSnapshotRequestTime >= fallbackZoomSnapshotInterval else {
            return
        }

        zoomSnapshotInFlight = true
        lastFallbackSnapshotRequestTime = now
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
        // Pixels, from the real backing scale — SCDisplay reports points, so deriving
        // the scale from it grabbed the zoom fallback frame at 1× and the magnified
        // preview looked soft (see DisplayGeometry).
        let displayPixelSize = DisplayGeometry.pixelSize(for: display)
        guard let region, region.isUsable else {
            configuration.width = max(80, Int(displayPixelSize.width.rounded()))
            configuration.height = max(80, Int(displayPixelSize.height.rounded()))
            return
        }

        let displayPointSize = pointSize(for: display)
        let sourceRect = region.screenCaptureSourceRect(
            displayPointWidth: displayPointSize.width,
            displayPointHeight: displayPointSize.height
        )
        let outputSize = region.screenCaptureOutputSize(
            displayPixelWidth: displayPixelSize.width,
            displayPixelHeight: displayPixelSize.height,
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
        DisplayGeometry.pointSize(for: display)
    }

    private func screenForCurrentCapture(mouseLocation: CGPoint) -> NSScreen? {
        if let recordingRegion,
           let screen = NSScreen.screens.first(where: { $0.displayID == recordingRegion.displayID }) {
            return screen
        }
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    private func clamp(_ frame: NormalizedRect) -> NormalizedRect {
        frame.clampedCameraFrame
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
