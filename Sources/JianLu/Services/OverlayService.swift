import AVFoundation
import Foundation
import JianLuCore
import SwiftUI

@MainActor
final class OverlayService: ObservableObject {
    @Published var cameraFrame: NormalizedRect = .defaultCameraFrame
    @Published var cameraShape: CameraFrameShape = .circle
    @Published var cameraVisible = true
    @Published var selectedTool: AnnotationTool?
    @Published var zoomMagnification: Double = 1
    @Published var annotations: [AnnotationEvent] = []
    @Published var currentStrokePoints: [StrokePoint] = []

    private(set) var events: [EffectEvent] = []
    private var recordingStartedAt: Date?
    private var overlayWindow: OverlayWindowController?

    var currentRecordingTime: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    func beginRecording(cameraSession: AVCaptureSession, cameraEnabled: Bool) {
        recordingStartedAt = Date()
        cameraVisible = cameraEnabled
        annotations = []
        currentStrokePoints = []
        events = []
        recordCameraLayout()
        show(cameraSession: cameraSession)
    }

    func endRecording() {
        recordingStartedAt = nil
        hide()
    }

    func show(cameraSession: AVCaptureSession) {
        if overlayWindow == nil {
            overlayWindow = OverlayWindowController(overlayService: self, cameraSession: cameraSession)
        }
        overlayWindow?.show()
    }

    func hide() {
        overlayWindow?.hide()
        overlayWindow = nil
    }

    func toggleCameraVisibility() {
        cameraVisible.toggle()
        recordCameraLayout()
    }

    func toggleCameraShape() {
        cameraShape = cameraShape == .circle ? .square : .circle
        recordCameraLayout()
    }

    func updateCameraFrame(_ frame: NormalizedRect) {
        cameraFrame = clamp(frame)
    }

    func finishCameraFrameChange() {
        recordCameraLayout()
    }

    func adjustZoom(by delta: Double) {
        zoomMagnification = min(3, max(1, zoomMagnification + delta))
        let event = ZoomEvent(time: currentRecordingTime, magnification: zoomMagnification, focus: NormalizedPoint(x: 0.5, y: 0.5))
        events.append(.zoom(event))
    }

    func toggleZoom() {
        zoomMagnification = zoomMagnification > 1 ? 1 : 1.8
        let event = ZoomEvent(time: currentRecordingTime, magnification: zoomMagnification, focus: NormalizedPoint(x: 0.5, y: 0.5))
        events.append(.zoom(event))
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
}
