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

func sourceSlice(in haystack: String, from startNeedle: String, to endNeedle: String) -> String {
    guard let startRange = haystack.range(of: startNeedle),
          let endRange = haystack.range(of: endNeedle, range: startRange.upperBound..<haystack.endIndex) else {
        fail("source slice markers exist: \(startNeedle) -> \(endNeedle)")
    }
    return String(haystack[startRange.lowerBound..<endRange.lowerBound])
}

func expectOrder(_ firstNeedle: String, before secondNeedle: String, in haystack: String, _ message: String) {
    guard let firstRange = haystack.range(of: firstNeedle),
          let secondRange = haystack.range(of: secondNeedle) else {
        fail(message)
    }
    expect(firstRange.lowerBound < secondRange.lowerBound, message)
}

func containsStandaloneAssignment(to variableName: String, value: String, in haystack: String) -> Bool {
    haystack.split(whereSeparator: \.isNewline).contains { line in
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "\(variableName) = \(value)"
    }
}

func expectOrder(_ orderedNeedles: [String], in haystack: String, _ message: String) {
    var searchStart = haystack.startIndex
    for needle in orderedNeedles {
        guard let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) else {
            fail(message)
        }
        searchStart = range.upperBound
    }
}

let arguments = CommandLine.arguments
let appURL = if arguments.count >= 2 {
    URL(fileURLWithPath: arguments[1], isDirectory: true)
} else {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("dist/简录.app", isDirectory: true)
}
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

let packageSourceURL = projectRoot.appendingPathComponent("Package.swift")
let packageSource = (try? String(contentsOf: packageSourceURL, encoding: .utf8)) ?? ""
expect(packageSource.contains("resources: ["), "JianLuCore declares bundled resources")
expect(packageSource.contains(".process(\"Resources\")"), "JianLuCore processes camera background resources")

let buildScriptURL = projectRoot.appendingPathComponent("script/build_and_run.sh")
let buildScriptSource = (try? String(contentsOf: buildScriptURL, encoding: .utf8)) ?? ""
expect(buildScriptSource.contains("--shortcut-permission|shortcut-permission"), "build script can diagnose shortcut permission requirements")
expect(buildScriptSource.contains("--repair-shortcut-permission|repair-shortcut-permission"), "build script can reset stale shortcut TCC records")
expect(buildScriptSource.contains("--verify-existing|verify-existing"), "build script can verify the currently signed app without rebuilding it")
expect(buildScriptSource.contains("--run-existing|run-existing"), "build script can launch the currently signed app without rebuilding it")
expect(buildScriptSource.contains("should_build=false"), "build script can skip rebuilds for permission diagnostics")
expect(buildScriptSource.contains("should_stop_running_app=false"), "permission diagnostics do not kill the app being inspected")
expect(buildScriptSource.contains("tccutil reset Accessibility"), "shortcut repair resets Accessibility permission for the current bundle id")
expect(buildScriptSource.contains("tccutil reset ListenEvent"), "shortcut repair resets Input Monitoring permission for the current bundle id")
expect(buildScriptSource.contains("kTCCServiceAccessibility"), "shortcut diagnostics inspect Accessibility TCC records")
expect(buildScriptSource.contains("kTCCServiceListenEvent"), "shortcut diagnostics inspect Input Monitoring TCC records")
expect(buildScriptSource.contains("click + and choose $APP_BUNDLE"), "shortcut repair explains how to add JianLu when Input Monitoring is empty")
expect(buildScriptSource.contains("APP_RESOURCES=\"$APP_CONTENTS/Resources\""), "build script stages app resources")
expect(buildScriptSource.contains("-name \"*.resources\""), "build script copies SwiftPM resource bundles into the app")
expectOrder(
    ["configure_mode", "if $should_stop_running_app", "if $should_build", "case \"$MODE\" in"],
    in: buildScriptSource,
    "build script decides whether to stop/build before dispatching a mode"
)

let cameraBackgroundResourceNames = [
    "office-photo.png",
    "bookshelf-photo.png",
    "meeting-room-photo.png",
    "city-window-photo.png",
    "light-studio-photo.png"
]
let sourceBackgroundDirectoryURL = projectRoot.appendingPathComponent("Sources/JianLuCore/Resources/CameraBackgrounds")
for resourceName in cameraBackgroundResourceNames {
    let sourceURL = sourceBackgroundDirectoryURL.appendingPathComponent(resourceName)
    expect(fileManager.fileExists(atPath: sourceURL.path), "\(resourceName) exists in source resources")
    let attributes = (try? fileManager.attributesOfItem(atPath: sourceURL.path)) ?? [:]
    let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
    expect(fileSize > 100_000, "\(resourceName) is a real raster background asset")
}
let appResourcesURL = appURL.appendingPathComponent("Contents/Resources")
let bundledResourcePaths = fileManager
    .enumerator(at: appResourcesURL, includingPropertiesForKeys: nil)?
    .compactMap { ($0 as? URL)?.path } ?? []
for resourceName in cameraBackgroundResourceNames {
    expect(
        bundledResourcePaths.contains { path in
            path.hasSuffix("/CameraBackgrounds/\(resourceName)") || path.hasSuffix("/\(resourceName)")
        },
        "\(resourceName) is included in the built app resources"
    )
}

let appSourceURL = projectRoot.appendingPathComponent("Sources/JianLu/App/JianLuApp.swift")
let appSource = (try? String(contentsOf: appSourceURL, encoding: .utf8)) ?? ""
expect(appSource.contains("applicationShouldHandleReopen"), "Dock reopen restores the main JianLu window")
expect(appSource.contains("AppState.shared"), "WindowGroup and fallback AppKit window share one app state")
expect(appSource.contains("Button(\"区域截图\")"), "app menu exposes a screenshot command")
expect(appSource.contains("appState.takeScreenshotIntent()"), "app menu routes screenshots through app state")
expect(!appSource.contains("init()"), "JianLu lets SwiftUI create its WindowGroup before fallback checks")
expect(appSource.contains("asyncAfter(deadline: .now() + 0.15)"), "JianLu delays fallback checks until after launch window restoration")
expect(appSource.contains("AppWindowUtility.restoreOrCreateMainWindow()"), "app activation paths bring the main window forward")

let appWindowUtilitySourceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/AppWindowUtility.swift")
let appWindowUtilitySource = (try? String(contentsOf: appWindowUtilitySourceURL, encoding: .utf8)) ?? ""
expect(appWindowUtilitySource.contains("mainWindowIdentifier"), "main window utility marks real JianLu main windows explicitly")
expect(appWindowUtilitySource.contains("fallbackMainWindowController"), "main window utility owns a reusable fallback main window")
expect(appWindowUtilitySource.contains("NSHostingView"), "fallback main window hosts SwiftUI content")
expect(appWindowUtilitySource.contains("ContentView()\n            .environmentObject(AppState.shared)"), "fallback main window shows the normal JianLu content")
expect(appWindowUtilitySource.contains("window.isReleasedWhenClosed = false"), "fallback main window can be shown again after close")
expect(appWindowUtilitySource.contains("restoreOrCreateMainWindow"), "main window utility restores or creates the main window")
expect(appWindowUtilitySource.contains("let hasVisibleMainWindow = restoreMainWindows()"), "main window utility checks restored visibility before creating fallback")
expect(appWindowUtilitySource.contains("for extraWindow in windows where extraWindow !== window"), "main window restoration orders out duplicate main windows")
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
    appWindowUtilitySource.contains("let hasVisibleMainWindow = window.isVisible"),
    "main window restoration only succeeds when a visible main window exists"
)

let controlBarSourceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/RecordingControlBarWindowController.swift")
let controlBarSource = (try? String(contentsOf: controlBarSourceURL, encoding: .utf8)) ?? ""
let controlBarViewURL = projectRoot.appendingPathComponent("Sources/JianLu/Views/RecordingControlBarView.swift")
let controlBarViewSource = (try? String(contentsOf: controlBarViewURL, encoding: .utf8)) ?? ""
let settingsViewURL = projectRoot.appendingPathComponent("Sources/JianLu/Views/SettingsView.swift")
let settingsViewSource = (try? String(contentsOf: settingsViewURL, encoding: .utf8)) ?? ""
expect(controlBarSource.contains(".nonactivatingPanel"), "recording control bar does not activate JianLu while recording")
expect(controlBarSource.contains("panel.orderFrontRegardless()"), "recording control bar is shown without becoming key")
expect(controlBarSource.contains("controlBarFrame(in:"), "recording control bar uses a reusable bounded layout helper")
expect(controlBarSource.contains("screenFrame.width - horizontalInset * 2"), "recording control bar width is bounded by the screen")
expect(!controlBarSource.contains("max(560"), "recording control bar avoids a hard minimum width that can exceed small screens")
expect(controlBarViewSource.contains("ScrollView(.horizontal, showsIndicators: false)"), "recording control bar keeps all named controls reachable on narrow screens")
expect(controlBarViewSource.contains("fixedSize(horizontal: true, vertical: false)"), "recording control bar does not squeeze button labels until they disappear")
expect(controlBarViewSource.contains("鼠标放大已开"), "main zoom toolbar button names the enabled mouse zoom mode")
expect(controlBarViewSource.contains("鼠标放大"), "main zoom toolbar button uses a simple Chinese label")
expect(controlBarViewSource.contains("overlay.requestToggleClickZoomMode()"), "main zoom toolbar action goes through the app intent feedback path")
expect(controlBarViewSource.contains("ControlBarButton(title: \"圆形\""), "main toolbar exposes a one-click circle annotation tool")
expect(controlBarViewSource.contains("缩小头像框"), "control menu can shrink the camera avatar")
expect(controlBarViewSource.contains("放大头像框"), "control menu can enlarge the camera avatar")
expect(controlBarViewSource.contains("ForEach(CameraFrameShape.allCases"), "control menu can choose every camera avatar shape")
expect(controlBarViewSource.contains("overlay.setCameraShape(shape)"), "control menu sets the selected camera avatar shape directly")
expect(!controlBarViewSource.contains("overlay.toggleFollowZoomMode()"), "toolbar no longer exposes a confusing always-on zoom mode")
expect(!controlBarViewSource.contains("点击模式"), "toolbar does not keep a second zoom button")
expect(!controlBarViewSource.contains("overlay.toggleClickZoomMode()"), "zoom toolbar action is not a silent direct state toggle")
expect(settingsViewSource.contains("Picker(\"默认头像形状\", selection: $appState.preferences.cameraShape)"), "settings expose the default camera avatar shape")
expect(settingsViewSource.contains("ForEach(CameraFrameShape.allCases"), "default camera avatar shape picker lists all supported shapes")
expect(settingsViewSource.contains("默认头像大小"), "settings expose a default camera avatar size control")
expect(settingsViewSource.contains("NormalizedRect.minCameraFrameSize...NormalizedRect.maxCameraFrameSize"), "camera avatar size slider uses the core clamped range")
expect(settingsViewSource.contains("appState.updateDefaultCameraSize(size)"), "camera avatar size slider persists through app state")
expect(settingsViewSource.contains("Picker(\"截图/录屏快捷键\", selection: $appState.preferences.captureShortcutPreset)"), "settings expose screenshot and recording shortcut mode")
expect(settingsViewSource.contains("CaptureShortcutPreset.allCases"), "shortcut mode picker lists all capture shortcut presets")
expect(settingsViewSource.contains("captureShortcutPreset.detail"), "settings explain capture shortcut replacement behavior")
expect(settingsViewSource.contains("Toggle(\"完成截图后自动复制到剪切板\", isOn: $appState.preferences.screenshotAutoCopyOnFinish)"), "settings expose screenshot auto-copy preference")

let regionSelectionSourceURL = projectRoot.appendingPathComponent("Sources/JianLu/Views/CaptureRegionSelectionView.swift")
let regionSelectionSource = (try? String(contentsOf: regionSelectionSourceURL, encoding: .utf8)) ?? ""
expect(regionSelectionSource.contains("enum CaptureRegionSelectionPurpose"), "region selection supports different recording and screenshot modes")
expect(regionSelectionSource.contains("case screenshot"), "region selection can label screenshot capture")
expect(regionSelectionSource.contains("var windowTitle"), "region selection purpose provides a matching window title")
expect(regionSelectionSource.contains("\"选择截图区域\""), "screenshot selection window title names screenshots, not recordings")
expect(regionSelectionSource.contains("enum CaptureRegionSelectionPhase"), "region selection uses an explicit selecting/capturing/editing state machine")
expect(regionSelectionSource.contains("@Published var phase: CaptureRegionSelectionPhase = .selecting"), "region selection exposes phase for duplicate click prevention")
expect(regionSelectionSource.contains("guard canStart else { return }"), "region selection confirms only once while capture starts")
expect(regionSelectionSource.contains("func beginEditing(image: CGImage)"), "region selection can enter inline screenshot editing")
expect(regionSelectionSource.contains("enum ScreenshotEditingTool"), "inline screenshot editing has dedicated tools")
expect(regionSelectionSource.contains("case text"), "inline screenshot editing supports text markup")
expect(regionSelectionSource.contains("case mosaic"), "inline screenshot editing supports mosaic markup")
expect(regionSelectionSource.contains("ScreenshotInlineToolbar"), "inline screenshot editing shows a local toolbar")
expect(regionSelectionSource.contains("ScreenshotMarkupRenderer.render"), "inline screenshot editing renders final markup through the screenshot renderer")
expect(regionSelectionSource.contains("struct CaptureWindowCandidate"), "screenshot selection can track window candidates")
expect(regionSelectionSource.contains("func updateWindowHover"), "screenshot selection can auto-highlight windows under the pointer")
expect(regionSelectionSource.contains("func confirmHoveredWindowSelection"), "screenshot selection can capture a hovered window with one click")
expect(regionSelectionSource.contains("Self.clamped("), "region selection clamps restored regions to the current screen")
expect(regionSelectionSource.contains("private static func clamped"), "region selection has a static clamp helper usable during initialization")
expect(regionSelectionSource.contains("DragGesture(minimumDistance: model.purpose == .screenshot ? 0 : 8)"), "screenshot selection accepts click-to-window while recording selection still ignores the opening click")
expect(regionSelectionSource.contains("model.confirmSelection()"), "screenshot drag release can immediately capture the selected area")
expect(regionSelectionSource.contains("SelectionCornerHandles"), "region selection highlights the selected area with visible corner handles")
expect(regionSelectionSource.contains("Return 开始录制，Esc 取消，⌃⌥⌘R 也可确认当前区域"), "region selection shows the actual available keyboard actions")
expect(!regionSelectionSource.contains("再次按主录制快捷键"), "region selection avoids vague shortcut wording")

let regionSelectionControllerURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/CaptureRegionSelectionWindowController.swift")
let regionSelectionController = (try? String(contentsOf: regionSelectionControllerURL, encoding: .utf8)) ?? ""
expect(regionSelectionController.contains("NSEvent.mouseLocation"), "region selection opens on the display under the pointer")
expect(regionSelectionController.contains("panel.title = purpose.windowTitle"), "region selection window title follows recording or screenshot purpose")
expect(regionSelectionController.contains("override func keyDown"), "region selection supports keyboard shortcuts")
expect(regionSelectionController.contains("case 53"), "region selection lets Escape cancel selection")
expect(regionSelectionController.contains("case 36, 76"), "region selection lets Return confirm selection")
expect(regionSelectionController.contains("model?.confirmDefaultAction()"), "Return completes inline screenshot editing after selection")
expect(regionSelectionController.contains("hideForCapture"), "region selection can hide itself before ScreenCaptureKit captures")
expect(regionSelectionController.contains("beginEditing(image: CGImage)"), "region selection controller can show captured images inline")
expect(regionSelectionController.contains("preferredFullScreenRegion"), "full-screen screenshots use the pointer display region")
expect(regionSelectionController.contains("windowCandidates(for:"), "screenshot selection collects on-screen windows for auto selection")
expect(regionSelectionController.contains("CGWindowListCopyWindowInfo"), "screenshot window auto-selection uses the system window list")
expect(regionSelectionController.contains("acceptsMouseMovedEvents = true"), "screenshot selection receives hover updates without dragging")

let overlayWindowSourceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/OverlayWindowController.swift")
let overlayWindowSource = (try? String(contentsOf: overlayWindowSourceURL, encoding: .utf8)) ?? ""
expect(overlayWindowSource.contains("recordingRegion.displayID"), "recording overlay follows the selected display")
expect(overlayWindowSource.contains("handleClickZoomPolling"), "click zoom mode has a mouse-state polling fallback")
expect(overlayWindowSource.contains("overlayService.beginClickZoom()"), "click zoom polling can start transient zoom")
expect(overlayWindowSource.contains("overlayService.endClickZoom()"), "click zoom polling can end transient zoom")
expect(overlayWindowSource.contains("0.016"), "click zoom polling is frequent enough to catch ordinary mouse presses")
expect(overlayWindowSource.contains("overlayService.zoomClickModeEnabled || overlayService.zoomShortcutActive"), "holding the zoom shortcut can use the same region-aware click zoom path")
expect(
    !overlayWindowSource.contains("overlayService.zoomClickModeEnabled, captureRect.contains(screenPoint)"),
    "mouse zoom mode observes clicks without stealing them from the recorded app"
)
expect(overlayWindowSource.contains("panel.isFloatingPanel = true"), "recording overlay is configured as an interactive floating panel")
expect(overlayWindowSource.contains("panel.worksWhenModal = true"), "recording overlay continues to accept annotation gestures above modal surfaces")
expect(overlayWindowSource.contains("panel.becomesKeyOnlyIfNeeded = false"), "recording overlay can become key for SwiftUI annotation gestures")
expect(overlayWindowSource.contains("override var canBecomeKey: Bool { true }"), "recording overlay panel accepts pointer gestures for annotations")

expect(controlBarSource.contains("recordingRegion.displayID"), "recording control bar follows the selected display")

let recordingOverlayViewURL = projectRoot.appendingPathComponent("Sources/JianLu/Views/RecordingOverlayView.swift")
let recordingOverlayViewSource = (try? String(contentsOf: recordingOverlayViewURL, encoding: .utf8)) ?? ""
expect(recordingOverlayViewSource.contains("LiveZoomViewportView"), "live zoom uses an open-recorder-style full viewport zoom")
expect(recordingOverlayViewSource.contains("ZoomLensGeometry(lensSize: captureSize)"), "live zoom treats the whole recording region as the zoom viewport")
expect(recordingOverlayViewSource.contains("zoomedRegionImageFrame"), "live zoom anchors the enlarged screen content under the cursor focus")
expect(
    recordingOverlayViewSource.contains("focusPoint(")
        && recordingOverlayViewSource.contains("CGRect(origin: .zero, size: captureSize)"),
    "live zoom marker follows the anchored cursor focus"
)
expect(recordingOverlayViewSource.contains(".frame(width: captureRect.width, height: captureRect.height)"), "live zoom covers the selected recording region")
expect(recordingOverlayViewSource.contains(".position(x: captureRect.midX, y: captureRect.midY)"), "live zoom stays aligned with the selected recording region")
expect(recordingOverlayViewSource.contains("transaction.animation = nil"), "cursor-follow zoom position updates do not leave trailing animation ghosts")
expect(!recordingOverlayViewSource.contains(".animation(.easeInOut(duration: 0.08), value: overlay.currentZoomFocus)"), "cursor-follow zoom focus no longer animates every mouse move")
expect(recordingOverlayViewSource.contains(".frame(width: geometry.size.width, height: geometry.size.height)"), "annotation canvas has a stable full-overlay hit target")
expect(recordingOverlayViewSource.contains("@ObservedObject var cameraService: CameraCaptureService"), "recording overlay observes processed camera preview updates")
expect(recordingOverlayViewSource.contains("processedImage: cameraService.processedPreviewImage"), "picture-in-picture uses processed camera frames when available")
expect(!recordingOverlayViewSource.contains("LiveZoomLensView"), "live zoom is not a small magnifier window")
expect(!recordingOverlayViewSource.contains("zoomedImageFrame("), "live zoom no longer jumps the cursor focus to the center")

let cameraPreviewViewURL = projectRoot.appendingPathComponent("Sources/JianLu/Views/CameraPreviewView.swift")
let cameraPreviewViewSource = (try? String(contentsOf: cameraPreviewViewURL, encoding: .utf8)) ?? ""
expect(!cameraPreviewViewSource.contains("fatalError"), "camera preview view does not keep a latent crash path")
expect(cameraPreviewViewSource.contains("private func configurePreviewLayer()"), "camera preview view shares setup across code and coder initializers")
expect(cameraPreviewViewSource.contains("let processedImage: CGImage?"), "camera preview can show the processed camera frame")
expect(cameraPreviewViewSource.contains("CameraPreviewLayerView(session: session)"), "camera preview keeps the raw camera layer as a fallback")
expect(cameraPreviewViewSource.contains("Image(decorative: processedImage"), "camera preview overlays processed background and beauty frames")

let overlayServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/OverlayService.swift")
let overlayServiceSource = (try? String(contentsOf: overlayServiceURL, encoding: .utf8)) ?? ""
expect(overlayServiceSource.contains("cameraService: CameraCaptureService"), "overlay receives the camera service so live processed frames can update")
expect(overlayServiceSource.contains("func setCameraVisibility(_ isVisible: Bool)"), "overlay can set camera visibility without relying on toggle state")
expect(overlayServiceSource.contains("private var onToggleClickZoomMode"), "overlay can route click zoom requests back to app state")
expect(overlayServiceSource.contains("func requestToggleClickZoomMode()"), "overlay exposes a click zoom request instead of silent toolbar mutation")
expect(overlayServiceSource.contains("@Published var zoomFollowModeEnabled"), "overlay exposes a simple follow zoom mode")
expect(overlayServiceSource.contains("@Published var zoomShortcutActive"), "overlay exposes shortcut-held zoom state")
expect(overlayServiceSource.contains("func toggleFollowZoomMode()"), "overlay can toggle direct visible zoom from the toolbar")
expect(overlayServiceSource.contains("func setCameraSize(_ size: Double)"), "overlay can resize the camera avatar from controls")
expect(overlayServiceSource.contains("func setCameraShape(_ shape: CameraFrameShape)"), "overlay can set each camera avatar shape explicitly")
expect(overlayServiceSource.contains("func setCameraLayout(frame: NormalizedRect, shape: CameraFrameShape)"), "overlay can sync persisted camera avatar layout through one recording-aware path")
expect(overlayServiceSource.contains("private var onCameraLayoutChanged"), "overlay can report camera avatar layout changes")
expect(overlayServiceSource.contains("onCameraLayoutChanged?(cameraFrame, cameraShape)"), "overlay reports persisted camera avatar frame and shape")
expect(overlayServiceSource.contains("guard zoomClickModeEnabled || zoomShortcutActive else { return }"), "hold shortcut plus mouse click can trigger zoom without enabling toolbar click mode")
expect(
    overlayServiceSource.contains("""
        if zoomFollowModeEnabled {
            zoomClickModeEnabled = false
            selectedTool = nil
            currentStrokePoints = []
            beginTransientZoom()
        } else {
            endTransientZoom()
        }
"""),
    "follow zoom immediately starts visible live zoom and exits click/annotation tools"
)
expect(
    overlayServiceSource.contains("if zoomClickModeEnabled {")
        && overlayServiceSource.contains("zoomFollowModeEnabled = false")
        && overlayServiceSource.contains("selectedTool = nil")
        && overlayServiceSource.contains("currentStrokePoints = []"),
    "click zoom mode exits annotation tools"
)
expect(
    overlayServiceSource.contains("if selectedTool != nil {")
        && overlayServiceSource.contains("zoomFollowModeEnabled = false")
        && overlayServiceSource.contains("zoomClickModeEnabled = false")
        && overlayServiceSource.contains("endTransientZoom()"),
    "annotation tools exit zoom modes"
)
expect(overlayServiceSource.contains("func prewarmZoomPreview()"), "overlay can prewarm a live zoom frame before the user presses the shortcut")
expect(overlayServiceSource.contains("private let liveZoomFrameInterval: TimeInterval = 1.0 / 30.0"), "live zoom refreshes often enough to feel smooth without overloading capture")
expect(overlayServiceSource.contains("withAnimation(.easeInOut(duration: 0.12))"), "live zoom fades in and out smoothly")
expect(overlayServiceSource.contains("currentZoomFocus = focus"), "live zoom follows the current mouse focus directly")
expect(overlayServiceSource.contains("zoomFocusRecordInterval"), "live zoom records cursor focus often enough to match the clicked position")
expect(!overlayServiceSource.contains("resolvedLiveZoomFocus"), "live zoom no longer lags behind through export safe-zone focus resolution")
expect(overlayServiceSource.contains("isMouseInsideRecordingRegion()"), "click zoom starts only when the mouse is inside the recording region")
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
expect(hotkeyServiceSource.contains("CaptureShortcutPreset"), "hotkey service reads screenshot and recording shortcut mode")
expect(hotkeyServiceSource.contains("case .macReplacement"), "hotkey service supports Mac-style shortcut replacement")
expect(hotkeyServiceSource.contains("shouldSuppressSystemShortcut"), "Mac-style replacement can suppress the original system shortcut when the event tap allows it")
expect(hotkeyServiceSource.contains("guard preset == .macReplacement else { return false }"), "default shortcut mode does not suppress original macOS screenshot shortcuts")
expect(hotkeyServiceSource.contains("markSuppressedCaptureKeyDown"), "replacement shortcuts remember swallowed key-down events")
expect(hotkeyServiceSource.contains("consumeSuppressedCaptureKeyUp"), "replacement shortcuts also swallow the matching key-up event")
expect(!hotkeyServiceSource.contains("guard event.type == .keyDown, !event.isRepeat else { return false }"), "replacement shortcut suppression is not limited to the initial key-down event")
expect(hotkeyServiceSource.contains("capturePreset != .macReplacement || eventTap != nil"), "Mac-style replacement shortcuts only fire when the suppressing event tap is active")
expect(hotkeyServiceSource.contains("tap: .cghidEventTap"), "replacement shortcuts are intercepted at the HID event tap before macOS screenshot shortcuts")
expect(!hotkeyServiceSource.contains("tap: .cgSessionEventTap"), "replacement shortcuts do not rely on a later session event tap")
expect(hotkeyServiceSource.contains("options: .defaultTap"), "hotkey event tap is capable of suppressing handled system shortcuts")
expect(hotkeyServiceSource.contains("return shouldSuppress ? nil : Unmanaged.passUnretained(event)"), "handled replacement shortcuts are swallowed before macOS receives them")
expect(hotkeyServiceSource.contains("case 15:\n            handler?(.toggleRecording)"), "default recording shortcut toggles recording instead of only stopping")
expect(!hotkeyServiceSource.contains("leftMouseDown"), "click zoom is driven by region-aware overlay polling instead of global mouse-down events")
expect(!hotkeyServiceSource.contains("beginClickZoom"), "hotkey service does not start click zoom outside the recording region")

let screenshotCaptureServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/ScreenshotCaptureService.swift")
let screenshotCaptureServiceSource = (try? String(contentsOf: screenshotCaptureServiceURL, encoding: .utf8)) ?? ""
expect(screenshotCaptureServiceSource.contains("SCScreenshotManager.captureImage"), "screenshot capture uses ScreenCaptureKit image capture")
expect(screenshotCaptureServiceSource.contains("includeAppWindows"), "screenshot capture respects the include-app-window preference")
expect(screenshotCaptureServiceSource.contains("CGImageDestinationFinalize"), "screenshot capture service can write PNG output")

let screenshotMarkupURL = projectRoot.appendingPathComponent("Sources/JianLuCore/Models/ScreenshotMarkup.swift")
let screenshotMarkupSource = (try? String(contentsOf: screenshotMarkupURL, encoding: .utf8)) ?? ""
expect(screenshotMarkupSource.contains("public enum ScreenshotMarkup"), "screenshot markup has a dedicated core model")
expect(screenshotMarkupSource.contains("case stroke(AnnotationEvent)"), "screenshot markup reuses existing stroke annotations")
expect(screenshotMarkupSource.contains("ScreenshotTextMarkup"), "screenshot markup supports text")
expect(screenshotMarkupSource.contains("ScreenshotMosaicMarkup"), "screenshot markup supports mosaic regions")

let screenshotMarkupRendererURL = projectRoot.appendingPathComponent("Sources/JianLuCore/Export/ScreenshotMarkupRenderer.swift")
let screenshotMarkupRendererSource = (try? String(contentsOf: screenshotMarkupRendererURL, encoding: .utf8)) ?? ""
expect(screenshotMarkupRendererSource.contains("public enum ScreenshotMarkupRenderer"), "screenshot markup renderer is available to the app")
expect(screenshotMarkupRendererSource.contains("imageByApplyingMosaics"), "screenshot markup renderer applies mosaics before drawing annotations")
expect(screenshotMarkupRendererSource.contains("CTLineDraw"), "screenshot markup renderer burns text into copied or saved images")

let captureServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/CaptureService.swift")
let captureServiceSource = (try? String(contentsOf: captureServiceURL, encoding: .utf8)) ?? ""
expect(captureServiceSource.contains("cleanupAfterFailedStart"), "screen startup failures clean partial recorder state")
expect(captureServiceSource.contains("try? await stream.stopCapture()"), "screen startup cleanup stops a partially started stream")
expect(captureServiceSource.contains("recordingOutput = nil"), "screen startup cleanup clears recording output")
expect(captureServiceSource.contains("frameOutput.reset()"), "screen startup cleanup clears cached live zoom frames")
expect(captureServiceSource.contains("waitForFirstScreenFrame"), "screen recording warms the first frame before zoom hotkeys become useful")
expect(captureServiceSource.contains("Live zoom first frame"), "screen recording logs whether live zoom has a warm frame")
expect(captureServiceSource.contains("try? FileManager.default.removeItem(at: outputURL)"), "screen startup cleanup removes incomplete screen files")

let projectVideoBuilderURL = projectRoot.appendingPathComponent("Sources/JianLuCore/Export/ProjectVideoCompositionBuilder.swift")
let projectVideoBuilderSource = (try? String(contentsOf: projectVideoBuilderURL, encoding: .utf8)) ?? ""
expect(projectVideoBuilderSource.contains("let usesCustomCompositor = cameraTrackID != nil || hasActiveZoom || !annotationEvents.isEmpty"), "export routes camera, active zoom, and annotations through the same compositor")
expect(projectVideoBuilderSource.contains("annotationEvents: annotationEvents"), "custom compositor receives exported annotations")
expect(!projectVideoBuilderSource.contains("animationTool"), "project export builder never combines CoreAnimationTool with the custom video compositor")
expect(projectVideoBuilderSource.contains("project.cameraRecordingOffset"), "camera export uses the stored alignment offset")
expect(projectVideoBuilderSource.contains("project.microphoneRecordingOffset"), "microphone export uses the stored alignment offset")
expect(projectVideoBuilderSource.contains("alignedMediaRange"), "separate media tracks share an offset-aware source range helper")
expect(projectVideoBuilderSource.contains("addScreenAudioTracks("), "screen audio export uses a helper that can handle multiple source tracks")
expect(projectVideoBuilderSource.contains("for screenAudioTrack in screenAudioTracks"), "screen audio export iterates each source track separately")
expect(projectVideoBuilderSource.contains("composition.addMutableTrack(\n                withMediaType: .audio"), "screen audio export creates composition tracks for audio")
expect(projectVideoBuilderSource.contains("projectClampedToScreenDuration"), "project export clamps old timelines to the actual screen asset duration")
expect(projectVideoBuilderSource.contains("screenAsset.load(.duration)"), "project export reads the real screen asset duration")

let cameraCompositorURL = projectRoot.appendingPathComponent("Sources/JianLuCore/Export/CameraShapeVideoCompositor.swift")
let cameraCompositorSource = (try? String(contentsOf: cameraCompositorURL, encoding: .utf8)) ?? ""
let exportZoomTimelineURL = projectRoot.appendingPathComponent("Sources/JianLuCore/Export/ExportZoomTimeline.swift")
let exportZoomTimelineSource = (try? String(contentsOf: exportZoomTimelineURL, encoding: .utf8)) ?? ""
expect(exportZoomTimelineSource.contains("rampInSeconds = 0.45"), "export zoom copies open-recorder's balanced ramp-in timing")
expect(exportZoomTimelineSource.contains("rampOutSeconds = 0.35"), "export zoom copies open-recorder's balanced ramp-out timing")
expect(exportZoomTimelineSource.contains("smoothstep"), "export zoom uses open-recorder-style eased progress")
expect(exportZoomTimelineSource.contains("focusClampRange = 0.0...1.0"), "export zoom preserves the clicked focus instead of pushing edge clicks inward")
expect(exportZoomTimelineSource.contains("focus = clamped(state.focus)"), "export zoom follows the latest recorded cursor focus exactly")
expect(exportZoomTimelineSource.contains("resolvedFocus"), "export zoom follows cursor focus without jitter")
expect(exportZoomTimelineSource.contains("CGAffineTransform(translationX: -focus.x, y: -focus.y)"), "export zoom anchors the transform at the cursor focus")
expect(cameraCompositorSource.contains("public let zoomRegions"), "camera compositor precomputes zoom regions outside the per-frame render path")
expect(cameraCompositorSource.contains("annotationEvents"), "camera compositor receives annotation events for custom export")
expect(cameraCompositorSource.contains("compositeAnnotations"), "camera compositor draws annotations without CoreAnimationTool")
expectOrder(
    "image = compositeAnnotations(",
    before: "image = zoomedImage(",
    in: cameraCompositorSource,
    "camera compositor applies zoom to the full composed frame"
)
expect(captureServiceSource.contains("defer {\n            cleanupAfterStop()"), "screen stop cleanup runs even when stop capture reports an error")
expect(captureServiceSource.contains("private func cleanupAfterStop()"), "screen stop cleanup is centralized")
expect(captureServiceSource.contains("stream = nil\n        recordingOutput = nil"), "screen stop cleanup clears stale stream and output references")

