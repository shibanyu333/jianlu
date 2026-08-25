import JianLuCore
import SwiftUI

enum CaptureRegionSelectionPurpose {
    case recording
    case screenshot

    var minimumSize: CGFloat {
        switch self {
        case .recording:
            80
        case .screenshot:
            20
        }
    }

    var title: String {
        switch self {
        case .recording:
            tr("拖拽选择录制区域", "Drag to select the recording area")
        case .screenshot:
            tr("拖拽选择截图区域", "Drag to select the screenshot area")
        }
    }

    var windowTitle: String {
        switch self {
        case .recording:
            tr("选择录制区域", "Select recording area")
        case .screenshot:
            tr("选择截图区域", "Select screenshot area")
        }
    }

    var confirmTitle: String {
        switch self {
        case .recording:
            tr("开始录制", "Start recording")
        case .screenshot:
            tr("截图", "Capture")
        }
    }

    var startingTitle: String {
        switch self {
        case .recording:
            tr("正在开始", "Starting…")
        case .screenshot:
            tr("正在截图", "Capturing…")
        }
    }

    var confirmSystemImage: String {
        switch self {
        case .recording:
            "record.circle"
        case .screenshot:
            "camera.viewfinder"
        }
    }

    var hint: String {
        switch self {
        case .recording:
            tr("Return 开始录制，Esc 取消，⌃⌥⌘R 也可确认当前区域", "Return to start, Esc to cancel — ⌃⌥⌘R also confirms the current area")
        case .screenshot:
            tr("Return 截图，Esc 取消；截图后可继续标注和涂鸦", "Return to capture, Esc to cancel — you can annotate afterwards")
        }
    }
}

enum CaptureRegionSelectionPhase {
    case selecting
    case capturing
    case editing
}

enum ScreenshotEditingTool: CaseIterable, Hashable {
    case select
    case pen
    case highlight
    case line
    case arrow
    case rectangle
    case ellipse
    case text
    case mosaic

    /// Whether picking this tool draws something new. `.select` only picks up and
    /// adjusts markup that is already on the screenshot.
    var isDrawingTool: Bool {
        self != .select
    }

    var annotationTool: AnnotationTool? {
        switch self {
        case .pen:
            .pen
        case .highlight:
            .highlight
        case .line:
            .line
        case .arrow:
            .arrow
        case .rectangle:
            .rectangle
        case .ellipse:
            .ellipse
        case .select, .text, .mosaic:
            nil
        }
    }

    var title: String {
        switch self {
        case .select:
            tr("选择", "Select")
        case .pen:
            tr("画笔", "Pen")
        case .highlight:
            tr("高亮", "Highlight")
        case .line:
            tr("直线", "Line")
        case .arrow:
            tr("箭头", "Arrow")
        case .rectangle:
            tr("方框", "Rectangle")
        case .ellipse:
            "圆形"
        case .text:
            tr("文字", "Text")
        case .mosaic:
            tr("马赛克", "Mosaic")
        }
    }

    var symbol: String {
        switch self {
        case .select:
            "cursorarrow"
        case .pen:
            "pencil"
        case .highlight:
            "highlighter"
        case .line:
            "line.diagonal"
        case .arrow:
            "arrow.up.right"
        case .rectangle:
            "square"
        case .ellipse:
            "circle"
        case .text:
            "textformat"
        case .mosaic:
            "checkerboard.rectangle"
        }
    }
}

struct CaptureWindowCandidate: Identifiable, Equatable {
    let id: UInt32
    let rect: CGRect
    let title: String
}

@MainActor
final class CaptureRegionSelectionModel: ObservableObject {
    @Published var selectionRect: CGRect
    @Published var phase: CaptureRegionSelectionPhase = .selecting
    @Published var capturedImage: CGImage?
    @Published var selectedScreenshotTool: ScreenshotEditingTool = .pen
    @Published var markups: [ScreenshotMarkup] = []
    @Published var currentStrokePoints: [StrokePoint] = []
    @Published var currentMosaicRect: NormalizedRect?
    @Published var pendingTextAnchor: NormalizedPoint?
    @Published var pendingText = ""
    /// The markup the grips are attached to. Every finished markup becomes the
    /// selection so it can be dragged into place right after it is drawn.
    @Published var selectedMarkupID: UUID?

