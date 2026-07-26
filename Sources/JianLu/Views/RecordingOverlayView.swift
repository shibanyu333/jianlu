import JianLuCore
import SwiftUI

struct RecordingOverlayView: View {
    @ObservedObject var overlay: OverlayService
    @ObservedObject var cameraService: CameraCaptureService

    var body: some View {
        GeometryReader { geometry in
            let captureRect = overlay.captureRect(in: geometry.size)

            ZStack(alignment: .topLeading) {
                if overlay.isTransientZoomActive {
                    LiveZoomViewportView(overlay: overlay, captureRect: captureRect)
                }

                AnnotationCanvasView(overlay: overlay, captureRect: captureRect)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                if overlay.cameraVisible {
                    CameraBubbleView(
                        overlay: overlay,
                        cameraService: cameraService,
                        captureRect: captureRect
                    )
                }
            }
            .background(Color.clear)
        }
    }
}

private struct LiveZoomViewportView: View {
    @ObservedObject var overlay: OverlayService
    let captureRect: CGRect

    var body: some View {
        let captureSize = captureRect.size
        let geometry = ZoomLensGeometry(lensSize: captureSize)
        // liveZoomDepth (not the raw target magnification) so the on-screen zoom eases
        // in on the same curve the exported video uses — the region the presenter sees
        // magnified is the region the finished video shows.
        let imageFrame = geometry.zoomedRegionImageFrame(
            captureSize: captureSize,
            focus: overlay.currentZoomFocus,
            magnification: overlay.liveZoomDepth
        )
        let focusPoint = geometry.focusPoint(
            in: CGRect(origin: .zero, size: captureSize),
            focus: overlay.currentZoomFocus
        )

        // The magnified frame is larger than the viewport, so it has to be anchored as
        // an overlay on a viewport-sized base. As a ZStack child it would grow the
        // stack past `captureRect`, and the outer `.frame` would then CENTER that
        // oversized content — shifting the live picture by (1 - depth)/2 of the region
        // away from the region the export magnifies. Overlays never resize their base,
        // so the top-left anchor `zoomedRegionImageFrame` assumes actually holds.
        Color.clear
            .frame(width: captureRect.width, height: captureRect.height)
            .overlay(alignment: .topLeading) {
                if let image = overlay.zoomPreviewImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .offset(x: imageFrame.minX, y: imageFrame.minY)
                }
            }
            .overlay {
                if overlay.zoomPreviewImage == nil {
                    ZStack {
                        Color.blue.opacity(0.20)
                        VStack(spacing: 8) {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 32, weight: .semibold))
                            Text(tr("放大中", "Zooming"))
                                .font(.callout.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            .overlay {
                FocusMarker()
                    .frame(width: 34, height: 34)
                    .position(
                        x: focusPoint.x,
                        y: focusPoint.y
                    )
            }
            .overlay(alignment: .topTrailing) {
                Text("\(String(format: "%.1f", overlay.zoomMagnification))x")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(10)
            }
            .overlay {
                Rectangle()
                    .stroke(.white.opacity(0.92), lineWidth: 3)
                Rectangle()
                    .stroke(.blue.opacity(0.92), lineWidth: 4)
                    .padding(4)
            }
            .clipped()
            .position(x: captureRect.midX, y: captureRect.midY)
            .shadow(color: .black.opacity(0.28), radius: 18, y: 7)
            .allowsHitTesting(false)
            .transition(.opacity)
            .transaction { transaction in
                transaction.animation = nil
            }
    }
}

private struct FocusMarker: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.95), lineWidth: 3)
            Circle()
                .stroke(.blue.opacity(0.9), lineWidth: 2)
                .padding(4)
            Path { path in
                path.move(to: CGPoint(x: 17, y: 5))
                path.addLine(to: CGPoint(x: 17, y: 29))
                path.move(to: CGPoint(x: 5, y: 17))
                path.addLine(to: CGPoint(x: 29, y: 17))
            }
            .stroke(.white.opacity(0.9), lineWidth: 2)
        }
    }
}

private struct CameraBubbleView: View {
    @ObservedObject var overlay: OverlayService
    @ObservedObject var cameraService: CameraCaptureService
    let captureRect: CGRect

    @State private var dragStartFrame: NormalizedRect?
    @State private var resizeStartFrame: NormalizedRect?

    var body: some View {
        // Shared bubble geometry so "圆形" is a true circle, "椭圆" keeps its oval
        // aspect, and both match the exported video exactly (see
        // NormalizedRect.cameraBubbleRect).
        let bubble = overlay.cameraFrame.cameraBubbleRect(in: captureRect.size, shape: overlay.cameraShape)
        let size = bubble.size
        let origin = CGPoint(
            x: captureRect.minX + bubble.minX,
            y: captureRect.minY + bubble.minY
        )

        ZStack(alignment: .bottomTrailing) {
            CameraPreviewView(
                session: cameraService.previewSession,
                processedImage: cameraService.processedPreviewImage
            )
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
        .allowsHitTesting(overlay.selectedTool != nil && !overlay.isPaused)
        .contentShape(Rectangle())
        .gesture(strokeGesture(captureRect: captureRect))
    }

    private func strokeGesture(captureRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard overlay.selectedTool != nil, !overlay.isPaused else { return }
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

        let color = Color(annotationHex: annotation.colorHex, tool: annotation.tool)
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
        let length = AnnotationStyle.arrowHeadLength
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
