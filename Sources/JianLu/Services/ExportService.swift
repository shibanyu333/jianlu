import AVFoundation
import AppKit
import Foundation
import JianLuCore
import QuartzCore

enum ExportServiceError: LocalizedError {
    case missingVideoTrack
    case emptyTimeline
    case cannotCreateExportSession
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            "录屏文件里没有找到视频轨道。"
        case .emptyTimeline:
            "没有可导出的录制片段。"
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
    private var activeExportSession: AVAssetExportSession?

    func cancelCurrentExport() {
        activeExportSession?.cancelExport()
        activeExportSession = nil
        isExporting = false
        progress = 0
    }

    func export(project: RecordingProject, prefix: String = "export") async throws -> URL {
        isExporting = true
        progress = 0
        defer {
            activeExportSession = nil
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

        let screenAsset = AVURLAsset(url: project.screenRecordingURL)
        guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportServiceError.missingVideoTrack
        }

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportServiceError.missingVideoTrack
        }

        let screenAudioTracks = try await screenAsset.loadTracks(withMediaType: .audio)

        var cursor = CMTime.zero
        for segment in project.timeline.segments {
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
            )
            try compositionVideo.insertTimeRange(sourceRange, of: screenTrack, at: cursor)
            cursor = cursor + sourceRange.duration
        }
        try addScreenAudioTracks(screenAudioTracks, to: composition, project: project)

        var cameraTrackID: CMPersistentTrackID?
        if let cameraURL = project.cameraRecordingURL {
            cameraTrackID = try await addCameraTrack(
                from: cameraURL,
                to: composition,
                project: project
            )
        }
        if let microphoneURL = project.microphoneRecordingURL {
            try await addMicrophoneTrack(from: microphoneURL, to: composition, project: project)
        }

        let renderSize = try await normalizedRenderSize(for: screenTrack)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let zoomStates = project.exportedZoomStates()
        let hasActiveZoom = zoomStates.contains { $0.magnification > 1.001 }
        if cameraTrackID != nil || hasActiveZoom {
            videoComposition.customVideoCompositorClass = CameraShapeVideoCompositor.self
            videoComposition.instructions = [
                CameraShapeVideoCompositionInstruction(
                    timeRange: CMTimeRange(start: .zero, duration: cursor),
                    screenTrackID: compositionVideo.trackID,
                    cameraTrackID: cameraTrackID,
                    renderSize: renderSize,
                    zoomStates: zoomStates,
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

        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true
        activeExportSession = exportSession

        do {
            try await exportSession.export(to: outputURL, as: .mov)
            return outputURL
        } catch {
            throw ExportServiceError.exportFailed(error.localizedDescription)
        }
    }

    private func addCameraTrack(
        from cameraURL: URL,
        to composition: AVMutableComposition,
        project: RecordingProject
    ) async throws -> CMPersistentTrackID? {
        let cameraAsset = AVURLAsset(url: cameraURL)
        guard let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first,
              let compositionCamera = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }

        let cameraDuration = CMTimeGetSeconds(try await cameraAsset.load(.duration))
        var cursor = CMTime.zero
        var insertedCameraVideo = false
        for segment in project.timeline.segments {
            guard let alignedRange = alignedMediaRange(
                for: segment,
                assetDuration: cameraDuration,
                sourceOffset: project.cameraRecordingOffset
            ) else {
                cursor = cursor + CMTime(seconds: segment.duration, preferredTimescale: 600)
                continue
            }

            try compositionCamera.insertTimeRange(
                alignedRange.sourceRange,
                of: cameraTrack,
                at: cursor + alignedRange.destinationOffset
            )
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
    ) async throws {
        let microphoneAsset = AVURLAsset(url: microphoneURL)
        guard let microphoneTrack = try await microphoneAsset.loadTracks(withMediaType: .audio).first,
              let compositionMicrophone = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return
        }

        let microphoneDuration = CMTimeGetSeconds(try await microphoneAsset.load(.duration))
        var cursor = CMTime.zero
        for segment in project.timeline.segments {
            guard let alignedRange = alignedMediaRange(
                for: segment,
                assetDuration: microphoneDuration,
                sourceOffset: project.microphoneRecordingOffset
            ) else {
                cursor = cursor + CMTime(seconds: segment.duration, preferredTimescale: 600)
                continue
            }

            try compositionMicrophone.insertTimeRange(
                alignedRange.sourceRange,
                of: microphoneTrack,
                at: cursor + alignedRange.destinationOffset
            )
            cursor = cursor + CMTime(seconds: segment.duration, preferredTimescale: 600)
        }
    }

    private func addScreenAudioTracks(
        _ screenAudioTracks: [AVAssetTrack],
        to composition: AVMutableComposition,
        project: RecordingProject
    ) throws {
        for screenAudioTrack in screenAudioTracks {
            guard let compositionAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }

            var cursor = CMTime.zero
            for segment in project.timeline.segments {
                let sourceRange = CMTimeRange(
                    start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
                )
                try compositionAudio.insertTimeRange(sourceRange, of: screenAudioTrack, at: cursor)
                cursor = cursor + sourceRange.duration
            }
        }
    }

    private struct AlignedMediaRange {
        var sourceRange: CMTimeRange
        var destinationOffset: CMTime
    }

    private func alignedMediaRange(
        for segment: EditSegment,
        assetDuration: TimeInterval,
        sourceOffset: TimeInterval
    ) -> AlignedMediaRange? {
        let rawSourceStart = segment.sourceStart + sourceOffset
        let destinationDelay = max(0, -rawSourceStart)
        let sourceStart = max(0, rawSourceStart)
        let duration = min(segment.duration - destinationDelay, assetDuration - sourceStart)
        guard duration > 0 else { return nil }

        return AlignedMediaRange(
            sourceRange: CMTimeRange(
                start: CMTime(seconds: sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            ),
            destinationOffset: CMTime(seconds: destinationDelay, preferredTimescale: 600)
        )
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

        for timedAnnotation in timedAnnotations(project: project, duration: duration) {
            let layer = annotationLayer(timedAnnotation.annotation, renderSize: renderSize)
            applyVisibility(
                to: layer,
                start: timedAnnotation.annotation.time,
                end: timedAnnotation.visibleUntil,
                duration: duration
            )
            annotationContainer.addSublayer(layer)
        }

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
    }

    private struct TimedAnnotation {
        var annotation: AnnotationEvent
        var visibleUntil: TimeInterval
    }

    private func timedAnnotations(project: RecordingProject, duration: TimeInterval) -> [TimedAnnotation] {
        guard duration > 0 else { return [] }

        var annotations: [TimedAnnotation] = []
        var activeIndicesByID: [UUID: Int] = [:]

        for event in project.exportedAnnotationEvents().sorted(by: { $0.time < $1.time }) {
            let eventTime = min(max(event.time, 0), duration)
            switch event {
            case .annotation(var annotation):
                if let activeIndex = activeIndicesByID[annotation.id] {
                    annotations[activeIndex].visibleUntil = min(annotations[activeIndex].visibleUntil, eventTime)
                }
                annotation.time = eventTime
                annotations.append(TimedAnnotation(annotation: annotation, visibleUntil: duration))
                activeIndicesByID[annotation.id] = annotations.count - 1
            case .annotationClear:
                for index in activeIndicesByID.values {
                    annotations[index].visibleUntil = min(annotations[index].visibleUntil, eventTime)
                }
                activeIndicesByID.removeAll()
            default:
                break
            }
        }

        return annotations.filter { $0.visibleUntil - $0.annotation.time > 0.001 }
    }

    private func applyVisibility(to layer: CALayer, start: TimeInterval, end: TimeInterval, duration: TimeInterval) {
        let start = min(max(start, 0), duration)
        let end = min(max(end, start), duration)
        guard duration > 0, start > 0.001 || end < duration - 0.001 else {
            layer.opacity = 1
            return
        }

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.duration = duration
        animation.calculationMode = .discrete
        var values: [NSNumber] = []
        var keyTimes: [NSNumber] = []
        appendOpacityKey(time: 0, opacity: start <= 0.001 ? 1 : 0, values: &values, keyTimes: &keyTimes)
        if start > 0.001 {
            appendOpacityKey(time: start / duration, opacity: 1, values: &values, keyTimes: &keyTimes)
        }
        let endTime = min(max(end / duration, 0), 1)
        appendOpacityKey(time: endTime, opacity: 1, values: &values, keyTimes: &keyTimes)
        if end < duration - 0.001 {
            appendOpacityKey(time: min(1, endTime + 0.0001), opacity: 0, values: &values, keyTimes: &keyTimes)
        }
        appendOpacityKey(time: 1, opacity: end >= duration - 0.001 ? 1 : 0, values: &values, keyTimes: &keyTimes)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.opacity = 0
        layer.add(animation, forKey: "annotationVisibility")
    }

    private func appendOpacityKey(
        time: TimeInterval,
        opacity: Float,
        values: inout [NSNumber],
        keyTimes: inout [NSNumber]
    ) {
        let normalizedTime = min(max(time, 0), 1)
        if let last = keyTimes.last?.doubleValue, abs(last - normalizedTime) < 0.000001 {
            values[values.count - 1] = NSNumber(value: opacity)
            return
        }

        values.append(NSNumber(value: opacity))
        keyTimes.append(NSNumber(value: normalizedTime))
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

    private func normalizedRenderSize(for track: AVAssetTrack) async throws -> CGSize {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let size = naturalSize.applying(preferredTransform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }
}
