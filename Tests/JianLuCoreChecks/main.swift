import Foundation
import JianLuCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Check failed: \(message)\n", stderr)
        exit(1)
    }
}

expect(CoreVersion.name == "JianLuCore", "core module exposes its name")
runTimelineChecks()
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

    let cameraLayout = CameraLayoutEvent(
        time: 3,
        frame: NormalizedRect(x: 0.72, y: 0.62, width: 0.22, height: 0.22),
        shape: .circle,
        isVisible: true
    )
    let project = RecordingProject(
        screenRecordingURL: URL(fileURLWithPath: "/tmp/screen.mov"),
        cameraRecordingURL: URL(fileURLWithPath: "/tmp/camera.mov"),
        events: [.cameraLayout(cameraLayout)],
        timeline: timeline
    )

    expect(project.duration == 5, "project duration follows edit timeline")
    expect(project.events.count == 1, "project stores camera layout events")
}
