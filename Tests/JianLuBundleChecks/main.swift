import Foundation

func fail(_ message: String) -> Never {
    fputs("Bundle check failed: \(message)\n", stderr)
    exit(1)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fail(message)
    }
}

func occurrenceCount(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

func expectOrder(_ firstNeedle: String, before secondNeedle: String, in haystack: String, _ message: String) {
    guard let firstRange = haystack.range(of: firstNeedle),
          let secondRange = haystack.range(of: secondNeedle) else {
        fail(message)
    }
    expect(firstRange.lowerBound < secondRange.lowerBound, message)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fail("usage: JianLuBundleChecks /path/to/app.bundle")
}

let appURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
let fileManager = FileManager.default
let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
let executableURL = appURL.appendingPathComponent("Contents/MacOS/JianLu")

var isDirectory: ObjCBool = false
expect(fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory) && isDirectory.boolValue, "app bundle exists")
expect(fileManager.fileExists(atPath: infoPlistURL.path), "Info.plist exists")
expect(fileManager.isExecutableFile(atPath: executableURL.path), "JianLu executable is present and executable")

guard let infoPlist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] else {
    fail("Info.plist can be read")
}

func stringValue(_ key: String) -> String {
    guard let value = infoPlist[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fail("\(key) is present and non-empty")
    }
    return value
}

expect(stringValue("CFBundleExecutable") == "JianLu", "CFBundleExecutable is JianLu")
expect(stringValue("CFBundleIdentifier") == "com.local.JianLu", "CFBundleIdentifier is stable")
expect(stringValue("CFBundlePackageType") == "APPL", "bundle package type is APPL")
expect(stringValue("NSPrincipalClass") == "NSApplication", "NSPrincipalClass is NSApplication")

let minimumSystemVersion = stringValue("LSMinimumSystemVersion")
let minimumMajorVersion = Int(minimumSystemVersion.split(separator: ".").first ?? "") ?? 0
expect(minimumMajorVersion >= 15, "minimum macOS version is at least 15")

let usageDescriptionKeys = [
    "NSScreenCaptureUsageDescription",
    "NSCameraUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSAudioCaptureUsageDescription"
]
for key in usageDescriptionKeys {
    expect(stringValue(key).contains("简录"), "\(key) explains why JianLu needs the permission")
}

let projectRoot = appURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let environmentURL = projectRoot.appendingPathComponent(".codex/environments/environment.toml")
expect(fileManager.fileExists(atPath: environmentURL.path), "Codex environment config exists")

let environment = (try? String(contentsOf: environmentURL, encoding: .utf8)) ?? ""
expect(environment.contains("name = \"Run\""), "Codex Run action exists")
expect(environment.contains("command = \"./script/build_and_run.sh\""), "Codex Run action points at build_and_run.sh")

let controlBarSourceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/RecordingControlBarWindowController.swift")
let controlBarSource = (try? String(contentsOf: controlBarSourceURL, encoding: .utf8)) ?? ""
expect(controlBarSource.contains(".nonactivatingPanel"), "recording control bar does not activate JianLu while recording")
expect(controlBarSource.contains("panel.orderFrontRegardless()"), "recording control bar is shown without becoming key")

let regionSelectionSourceURL = projectRoot.appendingPathComponent("Sources/JianLu/Views/CaptureRegionSelectionView.swift")
let regionSelectionSource = (try? String(contentsOf: regionSelectionSourceURL, encoding: .utf8)) ?? ""
expect(regionSelectionSource.contains("@Published var isStarting"), "region selection exposes a starting state for duplicate click prevention")
expect(regionSelectionSource.contains("guard canStart, !isStarting else { return }"), "region selection confirms only once while recording starts")

let regionSelectionControllerURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/CaptureRegionSelectionWindowController.swift")
let regionSelectionController = (try? String(contentsOf: regionSelectionControllerURL, encoding: .utf8)) ?? ""
expect(regionSelectionController.contains("NSEvent.mouseLocation"), "region selection opens on the display under the pointer")

let overlayWindowSourceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/OverlayWindowController.swift")
let overlayWindowSource = (try? String(contentsOf: overlayWindowSourceURL, encoding: .utf8)) ?? ""
expect(overlayWindowSource.contains("recordingRegion.displayID"), "recording overlay follows the selected display")
expect(overlayWindowSource.contains("handleClickZoomPolling"), "click zoom mode has a mouse-state polling fallback")
expect(overlayWindowSource.contains("overlayService.beginClickZoom()"), "click zoom polling can start transient zoom")
expect(overlayWindowSource.contains("overlayService.endClickZoom()"), "click zoom polling can end transient zoom")

