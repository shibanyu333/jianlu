import JianLuCore
import SwiftUI

@MainActor
final class CaptureRegionSelectionModel: ObservableObject {
    @Published var selectionRect: CGRect
    @Published var isStarting = false

    let displayID: UInt32
    let screenSize: CGSize
    private let onStart: (RecordingRegion) -> Void
    private let onCancel: () -> Void

    var canStart: Bool {
        !isStarting && selectionRect.width >= 80 && selectionRect.height >= 80
    }

    init(
        displayID: UInt32,
        screenSize: CGSize,
        initialRegion: RecordingRegion?,
        onStart: @escaping (RecordingRegion) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.displayID = displayID
        self.screenSize = screenSize
        self.onStart = onStart
        self.onCancel = onCancel

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
        guard !isStarting else { return }
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        selectionRect = clamped(
            CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        )
    }

    func selectFullScreen() {
        guard !isStarting else { return }
        selectionRect = CGRect(origin: .zero, size: screenSize)
    }

    func confirmSelection() {
        guard canStart, !isStarting else { return }
        isStarting = true
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

    func cancel() {
        guard !isStarting else { return }
        onCancel()
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

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(selectionGesture(in: geometry.size))

                SelectionCutout(rect: model.selectionRect)
                    .fill(.black.opacity(0.52), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                SelectionBorder(rect: model.selectionRect)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .shadow(color: .black.opacity(0.35), radius: 6)
                    .allowsHitTesting(false)

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Label("拖拽选择录制区域", systemImage: "rectangle.dashed")
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
                            Label("全屏", systemImage: "rectangle.inset.filled")
                        }
                        .disabled(model.isStarting)

                        Button(role: .cancel) {
                            model.cancel()
                        } label: {
                            Label("取消", systemImage: "xmark")
                        }
                        .disabled(model.isStarting)

                        Button {
                            model.confirmSelection()
                        } label: {
                            Label(model.isStarting ? "正在开始" : "开始录制", systemImage: "record.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStart)
                    }
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 12)

                    Text("也可以再次按主录制快捷键确认当前区域")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.86))
                        .shadow(radius: 4)
                }
                .padding(.top, 54)
            }
        }
    }

    private func selectionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = value.startLocation
                }
                model.updateSelection(from: dragStart ?? value.startLocation, to: value.location)
            }
            .onEnded { _ in
                dragStart = nil
            }
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