    /// Whole-list snapshots taken before every edit, so undo also walks back moves,
    /// resizes and deletions — not just the last thing drawn.
    private var markupUndoStack: [[ScreenshotMarkup]] = []
    /// The selected markup as it was when the current drag started; every drag frame
    /// is applied to this, never to the already-moved copy, so nothing accumulates.
    private var draggedMarkupOriginal: ScreenshotMarkup?
    /// Which markup the current run of arrow-key nudges belongs to.
    private var lastNudgedMarkupID: UUID?
    private static let markupUndoLimit = 60

    let displayID: UInt32
    let screenSize: CGSize
    let purpose: CaptureRegionSelectionPurpose
    let windowCandidates: [CaptureWindowCandidate]
    /// The still grabbed when the shortcut fired. While it is present the selection
    /// happens on a frozen screen, and the final image is cropped out of this very
    /// frame — so what you select is exactly what you saw when you pressed the key.
    let frozenScreen: CGImage?
    private let onStart: (RecordingRegion) -> Void
    private let onCancel: () -> Void
    private let onFinish: ((CGImage) -> Void)?
    private let onCopy: ((CGImage) -> Void)?
    private let onSave: ((CGImage) -> Void)?
    private var hoveredWindowCandidateID: UInt32?

    var canStart: Bool {
        phase == .selecting && selectionRect.width >= purpose.minimumSize && selectionRect.height >= purpose.minimumSize
    }

    var isStarting: Bool {
        phase == .capturing
    }

    var isEditing: Bool {
        phase == .editing
    }

    init(
        displayID: UInt32,
        screenSize: CGSize,
        initialRegion: RecordingRegion?,
        windowCandidates: [CaptureWindowCandidate] = [],
        purpose: CaptureRegionSelectionPurpose = .recording,
        frozenScreen: CGImage? = nil,
        onStart: @escaping (RecordingRegion) -> Void,
        onCancel: @escaping () -> Void,
        onFinish: ((CGImage) -> Void)? = nil,
        onCopy: ((CGImage) -> Void)? = nil,
        onSave: ((CGImage) -> Void)? = nil
    ) {
        self.displayID = displayID
        self.screenSize = screenSize
        self.purpose = purpose
        self.windowCandidates = windowCandidates
        self.frozenScreen = frozenScreen
        self.onStart = onStart
        self.onCancel = onCancel
        self.onFinish = onFinish
        self.onCopy = onCopy
        self.onSave = onSave

        if let initialRegion, initialRegion.isUsable {
            selectionRect = Self.clamped(
                CGRect(
                    x: initialRegion.x,
                    y: initialRegion.y,
                    width: initialRegion.width,
                    height: initialRegion.height
                ),
                screenSize: screenSize
            )
        } else if purpose == .screenshot {
            selectionRect = .zero
        } else {
            let width = min(960, screenSize.width * 0.72)
            let height = min(600, screenSize.height * 0.66)
            selectionRect = CGRect(
                x: (screenSize.width - width) / 2,
                y: (screenSize.height - height) / 2,
                width: width,
                height: height
            )
        }
    }

    func updateSelection(from start: CGPoint, to end: CGPoint) {
        guard phase == .selecting else { return }
        hoveredWindowCandidateID = nil
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        selectionRect = clamped(
            CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        )
    }

    func selectFullScreen() {
        guard phase == .selecting else { return }
        hoveredWindowCandidateID = nil
        selectionRect = CGRect(origin: .zero, size: screenSize)
    }

    func confirmSelection() {
        guard canStart else { return }
        beginCapturing()
        let rect = clamped(selectionRect)
        onStart(
            RecordingRegion(
                displayID: displayID,
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: rect.height
            )
        )
    }

    func updateWindowHover(at point: CGPoint) {
        guard purpose == .screenshot, phase == .selecting else { return }
        if let candidate = windowCandidates.first(where: { $0.rect.contains(point) }) {
            hoveredWindowCandidateID = candidate.id
            selectionRect = candidate.rect
        } else if hoveredWindowCandidateID != nil {
            hoveredWindowCandidateID = nil
            selectionRect = .zero
        }
    }

    func confirmHoveredWindowSelection() {
        guard purpose == .screenshot, hoveredWindowCandidateID != nil, canStart else { return }
        confirmSelection()
    }

    func beginCapturing() {
        guard phase == .selecting else { return }
        phase = .capturing
    }

    func beginEditing(image: CGImage) {
        capturedImage = image
        markups = []
        currentStrokePoints = []
        currentMosaicRect = nil
        pendingTextAnchor = nil
        pendingText = ""
        selectedMarkupID = nil
        markupUndoStack = []
        draggedMarkupOriginal = nil
        selectedScreenshotTool = .pen
        phase = .editing
    }