expect(controlBarSource.contains("recordingRegion.displayID"), "recording control bar follows the selected display")

let recordingOverlayViewURL = projectRoot.appendingPathComponent("Sources/JianLu/Views/RecordingOverlayView.swift")
let recordingOverlayViewSource = (try? String(contentsOf: recordingOverlayViewURL, encoding: .utf8)) ?? ""
expect(recordingOverlayViewSource.contains("ZoomLensGeometry.lensDiameter"), "live zoom renders as a local mouse-area lens")
expect(recordingOverlayViewSource.contains("clampedLensCenter"), "live zoom lens follows the mouse focus inside the capture rect")
expect(recordingOverlayViewSource.contains(".clipShape(Circle())"), "live zoom lens has an obvious circular magnifier frame")

let overlayServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/OverlayService.swift")
let overlayServiceSource = (try? String(contentsOf: overlayServiceURL, encoding: .utf8)) ?? ""
expect(
    overlayServiceSource.contains("if zoomClickModeEnabled {\n            selectedTool = nil\n            currentStrokePoints = []\n        }"),
    "click zoom mode exits annotation tools"
)
expect(
    overlayServiceSource.contains("if selectedTool != nil {\n            zoomClickModeEnabled = false\n            endTransientZoom()\n        }"),
    "annotation tools exit click zoom mode"
)

let hotkeyServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/HotkeyService.swift")
let hotkeyServiceSource = (try? String(contentsOf: hotkeyServiceURL, encoding: .utf8)) ?? ""
expect(hotkeyServiceSource.contains("startShortcutPolling()"), "zoom hotkeys have a keyboard-state polling fallback")
expect(hotkeyServiceSource.contains("CGEventSource.keyState"), "zoom hotkey polling reads the real key-down state")

let captureServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/CaptureService.swift")
let captureServiceSource = (try? String(contentsOf: captureServiceURL, encoding: .utf8)) ?? ""
expect(captureServiceSource.contains("cleanupAfterFailedStart"), "screen startup failures clean partial recorder state")
expect(captureServiceSource.contains("try? await stream.stopCapture()"), "screen startup cleanup stops a partially started stream")
expect(captureServiceSource.contains("recordingOutput = nil"), "screen startup cleanup clears recording output")
expect(captureServiceSource.contains("frameOutput.reset()"), "screen startup cleanup clears cached live zoom frames")
expect(captureServiceSource.contains("try? FileManager.default.removeItem(at: outputURL)"), "screen startup cleanup removes incomplete screen files")
expect(captureServiceSource.contains("defer {\n            cleanupAfterStop()"), "screen stop cleanup runs even when stop capture reports an error")
expect(captureServiceSource.contains("private func cleanupAfterStop()"), "screen stop cleanup is centralized")
expect(captureServiceSource.contains("stream = nil\n        recordingOutput = nil"), "screen stop cleanup clears stale stream and output references")

let appStateSourceURL = projectRoot.appendingPathComponent("Sources/JianLu/App/AppState.swift")
let appStateSource = (try? String(contentsOf: appStateSourceURL, encoding: .utf8)) ?? ""
expect(!appStateSource.contains("cameraEnabled = false"), "camera startup degradation does not rewrite the user's camera preference")
expect(occurrenceCount(of: "restartHotkeyMonitoringIfAuthorized()", in: appStateSource) >= 3, "hotkey event tap is restarted after Accessibility permission changes")
expect(occurrenceCount(of: "startHotkeyMonitoring()", in: appStateSource) >= 2, "hotkey monitoring startup is reusable after permissions are granted")
expect(appStateSource.contains("输入监控"), "recording startup explains that zoom hotkeys also need Input Monitoring permission")
expect(appStateSource.contains("microphoneNoiseReductionEnabledForRecording = false"), "noise reduction startup failure falls back to ordinary microphone capture")
expect(appStateSource.contains("microphoneNoiseReductionEnabled: microphoneNoiseReductionEnabledForRecording"), "screen capture uses the noise reduction startup fallback state")
expect(appStateSource.contains("activeCameraRecordingOffset"), "recording projects store camera track alignment offset")
expect(appStateSource.contains("activeMicrophoneRecordingOffset"), "recording projects store microphone track alignment offset")
expect(appStateSource.contains("renderedPreviewURLs[id] = outputURL"), "successful exports become the current editor preview")
expect(appStateSource.contains("renderedPreviewMessages[id] = \"导出完成，下面播放的是最新成片。\""), "successful exports explain that the preview is the final movie")
expect(appStateSource.contains("if let currentProject = recentProjects.first(where: { $0.id == id }) {\n                    ensureRenderedPreview(for: currentProject)\n                }"), "failed exports restart the rendered preview that export cancelled")
expect(appStateSource.contains("previewExportService.cancelCurrentExport()"), "cancelling rendered previews also cancels the export session")
expectOrder(
    "microphoneCaptureService.startRecording(preferences: preferences)",
    before: "captureService.startDisplayRecording",
    in: appStateSource,
    "noise-reduced microphone starts before screen capture so failures can fall back to ordinary microphone"
)

let exportServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/ExportService.swift")
let exportServiceSource = (try? String(contentsOf: exportServiceURL, encoding: .utf8)) ?? ""
expect(exportServiceSource.contains("project.cameraRecordingOffset"), "camera export uses the stored alignment offset")
expect(exportServiceSource.contains("project.microphoneRecordingOffset"), "microphone export uses the stored alignment offset")
expect(exportServiceSource.contains("alignedMediaRange"), "separate media tracks share an offset-aware source range helper")
expect(exportServiceSource.contains("func cancelCurrentExport()"), "export service exposes cancellation for stale previews")
expect(exportServiceSource.contains("activeExportSession?.cancelExport()"), "export service cancels the underlying AVAssetExportSession")
expect(exportServiceSource.contains("addScreenAudioTracks("), "screen audio export uses a helper that can handle multiple source tracks")
expect(exportServiceSource.contains("for screenAudioTrack in screenAudioTracks"), "screen audio export iterates each source track separately")
expect(exportServiceSource.contains("composition.addMutableTrack(withMediaType: .audio"), "screen audio export creates composition tracks for audio")
expect(exportServiceSource.contains("try? FileManager.default.removeItem(at: outputURL)"), "failed exports remove incomplete output files")
expectOrder(
    "try? FileManager.default.removeItem(at: outputURL)",
    before: "throw ExportServiceError.exportFailed",
    in: exportServiceSource,
    "failed exports remove the incomplete file before reporting the error"
)

let permissionServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/PermissionService.swift")
let permissionServiceSource = (try? String(contentsOf: permissionServiceURL, encoding: .utf8)) ?? ""
expect(permissionServiceSource.contains("CGPreflightListenEventAccess()"), "shortcut permission checks include macOS Input Monitoring")
expect(permissionServiceSource.contains("CGRequestListenEventAccess()"), "shortcut permission requests include macOS Input Monitoring")

let contentViewURL = projectRoot.appendingPathComponent("Sources/JianLu/Views/ContentView.swift")
let contentViewSource = (try? String(contentsOf: contentViewURL, encoding: .utf8)) ?? ""
expect(contentViewSource.contains("输入监控"), "permission UI names Input Monitoring for zoom hotkeys")

let microphoneCaptureServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/MicrophoneCaptureService.swift")
let microphoneCaptureServiceSource = (try? String(contentsOf: microphoneCaptureServiceURL, encoding: .utf8)) ?? ""
expect(microphoneCaptureServiceSource.contains("cleanupAfterFailedStart"), "microphone startup failures clean partial recorder state")
expect(microphoneCaptureServiceSource.contains("engine.inputNode.removeTap(onBus: 0)"), "microphone startup cleanup removes any installed tap")
expect(microphoneCaptureServiceSource.contains("try? engine.inputNode.setVoiceProcessingEnabled(false)"), "microphone startup cleanup disables voice processing")
expect(microphoneCaptureServiceSource.contains("try? FileManager.default.removeItem(at: outputURL)"), "microphone startup cleanup removes incomplete audio files")

let cameraCaptureServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/CameraCaptureService.swift")
let cameraCaptureServiceSource = (try? String(contentsOf: cameraCaptureServiceURL, encoding: .utf8)) ?? ""
expect(cameraCaptureServiceSource.contains("cleanupAfterFailedStart"), "camera startup failures clean partial recorder state")
expect(cameraCaptureServiceSource.contains("delegateProxy.sampleHandler = { _ in }"), "camera startup cleanup resets sample handling")
expect(cameraCaptureServiceSource.contains("await stopSessionIfRunning()"), "camera startup cleanup stops the camera session")
expect(cameraCaptureServiceSource.contains("try? FileManager.default.removeItem(at: outputURL)"), "camera startup cleanup removes incomplete video files")
expect(cameraCaptureServiceSource.contains("let failedOutputURL = currentOutputURL"), "camera stop failures remember the incomplete output file")
expect(cameraCaptureServiceSource.contains("try? FileManager.default.removeItem(at: failedOutputURL)"), "camera stop failures remove incomplete video files")

print("JianLuBundleChecks passed")
