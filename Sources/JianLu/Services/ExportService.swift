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

    func export(project: RecordingProject, prefix: String = "export") async throws -> URL {
        isExporting = true
        progress = 0
        defer {
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

        var cameraTrackID: CMPersistentTrackID?
        if let cameraURL = project.cameraRecordingURL {
            cameraTrackID = try addCameraTrack(
                from: cameraURL,
                to: composition,
                project: project
            )
        }
        if let microphoneURL = project.microphoneRecordingURL {
            try addMicrophoneTrack(from: microphoneURL, to: composition, project: project)
        }

        let renderSize = normalizedRenderSize(for: screenTrack)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        if let cameraTrackID {
            videoComposition.customVideoCompositorClass = CameraShapeVideoCompositor.self
            videoComposition.instructions = [
                CameraShapeVideoCompositionInstruction(
                    timeRange: CMTimeRange(start: .zero, duration: cursor),
                    screenTrackID: compositionVideo.trackID,
                    cameraTrackID: cameraTrackID,
                    renderSize: renderSize,
                    zoomStates: project.exportedZoomStates(),
                    cameraStates: project.exportedCameraLayoutStates()
                )
            ]
        } else {
            let screenInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideo)
            applyZoomEvents(project: project, to: screenInstruction, renderSize: renderSize)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
            instruction.layerInstructions = [screenInstruction]
            videoComposition.instructions = [instruction]
        }
        videoComposition.animationTool = makeAnimationTool(project: project, renderSize: renderSize, duration: CMTimeGetSeconds(cursor))

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
        project: RecordingProject
    ) throws -> CMPersistentTrackID? {
        let cameraAsset = AVURLAsset(url: cameraURL)
        guard let cameraTrack = cameraAsset.tracks(withMediaType: .video).first,
              let compositionCamera = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }

        let cameraDuration = CMTimeGetSeconds(cameraAsset.duration)
        var cursor = CMTime.zero
        var insertedCameraVideo = false
        for segment in project.timeline.segments where segment.sourceStart < cameraDuration {
            let availableDuration = max(0, min(segment.duration, cameraDuration - segment.sourceStart))
            guard availableDuration > 0 else {
                cursor = cursor + CMTime(seconds: segment.duration, preferredTimescale: 600)
                continue
            }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: availableDuration, preferredTimescale: 600)
            )
            try compositionCamera.insertTimeRange(sourceRange, of: cameraTrack, at: cursor)
            insertedCameraVideo = true
            cursor = cursor + CMTime(seconds: segment.duration, preferredTimescale: 600)
        }

        guard insertedCameraVideo else {
            return nil
        }

        return compositionCamera.trackID
    }

    private func addMicrophoneTrack(
        from microphoneURL: URL,
        to composition: AVMutableComposition,
        project: RecordingProject
    ) throws {
        let microphoneAsset = AVURLAsset(url: microphoneURL)
        guard let microphoneTrack = microphoneAsset.tracks(withMediaType: .audio).first,
              let compositionMicrophone = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return
        }

        let microphoneDuration = CMTimeGetSeconds(microphoneAsset.duration)
        var cursor = CMTime.zero
        for segment in project.timeline.segments where segment.sourceStart < microphoneDuration {
            let availableDuration = max(0, min(segment.duration, microphoneDuration - segment.sourceStart))
            guard availableDuration > 0 else { continue }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: availableDuration, preferredTimescale: 600)
            )
            try compositionMicrophone.insertTimeRange(sourceRange, of: microphoneTrack, at: cursor)
            cursor = cursor + CMTime(seconds: segment.duration, preferredTimescale: 600)
        }
    }

    private func makeAnimationTool(project: RecordingProject, renderSize: CGSize, duration: TimeInterval) -> AVVideoCompositionCoreAnimationTool? {
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.isGeometryFlipped = true

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        let annotationContainer = CALayer()
        annotationContainer.frame = parentLayer.bounds
        applyZoomAnimation(to: annotationContainer, project: project, renderSize: renderSize, duration: duration)
        parentLayer.addSublayer(annotationContainer)

        for event in project.events {
            if case .annotation(let annotation) = event {
                annotationContainer.addSublayer(annotationLayer(annotation, renderSize: renderSize))
            }
        }

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
    }

    private func applyZoomEvents(
        project: RecordingProject,
        to instruction: AVMutableVideoCompositionLayerInstruction,
        renderSize: CGSize
    ) {
        let states = project.exportedZoomStates()
        guard let first = states.first else {
            instruction.setTransform(zoomTransform(magnification: 1, focus: NormalizedPoint(x: 0.5, y: 0.5), renderSize: renderSize), at: .zero)
            return
        }

        instruction.setTransform(
            zoomTransform(magnification: first.magnification, focus: first.focus, renderSize: renderSize),
            at: .zero
        )

        for state in states.dropFirst() {
            instruction.setTransform(
                zoomTransform(magnification: state.magnification, focus: state.focus, renderSize: renderSize),
                at: CMTime(seconds: state.time, preferredTimescale: 600)
            )
        }
    }

    private func applyZoomAnimation(
        to layer: CALayer,
        project: RecordingProject,
        renderSize: CGSize,
        duration: TimeInterval
    ) {
        guard duration > 0 else { return }
        let states = project.exportedZoomStates()
        guard !states.isEmpty else { return }

        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.duration = duration
        animation.calculationMode = .discrete
        animation.values = states.map {
            CATransform3DMakeAffineTransform(
                zoomTransform(magnification: $0.magnification, focus: $0.focus, renderSize: renderSize)
            )
        }
        animation.keyTimes = states.map { NSNumber(value: min(max($0.time / duration, 0), 1)) }
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        layer.add(animation, forKey: "zoom")
    }

    private func zoomTransform(magnification: Double, focus: NormalizedPoint, renderSize: CGSize) -> CGAffineTransform {
        let scale = CGFloat(min(max(magnification, 1), 3))
        let focusX = CGFloat(focus.x) * renderSize.width
        let focusY = CGFloat(focus.y) * renderSize.height
        return CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: focusX * (1 - scale),
            ty: focusY * (1 - scale)
        )
    }

    private func annotationLayer(_ annotation: AnnotationEvent, renderSize: CGSize) -> CAShapeLayer {
        let path = CGMutablePath()
        let points = annotation.points.map {
            CGPoint(x: $0.point.x * renderSize.width, y: $0.point.y * renderSize.height)
        }

        if let first = points.first {
            path.move(to: first)

            switch annotation.tool {
            case .rectangle, .ellipse:
                if let last = points.last {
                    let rect = CGRect(
                        x: min(first.x, last.x),
                        y: min(first.y, last.y),
                        width: abs(last.x - first.x),
                        height: abs(last.y - first.y)
                    )
                    if annotation.tool == .ellipse {
                        path.addEllipse(in: rect)
                    } else {
                        path.addRoundedRect(in: rect, cornerWidth: 4, cornerHeight: 4)
                    }
                }
            case .line, .arrow:
                if let last = points.last {
                    path.addLine(to: last)
                    if annotation.tool == .arrow {
                        addArrowHead(to: path, from: points.dropLast().last ?? first, to: last)
                    }
                }
            case .pen, .highlight:
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

    private func addArrowHead(to path: CGMutablePath, from start: CGPoint, to end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 18
        let spread: CGFloat = .pi / 7
        let left = CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread))
        let right = CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread))

        path.move(to: left)
        path.addLine(to: end)
        path.addLine(to: right)
    }

    private func nsColor(for annotation: AnnotationEvent) -> NSColor {
        annotation.tool == .highlight ? NSColor.systemYellow.withAlphaComponent(0.35) : .systemRed
    }

    private func normalizedRenderSize(for track: AVAssetTrack) -> CGSize {
        let size = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }
}