    func confirmDefaultAction() {
        switch phase {
        case .selecting:
            confirmSelection()
        case .capturing:
            break
        case .editing:
            finishEditing()
        }
    }

    func cancel() {
        guard phase != .capturing else { return }
        onCancel()
    }

    func selectScreenshotTool(_ tool: ScreenshotEditingTool) {
        commitPendingText()
        // Tapping the active tool again falls back to select/move instead of a mode
        // where clicking does nothing at all.
        selectedScreenshotTool = selectedScreenshotTool == tool ? .select : tool
    }

    func beginStroke(at point: NormalizedPoint) {
        guard let tool = selectedScreenshotTool.annotationTool else { return }
        currentStrokePoints = [StrokePoint(time: 0, point: point)]
        if tool.isShapeTool {
            currentStrokePoints.append(StrokePoint(time: 0, point: point))
        }
    }

    func appendStrokePoint(_ point: NormalizedPoint) {
        guard let tool = selectedScreenshotTool.annotationTool else { return }
        let strokePoint = StrokePoint(time: 0, point: point)
        if tool.isShapeTool, currentStrokePoints.count >= 2 {
            currentStrokePoints[currentStrokePoints.count - 1] = strokePoint
        } else {
            currentStrokePoints.append(strokePoint)
        }
    }

    func finishStroke() {
        guard let tool = selectedScreenshotTool.annotationTool, currentStrokePoints.count > 1 else {
            currentStrokePoints = []
            return
        }
        let annotation = AnnotationEvent(
            time: 0,
            tool: tool,
            points: currentStrokePoints,
            colorHex: tool == .highlight ? AnnotationStyle.highlightColorHex : AnnotationStyle.penColorHex,
            lineWidth: tool == .highlight ? 18 : 5
        )
        pushMarkupUndoSnapshot()
        markups.append(.stroke(annotation))
        selectedMarkupID = annotation.id
        currentStrokePoints = []
    }

    func updateMosaic(from start: NormalizedPoint, to end: NormalizedPoint) {
        guard selectedScreenshotTool == .mosaic else { return }
        currentMosaicRect = NormalizedRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    func finishMosaic() {
        guard let rect = currentMosaicRect, rect.width > 0.005, rect.height > 0.005 else {
            currentMosaicRect = nil
            return
        }
        let mosaic = ScreenshotMosaicMarkup(rect: rect)
        pushMarkupUndoSnapshot()
        markups.append(.mosaic(mosaic))
        selectedMarkupID = mosaic.id
        currentMosaicRect = nil
    }

    func beginText(at point: NormalizedPoint) {
        commitPendingText()
        pendingTextAnchor = point
        pendingText = ""
    }

    func commitPendingText() {
        guard let anchor = pendingTextAnchor else { return }
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let markup = ScreenshotTextMarkup(text: text, anchor: anchor)
            pushMarkupUndoSnapshot()
            markups.append(.text(markup))
            selectedMarkupID = markup.id
        }
        pendingTextAnchor = nil
        pendingText = ""
    }

    /// Walks back one whole edit — a stroke, but also a move, a resize, a delete or
    /// a clear, because every mutation snapshots the list first.
    func undoLastMarkup() {
        if pendingTextAnchor != nil {
            pendingTextAnchor = nil
            pendingText = ""
            return
        }
        if !currentStrokePoints.isEmpty {
            currentStrokePoints = []
            return
        }
        if currentMosaicRect != nil {
            currentMosaicRect = nil
            return
        }
        guard let previous = markupUndoStack.popLast() else { return }
        markups = previous
        if let selectedMarkupID, !markups.contains(where: { $0.id == selectedMarkupID }) {
            self.selectedMarkupID = nil
        }
    }

    func clearMarkups() {
        if !markups.isEmpty {
            pushMarkupUndoSnapshot()
        }
        markups = []
        currentStrokePoints = []
        currentMosaicRect = nil
        pendingTextAnchor = nil
        pendingText = ""
        selectedMarkupID = nil
    }

    // MARK: - Adjusting markup that is already on the screenshot

    var selectedMarkup: ScreenshotMarkup? {
        guard let selectedMarkupID else { return nil }
        return markups.first { $0.id == selectedMarkupID }
    }

    var canUndoMarkup: Bool {
        !markupUndoStack.isEmpty || hasUnfinishedMarkup
    }

    var canClearMarkup: Bool {
        !markups.isEmpty || hasUnfinishedMarkup
    }

    func selectMarkup(id: UUID?) {
        commitPendingText()
        guard selectedMarkupID != id else { return }
        selectedMarkupID = id
    }

