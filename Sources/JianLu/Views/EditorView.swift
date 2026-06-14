import AVKit
import JianLuCore
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var playheadRatio = 0.5
    @State private var selectedSegmentID: UUID?

    let project: RecordingProject

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("剪辑")
                        .font(.title2.weight(.semibold))
                    Text(project.screenRecordingURL.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    appState.exportProject(project.id)
                } label: {
                    Label("导出成片", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isExporting)
            }

            if let previewMessage = appState.previewMessage(for: project) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(appState.isRenderingPreview(for: project) ? 1 : 0)
                    Text(previewMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if appState.activeExportProjectID == project.id {
                HStack(spacing: 10) {
                    ProgressView(value: appState.exportProgress)
                        .frame(width: 180)
                    Text("正在导出成片 \(Int(appState.exportProgress * 100))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        appState.cancelExportIntent(for: project.id)
                    } label: {
                        Label(appState.isCancellingExport ? "正在取消" : "取消导出", systemImage: "xmark.circle")
                    }
                    .disabled(appState.isCancellingExport)
                }
            }

            PlayerPreview(url: appState.previewURL(for: project))
                .frame(minHeight: 250)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                Slider(value: $playheadRatio, in: 0...1)
                HStack {
                    Text("播放头：\(Int(playheadRatio * max(1, project.duration))) 秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        appState.splitProject(project.id, atExportRatio: playheadRatio)
                    } label: {
                        Label("分割", systemImage: "scissors")
                    }
                    .disabled(appState.isExporting || !project.timeline.canSplit(atExportRatio: playheadRatio))
                    Button {
                        if let selectedSegmentID {
                            appState.deleteSegment(selectedSegmentID, in: project.id)
                        }
                    } label: {
                        Label("删除选中片段", systemImage: "trash")
                    }
                    .disabled(appState.isExporting || project.timeline.segments.count <= 1 || selectedSegmentID == nil)
                }
            }

            SegmentStripView(segments: project.timeline.segments, selectedSegmentID: $selectedSegmentID)

            if let exportMessage = appState.exportMessage(for: project) {
                Text(exportMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            ensureSelectedSegment()
        }
        .onChange(of: project.id) { _, _ in
            selectedSegmentID = project.timeline.segments.first?.id
        }
        .onChange(of: project.timeline.segments) { _, _ in
            ensureSelectedSegment()
        }
    }

    private func ensureSelectedSegment() {
        guard let selectedSegmentID,
              project.timeline.segments.contains(where: { $0.id == selectedSegmentID }) else {
            self.selectedSegmentID = project.timeline.segments.first?.id
            return
        }
    }
}

private struct PlayerPreview: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.player = AVPlayer(url: url)
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        playerView.player = AVPlayer(url: url)
    }

    final class Coordinator {
        var url: URL

        init(url: URL) {
            self.url = url
        }
    }
}

private struct SegmentStripView: View {
    let segments: [EditSegment]
    @Binding var selectedSegmentID: UUID?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(segments) { segment in
                Button {
                    selectedSegmentID = segment.id
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Int(segment.duration.rounded())) 秒")
                            .font(.caption.weight(.medium))
                        Text("\(Int(segment.sourceStart))-\(Int(segment.sourceEnd))")
                            .font(.caption2)
                            .foregroundStyle(selectedSegmentID == segment.id ? .white.opacity(0.82) : .secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSegmentID == segment.id ? .white : .primary)
                .background(
                    selectedSegmentID == segment.id ? Color.accentColor : Color.accentColor.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
        }
    }
}
