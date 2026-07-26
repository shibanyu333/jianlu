import AVFoundation
import Foundation
import JianLuCore

enum ExportServiceError: LocalizedError {
    case missingVideoTrack
    case emptyTimeline
    case cannotCreateExportSession
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            tr("录屏文件里没有找到视频轨道。", "The recording has no video track.")
        case .emptyTimeline:
            tr("没有可导出的录制片段。", "There is nothing to export.")
        case .cannotCreateExportSession:
            tr("无法创建导出任务。", "Could not create the export session.")
        case .exportFailed(let message):
            "导出失败：\(message)"
        }
    }
}

@MainActor
final class ExportService: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    private var activeExportSession: AVAssetExportSession?
    private var progressTimer: Timer?

    func cancelCurrentExport() {
        activeExportSession?.cancelExport()
        activeExportSession = nil
        stopProgressPolling()
        isExporting = false
        progress = 0
    }

    func export(project: RecordingProject, prefix: String = "export") async throws -> URL {
        isExporting = true
        progress = 0
        defer {
            activeExportSession = nil
            stopProgressPolling()
            isExporting = false
            progress = 0
        }

        let outputURL = try RecordingFileStore.makeRecordingURL(
            prefix: prefix,
            directoryPath: project.preferences.recordingDirectoryPath
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        guard !project.timeline.segments.isEmpty else {
            throw ExportServiceError.emptyTimeline
        }

        let build = try await ProjectVideoCompositionBuilder.build(project: project)
        guard let exportSession = AVAssetExportSession(asset: build.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportServiceError.cannotCreateExportSession
        }

        exportSession.videoComposition = build.videoComposition
        exportSession.shouldOptimizeForNetworkUse = true
        activeExportSession = exportSession
        startProgressPolling(for: exportSession)

        do {
            try await exportSession.export(to: outputURL, as: .mov)
            progress = 1
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportServiceError.exportFailed(error.localizedDescription)
        }
    }

    private func startProgressPolling(for exportSession: AVAssetExportSession) {
        stopProgressPolling()
        let timer = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let exportSession = self.activeExportSession else { return }
                self.progress = Double(exportSession.progress)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