    /// Snapshots the list once at the start of a drag so the whole gesture — not
    /// every intermediate frame — is a single undo step.
    func beginMarkupDrag() {
        guard let selectedMarkup else { return }
        draggedMarkupOriginal = selectedMarkup
        pushMarkupUndoSnapshot()
    }

    /// `translation` is normalized to the screenshot, and is always applied to the
    /// markup as it was when the drag started.
    func dragSelectedMarkup(translation: CGSize) {
        guard let original = draggedMarkupOriginal, let index = selectedMarkupIndex else { return }
        markups[index] = original.moved(by: translation)
    }

    func resizeSelectedMarkup(handle: ScreenshotMarkupHandle, to point: NormalizedPoint) {
        guard let original = draggedMarkupOriginal, let index = selectedMarkupIndex else { return }
        markups[index] = original.resized(handle: handle, to: point)
    }

    func endMarkupDrag() {
        draggedMarkupOriginal = nil
    }

    /// Arrow-key nudge, in editor points. A run of nudges collapses into one undo
    /// step so key repeat cannot bury the rest of the history.
    func nudgeSelectedMarkup(dx: CGFloat, dy: CGFloat) {
        guard pendingTextAnchor == nil, let markup = selectedMarkup, let index = selectedMarkupIndex else { return }
        if lastNudgedMarkupID != selectedMarkupID {
            pushMarkupUndoSnapshot()
            lastNudgedMarkupID = selectedMarkupID
        }
        markups[index] = markup.moved(
            by: CGSize(width: dx / max(1, selectionRect.width), height: dy / max(1, selectionRect.height))
        )
    }

    func deleteSelectedMarkup() {
        guard pendingTextAnchor == nil, let index = selectedMarkupIndex else { return }
        pushMarkupUndoSnapshot()
        markups.remove(at: index)
        selectedMarkupID = nil
    }

    /// Escape drops the selection first, so a stray Escape while adjusting a box
    /// cannot throw the whole screenshot away.
    func dismissSelectionOrCancel() {
        if isEditing, selectedMarkupID != nil {
            selectedMarkupID = nil
            return
        }
        cancel()
    }

    private var hasUnfinishedMarkup: Bool {
        pendingTextAnchor != nil || !currentStrokePoints.isEmpty || currentMosaicRect != nil
    }

    private var selectedMarkupIndex: Int? {
        guard let selectedMarkupID else { return nil }
        return markups.firstIndex { $0.id == selectedMarkupID }
    }

    private func pushMarkupUndoSnapshot() {
        markupUndoStack.append(markups)
        if markupUndoStack.count > Self.markupUndoLimit {
            markupUndoStack.removeFirst()
        }
        lastNudgedMarkupID = nil
    }

    func saveEditingImage() {
        guard let image = renderedEditingImage() else { return }
        onSave?(image)
    }

    func copyEditingImage() {
        guard let image = renderedEditingImage() else { return }
        onCopy?(image)
    }

    func finishEditing() {
        guard let image = renderedEditingImage() else { return }
        onFinish?(image)
    }

    private func renderedEditingImage() -> CGImage? {
        commitPendingText()
        guard let capturedImage else { return nil }
        // The editor lays out markups in points over `selectionRect`; the captured
        // image is at pixel resolution. Pass the points→pixels ratio so strokes and
        // text are baked at the size the user drew, not half-size on Retina.
        let scale = CGFloat(capturedImage.width) / max(1, selectionRect.width)
        return ScreenshotMarkupRenderer.render(baseImage: capturedImage, markups: markups, scale: scale) ?? capturedImage
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        Self.clamped(rect, screenSize: screenSize)
    }