let appStateSourceURL = projectRoot.appendingPathComponent("Sources/JianLu/App/AppState.swift")
let appStateSource = (try? String(contentsOf: appStateSourceURL, encoding: .utf8)) ?? ""
expect(appStateSource.contains("@Published var isStartingRecording"), "app state exposes recording startup state")
expect(appStateSource.contains("@Published var isPreparingScreenshot"), "app state exposes screenshot preparation state")
expect(appStateSource.contains("@Published var isSelectingScreenshot"), "app state exposes screenshot region selection state")
expect(appStateSource.contains("private let screenshotCaptureService = ScreenshotCaptureService()"), "app state owns screenshot capture service")
expect(appStateSource.contains("private let regionSelectionController = CaptureRegionSelectionWindowController()"), "app state owns the inline screenshot selection/editor window")
expect(appStateSource.contains("func takeScreenshotIntent()"), "app state exposes a screenshot intent")
expect(appStateSource.contains("func takeFullScreenshotIntent()"), "app state exposes full-screen screenshot intent")
expect(appStateSource.contains("private func beginScreenshotSelection() async"), "app state can open screenshot region selection")
expect(appStateSource.contains("private func captureScreenshot(region: RecordingRegion?, rememberRegion: Bool) async"), "app state can capture selected or full screenshots")
expect(appStateSource.contains("private func finishScreenshotEditing"), "app state completes inline screenshot editing")
expect(appStateSource.contains("preferences.screenshotAutoCopyOnFinish"), "app state respects the screenshot auto-copy preference")
let screenshotSelectionAppStateSource = sourceSlice(
    in: appStateSource,
    from: "private func beginScreenshotSelection() async",
    to: "private func cancelScreenshotSelection()"
)
expect(
    !screenshotSelectionAppStateSource.contains("AppWindowUtility.minimizeMainWindows()"),
    "screenshot region selection does not minimize JianLu windows"
)
let screenshotCaptureAppStateSource = sourceSlice(
    in: appStateSource,
    from: "private func captureScreenshot(region: RecordingRegion?, rememberRegion: Bool) async",
    to: "private func finishScreenshotEditing"
)
expect(screenshotCaptureAppStateSource.contains("regionSelectionController.hideForCapture()"), "screenshot capture hides the overlay before ScreenCaptureKit captures")
expect(screenshotCaptureAppStateSource.contains("regionSelectionController.beginEditing(image: image)"), "screenshot capture returns the image to the inline editor")
expect(screenshotCaptureAppStateSource.contains("Task.sleep(nanoseconds: 120_000_000)"), "screenshot capture waits for the selection overlay to disappear")
expect(
    !screenshotCaptureAppStateSource.contains("AppWindowUtility.restoreMainWindows()"),
    "screenshot capture stays in the inline editor instead of restoring every main window"
)
expect(appStateSource.contains("try screenshotCaptureService.writePNG(image, to: url)"), "app state saves annotated screenshots through PNG writer")
expect(appStateSource.contains("NSPasteboard.general"), "app state copies annotated screenshots to the clipboard")
expect(appStateSource.contains("syncCameraProcessingPreferences(preferences)"), "preference changes immediately sync camera processing")
expect(appStateSource.contains("cameraCaptureService.updatePreviewPreferences(preferences)"), "camera background settings update live preview preferences")
expect(appStateSource.contains("cameraCaptureService.updateRecordingPreferences(preferences)"), "camera background settings update the active recording writer")
expect(appStateSource.contains("overlayService.cameraFrame = preferences.cameraFrame"), "app restores the saved camera avatar frame on launch")
expect(appStateSource.contains("overlayService.cameraShape = preferences.cameraShape"), "app restores the saved camera avatar shape on launch")
expect(appStateSource.contains("func updateDefaultCameraSize(_ size: Double)"), "settings can persist a default camera avatar size")
expect(appStateSource.contains("overlayService.setCameraLayout(frame: preferences.cameraFrame, shape: preferences.cameraShape)"), "preference changes sync camera avatar layout through the recording-aware overlay path")
expect(appStateSource.contains("private func updateDefaultCameraLayout(frame: NormalizedRect, shape: CameraFrameShape)"), "app can persist camera avatar layout changes")
expect(appStateSource.contains("preferences.cameraFrame = frame"), "camera avatar frame changes are saved to preferences")
expect(appStateSource.contains("preferences.cameraShape = shape"), "camera avatar shape changes are saved to preferences")
expect(appStateSource.contains("overlayService.setCameraLayout(frame: recordingPreferences.cameraFrame, shape: recordingPreferences.cameraShape)"), "recording startup syncs the camera avatar layout from current preferences")
expectOrder(
    "overlayService.setCameraLayout(frame: recordingPreferences.cameraFrame, shape: recordingPreferences.cameraShape)",
    before: "overlayService.beginRecording(",
    in: appStateSource,
    "camera avatar layout is synced before the recording overlay is shown"
)
expect(appStateSource.contains("guard !isStartingRecording else"), "recording intent ignores duplicate actions while startup is in progress")
expect(appStateSource.contains("isStartingRecording = true"), "recording startup state is set before devices and overlay are started")
expect(appStateSource.contains("isStartingRecording = false"), "recording startup state is cleared after success or failure")
expect(appStateSource.contains("func toggleCameraIntent() {\n        guard !isStartingRecording else"), "camera toggle is ignored while recording startup is in progress")
expect(appStateSource.contains("private func toggleRecordingCameraVisibility()"), "recording camera toggle is separated from the default camera preference")
expectOrder(
    "if isRecording {\n            toggleRecordingCameraVisibility()\n            return\n        }",
    before: "cameraEnabled.toggle()",
    in: appStateSource,
    "recording camera visibility changes do not rewrite the next-recording default"
)
expect(
    !containsStandaloneAssignment(to: "cameraEnabled", value: "false", in: appStateSource),
    "camera startup degradation does not rewrite the user's camera preference"
)
expect(appStateSource.contains("cameraCaptureService.hasActiveRecording"), "recording camera toggle checks that a camera track is actually being recorded")
expect(appStateSource.contains("let nextVisibility = !overlayService.cameraVisible"), "recording camera toggle flips the live overlay visibility")
expect(appStateSource.contains("overlayService.setCameraVisibility"), "recording camera toggle sets overlay visibility explicitly")
expect(!appStateSource.contains("overlayService.toggleCameraVisibility()"), "recording camera toggle does not blindly invert overlay state")
expect(appStateSource.contains("摄像头头像框已显示"), "recording camera toggle confirms when the avatar is visible")
expect(appStateSource.contains("摄像头头像框已隐藏"), "recording camera toggle confirms when the avatar is hidden")
expect(appStateSource.contains("func toggleClickZoomModeIntent()"), "app state owns click zoom feedback")
expect(appStateSource.contains("鼠标放大已开启"), "mouse zoom enable action has visible Chinese feedback")
expect(appStateSource.contains("鼠标放大已关闭"), "mouse zoom disable action has visible Chinese feedback")
expect(appStateSource.contains("录制已暂停，继续后可使用鼠标放大"), "paused mouse zoom action has visible Chinese feedback")
expect(appStateSource.contains("onToggleClickZoomMode:"), "recording overlay receives a click zoom intent callback")
expect(appStateSource.contains("onCameraLayoutChanged:"), "recording overlay reports avatar layout changes for persistence")
expect(appStateSource.contains("private var activeRecordingPreferences"), "recording stores a snapshot of preferences used for the active capture")
expectOrder(
    "preferences.lastSelectedRegion = region",
    before: "let recordingPreferences = preferences",
    in: appStateSource,
    "recording preference snapshot includes the confirmed capture region"
)
expect(appStateSource.contains("var actualRecordingPreferences = recordingPreferences"), "recording tracks actual preferences after startup downgrades")
expect(appStateSource.contains("actualRecordingPreferences.cameraEnabled = false"), "camera startup downgrade is reflected in the recorded project preferences")
expect(appStateSource.contains("actualRecordingPreferences.microphoneNoiseReductionEnabled = false"), "noise reduction downgrade is reflected in the recorded project preferences")
expect(appStateSource.contains("activeRecordingPreferences = actualRecordingPreferences"), "recording stores downgraded preferences before project creation")
expect(appStateSource.contains("activeRecordingPreferences.cameraBackgroundStyle = preferences.cameraBackgroundStyle"), "recording metadata follows live camera background style changes")
expect(appStateSource.contains("activeRecordingPreferences.cameraBackgroundBlur = preferences.cameraBackgroundBlur"), "recording metadata follows live camera blur changes")
expect(appStateSource.contains("activeRecordingPreferences.cameraBeautyLevel = preferences.cameraBeautyLevel"), "recording metadata follows live camera beauty changes")
expectOrder(
    "actualRecordingPreferences.cameraEnabled = false",
    before: "activeRecordingPreferences = actualRecordingPreferences",
    in: appStateSource,
    "camera downgrade is applied before active recording preferences are refreshed"
)
expect(appStateSource.contains("cameraCaptureService.startRecording(preferences: recordingPreferences)"), "camera recording uses the frozen recording preferences")
expect(appStateSource.contains("microphoneCaptureService.startRecording(preferences: recordingPreferences)"), "noise-reduced microphone recording uses the frozen recording preferences")
expect(appStateSource.contains("includeAppWindows: recordingPreferences.includeAppInterface"), "screen capture include-app setting comes from the frozen recording preferences")
expect(appStateSource.contains("directoryPath: recordingPreferences.recordingDirectoryPath"), "recording files are written to the directory selected at recording start")
expect(appStateSource.contains("let projectPreferences = activeRecordingPreferences ?? preferences"), "recording project falls back only if the active preference snapshot is unavailable")
expect(appStateSource.contains("preferences: projectPreferences"), "recording project stores the frozen preferences used by the capture")
expect(occurrenceCount(of: "restartHotkeyMonitoringIfAuthorized()", in: appStateSource) >= 3, "hotkey event tap is restarted after Accessibility permission changes")
expect(occurrenceCount(of: "startHotkeyMonitoring()", in: appStateSource) >= 2, "hotkey monitoring startup is reusable after permissions are granted")
expect(appStateSource.contains("输入监控"), "recording startup explains that zoom hotkeys also need Input Monitoring permission")
expect(appStateSource.contains("快捷键权限未完全就绪，仍可录屏"), "recording can start without shortcut monitoring permission")
expect(!appStateSource.contains("然后再开始录制\"\n            lastErrorMessage = \"缩放快捷键"), "shortcut monitoring is not a hard recording blocker")
expect(appStateSource.contains("overlayService.prewarmZoomPreview()"), "recording startup primes live zoom after screen capture is ready")
expect(appStateSource.contains("videoDuration(for: screenURL)"), "recorded projects store the actual screen movie duration")
expect(appStateSource.contains("AVURLAsset(url: url)"), "recording duration is measured from the written movie asset")
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
expect(appStateSource.contains("func deleteSegment(_ segmentID: UUID, in projectID: UUID)"), "editor can delete a specifically selected segment")
expect(!appStateSource.contains("func deleteLastSegment"), "editor deletion is not limited to the last segment")
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
expect(appStateSource.contains("func openCurrentVideo(for project: RecordingProject)"), "app state can open the current editor video")
expect(appStateSource.contains("NSWorkspace.shared.open(previewURL(for: project))"), "current editor video opens through the workspace")
expect(appStateSource.contains("@Published var activeExportProjectID"), "app state tracks which project owns the active export")
expect(appStateSource.contains("@Published var exportProgress"), "app state exposes export progress for the editor")
expect(appStateSource.contains("@Published var isCancellingExport"), "app state exposes export cancellation state")
expect(appStateSource.contains("activeExportProjectID = id"), "formal export records the active project id")
expect(appStateSource.contains("activeExportProjectID = nil"), "formal export clears the active project id after finishing")
expect(appStateSource.contains("startExportProgressPolling(for: id)"), "formal exports poll progress while running")
expect(appStateSource.contains("exportProgress = exportService.progress"), "formal export progress mirrors the export service")
expect(appStateSource.contains("正在导出 \\(Int(exportProgress * 100))%"), "formal export message includes a percent")
expect(appStateSource.contains("func cancelExportIntent(for id: UUID)"), "formal export can be cancelled from the editor")
expect(appStateSource.contains("activeExportProjectID == id"), "formal export cancellation only applies to the active export project")
expect(appStateSource.contains("exportService.cancelCurrentExport()"), "formal export cancellation stops the underlying export session")
expect(appStateSource.contains("已取消导出"), "formal export cancellation has Chinese feedback")
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
    "microphoneCaptureService.startRecording(preferences: recordingPreferences)",
    before: "captureService.startDisplayRecording",
    in: appStateSource,
    "noise-reduced microphone starts before screen capture so failures can fall back to ordinary microphone"
)

let exportServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/ExportService.swift")
let exportServiceSource = (try? String(contentsOf: exportServiceURL, encoding: .utf8)) ?? ""
expect(exportServiceSource.contains("ProjectVideoCompositionBuilder.build(project: project)"), "export service uses the shared project video composition builder")
expect(exportServiceSource.contains("func cancelCurrentExport()"), "export service exposes cancellation for stale previews")
expect(exportServiceSource.contains("activeExportSession?.cancelExport()"), "export service cancels the underlying AVAssetExportSession")
expect(exportServiceSource.contains("startProgressPolling(for: exportSession)"), "export service polls AVAssetExportSession progress")
expect(exportServiceSource.contains("progress = Double(exportSession.progress)"), "export service publishes session progress")
expect(exportServiceSource.contains("stopProgressPolling()"), "export service stops progress polling after export")
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
expect(permissionServiceSource.contains("var shortcutRecoveryMessage"), "shortcut permissions explain exactly which macOS permission is missing")
expect(permissionServiceSource.contains("删除旧“简录”条目"), "shortcut permission guidance explains stale local TCC rows after rebuilds")
expect(permissionServiceSource.contains("点“+”添加当前 App"), "shortcut permission guidance explains empty Input Monitoring lists")
expect(permissionServiceSource.contains("openAccessibilitySettings()"), "permission service can open Accessibility directly")
expect(permissionServiceSource.contains("openInputMonitoringSettings()"), "permission service can open Input Monitoring directly")

let contentViewURL = projectRoot.appendingPathComponent("Sources/JianLu/Views/ContentView.swift")
let contentViewSource = (try? String(contentsOf: contentViewURL, encoding: .utf8)) ?? ""
expect(contentViewSource.contains("MainWindowMarker"), "main content marks its NSWindow for precise restoration")
expect(contentViewSource.contains("appState.isStartingRecording"), "main recording button reflects startup state")
expect(contentViewSource.contains("appState.takeScreenshotIntent()"), "main header exposes screenshot capture")
expect(contentViewSource.contains("screenshotButtonTitle"), "main header reflects screenshot selection state")
expect(contentViewSource.contains("截图标注"), "dashboard surfaces screenshot annotation as a first-class feature")
expect(contentViewSource.contains("正在启动"), "main recording button labels startup state in Chinese")
expect(contentViewSource.contains(".disabled(appState.isStartingRecording)"), "main camera toggle is disabled while recording startup is in progress")
expect(contentViewSource.contains("输入监控"), "permission UI names Input Monitoring for zoom hotkeys")
expect(contentViewSource.contains("appState.permissionSnapshot.shortcutRecoveryMessage"), "permission warning shows the precise missing shortcut permission")
expect(contentViewSource.contains("打开辅助功能"), "permission warning has a direct Accessibility settings action")
expect(contentViewSource.contains("打开输入监控"), "permission warning has a direct Input Monitoring settings action")
expect(!contentViewSource.contains("keyboard.badge.exclamationmark"), "permission UI avoids unavailable SF Symbols that prevent the main window from rendering")
expect(contentViewSource.contains("let isSelected = project.id == appState.selectedProject?.id"), "recent recordings mark the currently edited project")
expect(contentViewSource.contains("ScrollViewReader"), "dashboard can scroll to the editor after selecting a recent recording")
expect(contentViewSource.contains("onRecentProjectSelected"), "recent recording selection is routed through a navigation callback")
expect(contentViewSource.contains("scrollProxy.scrollTo(\"selected-project-editor\", anchor: .top)"), "recent recording clicks visibly enter the selected editor")
expect(contentViewSource.contains(".id(\"selected-project-editor\")"), "selected editor has a stable scroll target")
expect(contentViewSource.contains("当前剪辑"), "recent recordings clearly label the current project")
expect(contentViewSource.contains("isSelected ? Color.accentColor.opacity(0.18)"), "recent recordings visually highlight the current project")
expect(contentViewSource.contains("ForEach(projects)"), "recent recordings list all saved recent projects")
expect(!contentViewSource.contains("projects.prefix(3)"), "recent recordings are not limited to the first three projects")

