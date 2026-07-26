import Foundation
import CoreGraphics
import CoreImage
@preconcurrency import AVFoundation
import QuartzCore
import JianLuCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Check failed: \(message)\n", stderr)
        exit(1)
    }
}

func expectClose(_ lhs: Double, _ rhs: Double, _ message: String) {
    expect(abs(lhs - rhs) < 0.0001, message)
}

@main
struct JianLuCoreChecks {
    static func main() async {
        expect(CoreVersion.name == "JianLuCore", "core module exposes its name")
        runTimelineChecks()
        runProjectLibraryChecks()
        runRecordingFileStoreChecks()
        runPermissionGateChecks()
        runPreferenceChecks()
        runZoomLensGeometryChecks()
        runCameraFrameProcessorChecks()
        runBeautyPipelineChecks()
        runAnnotationImageRendererChecks()
        runScreenshotMarkupRendererChecks()

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
    expect(!timeline.canSplit(atExportRatio: 0), "timeline cannot split at the start")
    expect(timeline.canSplit(atExportRatio: 0.5), "timeline can split inside a kept segment")
    expect(!timeline.canSplit(atExportRatio: 1), "timeline cannot split at the end")

    let onlySegmentID = timeline.segments[0].id
    expect(!timeline.deleteSegment(id: onlySegmentID), "timeline refuses to delete the final remaining segment")
    expect(timeline.segments.count == 1, "timeline keeps one segment after refusing final deletion")
    expect(timeline.totalExportDuration == 5, "timeline duration is unchanged after refused final deletion")

    let pauseTrimmedTimeline = EditTimeline.excluding(
        sourceDuration: 12,
        ranges: [
            EditSegment(sourceStart: 2, sourceEnd: 5),
            EditSegment(sourceStart: 8, sourceEnd: 10)
        ]
    )
    expect(
        pauseTrimmedTimeline.segments.map { [$0.sourceStart, $0.sourceEnd] } == [[0, 2], [5, 8], [10, 12]],
        "pause ranges are removed from the source timeline"
    )
    expect(pauseTrimmedTimeline.totalExportDuration == 7, "pause removal shortens export duration")
    expect(!pauseTrimmedTimeline.canSplit(atExportTime: 2), "timeline cannot split at a kept segment boundary")
    expect(pauseTrimmedTimeline.canSplit(atExportTime: 3), "timeline can split inside later kept segments")

    let allPausedTimeline = EditTimeline.excluding(
        sourceDuration: 6,
        ranges: [EditSegment(sourceStart: -1, sourceEnd: 8)]
    )
    expect(allPausedTimeline.segments.isEmpty, "an entirely paused recording has no exportable segments")

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
        cameraRecordingOffset: 0.25,
        microphoneRecordingOffset: 0.4,
        events: [.cameraLayout(cameraLayout)],
        timeline: timeline
    )

    expect(project.duration == 5, "project duration follows edit timeline")
    expect(project.events.count == 1, "project stores camera layout events")
    expect(project.microphoneRecordingURL?.lastPathComponent == "microphone.caf", "project stores independent microphone audio")
    expect(project.cameraRecordingOffset == 0.25, "project stores camera alignment offset")
    expect(project.microphoneRecordingOffset == 0.4, "project stores microphone alignment offset")
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
    expect(legacyProject?.cameraRecordingOffset == 0, "legacy projects default camera offset to zero")
    expect(legacyProject?.microphoneRecordingOffset == 0, "legacy projects default microphone offset to zero")

    let roundTrippedData = try? JSONEncoder().encode(trimmedTailProject)
    let roundTrippedProject = roundTrippedData.flatMap {
        try? JSONDecoder().decode(RecordingProject.self, from: $0)
    }
    expect(roundTrippedProject?.sourceDuration == 12, "project round trip preserves source duration")
    expect(roundTrippedProject?.cameraRecordingOffset == 0, "project round trip preserves default camera offset")
    expect(roundTrippedProject?.microphoneRecordingOffset == 0, "project round trip preserves default microphone offset")
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

    let annotation = AnnotationEvent(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
        time: 1,
        tool: .arrow,
        points: [
            StrokePoint(time: 1, point: NormalizedPoint(x: 0.1, y: 0.1)),
            StrokePoint(time: 1.4, point: NormalizedPoint(x: 0.4, y: 0.4))
        ],
        colorHex: "#FF3B30",
        lineWidth: 5
    )
    let laterAnnotation = AnnotationEvent(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        time: 6,
        tool: .highlight,
        points: [
            StrokePoint(time: 6, point: NormalizedPoint(x: 0.2, y: 0.2)),
            StrokePoint(time: 6.2, point: NormalizedPoint(x: 0.8, y: 0.2))
        ],
        colorHex: "#FFD43B",
        lineWidth: 18
    )
    let removedGapAnnotation = AnnotationEvent(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
        time: 3,
        tool: .rectangle,
        points: [
            StrokePoint(time: 3, point: NormalizedPoint(x: 0.12, y: 0.12)),
            StrokePoint(time: 3.2, point: NormalizedPoint(x: 0.48, y: 0.48))
        ],
        colorHex: "#FF3B30",
        lineWidth: 5
    )
    let annotatedProject = RecordingProject(
        screenRecordingURL: URL(fileURLWithPath: "/tmp/annotations.mov"),
        cameraRecordingURL: nil,
        events: [
            .annotation(annotation),
            .annotation(removedGapAnnotation),
            .annotation(laterAnnotation),
            .annotationClear(AnnotationClearEvent(time: 8))
        ],
        timeline: EditTimeline(
            segments: [
                EditSegment(sourceStart: 0, sourceEnd: 2),
                EditSegment(sourceStart: 5, sourceEnd: 10)
            ]
        )
    )
    let exportedAnnotationEvents = annotatedProject.exportedAnnotationEvents()
    expect(exportedAnnotationEvents.map(\.time) == [1, 2, 3, 5], "annotation and clear events are remapped through edited timeline")
    expect(!exportedAnnotationEvents.contains { event in
        if case .annotation(let annotation) = event {
            return annotation.id == removedGapAnnotation.id
        }
        return false
    }, "annotations created inside removed ranges do not leak into later kept segments")
    expect(exportedAnnotationEvents[1] == .annotation(AnnotationEvent(
        id: annotation.id,
        time: 2,
        tool: annotation.tool,
        points: [
            StrokePoint(time: 2, point: NormalizedPoint(x: 0.1, y: 0.1)),
            StrokePoint(time: 2, point: NormalizedPoint(x: 0.4, y: 0.4))
        ],
        colorHex: annotation.colorHex,
        lineWidth: annotation.lineWidth
    )), "active annotations carry into later kept segments")
    expect(exportedAnnotationEvents.last == .annotationClear(AnnotationClearEvent(time: 5)), "annotation clear events are remapped for export")

    let gapClearProject = RecordingProject(
        screenRecordingURL: URL(fileURLWithPath: "/tmp/gap-clear.mov"),
        cameraRecordingURL: nil,
        events: [
            .annotation(annotation),
            .annotationClear(AnnotationClearEvent(time: 3))
        ],
        timeline: EditTimeline(
            segments: [
                EditSegment(sourceStart: 0, sourceEnd: 2),
                EditSegment(sourceStart: 5, sourceEnd: 7)
            ]
        )
    )
    let gapClearEvents = gapClearProject.exportedAnnotationEvents()
    expect(gapClearEvents.map(\.time) == [1, 2], "clear events in removed ranges are applied at the next kept boundary")
    expect(gapClearEvents.last == .annotationClear(AnnotationClearEvent(time: 2)), "gap clear prevents old annotations from carrying forward")