    private static func clamped(_ rect: CGRect, screenSize: CGSize) -> CGRect {
        let width = min(max(1, rect.width), screenSize.width)
        let height = min(max(1, rect.height), screenSize.height)
        let x = min(max(0, rect.minX), max(0, screenSize.width - width))
        let y = min(max(0, rect.minY), max(0, screenSize.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct CaptureRegionSelectionView: View {
    @ObservedObject var model: CaptureRegionSelectionModel
    @State private var dragStart: CGPoint?
    @State private var isManualScreenshotSelection = false
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(selectionGesture(in: geometry.size))

                // The frozen screen sits under the dimming, so the selection shows the
                // still frame at full brightness and everything outside it dimmed.
                if !model.isEditing, let frozenScreen = model.frozenScreen {
                    Image(decorative: frozenScreen, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        .allowsHitTesting(false)
                }

                SelectionCutout(rect: model.selectionRect)
                    .fill(.black.opacity(0.58), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                if model.isEditing, let image = model.capturedImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: model.selectionRect.width, height: model.selectionRect.height)
                        .position(x: model.selectionRect.midX, y: model.selectionRect.midY)

                    ScreenshotInlineMarkupLayer(model: model, imageRect: model.selectionRect)

                    PendingScreenshotTextField(model: model, imageRect: model.selectionRect)
                        .focused($textFieldFocused)
                        .onSubmit {
                            model.commitPendingText()
                        }
                        .onChange(of: model.pendingTextAnchor != nil) { _, hasPendingText in
                            if hasPendingText {
                                DispatchQueue.main.async {
                                    textFieldFocused = true
                                }
                            }
                        }
                } else {
                    SelectionBorder(rect: model.selectionRect)
                        .fill(Color.accentColor.opacity(0.16))
                        .allowsHitTesting(false)
                }

                SelectionBorder(rect: model.selectionRect)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3))
                    .shadow(color: Color.accentColor.opacity(0.55), radius: 10)
                    .allowsHitTesting(false)

                SelectionBorder(rect: model.selectionRect)
                    .stroke(.white.opacity(0.86), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                    .allowsHitTesting(false)

                SelectionCornerHandles(rect: model.selectionRect)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.45), radius: 4)
                    .allowsHitTesting(false)

                if model.isEditing {
                    ScreenshotInlineToolbar(model: model)
                        .position(toolbarPosition(in: geometry.size))
                } else if model.purpose == .screenshot {
                    screenshotSelectionHint
                        .position(x: geometry.size.width / 2, y: 72)
                } else {
                    selectionToolbar
                        .padding(.top, 54)
                }
            }
        }
    }

    private var screenshotSelectionHint: some View {
        HStack(spacing: 10) {
            Label(
                model.isStarting ? tr("正在截图", "Capturing…") : "拖拽选区，悬停窗口后单击截取窗口",
                systemImage: model.isStarting ? "camera.viewfinder" : "cursorarrow.motionlines"
            )
            Divider()
                .frame(height: 18)
            Text(tr("Esc 取消", "Esc to cancel"))
                .foregroundStyle(.secondary)
        }
        .font(.callout.weight(.medium))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 12)
    }

    private var selectionToolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Label(model.purpose.title, systemImage: "rectangle.dashed")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)

                Divider()
                    .frame(height: 22)

                Text("\(Int(model.selectionRect.width)) x \(Int(model.selectionRect.height))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 110, alignment: .leading)

                Button {
                    model.selectFullScreen()
                } label: {
                    Label(tr("全屏", "Full screen"), systemImage: "rectangle.inset.filled")
                }
                .disabled(model.isStarting)

                Button(role: .cancel) {
                    model.cancel()
                } label: {
                    Label(tr("取消", "Cancel"), systemImage: "xmark")
                }
                .disabled(model.isStarting)

                Button {
                    model.confirmSelection()
                } label: {
                    Label(
                        model.isStarting ? model.purpose.startingTitle : model.purpose.confirmTitle,
                        systemImage: model.purpose.confirmSystemImage
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 12)

            Text(model.purpose.hint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.86))
                .shadow(radius: 4)
        }
    }

    private func selectionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: model.purpose == .screenshot ? 0 : 8)
            .onChanged { value in
                if model.purpose == .screenshot {
                    let movement = distance(from: value.startLocation, to: value.location)
                    guard movement >= 5 || isManualScreenshotSelection else { return }
                    isManualScreenshotSelection = true
                }
                if dragStart == nil {
                    dragStart = value.startLocation
                }
                model.updateSelection(from: dragStart ?? value.startLocation, to: value.location)
            }
            .onEnded { value in
                if model.purpose == .screenshot {
                    if isManualScreenshotSelection, model.canStart {
                        model.confirmSelection()
                    } else if distance(from: value.startLocation, to: value.location) < 5 {
                        model.confirmHoveredWindowSelection()
                    }
                    isManualScreenshotSelection = false
                }
                dragStart = nil
            }
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    private func toolbarPosition(in size: CGSize) -> CGPoint {
        let rect = model.selectionRect
        let horizontalPadding: CGFloat = 24
        let halfToolbarWidth = min(390, max(160, size.width / 2 - horizontalPadding))
        let x = min(max(rect.midX, halfToolbarWidth + horizontalPadding), max(halfToolbarWidth + horizontalPadding, size.width - halfToolbarWidth - horizontalPadding))
        let belowY = rect.maxY + 44
        let aboveY = rect.minY - 44
        // The editing toolbar carries a hint line, so it needs more room than the bare row.
        let y = belowY + 56 < size.height ? belowY : max(52, aboveY)
        return CGPoint(x: x, y: y)
    }
}