let editorViewURL = projectRoot.appendingPathComponent("Sources/JianLu/Views/EditorView.swift")
let editorViewSource = (try? String(contentsOf: editorViewURL, encoding: .utf8)) ?? ""
expect(editorViewSource.contains("@State private var selectedSegmentID"), "editor tracks the selected clip segment")
expect(editorViewSource.contains("appState.openCurrentVideo(for: project)"), "editor exposes an action to open the current preview or exported video")
expect(editorViewSource.contains("打开当前视频"), "editor labels current-video opening clearly")
expect(editorViewSource.contains("appState.activeExportProjectID == project.id"), "editor only shows export progress on the project being exported")
expect(editorViewSource.contains("ProgressView(value: appState.exportProgress)"), "editor shows formal export progress")
expect(editorViewSource.contains("正在导出成片"), "editor labels export progress clearly")
expect(editorViewSource.contains("appState.cancelExportIntent(for: project.id)"), "editor exposes a cancel action during formal export")
expect(editorViewSource.contains("取消导出"), "editor labels export cancellation clearly")
expect(editorViewSource.contains("deleteSegment(selectedSegmentID"), "editor deletes the selected segment instead of always deleting the tail")
expect(editorViewSource.contains("删除选中片段"), "editor labels segment deletion clearly")
expect(editorViewSource.contains("@Binding var selectedSegmentID: UUID?"), "segment strip exposes selection to the editor")
expect(!editorViewSource.contains("删除末段"), "editor no longer advertises tail-only deletion")

let statusBarControllerURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/StatusBarController.swift")
let statusBarControllerSource = (try? String(contentsOf: statusBarControllerURL, encoding: .utf8)) ?? ""
expect(statusBarControllerSource.contains("AppWindowUtility.restoreOrCreateMainWindow()"), "status bar can recreate a missing main window")

let microphoneCaptureServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/MicrophoneCaptureService.swift")
let microphoneCaptureServiceSource = (try? String(contentsOf: microphoneCaptureServiceURL, encoding: .utf8)) ?? ""
expect(microphoneCaptureServiceSource.contains("cleanupAfterFailedStart"), "microphone startup failures clean partial recorder state")
expect(microphoneCaptureServiceSource.contains("engine.inputNode.removeTap(onBus: 0)"), "microphone startup cleanup removes any installed tap")
expect(microphoneCaptureServiceSource.contains("try? engine.inputNode.setVoiceProcessingEnabled(false)"), "microphone startup cleanup disables voice processing")
expect(microphoneCaptureServiceSource.contains("try? FileManager.default.removeItem(at: outputURL)"), "microphone startup cleanup removes incomplete audio files")
expect(microphoneCaptureServiceSource.contains("MicrophoneSampleWriter: @unchecked Sendable"), "microphone audio writer can be captured safely by the realtime audio tap")
expect(microphoneCaptureServiceSource.contains("makeMicrophoneTapBlock"), "microphone audio tap block is created outside MainActor service isolation")

let cameraCaptureServiceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/CameraCaptureService.swift")
let cameraCaptureServiceSource = (try? String(contentsOf: cameraCaptureServiceURL, encoding: .utf8)) ?? ""
let cameraFrameProcessorURL = projectRoot.appendingPathComponent("Sources/JianLuCore/Export/CameraFrameProcessor.swift")
let cameraFrameProcessorSource = (try? String(contentsOf: cameraFrameProcessorURL, encoding: .utf8)) ?? ""
expect(cameraCaptureServiceSource.contains("cleanupAfterFailedStart"), "camera startup failures clean partial recorder state")
expect(cameraCaptureServiceSource.contains("@Published private(set) var processedPreviewImage"), "camera service publishes processed preview frames")
expect(cameraCaptureServiceSource.contains("CameraSampleCoordinator(previewPreferences: .defaults)"), "camera samples flow through a shared preview and recording coordinator")
expect(cameraCaptureServiceSource.contains("delegateProxy.sampleHandler = { [sampleCoordinator] sampleBuffer in"), "camera sample handler stays attached to the coordinator")
expect(cameraCaptureServiceSource.contains("sampleCoordinator.append(sampleBuffer)"), "camera frames feed both preview processing and the recording writer")
expect(!cameraCaptureServiceSource.contains("delegateProxy.sampleHandler = { _ in }"), "camera cleanup no longer disconnects live preview processing")
expect(cameraCaptureServiceSource.contains("func updatePreviewPreferences(_ preferences: RecordingPreferences)"), "camera service can update live preview processing preferences")
expect(cameraCaptureServiceSource.contains("func updateRecordingPreferences(_ preferences: RecordingPreferences)"), "camera service can update active writer processing preferences")
expect(cameraCaptureServiceSource.contains("sampleCoordinator.clearWriter()"), "camera cleanup clears only the recording writer")
expect(cameraCaptureServiceSource.contains("previewImageHandler?(nil)"), "turning processing off clears stale processed preview frames")
expect(cameraFrameProcessorSource.contains("public final class CameraFrameProcessor"), "camera preview and writer share one core frame processor")
expect(cameraFrameProcessorSource.contains("public func makePreviewImage"), "frame processor renders processed preview images")
expect(cameraFrameProcessorSource.contains("fallbackBlendedImage"), "camera background changes remain visible when person segmentation has no mask")
expect(cameraFrameProcessorSource.contains("photoBackgroundCache"), "real camera backgrounds are cached after loading")
expect(cameraFrameProcessorSource.contains("Bundle.module.url"), "real camera backgrounds load from bundled resources")
expect(cameraFrameProcessorSource.contains("subdirectory: \"CameraBackgrounds\""), "real camera backgrounds load from the CameraBackgrounds resource directory")
for resourceStem in ["office-photo", "bookshelf-photo", "meeting-room-photo", "city-window-photo", "light-studio-photo"] {
    expect(cameraFrameProcessorSource.contains(resourceStem), "\(resourceStem) is mapped to a camera background style")
}
expect(cameraCaptureServiceSource.contains("func updatePreferences(_ preferences: RecordingPreferences)"), "camera writer can receive live background preference updates")
expect(cameraCaptureServiceSource.contains("processor.processedImage(from: pixelBuffer, preferences: currentPreferences())"), "camera writer uses the shared processor with current preferences")
expect(cameraCaptureServiceSource.contains("await stopSessionIfRunning()"), "camera startup cleanup stops the camera session")
expect(cameraCaptureServiceSource.contains("try? FileManager.default.removeItem(at: outputURL)"), "camera startup cleanup removes incomplete video files")
expect(cameraCaptureServiceSource.contains("let failedOutputURL = currentOutputURL"), "camera stop failures remember the incomplete output file")
expect(cameraCaptureServiceSource.contains("try? FileManager.default.removeItem(at: failedOutputURL)"), "camera stop failures remove incomplete video files")

print("JianLuBundleChecks passed")
