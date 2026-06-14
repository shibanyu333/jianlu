import JianLuCore
import SwiftUI

@MainActor
final class ScreenshotEditorModel: ObservableObject {
    let image: CGImage
    @Published var selectedTool: AnnotationTool? = .pen
    @Published var annotations: [AnnotationEvent] = []
    @Published var currentStrokePoints: [StrokePoint] = []

    private let onSave: (CGImage) -> Void
    private let onCopy: (CGImage) -> Void
    private let onClose: () -> Void

    init(
        image: CGImage,
        onSave: @escaping (CGImage) -> Void,
        onCopy: @escaping (CGImage) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.image = image
        self.onSave = onSave
        self.onCopy = onCopy
        self.onClose = onClose
    }

    var imageSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    func selectTool(_ tool: AnnotationTool) {
        selectedTool = selectedTool == tool ? nil : tool
    }

    func beginStroke(at point: NormalizedPoint) {
        guard let selectedTool else { return }
        currentStrokePoints = [StrokePoint(time: 0, point: point)]
        if selectedTool.isShapeTool {
            currentStrokePoints.append(StrokePoint(time: 0, point: point))
        }
    }

    func appendStrokePoint(_ point: NormalizedPoint) {
        guard selectedTool != nil else { return }
        let strokePoint = StrokePoint(time: 0, point: point)
        if selectedTool?.isShapeTool == true, currentStrokePoints.count >= 2 {
            currentStrokePoints[currentStrokePoints.count - 1] = strokePoint
        } else {
            currentStrokePoints.append(strokePoint)
        }
    }

    func finishStroke() {
        guard let selectedTool, currentStrokePoints.count > 1 else {
            currentStrokePoints = []
            return
        }
        annotations.append(
            AnnotationEvent(
                time: 0,
                tool: selectedTool,
                points: currentStrokePoints,
                colorHex: selectedTool == .highlight ? "#FFD43B" : "#FF3B30",
                lineWidth: selectedTool == .highlight ? 18 : 5
            )
        )
        currentStrokePoints = []
    }

    func undoLastAnnotation() {
        if !currentStrokePoints.isEmpty {
            currentStrokePoints = []
            return
        }
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
    }

    func clearAnnotations() {
        annotations = []
        currentStrokePoints = []
    }

    func save() {
        finishStroke()
        onSave(renderedImage())
    }

    func copy() {
        finishStroke()
        onCopy(renderedImage())
    }

    func close() {
        onClose()
    }

    private func renderedImage() -> CGImage {
        AnnotationImageRenderer.render(baseImage: image, annotations: annotations) ?? image
    }
}

struct ScreenshotEditorView: View {
    @ObservedObject var model: ScreenshotEditorModel

    var body: some View {
        VStack(spacing: 0) {
            ScreenshotEditorToolbar(model: model)
            Divider()
            GeometryReader { geometry in
                let imageRect = fittedImageRect(imageSize: model.imageSize, containerSize: geometry.size)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.84)
                    Image(decorative: model.image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)

                    ScreenshotAnnotationLayer(model: model, imageRect: imageRect)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    private func fittedImageRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
    }
}

private struct ScreenshotEditorToolbar: View {
    @ObservedObject var model: ScreenshotEditorModel

    var body: some View {
        HStack(spacing: 8) {
            ToolButton(title: "画笔", symbol: "pencil", isActive: model.selectedTool == .pen) {
                model.selectTool(.pen)
            }
            ToolButton(title: "高亮", symbol: "highlighter", isActive: model.selectedTool == .highlight) {
                model.selectTool(.highlight)
            }
            ToolButton(title: "直线", symbol: "line.diagonal", isActive: model.selectedTool == .line) {
                model.selectTool(.line)
            }
            ToolButton(title: "箭头", symbol: "arrow.up.right", isActive: model.selectedTool == .arrow) {
                model.selectTool(.arrow)
            }
            ToolButton(title: "方框", symbol: "square", isActive: model.selectedTool == .rectangle) {
                model.selectTool(.rectangle)
            }
            ToolButton(title: "圆形", symbol: "circle", isActive: model.selectedTool == .ellipse) {
                model.selectTool(.ellipse)
            }

            Divider()
                .frame(height: 22)

            Button {
                model.undoLastAnnotation()
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(model.annotations.isEmpty && model.currentStrokePoints.isEmpty)

            Button {
                model.clearAnnotations()
            } label: {
                Label("清空", systemImage: "trash.slash")
            }
            .disabled(model.annotations.isEmpty && model.currentStrokePoints.isEmpty)

            Spacer()

            Button {
                model.copy()
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.shift, .command])

            Button {
                model.save()
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)

            Button {
                model.close()
            } label: {
                Label("关闭", systemImage: "xmark")
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
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
                .lineLimit(1)
                .frame(minWidth: 58)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .accentColor : .secondary)
        .help(title)
    }
}

private struct ScreenshotAnnotationLayer: View {
    @ObservedObject var model: ScreenshotEditorModel
    let imageRect: CGRect
    @State private var isDragging = false

    var body: some View {
        Canvas { context, _ in
            for annotation in model.annotations {
                draw(annotation, in: &context)
            }
            drawCurrentStroke(in: &context)
        }
        .contentShape(Rectangle())
        .allowsHitTesting(model.selectedTool != nil)
        .gesture(strokeGesture)
    }

    private var strokeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard imageRect.contains(value.location), model.selectedTool != nil else { return }
                let point = normalizedPoint(value.location)
                if !isDragging {
                    isDragging = true
                    model.beginStroke(at: point)
                } else {
                    model.appendStrokePoint(point)
                }
            }
            .onEnded { _ in
                isDragging = false
                model.finishStroke()
            }
    }

    private func drawCurrentStroke(in context: inout GraphicsContext) {
        guard let tool = model.selectedTool, model.currentStrokePoints.count > 1 else { return }
        draw(
            AnnotationEvent(
                time: 0,
                tool: tool,
                points: model.currentStrokePoints,
                colorHex: tool == .highlight ? "#FFD43B" : "#FF3B30",
                lineWidth: tool == .highlight ? 18 : 5
            ),
            in: &context
        )
    }

    private func draw(_ annotation: AnnotationEvent, in context: inout GraphicsContext) {
        let points = annotation.points.map { point in
            CGPoint(
                x: imageRect.minX + point.point.x * imageRect.width,
                y: imageRect.minY + point.point.y * imageRect.height
            )
        }
        guard let first = points.first else { return }

        var path = Path()
        switch annotation.tool {
        case .rectangle, .ellipse:
            guard let last = points.last else { return }
            let rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
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

    private func normalizedPoint(_ point: CGPoint) -> NormalizedPoint {
        NormalizedPoint(
            x: min(max(0, (point.x - imageRect.minX) / max(1, imageRect.width)), 1),
            y: min(max(0, (point.y - imageRect.minY) / max(1, imageRect.height)), 1)
        )
    }
}