private struct ScreenshotInlineToolbar: View {
    @ObservedObject var model: CaptureRegionSelectionModel

    var body: some View {
        VStack(spacing: 6) {
            toolbarRow
            Text(tr(
                "拖动标注可移动，拖角点改大小，Delete 删除，方向键微调",
                "Drag a markup to move it, drag a grip to resize, Delete removes, arrow keys nudge"
            ))
            .font(.caption)
            .foregroundStyle(.white.opacity(0.86))
            .shadow(radius: 4)
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: 7) {
            ForEach(ScreenshotEditingTool.allCases, id: \.self) { tool in
                Button {
                    model.selectScreenshotTool(tool)
                } label: {
                    Label(tool.title, systemImage: tool.symbol)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .tint(model.selectedScreenshotTool == tool ? .accentColor : .secondary)
                .help(tool.title)
            }

            Divider()
                .frame(height: 22)

            Button {
                model.deleteSelectedMarkup()
            } label: {
                Label(tr("删除所选", "Delete selected"), systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .disabled(model.selectedMarkupID == nil)
            .help(tr("删除所选标注（Delete）", "Delete the selected markup (Delete)"))

            Button {
                model.undoLastMarkup()
            } label: {
                Label(tr("撤销", "Undo"), systemImage: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            .disabled(!model.canUndoMarkup)
            .help(tr("撤销", "Undo"))

            Button {
                model.clearMarkups()
            } label: {
                Label(tr("清空", "Clear"), systemImage: "trash.slash")
            }
            .labelStyle(.iconOnly)
            .disabled(!model.canClearMarkup)
            .help(tr("清空", "Clear"))

            Divider()
                .frame(height: 22)

            Button {
                model.copyEditingImage()
            } label: {
                Label(tr("复制", "Copy"), systemImage: "doc.on.doc")
            }

            Button {
                model.saveEditingImage()
            } label: {
                Label(tr("保存", "Save"), systemImage: "square.and.arrow.down")
            }

            Button(role: .cancel) {
                model.cancel()
            } label: {
                Label(tr("取消", "Cancel"), systemImage: "xmark")
            }

            Button {
                model.finishEditing()
            } label: {
                Label(tr("完成", "Done"), systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 12)
    }
}

private struct PendingScreenshotTextField: View {
    @ObservedObject var model: CaptureRegionSelectionModel
    let imageRect: CGRect

    var body: some View {
        if let anchor = model.pendingTextAnchor {
            TextField(tr("文字", "Text"), text: $model.pendingText)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(minWidth: 96, maxWidth: 260, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.7), lineWidth: 1)
                )
                .position(
                    x: imageRect.minX + CGFloat(anchor.x) * imageRect.width + 52,
                    y: imageRect.minY + CGFloat(anchor.y) * imageRect.height + 18
                )
        }
    }
}

private struct ScreenshotInlineMarkupLayer: View {
    /// What the current drag is doing. Decided once, on the drag's first event, from
    /// whatever sits under the pointer where it started.
    private enum MarkupDragMode: Equatable {
        case draw
        case move
        case resize(ScreenshotMarkupHandle)
        /// A drag that neither draws nor grabs anything — select mode on bare pixels.
        case idle
    }

    @ObservedObject var model: CaptureRegionSelectionModel
    let imageRect: CGRect
    @State private var activeTextStart: CGPoint?
    @State private var dragMode: MarkupDragMode?

    var body: some View {
        Canvas { context, _ in
            for markup in model.markups {
                draw(markup, in: &context)
            }
            drawCurrentStroke(in: &context)
            drawCurrentMosaic(in: &context)
            drawSelectionChrome(in: &context)
        }
        .contentShape(Rectangle())
        .gesture(markupGesture)
    }

    private var markupGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let mode = dragMode ?? beginDrag(at: value.startLocation)
                dragMode = mode
                switch mode {
                case .resize(let handle):
                    model.resizeSelectedMarkup(handle: handle, to: normalizedPoint(value.location))
                case .move:
                    model.dragSelectedMarkup(
                        translation: ScreenshotMarkupGeometry.normalizedTranslation(value.translation, in: imageRect)
                    )
                case .draw:
                    continueDrawing(value)
                case .idle:
                    break
                }
            }
            .onEnded { value in
                switch dragMode {
                case .move, .resize:
                    model.endMarkupDrag()
                case .draw:
                    finishDrawing(value)
                case .idle, .none:
                    break
                }
                dragMode = nil
            }
    }

    /// Grips first, then a grabbable markup, then drawing — so a finished markup can
    /// always be picked back up, while a press on bare screenshot still starts a new one.
    private func beginDrag(at location: CGPoint) -> MarkupDragMode {
        if let selected = model.selectedMarkup,
           let handle = ScreenshotMarkupGeometry.handle(for: selected, at: location, in: imageRect) {
            model.beginMarkupDrag()
            return .resize(handle)
        }
        if let grabbed = grabbableMarkup(at: location) {
            model.selectMarkup(id: grabbed.id)
            model.beginMarkupDrag()
            return .move
        }
        model.selectMarkup(id: nil)
        guard model.selectedScreenshotTool.isDrawingTool, imageRect.contains(location) else { return .idle }
        return .draw
    }

    /// In select mode any markup can be picked up. While a drawing tool is active only
    /// the current selection is grabbable, so pressing inside an existing shape draws a
    /// new one instead of dragging the old one away.
    private func grabbableMarkup(at location: CGPoint) -> ScreenshotMarkup? {
        guard model.selectedScreenshotTool.isDrawingTool else {
            // Topmost first, and a filled hit inside closed shapes — in select mode
            // nothing is being drawn, so grabbing a box by its middle is what you want.
            return model.markups.reversed().first {
                ScreenshotMarkupGeometry.hitTest($0, at: location, in: imageRect, includingInterior: true)
            }
        }
        guard let selected = model.selectedMarkup,
              ScreenshotMarkupGeometry.hitTest(selected, at: location, in: imageRect) else {
            return nil
        }
        return selected
    }

    private func continueDrawing(_ value: DragGesture.Value) {
        guard imageRect.contains(value.location) else { return }
        let point = normalizedPoint(value.location)
        switch model.selectedScreenshotTool {
        case .select:
            break
        case .text:
            if activeTextStart == nil {
                activeTextStart = value.startLocation
            }
        case .mosaic:
            model.updateMosaic(from: normalizedPoint(value.startLocation), to: point)
        case .pen, .highlight, .line, .arrow, .rectangle, .ellipse:
            if model.currentStrokePoints.isEmpty {
                model.beginStroke(at: point)
            } else {
                model.appendStrokePoint(point)
            }
        }
    }

    private func finishDrawing(_ value: DragGesture.Value) {
        guard imageRect.contains(value.location) else {
            activeTextStart = nil
            model.finishStroke()
            model.finishMosaic()
            return
        }
        switch model.selectedScreenshotTool {
        case .select:
            break
        case .text:
            if distance(from: activeTextStart ?? value.startLocation, to: value.location) < 8 {
                model.beginText(at: normalizedPoint(value.location))
            }
            activeTextStart = nil
        case .mosaic:
            model.finishMosaic()
        case .pen, .highlight, .line, .arrow, .rectangle, .ellipse:
            model.finishStroke()
        }
    }

    private func draw(_ markup: ScreenshotMarkup, in context: inout GraphicsContext) {
        switch markup {
        case .stroke(let annotation):
            draw(annotation, in: &context)
        case .text(let text):
            draw(text, in: &context)
        case .mosaic(let mosaic):
            drawMosaic(rect: mosaic.rect, in: &context)
        }
    }

    private func drawCurrentStroke(in context: inout GraphicsContext) {
        guard let tool = model.selectedScreenshotTool.annotationTool, model.currentStrokePoints.count > 1 else { return }
        draw(
            AnnotationEvent(
                time: 0,
                tool: tool,
                points: model.currentStrokePoints,
                colorHex: tool == .highlight ? AnnotationStyle.highlightColorHex : AnnotationStyle.penColorHex,
                lineWidth: tool == .highlight ? 18 : 5
            ),
            in: &context
        )
    }

    private func drawCurrentMosaic(in context: inout GraphicsContext) {
        guard let rect = model.currentMosaicRect else { return }
        drawMosaic(rect: rect, in: &context)
    }

    /// The dashed box and grips around the selected markup. They live only in this
    /// preview layer — the exported PNG is rendered from `markups` alone.
    private func drawSelectionChrome(in context: inout GraphicsContext) {
        guard let markup = model.selectedMarkup else { return }

        let bounds = ScreenshotMarkupGeometry.boundingRect(for: markup, in: imageRect).insetBy(dx: -6, dy: -6)
        if bounds.width > 0, bounds.height > 0 {
            let outline = Path(roundedRect: bounds, cornerRadius: 5)
            context.stroke(outline, with: .color(.black.opacity(0.38)), style: StrokeStyle(lineWidth: 2.5))
            context.stroke(outline, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        }

        let radius = ScreenshotMarkupGeometry.handleRadius
        for spec in ScreenshotMarkupGeometry.handles(for: markup, in: imageRect) {
            let circle = Path(
                ellipseIn: CGRect(
                    x: spec.position.x - radius,
                    y: spec.position.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            context.fill(circle, with: .color(.white))
            context.stroke(circle, with: .color(.accentColor), lineWidth: 2)
        }
    }

    private func draw(_ annotation: AnnotationEvent, in context: inout GraphicsContext) {
        // Same path the hit-testing uses, so a stroke is grabbable exactly where it shows.
        let path = ScreenshotMarkupGeometry.path(for: annotation, in: imageRect)
        guard !path.isEmpty else { return }

        let color = Color(annotationHex: annotation.colorHex, tool: annotation.tool)
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: annotation.lineWidth, lineCap: .round, lineJoin: .round)
        )

        guard annotation.tool == .arrow, annotation.points.count >= 2 else { return }
        let points = annotation.points.map { ScreenshotMarkupGeometry.viewPoint($0.point, in: imageRect) }
        drawArrowHead(context: &context, from: points[points.count - 2], to: points[points.count - 1], color: color)
    }

    private func draw(_ text: ScreenshotTextMarkup, in context: inout GraphicsContext) {
        let point = ScreenshotMarkupGeometry.viewPoint(text.anchor, in: imageRect)
        context.draw(
            Text(text.text)
                .font(.system(size: text.fontSize, weight: .semibold))
                .foregroundStyle(.red),
            at: point,
            anchor: .topLeading
        )
    }

    private func drawMosaic(rect: NormalizedRect, in context: inout GraphicsContext) {
        let displayRect = ScreenshotMarkupGeometry.viewRect(rect, in: imageRect)
        let path = Path(roundedRect: displayRect, cornerRadius: 3)
        context.fill(path, with: .color(.gray.opacity(0.46)))
        context.stroke(path, with: .color(.white.opacity(0.72)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

        let step: CGFloat = 10
        var grid = Path()
        var x = displayRect.minX + step
        while x < displayRect.maxX {
            grid.move(to: CGPoint(x: x, y: displayRect.minY))
            grid.addLine(to: CGPoint(x: x, y: displayRect.maxY))
            x += step
        }
        var y = displayRect.minY + step
        while y < displayRect.maxY {
            grid.move(to: CGPoint(x: displayRect.minX, y: y))
            grid.addLine(to: CGPoint(x: displayRect.maxX, y: y))
            y += step
        }
        context.stroke(grid, with: .color(.black.opacity(0.24)), lineWidth: 1)
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

    private func normalizedPoint(_ point: CGPoint) -> NormalizedPoint {
        ScreenshotMarkupGeometry.normalizedPoint(point, in: imageRect)
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
}

private struct SelectionCutout: Shape {
    let rect: CGRect

    func path(in bounds: CGRect) -> Path {
        var path = Path(bounds)
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
        return path
    }
}

private struct SelectionBorder: Shape {
    let rect: CGRect

    func path(in bounds: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: 6)
    }
}

private struct SelectionCornerHandles: Shape {
    let rect: CGRect

    func path(in bounds: CGRect) -> Path {
        var path = Path()
        let length = min(30, max(12, min(rect.width, rect.height) * 0.22))

        addCorner(to: &path, origin: CGPoint(x: rect.minX, y: rect.minY), horizontal: length, vertical: length)
        addCorner(to: &path, origin: CGPoint(x: rect.maxX, y: rect.minY), horizontal: -length, vertical: length)
        addCorner(to: &path, origin: CGPoint(x: rect.minX, y: rect.maxY), horizontal: length, vertical: -length)
        addCorner(to: &path, origin: CGPoint(x: rect.maxX, y: rect.maxY), horizontal: -length, vertical: -length)

        return path
    }

    private func addCorner(to path: inout Path, origin: CGPoint, horizontal: CGFloat, vertical: CGFloat) {
        path.move(to: origin)
        path.addLine(to: CGPoint(x: origin.x + horizontal, y: origin.y))
        path.move(to: origin)
        path.addLine(to: CGPoint(x: origin.x, y: origin.y + vertical))
    }
}
