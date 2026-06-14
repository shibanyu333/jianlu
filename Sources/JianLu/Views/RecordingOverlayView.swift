import AVFoundation
import JianLuCore
import SwiftUI

struct RecordingOverlayView: View {
    @ObservedObject var overlay: OverlayService
    let cameraSession: AVCaptureSession

    var body: some View {
        GeometryReader { geometry in
            let captureRect = overlay.captureRect(in: geometry.size)

            ZStack(alignment: .topLeading) {
                AnnotationCanvasView(overlay: overlay, captureRect: captureRect)

                if overlay.isTransientZoomActive {
                    LiveZoomMagnifierView(overlay: overlay, captureRect: captureRect)
                }

                if overlay.cameraVisible {
                    CameraBubbleView(
                        overlay: overlay,
                        cameraSession: cameraSession,
                        captureRect: captureRect
                    )
                }
            }
            .background(Color.clear)
        }
    }
}

private struct LiveZoomMagnifierView: View {
    @ObservedObject var overlay: OverlayService
    let captureRect: CGRect

    var body: some View {
        let diameter = ZoomLensGeometry.lensDiameter(for: captureRect.size)
        let lensSize = CGSize(width: diameter, height: diameter)
        let geometry = ZoomLensGeometry(lensSize: lensSize)
        let focus = geometry.focusPoint(in: captureRect, focus: overlay.currentZoomFocus)
        let position = geometry.clampedLensCenter(in: captureRect, focus: overlay.currentZoomFocus)
        let imageFrame = geometry.zoomedImageFrame(
            captureSize: captureRect.size,
            focus: overlay.currentZoomFocus,
            magnification: overlay.zoomMagnification
        )

        ZStack(alignment: .topLeading) {
            ZStack {
                if let image = overlay.zoomPreviewImage {
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imageFrame.width, height: imageFrame.height)
                            .offset(x: imageFrame.minX, y: imageFrame.minY)
                    }
                    .frame(width: lensSize.width, height: lensSize.height)
                    .clipped()
                } else {
                    RadialGradient(
                        colors: [.blue.opacity(0.36), .black.opacity(0.62)],
                        center: .center,
                        startRadius: 8,
                        endRadius: diameter / 2
                    )
                    Text("放大中")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                }

                Circle()
                    .stroke(.white.opacity(0.94), lineWidth: 3)
                Circle()
                    .stroke(.blue.opacity(0.85), lineWidth: 1)
                    .padding(5)

                Path { path in
                    path.move(to: CGPoint(x: lensSize.width / 2 - 10, y: lensSize.height / 2))
                    path.addLine(to: CGPoint(x: lensSize.width / 2 + 10, y: lensSize.height / 2))
                    path.move(to: CGPoint(x: lensSize.width / 2, y: lensSize.height / 2 - 10))
                    path.addLine(to: CGPoint(x: lensSize.width / 2, y: lensSize.height / 2 + 10))
                }
                .stroke(.white.opacity(0.88), lineWidth: 2)

                VStack {
                    Spacer()
                    HStack {
                        Text("\(String(format: "%.1f", overlay.zoomMagnification))x")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.88), in: Capsule())
                        Spacer()
                    }
                    .padding(14)
                }
            }
            .foregroundStyle(.white)
            .frame(width: lensSize.width, height: lensSize.height)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
            .position(position)

            Circle()
                .fill(.blue)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .position(focus)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}

private struct CameraBubbleView: View {
    @ObservedObject var overlay: OverlayService
    let cameraSession: AVCaptureSession
    let captureRect: CGRect

    @State private var dragStartFrame: NormalizedRect?
    @State private var resizeStartFrame: NormalizedRect?

    var body: some View {
        let frame = overlay.cameraFrame
        let size = CGSize(width: frame.width * captureRect.width, height: frame.height * captureRect.height)
        let origin = CGPoint(
            x: captureRect.minX + frame.x * captureRect.width,
            y: captureRect.minY + frame.y * captureRect.height
        )

        ZStack(alignment: .bottomTrailing) {
            CameraPreviewView(session: cameraSession)
                .clipShape(CameraFrameClipShape(shape: overlay.cameraShape))
                .overlay {
                    CameraFrameClipShape(shape: overlay.cameraShape)
                        .stroke(.white.opacity(0.9), lineWidth: 3)
                }
                .shadow(radius: 12)

            Circle()
                .fill(.white)
                .frame(width: 16, height: 16)
                .shadow(radius: 3)
                .padding(6)
                .gesture(resizeGesture(captureSize: captureRect.size))
        }
        .frame(width: size.width, height: size.height)
        .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        .gesture(moveGesture(captureSize: captureRect.size))
    }

