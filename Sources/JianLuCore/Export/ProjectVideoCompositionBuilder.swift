@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

public enum ProjectVideoCompositionBuilderError: LocalizedError {
    case missingVideoTrack
    case emptyTimeline

    public var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            tr("录屏文件里没有找到视频轨道。", "The recording has no video track.")
        case .emptyTimeline:
            tr("没有可导出的录制片段。", "There is nothing to export.")
        }
    }
}

public struct ProjectVideoCompositionBuildResult {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let duration: CMTime

    public init(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        duration: CMTime
    ) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.duration = duration
    }
}

public enum ProjectVideoCompositionBuilder {
    public static func build(project: RecordingProject) async throws -> ProjectVideoCompositionBuildResult {
        guard !project.timeline.segments.isEmpty else {
            throw ProjectVideoCompositionBuilderError.emptyTimeline
        }

        let screenAsset = AVURLAsset(url: project.screenRecordingURL)
        guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ProjectVideoCompositionBuilderError.missingVideoTrack
        }
        let screenDuration = CMTimeGetSeconds(try await screenAsset.load(.duration))
        let effectiveProject = projectClampedToScreenDuration(project, screenDuration: screenDuration)
        guard !effectiveProject.timeline.segments.isEmpty else {
            throw ProjectVideoCompositionBuilderError.emptyTimeline
        }

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ProjectVideoCompositionBuilderError.missingVideoTrack
        }

        var cursor = CMTime.zero
        for segment in effectiveProject.timeline.segments {
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: segment.duration, preferredTimescale: 600)
            )
            try compositionVideo.insertTimeRange(sourceRange, of: screenTrack, at: cursor)
            cursor = cursor + sourceRange.duration
        }

        let screenAudioTracks = try await screenAsset.loadTracks(withMediaType: .audio)
        try addScreenAudioTracks(screenAudioTracks, to: composition, project: effectiveProject)

        let cameraTrackID: CMPersistentTrackID?
        if let cameraURL = effectiveProject.cameraRecordingURL {
            cameraTrackID = try await addCameraTrack(from: cameraURL, to: composition, project: effectiveProject)
        } else {
            cameraTrackID = nil
        }

        if let microphoneURL = effectiveProject.microphoneRecordingURL {
            try await addMicrophoneTrack(from: microphoneURL, to: composition, project: effectiveProject)
        }

        let renderSize = try await normalizedRenderSize(for: screenTrack)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let zoomStates = effectiveProject.exportedZoomStates()
        let annotationEvents = effectiveProject.exportedAnnotationEvents()
        let hasActiveZoom = zoomStates.contains { $0.magnification > 1.001 }
        let usesCustomCompositor = cameraTrackID != nil || hasActiveZoom || !annotationEvents.isEmpty

        if usesCustomCompositor {
            videoComposition.customVideoCompositorClass = CameraShapeVideoCompositor.self
            videoComposition.instructions = [
                CameraShapeVideoCompositionInstruction(
                    timeRange: CMTimeRange(start: .zero, duration: cursor),
                    screenTrackID: compositionVideo.trackID,
                    cameraTrackID: cameraTrackID,
                    renderSize: renderSize,
                    strokeScale: annotationStrokeScale(
                        renderSize: renderSize,
                        region: effectiveProject.preferences.lastSelectedRegion
                    ),
                    zoomStates: zoomStates,
                    annotationEvents: annotationEvents,
                    cameraStates: effectiveProject.exportedCameraLayoutStates()
                )
            ]
        } else {
            let screenInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideo)
            screenInstruction.setTransform(.identity, at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
            instruction.layerInstructions = [screenInstruction]
            videoComposition.instructions = [instruction]
        }

        return ProjectVideoCompositionBuildResult(
            composition: composition,
            videoComposition: videoComposition,
            duration: cursor
        )
    }

    private static func projectClampedToScreenDuration(
        _ project: RecordingProject,
        screenDuration: TimeInterval
    ) -> RecordingProject {
        guard screenDuration.isFinite, screenDuration > 0 else {
            return project
        }

        let segments = project.timeline.segments.compactMap { segment -> EditSegment? in
            let sourceStart = min(max(0, segment.sourceStart), screenDuration)
            let sourceEnd = min(max(sourceStart, segment.sourceEnd), screenDuration)
            guard sourceEnd - sourceStart > 0.001 else { return nil }
            return EditSegment(id: segment.id, sourceStart: sourceStart, sourceEnd: sourceEnd)
        }

        var clampedProject = project
        clampedProject.timeline = EditTimeline(segments: segments)
        clampedProject.sourceDuration = min(project.sourceDuration, screenDuration)
        return clampedProject
    }

    private static func addCameraTrack(
        from cameraURL: URL,
        to composition: AVMutableComposition,
        project: RecordingProject
    ) async throws -> CMPersistentTrackID? {
        let cameraAsset = AVURLAsset(url: cameraURL)
        guard let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first,
              let compositionCamera = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
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

        return insertedCameraVideo ? compositionCamera.trackID : nil
    }

    private static func addMicrophoneTrack(
        from microphoneURL: URL,
        to composition: AVMutableComposition,
        project: RecordingProject
    ) async throws {
        let microphoneAsset = AVURLAsset(url: microphoneURL)
        guard let microphoneTrack = try await microphoneAsset.loadTracks(withMediaType: .audio).first,
              let compositionMicrophone = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
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

    private static func addScreenAudioTracks(
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

    private static func alignedMediaRange(
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

    /// points→pixels scale so exported annotation strokes keep the thickness the
    /// presenter saw live. `renderSize` is the region's pixel size; the recording
    /// region width is in points, so the ratio is the display's backing scale.
    private static func annotationStrokeScale(renderSize: CGSize, region: RecordingRegion?) -> CGFloat {
        guard let region, region.width > 1, region.height > 1 else { return 1 }
        let scaleX = renderSize.width / region.width
        let scaleY = renderSize.height / region.height
        let scale = (scaleX + scaleY) / 2
        return scale.isFinite && scale > 0 ? scale : 1
    }

    private static func normalizedRenderSize(for track: AVAssetTrack) async throws -> CGSize {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        return CGSize(
            width: max(1, abs(transformed.width)),
            height: max(1, abs(transformed.height))
        )
    }
}
