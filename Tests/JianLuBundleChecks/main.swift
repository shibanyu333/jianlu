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

let appSourceURL = projectRoot.appendingPathComponent("Sources/JianLu/App/JianLuApp.swift")
let appSource = (try? String(contentsOf: appSourceURL, encoding: .utf8)) ?? ""
expect(appSource.contains("applicationShouldHandleReopen"), "Dock reopen restores the main JianLu window")
expect(appSource.contains("AppState.shared"), "WindowGroup and fallback AppKit window share one app state")
expect(!appSource.contains("init()"), "JianLu lets SwiftUI create its WindowGroup before fallback checks")
expect(appSource.contains("asyncAfter(deadline: .now() + 0.15)"), "JianLu delays fallback checks until after launch window restoration")
expect(appSource.contains("AppWindowUtility.restoreOrCreateMainWindow()"), "app activation paths bring the main window forward")

let appWindowUtilitySourceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/AppWindowUtility.swift")
let appWindowUtilitySource = (try? String(contentsOf: appWindowUtilitySourceURL, encoding: .utf8)) ?? ""
expect(appWindowUtilitySource.contains("fallbackMainWindowController"), "main window utility owns a reusable fallback main window")
expect(appWindowUtilitySource.contains("NSHostingView"), "fallback main window hosts SwiftUI content")
expect(appWindowUtilitySource.contains("ContentView()\n            .environmentObject(AppState.shared)"), "fallback main window shows the normal JianLu content")
expect(appWindowUtilitySource.contains("window.isReleasedWhenClosed = false"), "fallback main window can be shown again after close")
expect(appWindowUtilitySource.contains("restoreOrCreateMainWindow"), "main window utility restores or creates the main window")
expect(appWindowUtilitySource.contains("let hasVisibleMainWindow = restoreMainWindows()"), "main window utility checks restored visibility before creating fallback")
expect(
    appWindowUtilitySource.contains("Existing main window restored; skipping fallback main window"),
    "main window utility skips fallback creation when a visible main window already exists"
)
expect(
    !appWindowUtilitySource.contains("""
        _ = restoreMainWindows()
        showFallbackMainWindow()
"""),
    "main window utility avoids opening a duplicate fallback window"
)
expect(
    appWindowUtilitySource.contains("""
        let hasVisibleMainWindow = NSApp.windows.contains { window in
            isMainAppWindow(window) && window.isVisible
        }
"""),
    "main window restoration only succeeds when a visible main window exists"
)

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
expect(recordingOverlayViewSource.contains("let zoomViewportSize = captureSize"), "live zoom expands across the full recording region")
expect(recordingOverlayViewSource.contains("zoomedRegionImageFrame"), "live zoom uses the same full-region transform style as exported zoom")
expect(recordingOverlayViewSource.contains(".position(x: captureRect.midX, y: captureRect.midY)"), "live zoom fills the selected capture rect instead of a tiny lens")
expect(!recordingOverlayViewSource.contains(".clipShape(Circle())"), "live zoom is no longer a small circular lens")

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
expect(overlayServiceSource.contains("func prewarmZoomPreview()"), "overlay can prewarm a live zoom frame before the user presses the shortcut")
expect(
    !overlayServiceSource.contains("""
        zoomPreviewImage = nil
        appendZoomEvent(magnification: 1, focus: focus)
"""),
    "ending live zoom keeps the last preview frame for instant next-press feedback"
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
expect(captureServiceSource.contains("waitForFirstScreenFrame"), "screen recording warms the first frame before zoom hotkeys become useful")
expect(captureServiceSource.contains("Live zoom first frame"), "screen recording logs whether live zoom has a warm frame")
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
expect(appStateSource.contains("overlayService.prewarmZoomPreview()"), "recording startup primes live zoom after screen capture is ready")
expectOrder(
    "isRecording = true",
    before: "await captureService.waitForFirstScreenFrame()",
    in: appStateSource,
    "recording can still be stopped while live zoom preview is warming"
)
expect(appStateSource.contains("microphoneNoiseReductionEnabledForRecording = false"), "noise reduction startup failure falls back to ordinary microphone capture")
expect(appStateSource.contains("microphoneNoiseReductionEnabled: microphoneNoiseReductionEnabledForRecording"), "screen capture uses the noise reduction startup fallback state")
expect(appStateSource.contains("activeCameraRecordingOffset"), "recording projects store camera track alignment offset")
expect(appStateSource.contains("activeMicrophoneRecordingOffset"), "recording projects store microphone track alignment offset")
expect(appStateSource.contains("return recentProjects.first { $0.id == selectedProjectID } ?? recentProjects.first"), "stale selected project IDs fall back to the first available project")
expect(appStateSource.contains("deleteUnusedSidecarRecordings()"), "recordings with no exportable segments clean unreferenced sidecar files")
expect(
    appStateSource.contains("""
        } catch {
            if cameraCaptureService.hasActiveRecording {
                try? await cameraCaptureService.stopRecording()
            }
            if microphoneCaptureService.hasActiveRecording {
                try? microphoneCaptureService.stopRecording()
            }
            deleteUnusedSidecarRecordings()
"""),
    "stop recording failures also clean unreferenced sidecar files"
)
expect(appStateSource.contains("try? FileManager.default.removeItem(at: activeCameraRecordingURL)"), "no-export cleanup removes unused camera sidecars")
expect(appStateSource.contains("try? FileManager.default.removeItem(at: activeMicrophoneRecordingURL)"), "no-export cleanup removes unused microphone sidecars")
expectOrder(
    "deleteUnusedSidecarRecordings()\n            overlayService.endRecording()",
    before: "statusMessage = \"启动录制失败",
    in: appStateSource,
    "recording startup failures clean unreferenced camera and microphone sidecars"
)
expect(appStateSource.contains("renderedPreviewURLs[id] = outputURL"), "successful exports become the current editor preview")
expect(appStateSource.contains("renderedPreviewMessages[id] = \"导出完成，下面播放的是最新成片。\""), "successful exports explain that the preview is the final movie")
expectOrder(
    "deleteGeneratedPreviewIfNeeded(renderedPreviewURLs[id])",
    before: "renderedPreviewURLs[id] = outputURL",
    in: appStateSource,
    "successful exports delete the stale generated preview before replacing it with the final movie"
)
expect(appStateSource.contains("if let currentProject = recentProjects.first(where: { $0.id == id }) {\n                    ensureRenderedPreview(for: currentProject)\n                }"), "failed exports restart the rendered preview that export cancelled")
expect(appStateSource.contains("previewExportService.cancelCurrentExport()"), "cancelling rendered previews also cancels the export session")
expect(appStateSource.contains("deleteGeneratedPreviewIfNeeded"), "stale rendered previews are cleaned from disk")
expect(appStateSource.contains("url.lastPathComponent.hasPrefix(\"preview-\")"), "preview cleanup only removes generated preview files")
expectOrder(
    "deleteGeneratedPreviewIfNeeded(renderedPreviewURLs[project.id])",
    before: "renderedPreviewURLs[project.id] = nil",
    in: appStateSource,
    "stale preview files are deleted before dropping their URL"
)
expect(appStateSource.contains("if Task.isCancelled {\n                    deleteGeneratedPreviewIfNeeded(outputURL)\n                    return\n                }"), "cancelled preview tasks delete a completed but unused preview file")
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
expect(!contentViewSource.contains("keyboard.badge.exclamationmark"), "permission UI avoids unavailable SF Symbols that prevent the main window from rendering")

let statusBarControllerURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/StatusBarController.swift")
let statusBarControllerSource = (try? String(contentsOf: statusBarControllerURL, encoding: .utf8)) ?? ""
expect(statusBarControllerSource.contains("AppWindowUtility.restoreOrCreateMainWindow()"), "status bar can recreate a missing main window")

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
