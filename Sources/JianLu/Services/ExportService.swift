import AVFoundation
import AppKit
import Foundation
import JianLuCore
import QuartzCore

enum ExportServiceError: LocalizedError {
    case missingVideoTrack
    case cannotCreateExportSession
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            "录屏文件里没有找到视频轨道。"
        case .cannotCreateExportSession:
            "无法创建导出任务。"
        case .exportFailed(let message):
            "导出失败：\(message)"
        }
    }
}

@MainActor
final class ExportService: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0

    func export(project: RecordingProject) async throws -> URL {
        isExporting = true
        progress = 0
        defer {
            isExporting = false
            progress = 0
        }

        let outputURL = try RecordingFileStore.makeRecordingURL(prefix: "export")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let screenAsset = AVURLAsset(url: project.screenRecordingURL)
        guard let screenTrack = screenAsset.tracks(withMediaType: .video).first else {
            throw ExportServiceError.missingVideoTrack
        }

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportServiceError.missingVideoTrack
        }

        let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let screenAudioTracks = screenAsset.tracks(withMediaType: .audio)

        var cursor = CMTime.zero
        for segment in project.timeline.segments {
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
            )
            try compositionVideo.insertTimeRange(sourceRange, of: screenTrack, at: cursor)
            for audioTrack in screenAudioTracks {
                try compositionAudio?.insertTimeRange(sourceRange, of: audioTrack, at: cursor)
            }
            cursor = cursor + sourceRange.duration
        }

        var layerInstructions: [AVVideoCompositionLayerInstruction] = [
            AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideo)
        ]

        if let cameraURL = project.cameraRecordingURL {
            try addCameraTrack(
                from: cameraURL,
                to: composition,
                project: project,
                layerInstructions: &layerInstructions
            )
        }

        let renderSize = normalizedRenderSize(for: screenTrack)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instruction.layerInstructions = layerInstructions

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]
        videoComposition.animationTool = makeAnimationTool(project: project, renderSize: renderSize)

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportServiceError.cannotCreateExportSession
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                continuation.resume()
            }
        }

        if exportSession.status == .completed {
            return outputURL
        }

        throw ExportServiceError.exportFailed(exportSession.error?.localizedDescription ?? "未知错误")
    }

    private func addCameraTrack(
        from cameraURL: URL,
        to composition: AVMutableComposition,
        project: RecordingProject,
        layerInstructions: inout [AVVideoCompositionLayerInstruction]
    ) throws {
        let cameraAsset = AVURLAsset(url: cameraURL)
        guard let cameraTrack = cameraAsset.tracks(withMediaType: .video).first,
              let compositionCamera = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return
        }

        var cursor = CMTime.zero
        for segment in project.timeline.segments {
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
            )
            try compositionCamera.insertTimeRange(sourceRange, of: cameraTrack, at: cursor)
            cursor = cursor + sourceRange.duration
        }

        let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionCamera)
        let frame = latestCameraLayout(in: project)?.frame ?? .defaultCameraFrame
        let renderSize = normalizedRenderSize(for: composition.tracks(withMediaType: .video).first ?? cameraTrack)
        let cameraSize = normalizedRenderSize(for: cameraTrack)
        let targetWidth = renderSize.width * frame.width
        let targetHeight = renderSize.height * frame.height
        let scale = min(targetWidth / max(1, cameraSize.width), targetHeight / max(1, cameraSize.height))
        let translation = CGAffineTransform(translationX: renderSize.width * frame.x, y: renderSize.height * frame.y)
        let transform = cameraTrack.preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(translation)
        instruction.setTransform(transform, at: .zero)
        layerInstructions.insert(instruction, at: 0)
    }

    private func makeAnimationTool(project: RecordingProject, renderSize: CGSize) -> AVVideoCompositionCoreAnimationTool? {
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = true

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        for event in project.events {
            if case .annotation(let annotation) = event {
                parentLayer.addSublayer(annotationLayer(annotation, renderSize: renderSize))
            }
        }

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
    }

    private func annotationLayer(_ annotation: AnnotationEvent, renderSize: CGSize) -> CAShapeLayer {
        let path = CGMutablePath()
        let points = annotation.points.map {
            CGPoint(x: $0.point.x * renderSize.width, y: $0.point.y * renderSize.height)
        }
        if let first = points.first {
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
        }

        let layer = CAShapeLayer()
        layer.frame = CGRect(origin: .zero, size: renderSize)
        layer.path = path
        layer.fillColor = nil
        layer.strokeColor = nsColor(for: annotation).cgColor
        layer.lineWidth = annotation.lineWidth
        layer.lineCap = .round
        layer.lineJoin = .round
        return layer
    }

    private func nsColor(for annotation: AnnotationEvent) -> NSColor {
        annotation.tool == .highlight ? NSColor.systemYellow.withAlphaComponent(0.35) : .systemRed
    }

    private func latestCameraLayout(in project: RecordingProject) -> CameraLayoutEvent? {
        project.events.compactMap { event in
            if case .cameraLayout(let layout) = event {
                return layout
            }
            return nil
        }.last
    }

    private func normalizedRenderSize(for track: AVAssetTrack) -> CGSize {
        let size = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }
}
