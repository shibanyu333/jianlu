import Foundation
import CoreGraphics
@preconcurrency import AVFoundation
import QuartzCore
import JianLuCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Check failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct JianLuCoreChecks {
    static func main() async {
        expect(CoreVersion.name == "JianLuCore", "core module exposes its name")
        runTimelineChecks()
        runPermissionGateChecks()
        runPreferenceChecks()
        runZoomLensGeometryChecks()

        do {
            try await runVideoCompositorChecks()
        } catch {
            fputs("Video compositor check failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("JianLuCoreChecks passed")
    }
}

private func runTimelineChecks() {
    var timeline = EditTimeline.fullLength(duration: 12)
    let splitResult = timeline.split(at: 5)

    expect(splitResult, "timeline splits at a valid source time")
    expect(timeline.segments.count == 2, "split creates two segments")
    expect(timeline.totalExportDuration == 12, "split preserves export duration")

    let trailingSegmentID = timeline.segments[1].id
    expect(timeline.deleteSegment(id: trailingSegmentID), "deletes an existing segment")
    expect(timeline.totalExportDuration == 5, "deleting trailing segment shortens export")
    expect(timeline.exportTime(forSourceTime: 4) == 4, "maps kept source time into export time")
    expect(timeline.exportTime(forSourceTime: 7) == nil, "deleted source time is not exportable")

    let onlySegmentID = timeline.segments[0].id
    expect(!timeline.deleteSegment(id: onlySegmentID), "timeline refuses to delete the final remaining segment")
    expect(timeline.segments.count == 1, "timeline keeps one segment after refusing final deletion")
    expect(timeline.totalExportDuration == 5, "timeline duration is unchanged after refused final deletion")

    let cameraLayout = CameraLayoutEvent(
        time: 3,
        frame: NormalizedRect(x: 0.72, y: 0.62, width: 0.22, height: 0.22),
        shape: .circle,
        isVisible: true
    )
    let project = RecordingProject(
        screenRecordingURL: URL(fileURLWithPath: "/tmp/screen.mov"),
        cameraRecordingURL: URL(fileURLWithPath: "/tmp/camera.mov"),
        microphoneRecordingURL: URL(fileURLWithPath: "/tmp/microphone.caf"),
        events: [.cameraLayout(cameraLayout)],
        timeline: timeline
    )

    expect(project.duration == 5, "project duration follows edit timeline")
    expect(project.events.count == 1, "project stores camera layout events")
    expect(project.microphoneRecordingURL?.lastPathComponent == "microphone.caf", "project stores independent microphone audio")
    expect(project.needsRenderedPreview, "projects with effects need a rendered preview")

    let rawProject = RecordingProject(
        screenRecordingURL: URL(fileURLWithPath: "/tmp/raw.mov"),
        cameraRecordingURL: nil,
        events: [],
        timeline: .fullLength(duration: 3)
    )
    expect(!rawProject.needsRenderedPreview, "plain raw projects can use the original recording preview")

    let hiddenCameraOnlyProject = RecordingProject(
        screenRecordingURL: URL(fileURLWithPath: "/tmp/hidden-camera.mov"),
        cameraRecordingURL: nil,
        events: [
            .cameraLayout(
                CameraLayoutEvent(
                    time: 0,
                    frame: .defaultCameraFrame,
                    shape: .circle,
                    isVisible: false
                )
            )
        ],
        timeline: .fullLength(duration: 3)
    )
    expect(!hiddenCameraOnlyProject.needsRenderedPreview, "hidden camera layout alone does not require rendered preview")

    let trimmedTailProject = RecordingProject(
        screenRecordingURL: URL(fileURLWithPath: "/tmp/trimmed-tail.mov"),
        cameraRecordingURL: nil,
        sourceDuration: 12,
        events: [],
        timeline: EditTimeline(segments: [EditSegment(sourceStart: 0, sourceEnd: 5)])
    )
    expect(trimmedTailProject.needsRenderedPreview, "single-segment tail trims need a rendered preview")

    let legacyProjectJSON = """
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "createdAt": 0,
      "screenRecordingURL": "file:///tmp/legacy-screen.mov",
      "cameraRecordingURL": null,
      "microphoneRecordingURL": null,
      "preferences": {
        "includeAppInterface": false,
        "microphoneEnabled": true,
        "microphoneNoiseReductionEnabled": false,
        "cameraBackgroundStyle": "original",
        "cameraBackgroundBlur": "light",
        "cameraBeautyLevel": 0.25
      },
      "events": [],
      "timeline": {
        "segments": [
          {
            "id": "00000000-0000-0000-0000-000000000002",
            "sourceStart": 0,
            "sourceEnd": 4
          }
        ]
      }
    }
    """
    let legacyProject = try? JSONDecoder().decode(
        RecordingProject.self,
        from: Data(legacyProjectJSON.utf8)
    )
    expect(legacyProject?.sourceDuration == 4, "legacy projects derive source duration from the timeline")

    let roundTrippedData = try? JSONEncoder().encode(trimmedTailProject)
    let roundTrippedProject = roundTrippedData.flatMap {
        try? JSONDecoder().decode(RecordingProject.self, from: $0)
    }
    expect(roundTrippedProject?.sourceDuration == 12, "project round trip preserves source duration")
    expect(roundTrippedProject?.needsRenderedPreview == true, "project round trip preserves rendered preview requirements")

    let zoomedProject = RecordingProject(
        screenRecordingURL: URL(fileURLWithPath: "/tmp/zoomed.mov"),
        cameraRecordingURL: nil,
        events: [
            .zoom(ZoomEvent(time: 0.5, magnification: 1.8, focus: NormalizedPoint(x: 0.25, y: 0.35))),
            .zoom(ZoomEvent(time: 2, magnification: 1, focus: NormalizedPoint(x: 0.25, y: 0.35))),
            .zoom(ZoomEvent(time: 7, magnification: 2.2, focus: NormalizedPoint(x: 0.75, y: 0.4))),
            .zoom(ZoomEvent(time: 9, magnification: 1, focus: NormalizedPoint(x: 0.75, y: 0.4)))
        ],
        timeline: EditTimeline(
            segments: [
                EditSegment(sourceStart: 0, sourceEnd: 4),
                EditSegment(sourceStart: 6, sourceEnd: 10)
            ]
        )
    )
    let zoomStates = zoomedProject.exportedZoomStates()
    expect(zoomStates.map(\.time) == [0, 0.5, 2, 5, 7], "zoom states are remapped through edited timeline")
    expect(zoomStates[1].magnification == 1.8, "hold zoom records the enlarged state")
    expect(zoomStates[3].focus == NormalizedPoint(x: 0.75, y: 0.4), "zoom focus is preserved after trimming")

    let cameraTimelineProject = RecordingProject(
        screenRecordingURL: URL(fileURLWithPath: "/tmp/camera-layout.mov"),
        cameraRecordingURL: URL(fileURLWithPath: "/tmp/camera-layout-camera.mov"),
        events: [
            .cameraLayout(CameraLayoutEvent(time: 0, frame: .defaultCameraFrame, shape: .circle, isVisible: true)),
            .cameraLayout(CameraLayoutEvent(time: 2, frame: NormalizedRect(x: 0.08, y: 0.10, width: 0.20, height: 0.20), shape: .circle, isVisible: true)),
            .cameraLayout(CameraLayoutEvent(time: 5, frame: NormalizedRect(x: 0.08, y: 0.10, width: 0.20, height: 0.20), shape: .circle, isVisible: false)),
            .cameraLayout(CameraLayoutEvent(time: 8, frame: NormalizedRect(x: 0.60, y: 0.55, width: 0.24, height: 0.24), shape: .square, isVisible: true))
        ],
        timeline: EditTimeline(
            segments: [
                EditSegment(sourceStart: 0, sourceEnd: 4),
                EditSegment(sourceStart: 7, sourceEnd: 10)
            ]
        )
    )
    let cameraStates = cameraTimelineProject.exportedCameraLayoutStates()
    expect(cameraStates.map(\.time) == [0, 2, 4, 5], "camera layout states are remapped through edited timeline")
    expect(cameraStates[2].isVisible == false, "camera hidden state in a trimmed gap carries into the next kept segment")
    expect(cameraStates[3].shape == .square, "camera shape changes are preserved for export")
    expect(cameraStates[3].frame == NormalizedRect(x: 0.60, y: 0.55, width: 0.24, height: 0.24), "camera frame changes are preserved for export")
}

private func runPreferenceChecks() {
    let smallRegion = RecordingRegion(displayID: 1, x: 10, y: 10, width: 40, height: 40)
    expect(!smallRegion.isUsable, "tiny recording regions are rejected")

    let usableRegion = RecordingRegion(displayID: 1, x: 20, y: 30, width: 640, height: 360)
    expect(usableRegion.isUsable, "normal recording regions are usable")
    let retinaSourceRect = usableRegion.sourceRect(
        displayPixelWidth: 2880,
        displayPixelHeight: 1800,
        displayPointWidth: 1440,
        displayPointHeight: 900
    )
    expect(retinaSourceRect == CGRect(x: 40, y: 60, width: 1280, height: 720), "retina source rect converts points to pixels")

    let overflowingRegion = RecordingRegion(displayID: 1, x: 1400, y: 880, width: 200, height: 200)
    let clampedSourceRect = overflowingRegion.sourceRect(
        displayPixelWidth: 2880,
        displayPixelHeight: 1800,
        displayPointWidth: 1440,
        displayPointHeight: 900
    )
    expect(clampedSourceRect == CGRect(x: 2480, y: 1400, width: 400, height: 400), "source rect clamps after scaling to pixels")

    let preferences = RecordingPreferences(
        includeAppInterface: false,
        cameraEnabled: false,
        microphoneEnabled: false,
        microphoneNoiseReductionEnabled: true,
        cameraBackgroundStyle: .graphite,
        cameraBackgroundBlur: .medium,
        cameraBeautyLevel: 4,
        zoomShortcut: .controlOptionSpace,
        recordingDirectoryPath: "/tmp/jianlu-checks",
        lastSelectedRegion: usableRegion
    )
    expect(!preferences.cameraEnabled, "camera preference can be disabled")
    expect(!preferences.microphoneEnabled, "microphone preference can be disabled")
    expect(preferences.microphoneNoiseReductionEnabled, "microphone noise reduction preference can be enabled")
    expect(preferences.cameraBeautyLevel == 1, "beauty level is clamped")
    expect(preferences.zoomShortcut == .controlOptionSpace, "zoom shortcut preference is stored")
    expect(!preferences.zoomShortcut.displayName.isEmpty, "zoom shortcut has a display name")
    expect(preferences.recordingDirectoryPath == "/tmp/jianlu-checks", "recording directory path is stored")
    expect(preferences.lastSelectedRegion == usableRegion, "last selected region is stored")
    expect(AnnotationTool.rectangle.isShapeTool, "rectangle annotation is a shape tool")
    expect(AnnotationTool.ellipse.isShapeTool, "ellipse annotation is a shape tool")
    expect(CameraBackgroundStyle.allCases.contains(.office), "real office background is available")

    let legacyPreferencesJSON = """
    {
      "includeAppInterface": true,
      "microphoneEnabled": true,
      "microphoneNoiseReductionEnabled": false,
      "cameraBackgroundStyle": "office",
      "cameraBackgroundBlur": "light",
      "cameraBeautyLevel": 0.3,
      "recordingDirectoryPath": "/tmp/legacy-jianlu"
    }
    """
    let legacyPreferences = try? JSONDecoder().decode(
        RecordingPreferences.self,
        from: Data(legacyPreferencesJSON.utf8)
    )
    expect(legacyPreferences?.zoomShortcut == .controlOptionCommandZ, "legacy preferences get the default zoom shortcut")
    expect(legacyPreferences?.cameraEnabled == true, "legacy preferences keep camera enabled by default")
    expect(legacyPreferences?.recordingDirectoryPath == "/tmp/legacy-jianlu", "legacy preferences keep the recording path")
}

private func runZoomLensGeometryChecks() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let region = RecordingRegion(displayID: 1, x: 100, y: 120, width: 600, height: 400)
    let focus = ZoomLensGeometry.normalizedFocus(
        mouseLocation: CGPoint(x: 400, y: 580),
        screenFrame: screenFrame,
        recordingRegion: region
    )
    expect(abs(focus.x - 0.5) < 0.001, "zoom focus uses the recording region x coordinate")
    expect(abs(focus.y - 0.5) < 0.001, "zoom focus uses top-origin recording region y coordinate")

    let fullScreenFocus = ZoomLensGeometry.normalizedFocus(
        mouseLocation: CGPoint(x: 720, y: 450),
        screenFrame: screenFrame,
        recordingRegion: nil
    )
    expect(abs(fullScreenFocus.x - 0.5) < 0.001, "full-screen zoom focus maps x into normalized space")
    expect(abs(fullScreenFocus.y - 0.5) < 0.001, "full-screen zoom focus maps y into normalized space")

    let lens = ZoomLensGeometry(lensSize: CGSize(width: 200, height: 200))
    let imageFrame = lens.zoomedImageFrame(
        captureSize: CGSize(width: 1000, height: 500),
        focus: NormalizedPoint(x: 0.25, y: 0.6),
        magnification: 2
    )
    expect(imageFrame.width == 2000, "zoom lens scales captured frame width by magnification")
    expect(imageFrame.height == 1000, "zoom lens scales captured frame height by magnification")
    expect(imageFrame.minX == -400, "zoom lens keeps the focus under the center horizontally")
    expect(imageFrame.minY == -500, "zoom lens keeps the focus under the center vertically")

    let clampedCenter = lens.clampedLensCenter(
        in: CGRect(x: 10, y: 20, width: 800, height: 400),
        focus: NormalizedPoint(x: 0.02, y: 0.03)
    )
    expect(clampedCenter == CGPoint(x: 110, y: 120), "zoom lens center is clamped inside the capture rect")

    let smallDiameter = ZoomLensGeometry.lensDiameter(for: CGSize(width: 80, height: 90))
    expect(smallDiameter == 72, "zoom lens stays visible for tiny recording regions")
    let largeDiameter = ZoomLensGeometry.lensDiameter(for: CGSize(width: 1920, height: 1080))
    expect(largeDiameter == 280, "zoom lens has a stable maximum size")
}

private func runVideoCompositorChecks() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("jianlu-core-checks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let screenURL = directory.appendingPathComponent("screen.mov")
    let cameraURL = directory.appendingPathComponent("camera.mov")
    let outputURL = directory.appendingPathComponent("composited.mov")
    let annotatedOutputURL = directory.appendingPathComponent("composited-annotated.mov")
    try makeSolidColorMovie(url: screenURL, size: CGSize(width: 200, height: 200), color: (r: 20, g: 70, b: 220))
    try makeSolidColorMovie(url: cameraURL, size: CGSize(width: 120, height: 120), color: (r: 230, g: 40, b: 30))
    try await exportSyntheticCompositorMovie(screenURL: screenURL, cameraURL: cameraURL, outputURL: outputURL, overlaysAnnotation: false)

    let frame = try await firstFrameImage(from: outputURL)
    let center = pixelColor(in: frame, x: 100, y: 100)
    let maskedCorner = pixelColor(in: frame, x: 52, y: 52)
    expect(center.r > 170 && center.g < 90 && center.b < 90, "circle camera compositor keeps camera visible at the center")
    expect(maskedCorner.b > 150 && maskedCorner.r < 100, "circle camera compositor masks the camera corners")

    try await exportSyntheticCompositorMovie(screenURL: screenURL, cameraURL: cameraURL, outputURL: annotatedOutputURL, overlaysAnnotation: true)
    let annotatedFrame = try await firstFrameImage(from: annotatedOutputURL)
    let annotatedCenter = pixelColor(in: annotatedFrame, x: 100, y: 100)
    expect(annotatedCenter.g > 150 && annotatedCenter.r < 120, "camera compositor still renders annotation overlays")
}

private func makeSolidColorMovie(
    url: URL,
    size: CGSize,
    color: (r: UInt8, g: UInt8, b: UInt8),
    frameCount: Int = 6
) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }

    let width = Int(size.width)
    let height = Int(size.height)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
    )

    guard writer.canAdd(input) else {
        throw CheckError("cannot add synthetic video input")
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw writer.error ?? CheckError("cannot start synthetic writer")
    }
    writer.startSession(atSourceTime: .zero)

    guard let pool = adaptor.pixelBufferPool else {
        throw CheckError("cannot create synthetic pixel buffer pool")
    }
    for frameIndex in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.01)
        }
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw CheckError("cannot create synthetic pixel buffer")
        }
        fill(pixelBuffer, width: width, height: height, color: color)
        let time = CMTime(value: CMTimeValue(frameIndex), timescale: 30)
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            throw writer.error ?? CheckError("cannot append synthetic frame")
        }
    }

    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
        semaphore.signal()
    }
    semaphore.wait()
    guard writer.status == .completed else {
        throw writer.error ?? CheckError("synthetic writer did not complete")
    }
}

