import AVKit
import JianLuCore
import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var appState: AppState
    @State private var playheadRatio = 0.5

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
                        appState.deleteLastSegment(project.id)
                    } label: {
                        Label("删除末段", systemImage: "trash")
                    }
                    .disabled(appState.isExporting || project.timeline.segments.count <= 1)
                }
            }

            SegmentStripView(segments: project.timeline.segments)

            if let exportMessage = appState.exportMessage(for: project) {
                Text(exportMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
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

    var body: some View {
        HStack(spacing: 4) {
            ForEach(segments) { segment in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Int(segment.duration.rounded())) 秒")
                        .font(.caption.weight(.medium))
                    Text("\(Int(segment.sourceStart))-\(Int(segment.sourceEnd))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
