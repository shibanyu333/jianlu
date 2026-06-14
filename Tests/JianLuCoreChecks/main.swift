import Foundation
import CoreGraphics
import JianLuCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Check failed: \(message)\n", stderr)
        exit(1)
    }
}

expect(CoreVersion.name == "JianLuCore", "core module exposes its name")
runTimelineChecks()
runPermissionGateChecks()
runPreferenceChecks()
print("JianLuCoreChecks passed")

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