private func fill(
    _ pixelBuffer: CVPixelBuffer,
    width: Int,
    height: Int,
    color: (r: UInt8, g: UInt8, b: UInt8)
) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<height {
        let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let offset = x * 4
            row[offset] = color.b
            row[offset + 1] = color.g
            row[offset + 2] = color.r
            row[offset + 3] = 255
        }
    }
}

private func exportSyntheticCompositorMovie(screenURL: URL, cameraURL: URL, outputURL: URL, overlaysAnnotation: Bool) async throws {
    let screenAsset = AVURLAsset(url: screenURL)
    let cameraAsset = AVURLAsset(url: cameraURL)
    guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first,
          let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first else {
        throw CheckError("synthetic assets are missing tracks")
    }

    let composition = AVMutableComposition()
    guard let compositionScreen = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let compositionCamera = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw CheckError("cannot create synthetic composition tracks")
    }

    let duration = CMTime(value: 6, timescale: 30)
    let range = CMTimeRange(start: .zero, duration: duration)
    try compositionScreen.insertTimeRange(range, of: screenTrack, at: .zero)
    try compositionCamera.insertTimeRange(range, of: cameraTrack, at: .zero)

    let videoComposition = AVMutableVideoComposition()
    videoComposition.customVideoCompositorClass = CameraShapeVideoCompositor.self
    videoComposition.renderSize = CGSize(width: 200, height: 200)
    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
    videoComposition.instructions = [
        CameraShapeVideoCompositionInstruction(
            timeRange: range,
            screenTrackID: compositionScreen.trackID,
            cameraTrackID: compositionCamera.trackID,
            renderSize: CGSize(width: 200, height: 200),
            zoomStates: [],
            cameraStates: [
                CameraLayoutEvent(
                    time: 0,
                    frame: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                    shape: .circle,
                    isVisible: true
                )
            ]
        )
    ]
    if overlaysAnnotation {
        videoComposition.animationTool = annotationAnimationTool(renderSize: CGSize(width: 200, height: 200))
    }

    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
        throw CheckError("cannot create synthetic export session")
    }
    export.videoComposition = videoComposition

    try await export.export(to: outputURL, as: .mov)
}

