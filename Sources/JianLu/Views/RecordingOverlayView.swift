import AVFoundation
import JianLuCore
import SwiftUI

struct RecordingOverlayView: View {
    @ObservedObject var overlay: OverlayService
    let cameraSession: AVCaptureSession

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                AnnotationCanvasView(overlay: overlay)

                if overlay.cameraVisible {
                    CameraBubbleView(
                        overlay: overlay,
                        cameraSession: cameraSession,
                        containerSize: geometry.size
                    )
                }

                OverlayToolbarView(overlay: overlay)
                    .padding(.top, 22)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Color.clear)
        }
    }
}

private struct CameraBubbleView: View {
    @ObservedObject var overlay: OverlayService
    let cameraSession: AVCaptureSession
    let containerSize: CGSize

    @State private var dragStartFrame: NormalizedRect?
    @State private var resizeStartFrame: NormalizedRect?

    var body: some View {
        let frame = overlay.cameraFrame
        let size = CGSize(width: frame.width * containerSize.width, height: frame.height * containerSize.height)
        let origin = CGPoint(x: frame.x * containerSize.width, y: frame.y * containerSize.height)

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
                .gesture(resizeGesture(containerSize: containerSize))
        }
        .frame(width: size.width, height: size.height)
        .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        .gesture(moveGesture(containerSize: containerSize))
    }

    private func moveGesture(containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartFrame == nil {
                    dragStartFrame = overlay.cameraFrame
                }
                guard let start = dragStartFrame else { return }
                overlay.updateCameraFrame(
                    NormalizedRect(
                        x: start.x + value.translation.width / containerSize.width,
                        y: start.y + value.translation.height / containerSize.height,
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

    private func resizeGesture(containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStartFrame == nil {
                    resizeStartFrame = overlay.cameraFrame
                }
                guard let start = resizeStartFrame else { return }
                let delta = max(value.translation.width / containerSize.width, value.translation.height / containerSize.height)
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

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for annotation in overlay.annotations {
                    draw(annotation, in: &context, size: size)
                }
                drawCurrentStroke(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(strokeGesture(size: geometry.size))
        }
    }

    private func strokeGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard overlay.selectedTool != nil else { return }
                let point = normalizedPoint(value.location, size: size)
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

    private func drawCurrentStroke(in context: inout GraphicsContext, size: CGSize) {
        guard let tool = overlay.selectedTool, overlay.currentStrokePoints.count > 1 else { return }
        let event = AnnotationEvent(
            time: 0,
            tool: tool,
            points: overlay.currentStrokePoints,
            colorHex: tool == .highlight ? "#FFD43B" : "#FF3B30",
            lineWidth: tool == .highlight ? 18 : 5
        )
        draw(event, in: &context, size: size)
    }

    private func draw(_ annotation: AnnotationEvent, in context: inout GraphicsContext, size: CGSize) {
        let points = annotation.points.map { point in
            CGPoint(x: point.point.x * size.width, y: point.point.y * size.height)
        }
        guard let first = points.first else { return }

        var path = Path()
        path.move(to: first)

        if annotation.tool == .line || annotation.tool == .arrow {
            if let last = points.last {
                path.addLine(to: last)
            }
        } else {
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

    private func normalizedPoint(_ point: CGPoint, size: CGSize) -> NormalizedPoint {
        NormalizedPoint(
            x: min(max(0, point.x / max(1, size.width)), 1),
            y: min(max(0, point.y / max(1, size.height)), 1)
        )
    }
}

private struct OverlayToolbarView: View {
    @ObservedObject var overlay: OverlayService

    var body: some View {
        HStack(spacing: 8) {
            ToolButton(title: "缩放", symbol: "plus.magnifyingglass", isActive: overlay.zoomMagnification > 1) {
                overlay.toggleZoom()
            }
            ToolButton(title: "画笔", symbol: "pencil", isActive: overlay.selectedTool == .pen) {
                overlay.selectTool(.pen)
            }
            ToolButton(title: "高亮", symbol: "highlighter", isActive: overlay.selectedTool == .highlight) {
                overlay.selectTool(.highlight)
            }
            ToolButton(title: "直线", symbol: "line.diagonal", isActive: overlay.selectedTool == .line) {
                overlay.selectTool(.line)
            }
            ToolButton(title: "箭头", symbol: "arrow.up.right", isActive: overlay.selectedTool == .arrow) {
                overlay.selectTool(.arrow)
            }
            ToolButton(title: overlay.cameraShape.displayName, symbol: "rectangle.on.rectangle", isActive: false) {
                overlay.toggleCameraShape()
            }
            ToolButton(title: "撤销", symbol: "arrow.uturn.backward", isActive: false) {
                overlay.undoLastAnnotation()
            }
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 10)
    }
}

private struct ToolButton: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? .white : .primary)
        .background(isActive ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .help(title)
    }
}