    let boundaryClearProject = RecordingProject(
        screenRecordingURL: URL(fileURLWithPath: "/tmp/boundary-clear.mov"),
        cameraRecordingURL: nil,
        events: [
            .annotation(annotation),
            .annotationClear(AnnotationClearEvent(time: 5))
        ],
        timeline: EditTimeline(
            segments: [
                EditSegment(sourceStart: 0, sourceEnd: 2),
                EditSegment(sourceStart: 5, sourceEnd: 7)
            ]
        )
    )
    let boundaryClearEvents = boundaryClearProject.exportedAnnotationEvents()
    expect(boundaryClearEvents == [
        .annotation(annotation),
        .annotationClear(AnnotationClearEvent(time: 2))
    ], "clear events at a kept segment boundary prevent stale annotations from carrying forward")
}

private func runProjectLibraryChecks() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("jianlu-project-library-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var projects: [RecordingProject] = []
        for index in 0..<4 {
            let screenURL = directory.appendingPathComponent("screen-\(index).mov")
            FileManager.default.createFile(atPath: screenURL.path, contents: Data("screen-\(index)".utf8))
            projects.append(
                RecordingProject(
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    screenRecordingURL: screenURL,
                    cameraRecordingURL: nil,
                    sourceDuration: 10,
                    events: [],
                    timeline: .fullLength(duration: 10)
                )
            )
        }

        let storeURL = directory.appendingPathComponent("projects.json")
        try RecordingProjectLibrary.save(projects, to: storeURL, limit: 3)
        let loadedProjects = try RecordingProjectLibrary.load(from: storeURL, limit: 10)
        expect(loadedProjects.count == 3, "project library saves only the recent project limit")
        expect(loadedProjects.map(\.screenRecordingURL.lastPathComponent) == ["screen-0.mov", "screen-1.mov", "screen-2.mov"], "project library preserves recent ordering")

        try FileManager.default.removeItem(at: projects[1].screenRecordingURL)
        let filteredProjects = try RecordingProjectLibrary.load(from: storeURL, limit: 10)
        expect(filteredProjects.map(\.screenRecordingURL.lastPathComponent) == ["screen-0.mov", "screen-2.mov"], "project library filters missing screen recordings")

        let cameraURL = directory.appendingPathComponent("camera.mov")
        let microphoneURL = directory.appendingPathComponent("microphone.caf")
        FileManager.default.createFile(atPath: cameraURL.path, contents: Data("camera".utf8))
        FileManager.default.createFile(atPath: microphoneURL.path, contents: Data("microphone".utf8))
        let screenWithMissingSidecars = directory.appendingPathComponent("screen-sidecars.mov")
        FileManager.default.createFile(atPath: screenWithMissingSidecars.path, contents: Data("screen-sidecars".utf8))
        let sidecarProject = RecordingProject(
            screenRecordingURL: screenWithMissingSidecars,
            cameraRecordingURL: cameraURL,
            microphoneRecordingURL: microphoneURL,
            cameraRecordingOffset: 0.3,
            microphoneRecordingOffset: 0.4,
            sourceDuration: 10,
            events: [
                .cameraLayout(CameraLayoutEvent(time: 0, frame: .defaultCameraFrame, shape: .circle, isVisible: true))
            ],
            timeline: .fullLength(duration: 10)
        )
        let sidecarStoreURL = directory.appendingPathComponent("sidecars.json")
        try RecordingProjectLibrary.save([sidecarProject], to: sidecarStoreURL)
        try FileManager.default.removeItem(at: cameraURL)
        try FileManager.default.removeItem(at: microphoneURL)
        let loadedSidecarProjects = try RecordingProjectLibrary.load(from: sidecarStoreURL)
        expect(loadedSidecarProjects.count == 1, "project library keeps screen recordings when optional sidecars are missing")
        expect(loadedSidecarProjects[0].cameraRecordingURL == nil, "project library clears missing camera sidecars")
        expect(loadedSidecarProjects[0].microphoneRecordingURL == nil, "project library clears missing microphone sidecars")
        expect(loadedSidecarProjects[0].cameraRecordingOffset == 0, "project library clears missing camera offsets")
        expect(loadedSidecarProjects[0].microphoneRecordingOffset == 0, "project library clears missing microphone offsets")
        expect(!loadedSidecarProjects[0].needsRenderedPreview, "missing camera sidecars do not force rendered previews")

        let missingStoreURL = directory.appendingPathComponent("missing.json")
        let missingProjects = try RecordingProjectLibrary.load(from: missingStoreURL, limit: 10)
        expect(missingProjects.isEmpty, "missing project library starts empty")
    } catch {
        fputs("Project library check failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private func runRecordingFileStoreChecks() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("jianlu-file-store-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let firstURL = try RecordingFileStore.makeRecordingURL(
            prefix: "export",
            directoryPath: directory.path,
            date: date,
            uniqueID: "abcdef12"
        )
        expect(firstURL.lastPathComponent == "export-20231114-221320-000-abcdef12.mov", "recording file names include timestamp and unique suffix")

        FileManager.default.createFile(atPath: firstURL.path, contents: Data())
        let secondURL = try RecordingFileStore.makeRecordingURL(
            prefix: "export",
            directoryPath: directory.path,
            date: date,
            uniqueID: "abcdef12"
        )
        expect(secondURL.lastPathComponent == "export-20231114-221320-000-abcdef12-2.mov", "recording file names avoid existing collisions")

        let audioURL = try RecordingFileStore.makeRecordingURL(
            prefix: "microphone",
            extension: "caf",
            directoryPath: directory.path,
            date: date,
            uniqueID: "abc-def-345"
        )
        expect(audioURL.pathExtension == "caf", "recording file store preserves requested file extension")
        expect(audioURL.deletingLastPathComponent() == directory, "recording file store honors custom directories")
    } catch {
        fputs("Recording file store check failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

private func runPreferenceChecks() {
    let smallRegion = RecordingRegion(displayID: 1, x: 10, y: 10, width: 40, height: 40)
    expect(!smallRegion.isUsable, "tiny recording regions are rejected")

    let usableRegion = RecordingRegion(displayID: 1, x: 20, y: 30, width: 640, height: 360)
    expect(usableRegion.isUsable, "normal recording regions are usable")
    let screenCaptureSourceRect = usableRegion.screenCaptureSourceRect(
        displayPointWidth: 1440,
        displayPointHeight: 900
    )
    expect(
        screenCaptureSourceRect == CGRect(x: 20, y: 30, width: 640, height: 360),
        "ScreenCaptureKit source rect remains in display points on retina displays"
    )
    let screenCaptureOutputSize = usableRegion.screenCaptureOutputSize(
        displayPixelWidth: 2880,
        displayPixelHeight: 1800,
        displayPointWidth: 1440,
        displayPointHeight: 900
    )
    expect(screenCaptureOutputSize == CGSize(width: 1280, height: 720), "ScreenCaptureKit output size scales region points to pixels")

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

    let savedCameraFrame = NormalizedRect(x: 0.12, y: 0.18, width: 0.28, height: 0.28)
    let preferences = RecordingPreferences(
        includeAppInterface: false,
        cameraEnabled: false,
        microphoneEnabled: false,
        microphoneNoiseReductionEnabled: true,
        cameraBackgroundStyle: .graphite,
        cameraBackgroundBlur: .medium,
        cameraBeauty: CameraBeautySettings(smoothing: 4, whitening: 0.6, faceSlimming: 0.3),
        cameraFrame: savedCameraFrame,
        cameraShape: .square,
        zoomShortcut: .controlOptionSpace,
        zoomMouseButton: .right,
        captureShortcutPreset: .macReplacement,
        screenshotAutoCopyOnFinish: false,
        screenshotFreezesScreen: false,
        recordingDirectoryPath: "/tmp/jianlu-checks",
        lastSelectedRegion: usableRegion
    )
    expect(!preferences.cameraEnabled, "camera preference can be disabled")
    expect(!preferences.microphoneEnabled, "microphone preference can be disabled")
    expect(preferences.microphoneNoiseReductionEnabled, "microphone noise reduction preference can be enabled")
    expect(preferences.cameraBeauty.smoothing == 1, "beauty smoothing is clamped to 1")
    expect(preferences.cameraBeauty.whitening == 0.6, "beauty whitening is stored on its own")
    expect(preferences.cameraBeauty.faceSlimming == 0.3, "face slimming is stored on its own")
    expect(preferences.cameraBeauty.isEnabled, "any non-zero beauty control enables processing")
    expect(preferences.cameraBeauty.needsFaceDetection, "face slimming is what needs the face detection pass")
    expect(!CameraBeautySettings.off.isEnabled, "all-zero beauty skips processing entirely")
    expect(!CameraBeautySettings.natural.needsFaceDetection, "the natural preset does not pay for face detection")
    expect(CameraBeautySettings(legacyLevel: 0.4).smoothing == 0.4, "the old single beauty slider migrates to smoothing")
    expect(CameraBeautySettings(legacyLevel: 0.4).faceSlimming == 0, "migrated settings never switch on face slimming by surprise")
    expect(CameraBackgroundStyle.allCases.contains(.custom), "a custom image background is available")
    expect(CameraBackgroundStyle.custom.usesCustomImage, "the custom style is the one that paints a user image")
    expect(!CameraBackgroundStyle.office.usesCustomImage, "built-in scenes are not custom images")
    expect(preferences.cameraFrame == savedCameraFrame, "camera avatar frame preference is stored")
    expect(preferences.cameraShape == .square, "camera avatar shape preference is stored")
    expect(preferences.zoomShortcut == .controlOptionSpace, "zoom shortcut preference is stored")
    expect(preferences.zoomMouseButton == .right, "zoom mouse button preference is stored")
    expect(RecordingPreferences.defaults.zoomMouseButton == .middle, "clicking the middle mouse button zooms by default")
    expect(ZoomMouseButton.middle.pressedButtonMask == 1 << 2, "middle mouse button maps to the NSEvent middle button bit")
    expect(ZoomMouseButton.left.pressedButtonMask == 1, "left mouse button maps to the NSEvent left button bit")
    expect(ZoomMouseButton.right.pressedButtonMask == 1 << 1, "right mouse button maps to the NSEvent right button bit")
    expect(ZoomMouseButton.off.pressedButtonMask == 0, "mouse zoom can be turned off entirely")
    expect(ZoomMouseButton.allCases.allSatisfy { !$0.displayName.isEmpty }, "every mouse zoom button has a Chinese display name")
    expect(preferences.captureShortcutPreset == .macReplacement, "capture shortcut preset preference is stored")
    expect(!preferences.screenshotAutoCopyOnFinish, "screenshot auto-copy preference can be disabled")
    expect(RecordingPreferences.defaults.screenshotFreezesScreen, "screenshots freeze the screen at the shortcut by default")

    // Cropping the frozen full-display still down to the selection: the still is in
    // pixels, the selection is in display points.
    let frozenCrop = RecordingRegion(displayID: 1, x: 100, y: 50, width: 400, height: 300)
        .sourceRect(
            displayPixelWidth: 2940,
            displayPixelHeight: 1912,
            displayPointWidth: 1470,
            displayPointHeight: 956
        )
    expect(
        frozenCrop == CGRect(x: 200, y: 100, width: 800, height: 600),
        "the frozen screenshot is cropped with the region scaled from points to the still's pixels"
    )
    let frozenFullScreenCrop = RecordingRegion(displayID: 1, x: 0, y: 0, width: 1470, height: 956)
        .sourceRect(
            displayPixelWidth: 2940,
            displayPixelHeight: 1912,
            displayPointWidth: 1470,
            displayPointHeight: 956
        )
    expect(
        frozenFullScreenCrop == CGRect(x: 0, y: 0, width: 2940, height: 1912),
        "a full-screen selection keeps the whole frozen still"
    )
    expect(preferences.captureShortcutPreset.detail.contains("⇧⌘4"), "mac replacement preset names the screenshot shortcut")
    expect(preferences.captureShortcutPreset.detail.contains("阻止 macOS 原生"), "mac replacement preset explains that it suppresses original system shortcuts")
    expect(RecordingPreferences.defaults.captureShortcutPreset.detail.contains("不拦截"), "default capture shortcut preset leaves original macOS shortcuts enabled")
    expect(!preferences.zoomShortcut.displayName.isEmpty, "zoom shortcut has a display name")
    expect(preferences.recordingDirectoryPath == "/tmp/jianlu-checks", "recording directory path is stored")
    expect(preferences.lastSelectedRegion == usableRegion, "last selected region is stored")
    expect(AnnotationTool.rectangle.isShapeTool, "rectangle annotation is a shape tool")
    expect(AnnotationTool.ellipse.isShapeTool, "ellipse annotation is a shape tool")
    expect(CameraBackgroundStyle.allCases.contains(.office), "real office background is available")
    expect(CameraBackgroundBlur.strong.displayName == "重度", "strong background blur uses natural Chinese wording")

    let invalidCameraFramePreferences = RecordingPreferences(
        includeAppInterface: false,
        cameraBackgroundStyle: .original,
        cameraBackgroundBlur: .off,
        cameraBeauty: .natural,
        cameraFrame: NormalizedRect(x: -0.5, y: 1.4, width: 0.02, height: 0.9)
    )
    expect(
        invalidCameraFramePreferences.cameraFrame == NormalizedRect(x: 0, y: 0.55, width: 0.08, height: 0.45),
        "camera avatar frame preference is clamped to a usable visible range"
    )

    expectClose(NormalizedRect.minCameraFrameSize, 0.08, "camera avatar minimum size stays usable")
    expectClose(NormalizedRect.maxCameraFrameSize, 0.45, "camera avatar maximum size avoids covering too much screen")
    let centeredCameraFrame = NormalizedRect(x: 0.70, y: 0.60, width: 0.20, height: 0.20)
        .resizedCameraFrame(size: 0.32)
    expectClose(centeredCameraFrame.width, 0.32, "camera avatar resize applies the requested square size")
    expectClose(centeredCameraFrame.height, 0.32, "camera avatar resize keeps the avatar square")
    expectClose(centeredCameraFrame.x + centeredCameraFrame.width / 2, 0.80, "camera avatar resize preserves center x when possible")
    expectClose(centeredCameraFrame.y + centeredCameraFrame.height / 2, 0.70, "camera avatar resize preserves center y when possible")
    let edgeCameraFrame = NormalizedRect(x: 0.90, y: 0.90, width: 0.20, height: 0.20)
        .resizedCameraFrame(size: 0.32)
    expectClose(edgeCameraFrame.x, 0.68, "camera avatar resize clamps right edge back on screen")
    expectClose(edgeCameraFrame.y, 0.68, "camera avatar resize clamps bottom edge back on screen")

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
    expect(legacyPreferences?.captureShortcutPreset == .jianLuDefault, "legacy preferences get the default capture shortcut preset")
    expect(legacyPreferences?.screenshotAutoCopyOnFinish == true, "legacy preferences auto-copy screenshots by default")
    expect(legacyPreferences?.screenshotFreezesScreen == true, "legacy preferences get the frozen-screen screenshot default")
    expect(legacyPreferences?.cameraEnabled == true, "legacy preferences keep camera enabled by default")
    expect(legacyPreferences?.cameraFrame == .defaultCameraFrame, "legacy preferences get the default camera frame")
    expect(legacyPreferences?.cameraShape == .circle, "legacy preferences get the default camera shape")
    expect(legacyPreferences?.cameraBeauty.smoothing == 0.3, "a legacy beauty level becomes the smoothing amount")
    expect(legacyPreferences?.cameraBeauty.faceSlimming == 0, "legacy recordings do not gain face slimming")
    expect(legacyPreferences?.language == .system, "legacy preferences follow the system language")
    expect(legacyPreferences?.zoomMouseButton == .middle, "legacy preferences get the default middle-button mouse zoom")
    expect(legacyPreferences?.recordingDirectoryPath == "/tmp/legacy-jianlu", "legacy preferences keep the recording path")

    let encodedPreferences = try? JSONEncoder().encode(preferences)
    let decodedPreferences = encodedPreferences.flatMap {
        try? JSONDecoder().decode(RecordingPreferences.self, from: $0)
    }
    expect(decodedPreferences?.screenshotAutoCopyOnFinish == false, "screenshot auto-copy preference round-trips when disabled")
    expect(decodedPreferences?.zoomMouseButton == .right, "zoom mouse button preference round-trips")
    expect(decodedPreferences?.screenshotFreezesScreen == false, "screen freeze preference round-trips when disabled")

    runCameraBubbleGeometryChecks()
    runLocalizationChecks()
}

/// The whole UI is bilingual through `tr(zh, en)`, so switching the language has to
/// switch every localized string the model exposes.
private func runLocalizationChecks() {
    let original = L10n.current
    defer { L10n.setLanguage(original) }

    L10n.setLanguage(.chinese)
    expect(L10n.current == .chinese, "the language can be forced to Chinese")
    expect(tr("中文", "English") == "中文", "tr picks the Chinese string")
    expect(CameraFrameShape.ellipse.displayName == "椭圆", "shape names follow the language")
    expect(CameraBackgroundStyle.custom.displayName == "自定义图片", "background names follow the language")
    expect(ZoomMouseButton.middle.displayName == "鼠标中键", "mouse button names follow the language")
    expect(AnnotationTool.arrow.displayName == "箭头", "annotation tool names follow the language")

    L10n.setLanguage(.english)
    expect(tr("中文", "English") == "English", "tr picks the English string")
    expect(CameraFrameShape.ellipse.displayName == "Oval", "shape names switch to English")
    expect(CameraBackgroundStyle.custom.displayName == "Custom Image", "background names switch to English")
    expect(ZoomMouseButton.middle.displayName == "Middle button", "mouse button names switch to English")
    expect(AnnotationTool.arrow.displayName == "Arrow", "annotation tool names switch to English")
    expect(CaptureShortcutPreset.macReplacement.detail.contains("⇧⌘3"), "the English shortcut blurb still names the keys")

    expect(AppLanguage.chinese.resolved == .chinese, "an explicit language resolves to itself")
    expect(AppLanguage.english.resolved == .english, "an explicit language resolves to itself")
    expect(AppLanguage.system.resolved != .system, "the system language always resolves to a concrete language")
    expect(AppLanguage.allCases.count == 3, "language options are system, Chinese and English")
}

/// The camera bubble geometry both the live overlay and the export compositor use.
/// "圆形" must be a real circle on any aspect ratio; "椭圆" is the shape that keeps
/// the frame's own aspect ratio and therefore looks like an oval.
private func runCameraBubbleGeometryChecks() {
    expect(CameraFrameShape.allCases.contains(.ellipse), "an explicit oval camera avatar shape is available")
    expect(CameraFrameShape.ellipse.displayName == "椭圆", "the oval camera avatar shape is named 椭圆")
    expect(CameraFrameShape.circle.usesSquareBubble, "圆形 camera avatar uses a square box so it stays a true circle")
    expect(CameraFrameShape.square.usesSquareBubble, "方形 camera avatar uses a square box")
    expect(CameraFrameShape.roundedSquare.usesSquareBubble, "圆角方形 camera avatar uses a square box")
    expect(!CameraFrameShape.ellipse.usesSquareBubble, "椭圆 camera avatar keeps the frame aspect ratio")

    let wideCanvas = CGSize(width: 1600, height: 900)
    let avatarFrame = NormalizedRect(x: 0.5, y: 0.4, width: 0.22, height: 0.22)

    let circleBubble = avatarFrame.cameraBubbleRect(in: wideCanvas, shape: .circle)
    expectClose(circleBubble.width, 352, "圆形 camera avatar takes its size from the width fraction")
    expectClose(circleBubble.height, 352, "圆形 camera avatar is square on a 16:9 canvas, so it renders as a true circle")

    let ellipseBubble = avatarFrame.cameraBubbleRect(in: wideCanvas, shape: .ellipse)
    expectClose(ellipseBubble.width, 352, "椭圆 camera avatar keeps the width fraction")
    expectClose(ellipseBubble.height, 198, "椭圆 camera avatar follows the canvas aspect ratio")
    expect(ellipseBubble.width > ellipseBubble.height, "椭圆 camera avatar really is an oval, unlike 圆形")

    let offscreenFrame = NormalizedRect(x: 0.95, y: 0.95, width: 0.22, height: 0.22)
    for shape in CameraFrameShape.allCases {
        let bubble = offscreenFrame.cameraBubbleRect(in: wideCanvas, shape: shape)
        expect(bubble.minX >= -0.001 && bubble.minY >= -0.001, "\(shape.displayName) camera avatar stays inside the canvas")
        expect(
            bubble.maxX <= wideCanvas.width + 0.001 && bubble.maxY <= wideCanvas.height + 0.001,
            "\(shape.displayName) camera avatar never hangs off the canvas edge"
        )
    }
}

private func runAnnotationImageRendererChecks() {
    guard let baseImage = makeSolidImage(width: 80, height: 80, color: (r: 255, g: 255, b: 255)) else {
        expect(false, "annotation image renderer test creates a base image")
        return
    }
    let annotation = AnnotationEvent(
        time: 0,
        tool: .pen,
        points: [
            StrokePoint(time: 0, point: NormalizedPoint(x: 0.10, y: 0.50)),
            StrokePoint(time: 0, point: NormalizedPoint(x: 0.90, y: 0.50))
        ],
        colorHex: "#FF3B30",
        lineWidth: 10
    )
    guard let rendered = AnnotationImageRenderer.render(baseImage: baseImage, annotations: [annotation]) else {
        expect(false, "annotation image renderer produces an output image")
        return
    }
    let center = pixelColor(in: rendered, x: 40, y: 40)
    let untouchedCorner = pixelColor(in: rendered, x: 4, y: 4)
    expect(center.r > 180 && center.g < 120 && center.b < 120, "annotation image renderer burns doodles into the screenshot image")
    expect(untouchedCorner.r > 230 && untouchedCorner.g > 230 && untouchedCorner.b > 230, "annotation image renderer leaves untouched pixels intact")

    let topAnnotation = AnnotationEvent(
        time: 0,
        tool: .line,
        points: [
            StrokePoint(time: 0, point: NormalizedPoint(x: 0.10, y: 0.10)),
            StrokePoint(time: 0, point: NormalizedPoint(x: 0.90, y: 0.10))
        ],
        colorHex: "#FF3B30",
        lineWidth: 8
    )
    guard let topRendered = AnnotationImageRenderer.render(baseImage: baseImage, annotations: [topAnnotation]) else {
        expect(false, "annotation image renderer produces a top-line output image")
        return
    }
    let topPixel = pixelColor(in: topRendered, x: 40, y: 8)
    let bottomPixel = pixelColor(in: topRendered, x: 40, y: 72)
    expect(topPixel.r > 180 && topPixel.g < 120 && topPixel.b < 120, "screenshot annotations use top-origin normalized coordinates")
    expect(bottomPixel.r > 230 && bottomPixel.g > 230 && bottomPixel.b > 230, "screenshot annotations are not vertically flipped when saved")
}

private func runScreenshotMarkupRendererChecks() {
    guard let baseImage = makeGradientImage(width: 96, height: 96) else {
        expect(false, "screenshot markup renderer test creates a base image")
        return
    }

    let stroke = AnnotationEvent(
        time: 0,
        tool: .line,
        points: [
            StrokePoint(time: 0, point: NormalizedPoint(x: 0.10, y: 0.82)),
            StrokePoint(time: 0, point: NormalizedPoint(x: 0.90, y: 0.82))
        ],
        colorHex: "#FF3B30",
        lineWidth: 8
    )
    let markups: [ScreenshotMarkup] = [
        .mosaic(
            ScreenshotMosaicMarkup(
                rect: NormalizedRect(x: 0, y: 0, width: 0.50, height: 0.50),
                blockSize: 8
            )
        ),
        .stroke(stroke),
        .text(
            ScreenshotTextMarkup(
                text: "Hi",
                anchor: NormalizedPoint(x: 0.58, y: 0.18),
                colorHex: "#FF3B30",
                fontSize: 24
            )
        )
    ]

    guard let rendered = ScreenshotMarkupRenderer.render(baseImage: baseImage, markups: markups) else {
        expect(false, "screenshot markup renderer produces an output image")
        return
    }

    let mosaicA = pixelColor(in: rendered, x: 2, y: 2)
    let mosaicB = pixelColor(in: rendered, x: 6, y: 6)
    expect(
        mosaicA.r == mosaicB.r && mosaicA.g == mosaicB.g && mosaicA.b == mosaicB.b,
        "screenshot markup renderer pixelates pixels inside a mosaic block"
    )

    let linePixel = pixelColor(in: rendered, x: 48, y: 79)
    expect(linePixel.r > 180 && linePixel.g < 120 && linePixel.b < 120, "screenshot markup renderer preserves stroke annotations")

    expect(
        hasRedPixel(in: rendered, xRange: 54..<90, yRange: 8..<42),
        "screenshot markup renderer burns text into the screenshot image"
    )
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

    let openRecorderStyleZoom = ZoomLensGeometry(lensSize: CGSize(width: 1000, height: 500)).zoomedRegionImageFrame(
        captureSize: CGSize(width: 1000, height: 500),
        focus: NormalizedPoint(x: 0.25, y: 0.6),
        magnification: 1.8
    )
    let anchoredFocusX = openRecorderStyleZoom.minX + 0.25 * openRecorderStyleZoom.width
    let anchoredFocusY = openRecorderStyleZoom.minY + 0.6 * openRecorderStyleZoom.height
    expect(abs(openRecorderStyleZoom.width - 1800) < 0.001, "open-recorder-style zoom expands the recorded region width")
    expect(abs(openRecorderStyleZoom.height - 900) < 0.001, "open-recorder-style zoom expands the recorded region height")
    expect(abs(anchoredFocusX - 250) < 0.001, "open-recorder-style zoom keeps the focus pinned horizontally")
    expect(abs(anchoredFocusY - 300) < 0.001, "open-recorder-style zoom keeps the focus pinned vertically")

    // WYSIWYG guard: the region the presenter sees magnified in the live overlay must
    // be the region the exported video magnifies. The live frame is y-down, the export
    // transform is y-up, so the vertical edges are compared after flipping.
    let wysiwygCaptureSize = CGSize(width: 1600, height: 900)
    let wysiwygFocus = NormalizedPoint(x: 0.32, y: 0.71)
    let wysiwygDepth = 2.1
    let liveZoomFrame = ZoomLensGeometry(lensSize: wysiwygCaptureSize).zoomedRegionImageFrame(
        captureSize: wysiwygCaptureSize,
        focus: wysiwygFocus,
        magnification: wysiwygDepth
    )
    let exportRenderRect = CGRect(origin: .zero, size: wysiwygCaptureSize)
    let exportedZoomFrame = exportRenderRect.applying(
        ExportZoomTimeline.transform(
            for: ExportZoomEffect(depth: wysiwygDepth, focusX: wysiwygFocus.x, focusY: wysiwygFocus.y),
            in: exportRenderRect,
            flipsY: true
        )
    )
    expectClose(liveZoomFrame.width, exportedZoomFrame.width, "live zoom magnifies the same width the export does")
    expectClose(liveZoomFrame.height, exportedZoomFrame.height, "live zoom magnifies the same height the export does")
    expectClose(liveZoomFrame.minX, exportedZoomFrame.minX, "live zoom and exported zoom keep the same horizontal region")
    expectClose(
        liveZoomFrame.minY,
        wysiwygCaptureSize.height - exportedZoomFrame.maxY,
        "live zoom and exported zoom keep the same vertical region"
    )

    // The live overlay ramps its magnification on the export's own curve, so it never
    // shows a zoom depth the exported frame at that moment will not have.
    expectClose(ExportZoomTimeline.rampedDepth(target: 2, elapsed: 0), 1, "live zoom opens from 1x like the export")
    expectClose(
        ExportZoomTimeline.rampedDepth(target: 2, elapsed: ExportZoomTimeline.rampInSeconds),
        2,
        "live zoom reaches the target depth when the export ramp completes"
    )
    expectClose(
        ExportZoomTimeline.rampedDepth(target: 2, elapsed: ExportZoomTimeline.rampInSeconds / 2),
        1.5,
        "live zoom follows the export smoothstep ramp"
    )
    let rampStates = [
        ZoomEvent(time: 0, magnification: 2, focus: wysiwygFocus),
        ZoomEvent(time: 5, magnification: 1, focus: wysiwygFocus)
    ]
    let rampingExportEffect = ExportZoomTimeline.activeEffect(states: rampStates, duration: 6, at: 0.2)
    expectClose(
        rampingExportEffect?.depth ?? 0,
        ExportZoomTimeline.rampedDepth(target: 2, elapsed: 0.2),
        "live overlay depth matches the exported frame depth while the zoom ramps in"
    )

    let clampedCenter = lens.clampedLensCenter(
        in: CGRect(x: 10, y: 20, width: 800, height: 400),
        focus: NormalizedPoint(x: 0.02, y: 0.03)
    )
    expect(clampedCenter == CGPoint(x: 110, y: 120), "zoom lens center is clamped inside the capture rect")

    let smallDiameter = ZoomLensGeometry.lensDiameter(for: CGSize(width: 80, height: 90))
    expect(smallDiameter == 72, "zoom lens stays visible for tiny recording regions")
    let largeDiameter = ZoomLensGeometry.lensDiameter(for: CGSize(width: 1920, height: 1080))
    expect(largeDiameter == 280, "zoom lens has a stable maximum size")

    let zoomRegion = ExportZoomTimeline.regions(
        from: [
            ZoomEvent(time: 0.2, magnification: 1.8, focus: NormalizedPoint(x: 0.02, y: 0.98)),
            ZoomEvent(time: 1.4, magnification: 1, focus: NormalizedPoint(x: 0.02, y: 0.98))
        ],
        duration: 2
    )
    expect(zoomRegion == [
        ExportZoomRegion(
            start: 0.2,
            end: 1.4,
            depth: 1.8,
            focus: NormalizedPoint(x: 0.02, y: 0.98)
        )
    ], "export zoom regions preserve the clicked focus even near the edge")
    let edgeFocusEffect = ExportZoomTimeline.activeEffect(
        states: [
            ZoomEvent(time: 0.2, magnification: 1.8, focus: NormalizedPoint(x: 0.02, y: 0.98)),
            ZoomEvent(time: 1.4, magnification: 1, focus: NormalizedPoint(x: 0.02, y: 0.98))
        ],
        duration: 2,
        at: 0.8
    )
    expect(edgeFocusEffect?.focusX == 0.02, "export zoom keeps the clicked x focus near the recording edge")
    expect(edgeFocusEffect?.focusY == 0.98, "export zoom keeps the clicked y focus near the recording edge")
    let edgeAnchor = CGPoint(x: 20, y: 10)
    let anchoredTransform = ExportZoomTimeline.transform(
        for: ExportZoomEffect(depth: 1.8, focusX: 0.02, focusY: 0.98),
        in: CGRect(x: 0, y: 0, width: 1000, height: 500),
        flipsY: true
    )
    let transformedAnchor = edgeAnchor.applying(anchoredTransform)
    expect(abs(transformedAnchor.x - edgeAnchor.x) < 0.001, "export zoom transform anchors the clicked x point")
    expect(abs(transformedAnchor.y - edgeAnchor.y) < 0.001, "export zoom transform anchors the clicked y point")
    let smallMoveFocusEffect = ExportZoomTimeline.activeEffect(
        states: [
            ZoomEvent(time: 0.2, magnification: 1.8, focus: NormalizedPoint(x: 0.20, y: 0.20)),
            ZoomEvent(time: 0.25, magnification: 1.8, focus: NormalizedPoint(x: 0.26, y: 0.26)),
            ZoomEvent(time: 1.4, magnification: 1, focus: NormalizedPoint(x: 0.26, y: 0.26))
        ],
        duration: 2,
        at: 0.3
    )
    expect(smallMoveFocusEffect?.focusX == 0.26, "export zoom follows small mouse movements exactly")
    expect(smallMoveFocusEffect?.focusY == 0.26, "export zoom follows small vertical mouse movements exactly")
    let earlyProgress = ExportZoomTimeline.animationProgress(for: zoomRegion[0], at: 0.3)
    let holdProgress = ExportZoomTimeline.animationProgress(for: zoomRegion[0], at: 0.8)
    let lateProgress = ExportZoomTimeline.animationProgress(for: zoomRegion[0], at: 1.35)
    expect(earlyProgress > 0 && earlyProgress < 1, "export zoom ramps in instead of snapping")
    expect(holdProgress == 1, "export zoom holds at full depth between ramps")
    expect(lateProgress > 0 && lateProgress < 1, "export zoom ramps out smoothly")
    let guidedFocusEffect = ExportZoomTimeline.activeEffect(
        states: [
            ZoomEvent(time: 0.2, magnification: 1.8, focus: NormalizedPoint(x: 0.20, y: 0.20)),
            ZoomEvent(time: 0.8, magnification: 1.8, focus: NormalizedPoint(x: 0.88, y: 0.86)),
            ZoomEvent(time: 1.4, magnification: 1, focus: NormalizedPoint(x: 0.88, y: 0.86))
        ],
        duration: 2,
        at: 0.9
    )
    expect(guidedFocusEffect?.focusX == 0.88, "export zoom follows cursor focus exactly")
    expect(guidedFocusEffect?.focusY == 0.86, "export zoom follows cursor focus vertically exactly")
}

private func runCameraFrameProcessorChecks() {
    let width = 64
    let height = 64
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let result = CVPixelBufferCreate(
        nil,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )
    expect(result == kCVReturnSuccess, "camera frame processor test creates a pixel buffer")
    guard let pixelBuffer else {
        expect(false, "camera frame processor test has a pixel buffer")
        return
    }
    fill(pixelBuffer, width: width, height: height, color: (r: 0, g: 0, b: 0))

    let processor = CameraFrameProcessor()
    let originalPreferences = RecordingPreferences(
        includeAppInterface: false,
        cameraBackgroundStyle: .original,
        cameraBackgroundBlur: .off,
        cameraBeauty: .off
    )
    guard let originalImage = processor.makePreviewImage(from: pixelBuffer, preferences: originalPreferences) else {
        expect(false, "camera frame processor renders original preview image")
        return
    }
    let originalPixel = pixelColor(in: originalImage, x: width / 2, y: height / 2)
    expect(originalPixel.r < 5 && originalPixel.g < 5 && originalPixel.b < 5, "original camera processing keeps unchanged pixels")

    let virtualBackgroundPreferences = RecordingPreferences(
        includeAppInterface: false,
        cameraBackgroundStyle: .studioBlue,
        cameraBackgroundBlur: .off,
        cameraBeauty: .off
    )
    guard let processedImage = processor.makePreviewImage(from: pixelBuffer, preferences: virtualBackgroundPreferences) else {
        expect(false, "camera frame processor renders virtual background preview image")
        return
    }
    let processedPixel = pixelColor(in: processedImage, x: width / 2, y: height / 2)
    expect(
        processedPixel.b > processedPixel.r + 10 && processedPixel.b > 15,
        "virtual camera background visibly changes pixels even when segmentation has no mask"
    )

    let realisticBackgroundPreferences = RecordingPreferences(
        includeAppInterface: false,
        cameraBackgroundStyle: .office,
        cameraBackgroundBlur: .off,
        cameraBeauty: .off
    )
    guard let realisticImage = processor.makePreviewImage(from: pixelBuffer, preferences: realisticBackgroundPreferences) else {
        expect(false, "camera frame processor renders real photo background preview image")
        return
    }
    let realisticCenter = pixelColor(in: realisticImage, x: width / 2, y: height / 2)
    let realisticCorner = pixelColor(in: realisticImage, x: width / 5, y: height / 5)
    let maximumPhotoChannel = max(
        realisticCenter.r,
        realisticCenter.g,
        realisticCenter.b,
        realisticCorner.r,
        realisticCorner.g,
        realisticCorner.b
    )
    let photoVariation = abs(Int(realisticCenter.r) - Int(realisticCorner.r))
        + abs(Int(realisticCenter.g) - Int(realisticCorner.g))
        + abs(Int(realisticCenter.b) - Int(realisticCorner.b))
    expect(maximumPhotoChannel > 15, "real photo camera backgrounds are loaded from resources")
    expect(photoVariation > 4, "real photo camera backgrounds keep visible spatial detail")
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
    let projectExportOutputURL = directory.appendingPathComponent("project-export.mov")
    try makeSolidColorMovie(url: screenURL, size: CGSize(width: 200, height: 200), color: (r: 20, g: 70, b: 220))
    try makeSolidColorMovie(url: cameraURL, size: CGSize(width: 120, height: 120), color: (r: 230, g: 40, b: 30))
    do {
        try await exportSyntheticCompositorMovie(screenURL: screenURL, cameraURL: cameraURL, outputURL: outputURL, overlaysAnnotation: false)
    } catch {
        throw CheckError("camera compositor export failed: \(error.localizedDescription)")
    }

    let frame: CGImage
    do {
        frame = try await firstFrameImage(from: outputURL)
    } catch {
        throw CheckError("camera compositor frame read failed: \(error.localizedDescription)")
    }
    let center = pixelColor(in: frame, x: 100, y: 100)
    let maskedCorner = pixelColor(in: frame, x: 52, y: 52)
    expect(center.r > 170 && center.g < 90 && center.b < 90, "circle camera compositor keeps camera visible at the center")
    expect(maskedCorner.b > 150 && maskedCorner.r < 100, "circle camera compositor masks the camera corners")

    // 椭圆: a 140×50 bubble centered in the 200×200 frame. Sampling proves the export
    // really draws a wide oval instead of falling back to the square bubble the other
    // shapes use (a square bubble would cover x=100,y=130 as well).
    let ellipseOutputURL = directory.appendingPathComponent("composited-ellipse.mov")
    do {
        try await exportSyntheticCompositorMovie(
            screenURL: screenURL,
            cameraURL: cameraURL,
            outputURL: ellipseOutputURL,
            overlaysAnnotation: false,
            cameraState: CameraLayoutEvent(
                time: 0,
                frame: NormalizedRect(x: 0.15, y: 0.375, width: 0.7, height: 0.25),
                shape: .ellipse,
                isVisible: true
            )
        )
    } catch {
        throw CheckError("ellipse camera compositor export failed: \(error.localizedDescription)")
    }
    let ellipseFrame: CGImage
    do {
        ellipseFrame = try await firstFrameImage(from: ellipseOutputURL)
    } catch {
        throw CheckError("ellipse camera compositor frame read failed: \(error.localizedDescription)")
    }
    let ellipseCenter = pixelColor(in: ellipseFrame, x: 100, y: 100)
    let ellipseWideEdge = pixelColor(in: ellipseFrame, x: 35, y: 100)
    let ellipseBelowBubble = pixelColor(in: ellipseFrame, x: 100, y: 130)
    expect(ellipseCenter.r > 170 && ellipseCenter.b < 90, "ellipse camera compositor keeps camera visible at the center")
    expect(ellipseWideEdge.r > 150 && ellipseWideEdge.b < 110, "ellipse camera bubble spans the full frame width")
    expect(ellipseBelowBubble.b > 150 && ellipseBelowBubble.r < 100, "ellipse camera bubble stays short instead of falling back to a square box")

    do {
        try await exportSyntheticCompositorMovie(screenURL: screenURL, cameraURL: cameraURL, outputURL: annotatedOutputURL, overlaysAnnotation: true)
    } catch {
        throw CheckError("annotated compositor export failed: \(error.localizedDescription)")
    }
    let annotatedFrame: CGImage
    do {
        annotatedFrame = try await firstFrameImage(from: annotatedOutputURL)
    } catch {
        throw CheckError("annotated compositor frame read failed: \(error.localizedDescription)")
    }
    // The annotation runs along the bottom; sample it where the camera bubble does
    // not cover it. The center stays red because the camera correctly composites on
    // top of annotations, mirroring the live overlay z-order.
    let annotatedStripe = pixelColor(in: annotatedFrame, x: 100, y: 170)
    let annotatedCenter = pixelColor(in: annotatedFrame, x: 100, y: 100)
    expect(annotatedStripe.g > 150 && annotatedStripe.r < 120, "camera compositor still renders annotation overlays")
    expect(annotatedCenter.r > 150 && annotatedCenter.g < 110, "camera bubble composites on top of annotations (matches live z-order)")

    let projectExport = RecordingProject(
        screenRecordingURL: screenURL,
        cameraRecordingURL: cameraURL,
        sourceDuration: 0.5,
        events: [
            .cameraLayout(
                CameraLayoutEvent(
                    time: 0,
                    frame: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                    shape: .circle,
                    isVisible: true
                )
            ),
            .annotation(
                AnnotationEvent(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                    time: 0,
                    tool: .line,
                    points: [
                        StrokePoint(time: 0, point: NormalizedPoint(x: 0.10, y: 0.85)),
                        StrokePoint(time: 0, point: NormalizedPoint(x: 0.90, y: 0.85))
                    ],
                    colorHex: "#14E62E",
                    lineWidth: 18
                )
            )
        ],
        timeline: .fullLength(duration: 0.5)
    )
    do {
        try await exportProjectMovie(projectExport, outputURL: projectExportOutputURL)
    } catch {
        throw CheckError("project export failed: \(error.localizedDescription)")
    }
    let projectFrame: CGImage
    do {
        projectFrame = try await firstFrameImage(from: projectExportOutputURL)
    } catch {
        throw CheckError("project export frame read failed: \(error.localizedDescription)")
    }
    let projectCameraCenter = pixelColor(in: projectFrame, x: 100, y: 100)
    let projectAnnotationPixel = pixelColor(in: projectFrame, x: 100, y: 170)
    expect(projectCameraCenter.r > 170 && projectCameraCenter.g < 90, "project export keeps picture-in-picture visible in the final movie")
    expect(projectAnnotationPixel.g > 140 && projectAnnotationPixel.r < 140, "project export renders annotations in the final movie")

    let zoomSourceURL = directory.appendingPathComponent("zoom-source.mov")
    let zoomOutputURL = directory.appendingPathComponent("zoomed.mov")
    do {
        try makeQuadrantMovie(url: zoomSourceURL, size: CGSize(width: 200, height: 200))
        try await exportSyntheticCompositorMovie(
            screenURL: zoomSourceURL,
            cameraURL: nil,
            outputURL: zoomOutputURL,
            zoomStates: [
                ZoomEvent(time: 0, magnification: 2, focus: NormalizedPoint(x: 0.25, y: 0.25))
            ],
            overlaysAnnotation: false
        )
    } catch {
        throw CheckError("custom compositor zoom-only export failed: \(error.localizedDescription)")
    }
    let zoomedFrame: CGImage
    do {
        zoomedFrame = try await firstFrameImage(from: zoomOutputURL)
    } catch {
        throw CheckError("custom compositor zoom-only frame read failed: \(error.localizedDescription)")
    }
    let anchoredZoomFocus = pixelColor(in: zoomedFrame, x: 50, y: 50)
    expect(
        anchoredZoomFocus.g > 170 && anchoredZoomFocus.r < 90 && anchoredZoomFocus.b < 90,
        "custom compositor keeps the zoom focus pinned under the original cursor point"
    )
}

private func exportProjectMovie(_ project: RecordingProject, outputURL: URL) async throws {
    let build = try await ProjectVideoCompositionBuilder.build(project: project)
    guard let export = AVAssetExportSession(asset: build.composition, presetName: AVAssetExportPresetHighestQuality) else {
        throw CheckError("cannot create project export session")
    }
    export.videoComposition = build.videoComposition
    try await export.export(to: outputURL, as: AVFileType.mov)
}

private func makeSolidColorMovie(
    url: URL,
    size: CGSize,
    color: (r: UInt8, g: UInt8, b: UInt8),
    frameCount: Int = 6
) throws {
    try makeSyntheticMovie(url: url, size: size, frameCount: frameCount) { pixelBuffer, width, height in
        fill(pixelBuffer, width: width, height: height, color: color)
    }
}

private func makeQuadrantMovie(url: URL, size: CGSize, frameCount: Int = 6) throws {
    try makeSyntheticMovie(url: url, size: size, frameCount: frameCount) { pixelBuffer, width, height in
        fillQuadrants(pixelBuffer, width: width, height: height)
    }
}

private func makeSyntheticMovie(
    url: URL,
    size: CGSize,
    frameCount: Int,
    fillFrame: (CVPixelBuffer, Int, Int) -> Void
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
        fillFrame(pixelBuffer, width, height)
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

private func fillQuadrants(
    _ pixelBuffer: CVPixelBuffer,
    width: Int,
    height: Int
) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<height {
        let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let color: (r: UInt8, g: UInt8, b: UInt8)
            if y < height / 2, x < width / 2 {
                color = (r: 30, g: 220, b: 50)
            } else if y < height / 2 {
                color = (r: 30, g: 70, b: 220)
            } else if x < width / 2 {
                color = (r: 230, g: 40, b: 30)
            } else {
                color = (r: 230, g: 220, b: 30)
            }

            let offset = x * 4
            row[offset] = color.b
            row[offset + 1] = color.g
            row[offset + 2] = color.r
            row[offset + 3] = 255
        }
    }
}

private func exportSyntheticCompositorMovie(
    screenURL: URL,
    cameraURL: URL?,
    outputURL: URL,
    zoomStates: [ZoomEvent] = [],
    overlaysAnnotation: Bool,
    cameraState: CameraLayoutEvent = CameraLayoutEvent(
        time: 0,
        frame: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        shape: .circle,
        isVisible: true
    )
) async throws {
    let screenAsset = AVURLAsset(url: screenURL)
    guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
        throw CheckError("synthetic screen asset is missing a video track")
    }

    let cameraAsset = cameraURL.map { AVURLAsset(url: $0) }
    let cameraTrack: AVAssetTrack?
    if let cameraAsset {
        cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first
        guard cameraTrack != nil else {
            throw CheckError("synthetic camera asset is missing a video track")
        }
    } else {
        cameraTrack = nil
    }

    let composition = AVMutableComposition()
    guard let compositionScreen = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw CheckError("cannot create synthetic screen composition track")
    }

    let duration = CMTime(value: 6, timescale: 30)
    let range = CMTimeRange(start: .zero, duration: duration)
    try compositionScreen.insertTimeRange(range, of: screenTrack, at: .zero)
    var compositionCameraTrackID: CMPersistentTrackID?
    if let cameraTrack {
        guard let compositionCamera = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CheckError("cannot create synthetic camera composition track")
        }
        try compositionCamera.insertTimeRange(range, of: cameraTrack, at: .zero)
        compositionCameraTrackID = compositionCamera.trackID
    }

    let videoComposition = AVMutableVideoComposition()
    videoComposition.customVideoCompositorClass = CameraShapeVideoCompositor.self
    videoComposition.renderSize = CGSize(width: 200, height: 200)
    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
    videoComposition.instructions = [
        CameraShapeVideoCompositionInstruction(
            timeRange: range,
            screenTrackID: compositionScreen.trackID,
            cameraTrackID: compositionCameraTrackID,
            renderSize: CGSize(width: 200, height: 200),
            zoomStates: zoomStates,
            annotationEvents: overlaysAnnotation ? [
                .annotation(
                    AnnotationEvent(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
                        time: 0,
                        tool: .line,
                        // Runs along the bottom (below the centered camera bubble) so
                        // the overlay is visible where it is not covered, while the
                        // camera correctly sits on top at the center — matching the
                        // live overlay z-order (screen < annotations < camera).
                        points: [
                            StrokePoint(time: 0, point: NormalizedPoint(x: 0.10, y: 0.85)),
                            StrokePoint(time: 0, point: NormalizedPoint(x: 0.90, y: 0.85))
                        ],
                        colorHex: "#14E62E",
                        lineWidth: 24
                    )
                )
            ] : [],
            cameraStates: [cameraState]
        )
    ]

    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
        throw CheckError("cannot create synthetic export session")
    }
    export.videoComposition = videoComposition

    do {
        try await export.export(to: outputURL, as: .mov)
    } catch {
        throw CheckError("synthetic export failed: \(error.localizedDescription)")
    }
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

