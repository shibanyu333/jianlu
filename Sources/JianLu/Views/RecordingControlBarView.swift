import JianLuCore
import SwiftUI

struct RecordingControlBarView: View {
    @ObservedObject var overlay: OverlayService
    let onDragBy: (CGSize) -> Void

    @State private var previousDragTranslation: CGSize = .zero

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.headline)
                .frame(width: 28, height: 30)
                .foregroundStyle(.secondary)
                .help(tr("拖动工具栏", "Drag toolbar"))
                .gesture(dragGesture)

            Divider()
                .frame(height: 24)

            if overlay.isFinishing {
                finishingIndicator
            } else {
                controlRow
            }
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 10)
    }

    /// Stopping finalizes the movie, which can take several seconds. Saying so on the
    /// bar is the difference between "it's working" and "the button is broken".
    private var finishingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(tr("正在结束录制，请稍候…", "Finishing the recording…"))
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var controlRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ControlBarButton(title: overlay.isPaused ? tr("继续", "Resume") : tr("暂停", "Pause"), symbol: overlay.isPaused ? "play.fill" : "pause.fill", isActive: overlay.isPaused) {
                    overlay.requestTogglePause()
                }
                ControlBarButton(title: tr("结束", "Stop"), symbol: "stop.fill", isActive: true, tint: .red) {
                    overlay.requestStop()
                }

                Divider()
                    .frame(height: 24)

                ControlBarButton(title: overlay.zoomClickModeEnabled ? tr("鼠标放大已开", "Zoom on") : tr("鼠标放大", "Mouse zoom"), symbol: "plus.magnifyingglass", isActive: overlay.zoomClickModeEnabled) {
                    overlay.requestToggleClickZoomMode()
                }

                Divider()
                    .frame(height: 24)

                ControlBarButton(title: tr("画笔", "Pen"), symbol: "pencil", isActive: overlay.selectedTool == .pen) {
                    overlay.selectTool(.pen)
                }
                ControlBarButton(title: tr("箭头", "Arrow"), symbol: "arrow.up.right", isActive: overlay.selectedTool == .arrow) {
                    overlay.selectTool(.arrow)
                }
                ControlBarButton(title: tr("圆形", "Ellipse"), symbol: "circle", isActive: overlay.selectedTool == .ellipse) {
                    overlay.selectTool(.ellipse)
                }
                ControlBarButton(title: tr("清除", "Clear"), symbol: "trash.slash", isActive: false, isDisabled: overlay.isPaused) {
                    overlay.clearAllAnnotations()
                }

                MoreControlMenu(overlay: overlay)

                if overlay.isTransientZoomActive {
                    Text(tr("缩放中 ", "Zoom ") + "\(String(format: "%.1f", overlay.zoomMagnification))x")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                }

                if overlay.isPaused {
                    Text(tr("已暂停", "Paused"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let delta = CGSize(
                    width: value.translation.width - previousDragTranslation.width,
                    height: value.translation.height - previousDragTranslation.height
                )
                previousDragTranslation = value.translation
                onDragBy(delta)
            }
            .onEnded { _ in
                previousDragTranslation = .zero
            }
    }
}

private struct MoreControlMenu: View {
    @ObservedObject var overlay: OverlayService

    var body: some View {
        Menu {
            Button {
                overlay.adjustZoom(by: -0.2)
            } label: {
                Label(tr("缩小倍率", "Zoom out"), systemImage: "minus.magnifyingglass")
            }
            Button {
                overlay.adjustZoom(by: 0.2)
            } label: {
                Label(tr("放大倍率", "Zoom in"), systemImage: "plus.magnifyingglass")
            }
            Text(tr("当前倍率 ", "Current ") + "\(String(format: "%.1f", overlay.zoomMagnification))x")

            Divider()

            Button {
                overlay.selectTool(.highlight)
            } label: {
                Label(tr("高亮", "Highlight"), systemImage: "highlighter")
            }
            Button {
                overlay.selectTool(.line)
            } label: {
                Label(tr("直线", "Line"), systemImage: "line.diagonal")
            }
            Button {
                overlay.selectTool(.rectangle)
            } label: {
                Label(tr("方框", "Rectangle"), systemImage: "square")
            }
            Button {
                overlay.selectTool(.ellipse)
            } label: {
                Label(tr("圆框", "Ellipse"), systemImage: "circle")
            }

            Divider()

            Button {
                overlay.adjustCameraSize(by: -0.03)
            } label: {
                Label(tr("缩小头像框", "Smaller bubble"), systemImage: "minus.circle")
            }
            Button {
                overlay.adjustCameraSize(by: 0.03)
            } label: {
                Label(tr("放大头像框", "Bigger bubble"), systemImage: "plus.circle")
            }
            Text(tr("头像大小 ", "Bubble size ") + "\(Int(overlay.cameraFrame.width * 100))%")

            Divider()

            ForEach(CameraFrameShape.allCases, id: \.self) { shape in
                Button {
                    overlay.setCameraShape(shape)
                } label: {
                    Label(
                        tr("头像框：", "Bubble: ") + shape.displayName,
                        systemImage: shape.systemImageName
                    )
                }
            }

            Divider()

            Button {
                overlay.toggleCameraShape()
            } label: {
                Label(tr("切换头像框：", "Next shape: ") + overlay.cameraShape.displayName, systemImage: "rectangle.on.rectangle")
            }
            Button {
                overlay.undoLastAnnotation()
            } label: {
                Label(tr("撤销上一笔", "Undo last stroke"), systemImage: "arrow.uturn.backward")
            }
            .disabled(overlay.isPaused)
        } label: {
            Label(tr("更多", "More"), systemImage: "ellipsis.circle")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(minWidth: 58, minHeight: 30)
                .padding(.horizontal, 6)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(tr("更多功能", "More options"))
    }
}

private extension CameraFrameShape {
    var systemImageName: String {
        switch self {
        case .circle:
            "circle"
        case .ellipse:
            "oval"
        case .square:
            "square"
        case .roundedSquare:
            "app"
        }
    }
}

private struct ControlBarButton: View {
    let title: String
    let symbol: String
    let isActive: Bool
    var tint: Color = .accentColor
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(minWidth: 58, minHeight: 30)
                .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? .white : .primary)
        .background(isActive ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .opacity(isDisabled ? 0.45 : 1)
        .disabled(isDisabled)
        .help(title)
    }
}
