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
                .help("拖动工具栏")
                .gesture(dragGesture)

            Divider()
                .frame(height: 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ControlBarButton(title: overlay.isPaused ? "继续" : "暂停", symbol: overlay.isPaused ? "play.fill" : "pause.fill", isActive: overlay.isPaused) {
                        overlay.requestTogglePause()
                    }
                    ControlBarButton(title: "结束", symbol: "stop.fill", isActive: true, tint: .red) {
                        overlay.requestStop()
                    }

                    Divider()
                        .frame(height: 24)

                    ControlBarButton(title: overlay.zoomFollowModeEnabled ? "放大已开" : "放大", symbol: "plus.magnifyingglass", isActive: overlay.zoomFollowModeEnabled) {
                        overlay.toggleFollowZoomMode()
                    }
                    ControlBarButton(title: overlay.zoomClickModeEnabled ? "点击已开" : "点击模式", symbol: "cursorarrow.click.2", isActive: overlay.zoomClickModeEnabled) {
                        overlay.requestToggleClickZoomMode()
                    }

                    Divider()
                        .frame(height: 24)

                    ControlBarButton(title: "画笔", symbol: "pencil", isActive: overlay.selectedTool == .pen) {
                        overlay.selectTool(.pen)
                    }
                    ControlBarButton(title: "箭头", symbol: "arrow.up.right", isActive: overlay.selectedTool == .arrow) {
                        overlay.selectTool(.arrow)
                    }
                    ControlBarButton(title: "清除", symbol: "trash.slash", isActive: false, isDisabled: overlay.isPaused) {
                        overlay.clearAllAnnotations()
                    }

                    MoreControlMenu(overlay: overlay)

                    if overlay.isTransientZoomActive {
                        Text("缩放中 \(String(format: "%.1f", overlay.zoomMagnification))x")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                    }

                    if overlay.isPaused {
                        Text("已暂停")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 10)
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
                Label("缩小倍率", systemImage: "minus.magnifyingglass")
            }
            Button {
                overlay.adjustZoom(by: 0.2)
            } label: {
                Label("放大倍率", systemImage: "plus.magnifyingglass")
            }
            Text("当前倍率 \(String(format: "%.1f", overlay.zoomMagnification))x")

            Divider()

            Button {
                overlay.selectTool(.highlight)
            } label: {
                Label("高亮", systemImage: "highlighter")
            }
            Button {
                overlay.selectTool(.line)
            } label: {
                Label("直线", systemImage: "line.diagonal")
            }
            Button {
                overlay.selectTool(.rectangle)
            } label: {
                Label("方框", systemImage: "square")
            }
            Button {
                overlay.selectTool(.ellipse)
            } label: {
                Label("圆框", systemImage: "circle")
            }

            Divider()

            Button {
                overlay.toggleCameraShape()
            } label: {
                Label("头像框：\(overlay.cameraShape.displayName)", systemImage: "rectangle.on.rectangle")
            }
            Button {
                overlay.undoLastAnnotation()
            } label: {
                Label("撤销上一笔", systemImage: "arrow.uturn.backward")
            }
            .disabled(overlay.isPaused)
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(minWidth: 58, minHeight: 30)
                .padding(.horizontal, 6)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("更多功能")
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