    private func moveGesture(captureSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartFrame == nil {
                    dragStartFrame = overlay.cameraFrame
                }
                guard let start = dragStartFrame else { return }
                overlay.updateCameraFrame(
                    NormalizedRect(
                        x: start.x + value.translation.width / max(1, captureSize.width),
                        y: start.y + value.translation.height / max(1, captureSize.height),
                        width: start.width,
                        height: start.height
                    )
                )
            }
            .onEnded { _ in
                dragStartFrame = nil
                overlay.finishCameraFrameChange()
            }
    }

    private func resizeGesture(captureSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStartFrame == nil {
                    resizeStartFrame = overlay.cameraFrame
                }
                guard let start = resizeStartFrame else { return }
                let delta = max(
                    value.translation.width / max(1, captureSize.width),
                    value.translation.height / max(1, captureSize.height)
                )
                overlay.updateCameraFrame(
                    NormalizedRect(
                        x: start.x,
                        y: start.y,
                        width: start.width + delta,
                        height: start.height + delta
                    )
                )
            }
            .onEnded { _ in
                resizeStartFrame = nil
                overlay.finishCameraFrameChange()
            }
    }
}

private struct CameraFrameClipShape: Shape {
    let shape: CameraFrameShape

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .circle:
            Path(ellipseIn: rect)
        case .square:
            Path(rect)
        case .roundedSquare:
            Path(roundedRect: rect, cornerRadius: 18)
        }
    }
}

private struct AnnotationCanvasView: View {
    @ObservedObject var overlay: OverlayService
    let captureRect: CGRect

    var body: some View {
        Canvas { context, _ in
            for annotation in overlay.annotations {
                draw(annotation, in: &context, captureRect: captureRect)
            }
            drawCurrentStroke(in: &context, captureRect: captureRect)
        }
        .allowsHitTesting(overlay.selectedTool != nil)
        .contentShape(Rectangle())
        .gesture(strokeGesture(captureRect: captureRect))
    }

    private func strokeGesture(captureRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard overlay.selectedTool != nil else { return }
                guard captureRect.contains(value.location) else { return }
                let point = normalizedPoint(value.location, captureRect: captureRect)
                if overlay.currentStrokePoints.isEmpty {
                    overlay.beginStroke(at: point)
                } else {
                    overlay.appendStrokePoint(point)
                }
            }
            .onEnded { _ in
                overlay.finishStroke()
            }
    }

    private func drawCurrentStroke(in context: inout GraphicsContext, captureRect: CGRect) {
        guard let tool = overlay.selectedTool, overlay.currentStrokePoints.count > 1 else { return }
        let event = AnnotationEvent(
            time: 0,
            tool: tool,
            points: overlay.currentStrokePoints,
            colorHex: tool == .highlight ? "#FFD43B" : "#FF3B30",
            lineWidth: tool == .highlight ? 18 : 5
        )
        draw(event, in: &context, captureRect: captureRect)
    }

    private func draw(_ annotation: AnnotationEvent, in context: inout GraphicsContext, captureRect: CGRect) {
        let points = annotation.points.map { point in
            CGPoint(
                x: captureRect.minX + point.point.x * captureRect.width,
                y: captureRect.minY + point.point.y * captureRect.height
            )
        }
        guard let first = points.first else { return }

        var path = Path()

        switch annotation.tool {
        case .rectangle, .ellipse:
            guard let last = points.last else { return }
            let rect = rect(from: first, to: last)
            if annotation.tool == .ellipse {
                path.addEllipse(in: rect)
            } else {
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
            }
        case .line, .arrow:
            path.move(to: first)
            if let last = points.last {
                path.addLine(to: last)
            }
        case .pen, .highlight:
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }

        let color = annotation.tool == .highlight ? Color.yellow.opacity(0.35) : Color.red
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: annotation.lineWidth, lineCap: .round, lineJoin: .round)
        )

        if annotation.tool == .arrow, points.count >= 2, let end = points.last {
            drawArrowHead(context: &context, from: points[points.count - 2], to: end, color: color)
        }
    }

    private func drawArrowHead(context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, color: Color) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 18
        let spread: CGFloat = .pi / 7
        let points = [
            CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)),
            end,
            CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread))
        ]

        var path = Path()
        path.move(to: points[0])
        path.addLine(to: points[1])
        path.addLine(to: points[2])
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
    }

    private func rect(from first: CGPoint, to last: CGPoint) -> CGRect {
        CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
    }

    private func normalizedPoint(_ point: CGPoint, captureRect: CGRect) -> NormalizedPoint {
        NormalizedPoint(
            x: min(max(0, (point.x - captureRect.minX) / max(1, captureRect.width)), 1),
            y: min(max(0, (point.y - captureRect.minY) / max(1, captureRect.height)), 1)
        )
    }
}

extension OverlayService {
    func captureRect(in size: CGSize) -> CGRect {
        guard let recordingRegion, recordingRegion.isUsable else {
            return CGRect(origin: .zero, size: size)
        }
        let x = min(max(0, recordingRegion.x), max(0, size.width - recordingRegion.width))
        let y = min(max(0, recordingRegion.y), max(0, size.height - recordingRegion.height))
        let width = min(recordingRegion.width, size.width - x)
        let height = min(recordingRegion.height, size.height - y)
        return CGRect(x: x, y: y, width: max(1, width), height: max(1, height))
    }
}