private func makeSolidImage(width: Int, height: Int, color: (r: UInt8, g: UInt8, b: UInt8)) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = color.r
            bytes[offset + 1] = color.g
            bytes[offset + 2] = color.b
            bytes[offset + 3] = 255
        }
    }

    let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    return context?.makeImage()
}

private func makeGradientImage(width: Int, height: Int) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8(min(255, x * 255 / max(1, width - 1)))
            bytes[offset + 1] = UInt8(min(255, y * 255 / max(1, height - 1)))
            bytes[offset + 2] = 80
            bytes[offset + 3] = 255
        }
    }

    let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    return context?.makeImage()
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

private func hasRedPixel(in image: CGImage, xRange: Range<Int>, yRange: Range<Int>) -> Bool {
    for y in yRange {
        for x in xRange {
            let pixel = pixelColor(in: image, x: x, y: y)
            if pixel.r > 160 && pixel.g < 140 && pixel.b < 140 {
                return true
            }
        }
    }
    return false
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


/// Each retouch control has to actually change the picture on its own, and doing
/// nothing has to stay a true no-op (so "all off" really is the cheap path).
private func runBeautyPipelineChecks() {
    let width = 160
    let height = 120
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard let pixelBuffer = buffer else {
        expect(false, "beauty check allocates a pixel buffer")
        return
    }
    // Mid grey with a bright block, so smoothing has an edge to work against.
    fill(pixelBuffer, width: width, height: height, color: (r: 120, g: 110, b: 105))
    fillBlock(pixelBuffer, x: 55, y: 35, width: 50, height: 50, color: (r: 240, g: 235, b: 230))

    let processor = CameraFrameProcessor()
    func preferences(_ beauty: CameraBeautySettings) -> RecordingPreferences {
        RecordingPreferences(
            includeAppInterface: false,
            cameraBackgroundStyle: .original,
            cameraBackgroundBlur: .off,
            cameraBeauty: beauty
        )
    }
    func sample(_ beauty: CameraBeautySettings, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let image = processor.makePreviewImage(from: pixelBuffer, preferences: preferences(beauty)) else { return nil }
        return pixelColor(in: image, x: x, y: y)
    }

    // Sample right on the bright block's edge, where a surface blur has to change the
    // value; the middle of a flat block would look identical either way.
    guard let untouched = sample(.off, x: 54, y: 60),
          let smoothed = sample(CameraBeautySettings(smoothing: 1, whitening: 0, faceSlimming: 0), x: 54, y: 60),
          let flatUntouched = sample(.off, x: 20, y: 20),
          let whitened = sample(CameraBeautySettings(smoothing: 0, whitening: 1, faceSlimming: 0), x: 20, y: 20) else {
        expect(false, "beauty check renders preview frames")
        return
    }

    // Sampled on the bright block's edge, where blurring changes the value.
    let smoothingDelta = abs(Int(smoothed.r) - Int(untouched.r))
        + abs(Int(smoothed.g) - Int(untouched.g))
        + abs(Int(smoothed.b) - Int(untouched.b))
    expect(smoothingDelta > 6, "smoothing visibly softens the frame (delta \(smoothingDelta))")
    expect(Int(whitened.r) > Int(flatUntouched.r) + 5, "whitening brightens the frame")
    expect(Int(whitened.g) > Int(flatUntouched.g) + 5, "whitening brightens every channel")

    // Face slimming runs its own detection + warp path; exercise it repeatedly so the
    // detection throttle is executed too, not just the first frame.
    let slimming = CameraBeautySettings(smoothing: 0, whitening: 0, faceSlimming: 1)
    for _ in 0..<12 {
        guard sample(slimming, x: 20, y: 20) != nil else {
            expect(false, "face slimming renders a frame even when no face is detected")
            return
        }
    }

    guard let noBeauty = sample(.off, x: 20, y: 20) else {
        expect(false, "beauty check renders the untouched frame")
        return
    }
    expect(
        abs(Int(noBeauty.r) - 120) <= 2 && abs(Int(noBeauty.g) - 110) <= 2,
        "with every control at zero the frame comes through untouched"
    )
}

private func fillBlock(
    _ pixelBuffer: CVPixelBuffer,
    x originX: Int,
    y originY: Int,
    width blockWidth: Int,
    height blockHeight: Int,
    color: (r: UInt8, g: UInt8, b: UInt8)
) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in originY..<(originY + blockHeight) {
        let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in originX..<(originX + blockWidth) {
            let offset = x * 4
            row[offset] = color.b
            row[offset + 1] = color.g
            row[offset + 2] = color.r
            row[offset + 3] = 255
        }
    }
}