private func annotationAnimationTool(renderSize: CGSize) -> AVVideoCompositionCoreAnimationTool {
    let parentLayer = CALayer()
    parentLayer.frame = CGRect(origin: .zero, size: renderSize)
    parentLayer.isGeometryFlipped = true

    let videoLayer = CALayer()
    videoLayer.frame = parentLayer.bounds
    parentLayer.addSublayer(videoLayer)

    let marker = CALayer()
    marker.frame = CGRect(x: 88, y: 88, width: 24, height: 24)
    marker.backgroundColor = CGColor(red: 0.08, green: 0.90, blue: 0.18, alpha: 1)
    parentLayer.addSublayer(marker)

    return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)
}

private func firstFrameImage(from url: URL) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try await generator.image(at: CMTime(value: 1, timescale: 30)).image
}

private func pixelColor(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let clampedX = min(max(0, x), width - 1)
    let clampedY = min(max(0, y), height - 1)
    let offset = (clampedY * width + clampedX) * 4
    return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
}

private struct CheckError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private func runPermissionGateChecks() {
    let noScreen = RecordingPermissionState(
        screenRecordingGranted: false,
        cameraGranted: true,
        microphoneGranted: true
    )
    expect(
        RecordingPermissionGate.decision(for: noScreen, cameraEnabled: true) == .needsScreenRecordingPermission,
        "screen recording permission blocks recording startup"
    )

    let noCamera = RecordingPermissionState(
        screenRecordingGranted: true,
        cameraGranted: false,
        microphoneGranted: true
    )
    expect(
        RecordingPermissionGate.decision(for: noCamera, cameraEnabled: true) == .missingMediaPermissions(["摄像头"]),
        "enabled camera requires camera permission"
    )
    expect(
        RecordingPermissionGate.decision(for: noCamera, cameraEnabled: false) == .allowed,
        "disabled camera does not block recording"
    )

    let noMicrophone = RecordingPermissionState(
        screenRecordingGranted: true,
        cameraGranted: true,
        microphoneGranted: false
    )
    expect(
        RecordingPermissionGate.decision(for: noMicrophone, cameraEnabled: true, microphoneEnabled: false) == .allowed,
        "disabled microphone does not block recording"
    )
}
