import AppKit
import AVFoundation
import Foundation
import JianLuCore
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording = false
    /// Whether the HID event tap that intercepts and suppresses native screenshot
    /// shortcuts is currently alive. The "Mac 同款替代" preset only works while this
    /// is true; otherwise the app is on the listen-only fallback and can neither
    /// replace nor block the system ⇧⌘3/4/5 behavior.
    @Published var captureShortcutInterceptionActive = false
    @Published var cameraEnabled = true {
        didSet {
            guard preferences.cameraEnabled != cameraEnabled else { return }
            preferences.cameraEnabled = cameraEnabled
        }
    }
    @Published var statusMessage = tr("准备录制客户方案讲解", "Ready to record")
    @Published var permissionSnapshot = PermissionService.snapshot()
    @Published var recentProjects: [RecordingProject] = AppState.loadRecentProjects() {
        didSet {
            AppState.saveRecentProjects(recentProjects)
        }
    }
    @Published var lastErrorMessage: String?
    @Published var selectedProjectID: UUID?
    @Published var exportMessages: [UUID: String] = [:]
    @Published var isExporting = false
    @Published var activeExportProjectID: UUID?
    @Published var exportProgress: Double = 0
    @Published var isCancellingExport = false
    @Published var isStoppingRecording = false
    @Published var isStartingRecording = false
    @Published var isPreparingRegionSelection = false
    @Published var isSelectingRegion = false
    @Published var isPreparingScreenshot = false
    @Published var isSelectingScreenshot = false
    @Published var isPaused = false
    /// Mirrors the macOS login item state; macOS owns it, so this is refreshed rather
    /// than persisted alongside the other preferences.
    @Published var launchAtLoginState: LaunchAtLoginService.State = .disabled
    @Published var renderedPreviewURLs: [UUID: URL] = [:]
    @Published var renderedPreviewMessages: [UUID: String] = [:]
    @Published var preferences: RecordingPreferences = AppState.loadPreferences() {
        didSet {
            AppState.savePreferences(preferences)
            L10n.setLanguage(preferences.language)
            syncCameraPreferences(preferences)
            overlayService.zoomMouseButton = preferences.zoomMouseButton
            hotkeyService.updateCaptureShortcutPreset(preferences.captureShortcutPreset)
        }
    }

    let captureService = CaptureService()
    let cameraCaptureService = CameraCaptureService()
    let microphoneCaptureService = MicrophoneCaptureService()
    let overlayService = OverlayService()
    private let screenshotCaptureService = ScreenshotCaptureService()
    private let exportService = ExportService()
    private let previewExportService = ExportService()
    private let hotkeyService = HotkeyService()
    private let regionSelectionController = CaptureRegionSelectionWindowController()
    private var statusBarController: StatusBarController?
    private static let preferencesKey = "com.local.JianLu.recordingPreferences"
    private static let recentProjectLimit = 20

    private var activeScreenRecordingURL: URL?
    private var activeCameraRecordingURL: URL?
    private var activeMicrophoneRecordingURL: URL?
    private var activeRecordingPreferences: RecordingPreferences?
    private var activeCameraRecordingOffset: TimeInterval = 0
    private var activeMicrophoneRecordingOffset: TimeInterval = 0
    /// The still captured the instant a screenshot was triggered; the selection is made
    /// on it and the final image is cropped out of it. Nil when the freeze preference is
    /// off or the grab failed, in which case the live screen is captured on confirm.
    private var frozenScreenshotImage: CGImage?
    /// A stop pressed before the recording finished starting; honoured once it is up.
    private var stopRequestedDuringStartup = false
    private var recordingStartedAt: Date?
    private var pauseStartedAt: TimeInterval?
    private var pausedRanges: [(start: TimeInterval, end: TimeInterval)] = []
    private var renderedPreviewTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        L10n.setLanguage(preferences.language)
        // The default was evaluated before the language was known.
        statusMessage = tr("准备录制客户方案讲解", "Ready to record")
        cameraEnabled = preferences.cameraEnabled
        cameraCaptureService.updatePreviewPreferences(preferences)
        overlayService.cameraFrame = preferences.cameraFrame
        overlayService.cameraShape = preferences.cameraShape
        overlayService.zoomMouseButton = preferences.zoomMouseButton
        selectedProjectID = recentProjects.first?.id
        launchAtLoginState = LaunchAtLoginService.state
        startHotkeyMonitoring()
        statusBarController = StatusBarController(appState: self)
        if let firstProject = recentProjects.first {
            ensureRenderedPreview(for: firstProject)
        }
    }

    private func startHotkeyMonitoring() {
        hotkeyService.start(
            zoomShortcutProvider: { [weak self] in
                self?.preferences.zoomShortcut ?? .controlOptionCommandZ
            },
            captureShortcutPresetProvider: { [weak self] in
                self?.preferences.captureShortcutPreset ?? .jianLuDefault
            },
            handler: { [weak self] action in
                self?.handleHotkey(action)
            }
        )
        captureShortcutInterceptionActive = hotkeyService.isEventTapActive
    }

    private func restartHotkeyMonitoringIfAuthorized() {
        // Keep the published flag honest whenever permissions are re-checked.
        if hotkeyService.isEventTapActive {
            captureShortcutInterceptionActive = true
            return
        }
        // The suppressing HID tap needs Accessibility; Input Monitoring helps the
        // NSEvent fallback. Retry whenever either was just granted — it is cheap and
        // sometimes lights up the tap without a full restart. If it still fails, the
        // UI surfaces a restart hint (macOS often only applies the grant on relaunch).
        let snapshot = PermissionService.snapshot()
        guard snapshot.shortcutAccessibilityGranted || snapshot.shortcutInputMonitoringGranted else {
            captureShortcutInterceptionActive = false
            return
        }
        startHotkeyMonitoring()
    }

    /// Whether the current preset promises to replace the native screenshot
    /// shortcuts but the interception tap is not actually running. In this state
    /// ⇧⌘3/4/5 still trigger macOS, not 简录, and the user must grant Accessibility
    /// and relaunch.
    var captureShortcutNeedsInterception: Bool {
        preferences.captureShortcutPreset == .macReplacement && !captureShortcutInterceptionActive
    }

    /// Relaunch 简录 so a freshly granted TCC permission (Accessibility / Input
    /// Monitoring) takes effect for the HID event tap.
    func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    func toggleRecordingIntent() {
        guard !isStoppingRecording else {
            statusMessage = tr("正在停止录制，请稍候", "Stopping the recording…")
            return
        }
        if isRecording {
            Task {
                await stopRecording()
            }
            return
        }
        guard !isStartingRecording else {
            // The control bar is already on screen while ScreenCaptureKit spins up, so
            // this press used to land on a dead button. Remember it and stop as soon as
            // the recording is actually running.
            stopRequestedDuringStartup = true
            overlayService.setFinishing(true)
            statusMessage = tr("正在启动录制，启动完成后会立即结束", "Starting the recording — it will stop as soon as it is up")
            return
        }
        overlayService.setFinishing(false)
        guard !isPreparingRegionSelection else {
            statusMessage = tr("正在准备选择区域，请稍候", "Preparing the area picker…")
            return
        }
        guard !isPreparingScreenshot, !isSelectingScreenshot else {
            statusMessage = tr("请先完成或取消当前截图", "Finish or cancel the current screenshot first")
            return
        }

        if isSelectingRegion {
            regionSelectionController.confirmSelection()
        } else {
            isPreparingRegionSelection = true
            statusMessage = tr("正在检查权限并准备选择区域...", "Checking permissions and preparing the area picker…")
            Task {
                await beginRegionSelection()
            }
        }
    }

    func takeScreenshotIntent() {
        guard !isRecording, !isStoppingRecording, !isStartingRecording else {
            statusMessage = tr("录制进行中，请先停止录制后再截图", "Stop the recording before taking a screenshot")
            return
        }
        guard !isPreparingScreenshot else {
            statusMessage = tr("正在准备截图，请稍候", "Preparing the screenshot…")
            return
        }
        guard !isPreparingRegionSelection else {
            statusMessage = tr("正在准备录制区域，请稍候", "Preparing the recording area…")
            return
        }

        if isSelectingScreenshot {
            regionSelectionController.confirmSelection()
        } else if isSelectingRegion {
            statusMessage = tr("请先完成或取消当前录制区域选择", "Finish or cancel the recording area selection first")
        } else {
            isPreparingScreenshot = true
            statusMessage = tr("正在准备截图...", "Preparing the screenshot…")
            Task {
                await beginScreenshotSelection()
            }
        }
    }

    func takeFullScreenshotIntent() {
        guard !isRecording, !isStoppingRecording, !isStartingRecording else {
            statusMessage = tr("录制进行中，请先停止录制后再截图", "Stop the recording before taking a screenshot")
            return
        }
        guard !isPreparingScreenshot, !isSelectingScreenshot else {
            statusMessage = tr("正在处理截图，请稍候", "Working on the screenshot…")
            return
        }
        guard !isPreparingRegionSelection, !isSelectingRegion else {
            statusMessage = tr("请先完成或取消当前录制区域选择", "Finish or cancel the recording area selection first")
            return
        }

        isPreparingScreenshot = true
        statusMessage = tr("正在截取全屏...", "Capturing the full screen…")
        Task {
            await captureFullScreenshot()
        }
    }

    func toggleCameraIntent() {
        guard !isStartingRecording else {
            statusMessage = tr("正在启动录制，请稍候", "Starting the recording…")
            return
        }

        if isRecording {
            toggleRecordingCameraVisibility()
            return
        }

        cameraEnabled.toggle()
        statusMessage = cameraEnabled ? tr("摄像头头像框已开启", "Camera bubble on") : tr("摄像头头像框已关闭", "Camera bubble off")
    }

    private func toggleRecordingCameraVisibility() {
        guard cameraCaptureService.hasActiveRecording else {
            overlayService.setCameraVisibility(false)
            statusMessage = cameraEnabled ? tr("本次录制未包含摄像头轨道，下次录制会再次尝试开启", "No camera track in this recording; the next one will try again") : tr("本次录制未包含摄像头轨道", "This recording has no camera track")
            return
        }

        let nextVisibility = !overlayService.cameraVisible
        overlayService.setCameraVisibility(nextVisibility)
        statusMessage = nextVisibility ? tr("摄像头头像框已显示", "Camera bubble shown") : tr("摄像头头像框已隐藏", "Camera bubble hidden")
    }

    /// Whether the camera/microphone pickers have to sit still. Both writers lock onto
    /// the current device's format when a take starts — the camera's frame size comes
    /// from its first frame — so a mid-take swap would silently damage the recording
    /// rather than change it.
    var isDeviceSelectionLocked: Bool {
        isRecording || isStartingRecording || isStoppingRecording
    }

    private func updateDefaultCameraLayout(frame: NormalizedRect, shape: CameraFrameShape) {
        guard preferences.cameraFrame != frame || preferences.cameraShape != shape else { return }
        preferences.cameraFrame = frame
        preferences.cameraShape = shape
    }

    func updateDefaultCameraSize(_ size: Double) {
        let frame = preferences.cameraFrame.resizedCameraFrame(size: size)
        guard preferences.cameraFrame != frame else { return }
        preferences.cameraFrame = frame
    }

    private func syncCameraPreferences(_ preferences: RecordingPreferences) {
        overlayService.setCameraLayout(frame: preferences.cameraFrame, shape: preferences.cameraShape)
        syncCameraProcessingPreferences(preferences)
    }

    private func syncCameraProcessingPreferences(_ preferences: RecordingPreferences) {
        cameraCaptureService.updatePreviewPreferences(preferences)
        cameraCaptureService.selectDevice(preferences.cameraDeviceID)
        guard cameraCaptureService.hasActiveRecording else { return }

        cameraCaptureService.updateRecordingPreferences(preferences)
        guard var activeRecordingPreferences else { return }
        activeRecordingPreferences.cameraBackgroundStyle = preferences.cameraBackgroundStyle
        activeRecordingPreferences.cameraBackgroundBlur = preferences.cameraBackgroundBlur
        activeRecordingPreferences.cameraBeauty = preferences.cameraBeauty
        activeRecordingPreferences.cameraBackgroundImagePath = preferences.cameraBackgroundImagePath
        self.activeRecordingPreferences = activeRecordingPreferences
    }

    func requestPermissions() {
        let snapshotBeforeRequest = PermissionService.snapshot()
        if !snapshotBeforeRequest.screenRecordingGranted {
            PermissionService.requestScreenRecordingAccess()
            statusMessage = tr("请在系统设置中允许“简录”屏幕录制权限，然后重新打开 App", "Allow Screen Recording for JianLu in System Settings, then reopen the app")
        }
        if !snapshotBeforeRequest.shortcutMonitoringGranted {
            PermissionService.requestShortcutMonitoringAccess()
            statusMessage = tr("请在系统设置中允许“简录”辅助功能和输入监控权限，否则缩放快捷键不会生效", "Allow Accessibility and Input Monitoring for JianLu, otherwise the zoom shortcut will not work")
        }

        Task {
            permissionSnapshot = await PermissionService.requestMediaAccess(
                cameraEnabled: cameraEnabled,
                microphoneEnabled: preferences.microphoneEnabled
            )
            restartHotkeyMonitoringIfAuthorized()
            if permissionSnapshot.missingDescriptions.isEmpty {
                statusMessage = tr("权限已就绪，可以开始录制", "All permissions granted — ready to record")
            } else {
                statusMessage = tr("还缺少权限：", "Still missing: ") + permissionSnapshot.missingDescriptions.joined(separator: tr("、", ", "))
            }
        }
    }

    func refreshPermissions() {
        permissionSnapshot = PermissionService.snapshot()
        restartHotkeyMonitoringIfAuthorized()
        launchAtLoginState = LaunchAtLoginService.state
    }

    /// Turn the macOS login item on or off. macOS may still ask the user to approve it,
    /// which the settings UI surfaces.
    func setLaunchAtLogin(_ enabled: Bool) {
        if let errorMessage = LaunchAtLoginService.set(enabled) {
            lastErrorMessage = errorMessage
        }
        launchAtLoginState = LaunchAtLoginService.state
        statusMessage = launchAtLoginState.isOn
            ? tr("已设置开机自启动", "JianLu will start at login")
            : tr("已关闭开机自启动", "JianLu will not start at login")
    }

    func openLoginItemsSettings() {
        LaunchAtLoginService.openLoginItemsSettings()
    }

    func openScreenRecordingSettings() {
        PermissionService.openScreenRecordingSettings()
    }

    func openShortcutMonitoringSettings() {
        PermissionService.openShortcutMonitoringSettings()
    }

    func openAccessibilitySettings() {
        PermissionService.openAccessibilitySettings()
    }

    func openInputMonitoringSettings() {
        PermissionService.openInputMonitoringSettings()
    }

    private func beginRegionSelection() async {
        guard await ensureRecordingPermissions() else {
            isPreparingRegionSelection = false
            return
        }

        isPreparingRegionSelection = false
        isSelectingRegion = true
        lastErrorMessage = nil
        statusMessage = tr("拖拽选择录制区域，然后点击“开始录制”", "Drag to pick the recording area, then press Start")
        regionSelectionController.show(
            initialRegion: preferences.lastSelectedRegion,
            onStart: { [weak self] region in
                Task { @MainActor [weak self] in
                    await self?.startRecording(region: region)
                }
            },
            onCancel: { [weak self] in
                self?.cancelRegionSelection()
            }
        )
        AppWindowUtility.minimizeMainWindows()
    }

    private func cancelRegionSelection() {
        regionSelectionController.hide()
        isSelectingRegion = false
        statusMessage = tr("已取消录制", "Recording cancelled")
        AppWindowUtility.restoreMainWindows()
    }

    private func beginScreenshotSelection() async {
        refreshPermissions()
        guard permissionSnapshot.screenRecordingGranted else {
            PermissionService.requestScreenRecordingAccess()
            refreshPermissions()
            isPreparingScreenshot = false
            statusMessage = tr("请在系统设置中允许“简录”屏幕录制权限，然后重新打开 App 再截图", "Allow Screen Recording for JianLu in System Settings, then reopen the app to capture")
            lastErrorMessage = tr("截图需要屏幕录制权限。macOS 授权后通常需要重新打开 App。", "Screenshots need Screen Recording access. macOS usually applies it only after a relaunch.")
            return
        }

        // Freeze first, before any 简录 UI is on screen, so the still is the moment the
        // shortcut fired rather than whatever the screen drifts to during selection.
        await captureFrozenScreenIfNeeded()

        isPreparingScreenshot = false
        isSelectingScreenshot = true
        lastErrorMessage = nil
        statusMessage = frozenScreenshotImage == nil
            ? tr("拖拽选择截图区域，或单击自动框选的窗口", "Drag to select an area, or click a highlighted window")
            : tr("画面已冻结：拖拽选择截图区域，或单击自动框选的窗口", "Screen frozen — drag to select an area, or click a highlighted window")
        // Remember where the focus came from before the panel activates 简录, so the
        // screen goes back to the app the user was in once the screenshot is done.
        AppWindowUtility.beginCaptureSession()
        showScreenshotSelectionPanel(initialRegion: nil)
    }

    /// Grab the still the region selection will be made on. Failure is not fatal — the
    /// screenshot simply falls back to capturing the live screen on confirm.
    private func captureFrozenScreenIfNeeded() async {
        frozenScreenshotImage = nil
        guard preferences.screenshotFreezesScreen,
              let fullScreenRegion = regionSelectionController.preferredFullScreenRegion() else {
            return
        }

        do {
            frozenScreenshotImage = try await screenshotCaptureService.captureFrozenScreen(
                region: fullScreenRegion,
                includeAppWindows: preferences.includeAppInterface
            )
        } catch {
            frozenScreenshotImage = nil
        }
    }

    private func cancelScreenshotSelection() {
        AppWindowUtility.endCaptureSession()
        regionSelectionController.hide()
        frozenScreenshotImage = nil
        isSelectingScreenshot = false
        isPreparingScreenshot = false
        statusMessage = tr("已取消截图", "Screenshot cancelled")
    }

    private func captureFullScreenshot() async {
        refreshPermissions()
        guard permissionSnapshot.screenRecordingGranted else {
            PermissionService.requestScreenRecordingAccess()
            refreshPermissions()
            isPreparingScreenshot = false
            statusMessage = tr("请在系统设置中允许“简录”屏幕录制权限，然后重新打开 App 再截图", "Allow Screen Recording for JianLu in System Settings, then reopen the app to capture")
            lastErrorMessage = tr("截图需要屏幕录制权限。macOS 授权后通常需要重新打开 App。", "Screenshots need Screen Recording access. macOS usually applies it only after a relaunch.")
            return
        }

        guard let fullScreenRegion = regionSelectionController.preferredFullScreenRegion() else {
            isPreparingScreenshot = false
            statusMessage = tr("没有找到可截图的显示器", "No display available to capture")
            lastErrorMessage = tr("没有找到可截图的显示器。", "No display available to capture.")
            return
        }

        await captureFrozenScreenIfNeeded()

        isPreparingScreenshot = false
        isSelectingScreenshot = true
        lastErrorMessage = nil
        statusMessage = tr("正在截取全屏...", "Capturing the full screen…")
        AppWindowUtility.beginCaptureSession()
        showScreenshotSelectionPanel(initialRegion: fullScreenRegion)
        regionSelectionController.beginCapturePhase()
        await captureScreenshot(region: fullScreenRegion, rememberRegion: false)
    }

    private func showScreenshotSelectionPanel(initialRegion: RecordingRegion?) {
        regionSelectionController.show(
            initialRegion: initialRegion,
            purpose: .screenshot,
            frozenScreen: frozenScreenshotImage,
            onStart: { [weak self] region in
                Task { @MainActor [weak self] in
                    await self?.captureScreenshot(region: region, rememberRegion: true)
                }
            },
            onCancel: { [weak self] in
                self?.cancelScreenshotSelection()
            },
            onFinish: { [weak self] renderedImage in
                self?.finishScreenshotEditing(renderedImage)
            },
            onCopy: { [weak self] renderedImage in
                self?.copyScreenshotAndClose(renderedImage)
            },
            onSave: { [weak self] renderedImage in
                self?.saveScreenshot(renderedImage)
            }
        )
    }

    private func captureScreenshot(region: RecordingRegion?, rememberRegion: Bool) async {
        isPreparingScreenshot = false
        if rememberRegion, let region {
            preferences.lastSelectedRegion = region
        }

        // Frozen path: the pixels were already grabbed when the shortcut fired, so just
        // crop them. Nothing has to be hidden and no settle delay is needed.
        if let frozenScreenshotImage,
           let region,
           let displayPointSize = regionSelectionController.pointSize(forDisplayID: region.displayID),
           let cropped = screenshotCaptureService.crop(
               frozenScreenshotImage,
               to: region,
               displayPointSize: displayPointSize
           ) {
            self.frozenScreenshotImage = nil
            regionSelectionController.beginEditing(image: cropped)
            isSelectingScreenshot = true
            statusMessage = tr("截图已就绪，可标注、涂鸦、添加文字或马赛克", "Screenshot ready — annotate, add text or mosaic")
            lastErrorMessage = nil
            return
        }

        frozenScreenshotImage = nil
        // Live path: the selection overlay has to get out of the frame first.
        regionSelectionController.hideForCapture()
        statusMessage = tr("正在生成截图...", "Building the screenshot…")
        try? await Task.sleep(nanoseconds: 120_000_000)

        do {
            let image = try await screenshotCaptureService.capture(
                region: region,
                includeAppWindows: preferences.includeAppInterface
            )
            regionSelectionController.beginEditing(image: image)
            isSelectingScreenshot = true
            statusMessage = tr("截图已就绪，可标注、涂鸦、添加文字或马赛克", "Screenshot ready — annotate, add text or mosaic")
            lastErrorMessage = nil
        } catch {
            AppWindowUtility.endCaptureSession(showingMainWindow: true)
            regionSelectionController.hide()
            isSelectingScreenshot = false
            lastErrorMessage = error.localizedDescription
            statusMessage = tr("截图失败：", "Screenshot failed: ") + error.localizedDescription
        }
    }

    private func finishScreenshotEditing(_ image: CGImage) {
        if preferences.screenshotAutoCopyOnFinish {
            copyScreenshot(image)
        } else {
            statusMessage = tr("截图已完成", "Screenshot done")
            lastErrorMessage = nil
        }
        closeScreenshotEditing()
    }

    private func copyScreenshotAndClose(_ image: CGImage) {
        copyScreenshot(image)
        closeScreenshotEditing()
    }

    private func closeScreenshotEditing() {
        // Focus goes back first: once the overlay is gone AppKit would pick the next
        // active app itself, and 简录 winning that lottery is exactly the main window
        // popping up in the user's face after every screenshot.
        AppWindowUtility.endCaptureSession()
        regionSelectionController.hide()
        frozenScreenshotImage = nil
        isSelectingScreenshot = false
        isPreparingScreenshot = false
    }

    private func saveScreenshot(_ image: CGImage) {
        do {
            let url = try RecordingFileStore.makeRecordingURL(
                prefix: "screenshot",
                extension: "png",
                directoryPath: preferences.recordingDirectoryPath
            )
            try screenshotCaptureService.writePNG(image, to: url)
            statusMessage = tr("截图已保存：", "Screenshot saved: ") + url.lastPathComponent
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            statusMessage = tr("保存截图失败：", "Could not save the screenshot: ") + error.localizedDescription
        }
    }

    private func copyScreenshot(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let nsImage = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        if pasteboard.writeObjects([nsImage]) {
            statusMessage = tr("已复制带标注的截图", "Annotated screenshot copied")
            lastErrorMessage = nil
        } else {
            statusMessage = tr("复制截图失败", "Could not copy the screenshot")
            lastErrorMessage = tr("系统剪贴板暂时不可用。", "The system clipboard is unavailable right now.")
        }
    }

    private func ensureRecordingPermissions() async -> Bool {
        refreshPermissions()
        if !permissionSnapshot.screenRecordingGranted {
            PermissionService.requestScreenRecordingAccess()
            refreshPermissions()
            statusMessage = tr("请在系统设置中允许“简录”屏幕录制权限，然后重新打开 App 再开始录制", "Allow Screen Recording for JianLu in System Settings, then reopen the app to record")
            lastErrorMessage = tr("屏幕录制权限尚未就绪。macOS 授权后通常需要重新打开 App。", "Screen Recording access is not ready. macOS usually applies it only after a relaunch.")
            isRecording = false
            return false
        }
        if !permissionSnapshot.shortcutMonitoringGranted {
            PermissionService.requestShortcutMonitoringAccess()
            refreshPermissions()
            if !permissionSnapshot.shortcutMonitoringGranted {
                statusMessage = tr("快捷键权限未完全就绪，仍可录屏；按住缩放快捷键可能无效", "Shortcut permissions are incomplete — recording still works, but hold-to-zoom may not")
                lastErrorMessage = tr("快捷键权限未完全就绪，仍可录屏；按住缩放快捷键可能无效，请使用顶部栏“鼠标放大”。", "Shortcut permissions are incomplete — recording still works, but hold-to-zoom may not. Use the toolbar's mouse zoom instead.")
            }
        }

        permissionSnapshot = await PermissionService.requestMediaAccess(
            cameraEnabled: cameraEnabled,
            microphoneEnabled: preferences.microphoneEnabled
        )

        switch RecordingPermissionGate.decision(
            for: permissionSnapshot.recordingState,
            cameraEnabled: cameraEnabled,
            microphoneEnabled: preferences.microphoneEnabled
        ) {
        case .allowed:
            return true
        case .needsScreenRecordingPermission:
            PermissionService.requestScreenRecordingAccess()
            refreshPermissions()
            statusMessage = tr("请在系统设置中允许“简录”屏幕录制权限，然后重新打开 App 再开始录制", "Allow Screen Recording for JianLu in System Settings, then reopen the app to record")
            lastErrorMessage = tr("屏幕录制权限尚未就绪。macOS 授权后通常需要重新打开 App。", "Screen Recording access is not ready. macOS usually applies it only after a relaunch.")
            isRecording = false
            return false
        case .missingMediaPermissions(let missing):
            // Screen recording is granted here (otherwise the gate returns
            // needsScreenRecordingPermission). Camera/microphone are optional, so
            // degrade to a screen-only recording instead of blocking entirely. The
            // unauthorized tracks are skipped in startRecording based on the snapshot.
            statusMessage = tr("未授权", "No access to ") + missing.joined(separator: tr("、", ", ")) + tr("，本次只录制屏幕", " — recording the screen only")
            lastErrorMessage = tr("未授权：", "No access to: ") + missing.joined(separator: tr("、", ", ")) + tr("。本次只录制屏幕，可在系统设置授权后重新录制。", ". Recording the screen only; grant access in System Settings and record again.")
            return true
        }
    }

    private func startRecording(region: RecordingRegion) async {
        regionSelectionController.hide()
        isSelectingRegion = false
        isStartingRecording = true
        stopRequestedDuringStartup = false
        statusMessage = tr("正在启动录制...", "Starting the recording…")
        preferences.lastSelectedRegion = region
        let recordingPreferences = preferences
        activeRecordingPreferences = recordingPreferences
        AppWindowUtility.minimizeMainWindows()
        activeCameraRecordingOffset = 0
        activeMicrophoneRecordingOffset = 0
        var actualRecordingPreferences = recordingPreferences
        var startupWarnings: [String] = []
        var cameraEnabledForRecording = cameraEnabled
        var microphoneNoiseReductionEnabledForRecording = recordingPreferences.microphoneNoiseReductionEnabled
        var cameraRecordingStartedAt: Date?
        var microphoneRecordingStartedAt: Date?

        do {
            if !PermissionService.snapshot().shortcutMonitoringGranted {
                startupWarnings.append(tr("快捷键权限未完全就绪，仍可录屏；按住缩放快捷键可能无效，可使用顶部栏“鼠标放大”。", "Shortcut permissions are incomplete — recording still works, but hold-to-zoom may not. Use the toolbar's mouse zoom instead."))
            }

            // Only attempt the camera when it is actually authorized. Configuring the
            // session without permission yields a black, silent camera track rather
            // than a thrown error, so guard on the snapshot and degrade cleanly.
            let cameraAuthorized = permissionSnapshot.cameraGranted
            if cameraEnabled && cameraAuthorized {
                if !MediaDeviceCatalog.isAvailable(preferredID: recordingPreferences.cameraDeviceID, mediaType: .video) {
                    startupWarnings.append(tr("所选摄像头已断开，本次改用系统默认摄像头。", "The selected camera is disconnected — recording with the system default camera instead."))
                }
                do {
                    activeCameraRecordingURL = try await cameraCaptureService.startRecording(preferences: recordingPreferences)
                    cameraRecordingStartedAt = Date()
                } catch {
                    cameraEnabledForRecording = false
                    actualRecordingPreferences.cameraEnabled = false
                    activeCameraRecordingURL = nil
                    startupWarnings.append(tr("摄像头不可用，已继续只录屏幕：", "Camera unavailable — recording the screen only: ") + error.localizedDescription)
                }
            } else if cameraEnabled {
                cameraEnabledForRecording = false
                actualRecordingPreferences.cameraEnabled = false
                activeCameraRecordingURL = nil
                startupWarnings.append(tr("摄像头未授权，本次只录制屏幕。可在系统设置 → 隐私与安全性 → 摄像头 授权后重新录制。", "Camera access denied — recording the screen only. Grant it in System Settings › Privacy & Security › Camera and record again."))
            }

            let microphoneAuthorized = permissionSnapshot.microphoneGranted
            if recordingPreferences.microphoneEnabled && !microphoneAuthorized {
                microphoneNoiseReductionEnabledForRecording = false
                actualRecordingPreferences.microphoneNoiseReductionEnabled = false
                startupWarnings.append(tr("麦克风未授权，本次不录制讲解声音。可在系统设置 → 隐私与安全性 → 麦克风 授权后重新录制。", "Microphone access denied — no narration in this recording. Grant it in System Settings › Privacy & Security › Microphone."))
            }

            // The noise-reduced path reports its own device fallback from inside the
            // audio engine; this covers the ScreenCaptureKit path, which silently
            // accepts a nil device ID and records the system default instead.
            if recordingPreferences.microphoneEnabled
                && microphoneAuthorized
                && !recordingPreferences.microphoneNoiseReductionEnabled
                && !MediaDeviceCatalog.isAvailable(preferredID: recordingPreferences.microphoneDeviceID, mediaType: .audio) {
                startupWarnings.append(tr("所选麦克风已断开，本次改用系统默认麦克风。", "The selected microphone is disconnected — recording with the system default microphone instead."))
            }

            if recordingPreferences.microphoneEnabled && microphoneAuthorized && recordingPreferences.microphoneNoiseReductionEnabled {
                do {
                    activeMicrophoneRecordingURL = try microphoneCaptureService.startRecording(preferences: recordingPreferences)
                    microphoneRecordingStartedAt = Date()
                    startupWarnings.append(contentsOf: microphoneCaptureService.startupWarnings)
                } catch {
                    activeMicrophoneRecordingURL = nil
                    microphoneNoiseReductionEnabledForRecording = false
                    actualRecordingPreferences.microphoneNoiseReductionEnabled = false
                    startupWarnings.append(contentsOf: microphoneCaptureService.startupWarnings)
                    startupWarnings.append(tr("麦克风降噪不可用，已改用普通麦克风录制：", "Noise reduction unavailable — recording with the plain microphone: ") + error.localizedDescription)
                }
            }

            activeRecordingPreferences = actualRecordingPreferences
            overlayService.setCameraLayout(frame: recordingPreferences.cameraFrame, shape: recordingPreferences.cameraShape)

            overlayService.beginRecording(
                cameraService: cameraCaptureService,
                cameraEnabled: cameraEnabledForRecording,
                recordingRegion: region,
                screenFrameProvider: { [weak self] in
                    self?.captureService.latestScreenFrame()
                },
                onStop: { [weak self] in
                    self?.toggleRecordingIntent()
                },
                onTogglePause: { [weak self] in
                    self?.togglePauseIntent()
                },
                onToggleClickZoomMode: { [weak self] in
                    self?.toggleClickZoomModeIntent()
                },
                onCameraLayoutChanged: { [weak self] frame, shape in
                    self?.updateDefaultCameraLayout(frame: frame, shape: shape)
                }
            )
            activeScreenRecordingURL = try await captureService.startDisplayRecording(
                includeAppWindows: recordingPreferences.includeAppInterface,
                microphoneEnabled: recordingPreferences.microphoneEnabled && permissionSnapshot.microphoneGranted,
                microphoneNoiseReductionEnabled: microphoneNoiseReductionEnabledForRecording,
                microphoneDeviceID: recordingPreferences.microphoneDeviceID,
                region: region,
                directoryPath: recordingPreferences.recordingDirectoryPath
            )
            let startedAt = Date()
            recordingStartedAt = startedAt
            activeCameraRecordingOffset = cameraRecordingStartedAt.map { startedAt.timeIntervalSince($0) } ?? 0
            activeMicrophoneRecordingOffset = microphoneRecordingStartedAt.map { startedAt.timeIntervalSince($0) } ?? 0
            overlayService.alignRecordingClock(to: startedAt)
            pauseStartedAt = nil
            pausedRanges = []
            isPaused = false
            overlayService.setPaused(false)
            isStartingRecording = false
            isRecording = true
            await captureService.waitForFirstScreenFrame()
            overlayService.prewarmZoomPreview()
            lastErrorMessage = startupWarnings.isEmpty ? nil : startupWarnings.joined(separator: "\n")
            statusMessage = startupWarnings.isEmpty ? tr("录制中：顶部快捷栏可暂停或结束录制", "Recording — use the floating bar to pause or stop") : tr("录制中：部分设备已自动降级", "Recording — some devices were skipped")
            if stopRequestedDuringStartup {
                stopRequestedDuringStartup = false
                await stopRecording()
            }
        } catch {
            if captureService.isRecording {
                try? await captureService.stopDisplayRecording()
            }
            if cameraCaptureService.hasActiveRecording {
                try? await cameraCaptureService.stopRecording()
            }
            if microphoneCaptureService.hasActiveRecording {
                try? microphoneCaptureService.stopRecording()
            }
            deleteUnusedSidecarRecordings()
            overlayService.endRecording()
            AppWindowUtility.restoreMainWindows()
            activeScreenRecordingURL = nil
            activeCameraRecordingURL = nil
            activeMicrophoneRecordingURL = nil
            activeRecordingPreferences = nil
            activeCameraRecordingOffset = 0
            activeMicrophoneRecordingOffset = 0
            recordingStartedAt = nil
            pauseStartedAt = nil
            pausedRanges = []
            isPaused = false
            isStartingRecording = false
            stopRequestedDuringStartup = false
            lastErrorMessage = error.localizedDescription
            statusMessage = tr("启动录制失败：", "Could not start recording: ") + error.localizedDescription
            isRecording = false
        }
    }

    private func stopRecording() async {
        guard !isStoppingRecording else { return }

        isStoppingRecording = true
        // Finalizing the movie can take seconds; the bar has to say so, or the stop
        // button reads as broken and gets pressed again.
        overlayService.setFinishing(true)
        statusMessage = tr("正在停止录制...", "Stopping the recording…")
        defer {
            isStoppingRecording = false
        }

        do {
            closeActivePauseIfNeeded()
            try await captureService.stopDisplayRecording()
            var stopWarnings: [String] = []
            var noExportableSegmentMessage: String?
            let projectPreferences = activeRecordingPreferences ?? preferences
            if cameraCaptureService.hasActiveRecording {
                do {
                    try await cameraCaptureService.stopRecording()
                } catch {
                    activeCameraRecordingURL = nil
                    stopWarnings.append(tr("摄像头视频保存失败，已保留屏幕录制：", "The camera video could not be saved; the screen recording was kept: ") + error.localizedDescription)
                }
            }
            if microphoneCaptureService.hasActiveRecording {
                do {
                    try microphoneCaptureService.stopRecording()
                    if let microphoneWriteWarning = microphoneCaptureService.lastWriteFailureMessage {
                        stopWarnings.append(microphoneWriteWarning)
                    }
                } catch {
                    activeMicrophoneRecordingURL = nil
                    stopWarnings.append(tr("降噪麦克风音轨保存失败，已保留屏幕录制：", "The noise-reduced audio could not be saved; the screen recording was kept: ") + error.localizedDescription)
                }
            }

            if let screenURL = activeScreenRecordingURL {
                let measuredDuration = await videoDuration(for: screenURL)
                let fallbackDuration = Date().timeIntervalSince(recordingStartedAt ?? Date())
                let duration = max(0.1, measuredDuration ?? fallbackDuration)
                let timeline = timelineExcludingPausedRanges(duration: duration)
                if timeline.segments.isEmpty {
                    noExportableSegmentMessage = tr("录制内容全部处于暂停状态，未生成剪辑项目。原始录屏已保存：", "The whole recording was paused, so no project was created. The raw screen recording was kept: ") + screenURL.path
                    deleteUnusedSidecarRecordings()
                } else {
                    let project = RecordingProject(
                        screenRecordingURL: screenURL,
                        cameraRecordingURL: activeCameraRecordingURL,
                        microphoneRecordingURL: activeMicrophoneRecordingURL,
                        cameraRecordingOffset: activeCameraRecordingOffset,
                        microphoneRecordingOffset: activeMicrophoneRecordingOffset,
                        sourceDuration: duration,
                        preferences: projectPreferences,
                        events: overlayService.events,
                        timeline: timeline
                    )
                    recentProjects.insert(project, at: 0)
                    recentProjects = Array(recentProjects.prefix(Self.recentProjectLimit))
                    selectedProjectID = project.id
                    refreshRenderedPreview(for: project)
                }
            }

            activeScreenRecordingURL = nil
            activeCameraRecordingURL = nil
            activeMicrophoneRecordingURL = nil
            activeRecordingPreferences = nil
            activeCameraRecordingOffset = 0
            activeMicrophoneRecordingOffset = 0
            recordingStartedAt = nil
            pauseStartedAt = nil
            pausedRanges = []
            overlayService.endRecording()
            isRecording = false
            isPaused = false
            let messages = stopWarnings + [noExportableSegmentMessage].compactMap { $0 }
            lastErrorMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
            if noExportableSegmentMessage != nil {
                statusMessage = tr("录制已停止，没有可导出的片段", "Recording stopped — nothing to export")
            } else {
                statusMessage = stopWarnings.isEmpty ? tr("录制已停止，可以进入剪辑和导出", "Recording stopped — ready to edit and export") : tr("录制已停止，部分附加轨道已跳过", "Recording stopped — some extra tracks were skipped")
            }
            // The main window was minimized when recording started. Popping it back up
            // would yank focus away from whatever the user moved on to, so it stays put
            // unless they asked for it; the menu bar icon reopens it and shows the
            // result. Failure paths below still restore it, because there the user has
            // an error to read.
            if preferences.openMainWindowAfterRecording {
                AppWindowUtility.restoreMainWindows()
            }
        } catch {
            if cameraCaptureService.hasActiveRecording {
                try? await cameraCaptureService.stopRecording()
            }
            if microphoneCaptureService.hasActiveRecording {
                try? microphoneCaptureService.stopRecording()
            }
            deleteUnusedSidecarRecordings()
            // The screen `.mov` is written to disk independently of this failure and
            // is NOT deleted here, but its finalization state is unknown after a stop
            // error, so we don't add a possibly-broken file to the project library.
            // Surface its path instead so the recording isn't silently lost.
            let orphanedScreenURL = activeScreenRecordingURL
            activeScreenRecordingURL = nil
            activeCameraRecordingURL = nil
            activeMicrophoneRecordingURL = nil
            activeRecordingPreferences = nil
            activeCameraRecordingOffset = 0
            activeMicrophoneRecordingOffset = 0
            recordingStartedAt = nil
            pauseStartedAt = nil
            pausedRanges = []
            overlayService.endRecording()
            isRecording = false
            isPaused = false
            AppWindowUtility.restoreMainWindows()
            if let orphanedScreenURL {
                lastErrorMessage = error.localizedDescription + tr("\n原始录屏已保留，可手动打开：", "\nThe raw screen recording was kept and can be opened manually: ") + orphanedScreenURL.path
            } else {
                lastErrorMessage = error.localizedDescription
            }
            statusMessage = tr("停止录制失败：", "Could not stop recording: ") + error.localizedDescription
        }
    }

    func togglePauseIntent() {
        guard isRecording, !isStoppingRecording else { return }

        if isPaused {
            closeActivePauseIfNeeded()
            isPaused = false
            overlayService.setPaused(false)
            statusMessage = tr("已继续录制", "Recording resumed")
        } else {
            pauseStartedAt = currentRecordingTime
            isPaused = true
            overlayService.setPaused(true)
            statusMessage = tr("录制已暂停，导出会自动跳过暂停段", "Paused — the export skips paused stretches")
        }
    }

    func toggleClickZoomModeIntent() {
        guard isRecording, !isStoppingRecording else { return }
        guard !isPaused else {
            overlayService.toggleClickZoomMode()
            statusMessage = tr("录制已暂停，继续后可使用鼠标放大", "Paused — resume to use mouse zoom")
            return
        }

        overlayService.toggleClickZoomMode()
        statusMessage = overlayService.zoomClickModeEnabled
            ? tr("鼠标放大已开启，按住鼠标左键即可放大重点区域", "Mouse zoom on — hold the left button to magnify")
            : tr("鼠标放大已关闭", "Mouse zoom off")
    }

    /// Pick a background picture. The file is copied into the app's support folder so a
    /// later export still finds it even if the original is moved, renamed or deleted.
    func chooseCameraBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = tr("选择背景图片", "Choose a background image")
        panel.prompt = tr("使用这张图片", "Use image")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let stored = try storeCameraBackgroundImage(from: url)
            preferences.cameraBackgroundImagePath = stored.path
            preferences.cameraBackgroundStyle = .custom
            statusMessage = tr("已设置自定义背景：", "Custom background set: ") + url.lastPathComponent
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = tr("无法读取这张背景图片：", "Could not read that background image: ") + error.localizedDescription
        }
    }

    func clearCameraBackgroundImage() {
        preferences.cameraBackgroundImagePath = nil
        if preferences.cameraBackgroundStyle == .custom {
            preferences.cameraBackgroundStyle = .original
        }
    }

    var cameraBackgroundImageName: String? {
        guard let path = preferences.cameraBackgroundImagePath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func storeCameraBackgroundImage(from url: URL) throws -> URL {
        let directory = AppState.cameraBackgroundsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "png" : url.pathExtension)
        let data = try Data(contentsOf: url)
        try data.write(to: destination)
        // Only the picture in use is kept; older picks are disposable copies.
        if let previous = preferences.cameraBackgroundImagePath,
           previous.hasPrefix(directory.path) {
            try? FileManager.default.removeItem(atPath: previous)
        }
        return destination
    }

    private static var cameraBackgroundsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("简录", isDirectory: true)
            .appendingPathComponent("CameraBackgrounds", isDirectory: true)
    }

    func chooseRecordingDirectory() {
        let panel = NSOpenPanel()
        panel.title = tr("选择默认保存目录", "Choose where recordings are saved")
        panel.prompt = tr("使用此目录", "Use this folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = RecordingFileStore.recordingsDirectory(path: preferences.recordingDirectoryPath)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.recordingDirectoryPath = url.path
        statusMessage = tr("默认保存目录已更新", "Save location updated")
    }

    func openRecordingDirectory() {
        let directory = RecordingFileStore.recordingsDirectory(path: preferences.recordingDirectoryPath)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    var recordingDirectoryDisplayPath: String {
        RecordingFileStore.recordingsDirectory(path: preferences.recordingDirectoryPath).path
    }

    private func closeActivePauseIfNeeded() {
        guard let pauseStartedAt else { return }
        let end = max(pauseStartedAt, currentRecordingTime)
        pausedRanges.append((pauseStartedAt, end))
        self.pauseStartedAt = nil
    }

    private func timelineExcludingPausedRanges(duration: TimeInterval) -> EditTimeline {
        EditTimeline.excluding(
            sourceDuration: duration,
            ranges: pausedRanges.map { EditSegment(sourceStart: $0.start, sourceEnd: $0.end) }
        )
    }

    private func videoDuration(for url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite,
              duration > 0 else {
            return nil
        }
        return duration
    }

    private func deleteUnusedSidecarRecordings() {
        if let activeCameraRecordingURL {
            try? FileManager.default.removeItem(at: activeCameraRecordingURL)
        }
        if let activeMicrophoneRecordingURL {
            try? FileManager.default.removeItem(at: activeMicrophoneRecordingURL)
        }
    }

    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .takeScreenshot:
            takeScreenshotIntent()
        case .takeFullScreenshot:
            takeFullScreenshotIntent()
        case .toggleRecording:
            toggleRecordingIntent()
        case .beginHoldZoom:
            guard isRecording else { return }
            guard !isPaused else {
                statusMessage = tr("录制已暂停，继续后可使用缩放", "Paused — resume to use zoom")
                return
            }
            overlayService.beginHoldZoom()
            statusMessage = tr("按住缩放：可直接放大，也可按住后点击鼠标触发", "Hold to zoom — magnifies right away, or hold and click")
        case .endHoldZoom:
            guard isRecording else { return }
            overlayService.endHoldZoom()
            statusMessage = tr("缩放已恢复", "Zoom released")
        case .zoomIn:
            overlayService.adjustZoom(by: 0.2)
            statusMessage = tr("临时缩放倍率 ", "Zoom level ") + String(format: "%.1f", overlayService.zoomMagnification) + "x"
        case .zoomOut:
            overlayService.adjustZoom(by: -0.2)
            statusMessage = tr("临时缩放倍率 ", "Zoom level ") + String(format: "%.1f", overlayService.zoomMagnification) + "x"
        case .selectTool(let tool):
            overlayService.selectTool(tool)
            if overlayService.selectedTool == nil {
                statusMessage = tr("标注工具已关闭，鼠标会穿透到其他软件", "Annotation tools off — clicks pass through again")
            } else {
                statusMessage = tr("标注工具：", "Tool: ") + tool.displayName + tr("，再次选择可关闭", " — pick it again to turn it off")
            }
        case .undo:
            guard !isPaused else {
                statusMessage = tr("录制已暂停，继续后再撤销标注", "Paused — resume to undo annotations")
                return
            }
            overlayService.undoLastAnnotation()
            statusMessage = tr("已撤销上一笔标注", "Undid the last stroke")
        case .clearAnnotations:
            guard !isPaused else {
                statusMessage = tr("录制已暂停，继续后再清除标注", "Paused — resume to clear annotations")
                return
            }
            overlayService.clearAllAnnotations()
            statusMessage = tr("已清除全部标注", "All annotations cleared")
        case .toggleCamera:
            toggleCameraIntent()
        case .toggleCameraShape:
            overlayService.toggleCameraShape()
            statusMessage = tr("摄像头形状：", "Bubble shape: ") + overlayService.cameraShape.displayName
        }
    }

    private var currentRecordingTime: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    var selectedProject: RecordingProject? {
        guard let selectedProjectID else { return recentProjects.first }
        return recentProjects.first { $0.id == selectedProjectID } ?? recentProjects.first
    }

    func selectProject(_ id: UUID) {
        selectedProjectID = id
        if let project = recentProjects.first(where: { $0.id == id }) {
            ensureRenderedPreview(for: project)
        }
    }

    /// Drops a finished recording from the library and moves everything it owns to the
    /// Trash. Trash, not `removeItem`: a recording cannot be re-shot, so a misclick has
    /// to stay recoverable from Finder. Exported movies are the user's own output and
    /// are deliberately left alone.
    func deleteProject(_ id: UUID) {
        guard let index = recentProjects.firstIndex(where: { $0.id == id }) else { return }
        guard activeExportProjectID != id else {
            statusMessage = tr("这段录制正在导出，取消或等它结束后再删除", "This recording is exporting — cancel or wait for it, then delete")
            return
        }

        let project = recentProjects[index]
        cancelRenderedPreview(for: id)
        let generatedPreviewURL = renderedPreviewURLs[id]
        renderedPreviewURLs[id] = nil
        renderedPreviewMessages[id] = nil
        exportMessages[id] = nil

        var trashTargets = [project.screenRecordingURL]
        trashTargets.append(contentsOf: [project.cameraRecordingURL, project.microphoneRecordingURL].compactMap { $0 })
        if let generatedPreviewURL, generatedPreviewURL.lastPathComponent.hasPrefix("preview-") {
            trashTargets.append(generatedPreviewURL)
        }

        var failedNames: [String] = []
        for url in trashTargets where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failedNames.append(url.lastPathComponent)
            }
        }

        recentProjects.remove(at: index)
        if selectedProjectID == id {
            selectedProjectID = recentProjects.first?.id
        }
        if let nextProject = selectedProject {
            ensureRenderedPreview(for: nextProject)
        }

        if failedNames.isEmpty {
            statusMessage = tr("已移到废纸篓：", "Moved to Trash: ") + project.screenRecordingURL.lastPathComponent
        } else {
            statusMessage = tr("已从列表移除，但这些文件没能移到废纸篓：", "Removed from the list, but these files could not be moved to the Trash: ")
                + failedNames.joined(separator: "、")
            lastErrorMessage = statusMessage
        }
    }

    func splitProject(_ id: UUID, atExportRatio ratio: Double) {
        guard !isExporting else {
            statusMessage = tr("正在导出，完成后再剪辑", "Exporting — edit again when it finishes")
            return
        }
        guard let index = recentProjects.firstIndex(where: { $0.id == id }) else { return }
        let clampedRatio = min(max(0, ratio), 1)
        let exportTime = recentProjects[index].timeline.totalExportDuration * clampedRatio
        guard recentProjects[index].timeline.canSplit(atExportTime: exportTime) else {
            statusMessage = tr("请选择片段中间位置再分割", "Pick a spot inside a clip to split it")
            return
        }
        guard let sourceTime = recentProjects[index].timeline.sourceTime(forExportTime: exportTime) else {
            return
        }

        if recentProjects[index].timeline.split(at: sourceTime) {
            recentProjects = recentProjects
            exportMessages[id] = nil
            refreshRenderedPreview(for: recentProjects[index], force: true)
            statusMessage = tr("已在 ", "Split at ") + "\(Int(sourceTime))" + tr(" 秒处分割", "s")
        }
    }

    func deleteSegment(_ segmentID: UUID, in projectID: UUID) {
        guard !isExporting else {
            statusMessage = tr("正在导出，完成后再剪辑", "Exporting — edit again when it finishes")
            return
        }
        guard let index = recentProjects.firstIndex(where: { $0.id == projectID }),
              recentProjects[index].timeline.segments.count > 1 else {
            statusMessage = tr("至少保留一个片段", "Keep at least one clip")
            return
        }

        if recentProjects[index].timeline.deleteSegment(id: segmentID) {
            recentProjects = recentProjects
            exportMessages[projectID] = nil
            refreshRenderedPreview(for: recentProjects[index], force: true)
            statusMessage = tr("已删除选中片段", "Clip deleted")
        } else {
            statusMessage = tr("请选择要删除的片段", "Select a clip to delete")
        }
    }

    func exportProject(_ id: UUID) {
        guard !isExporting else {
            statusMessage = tr("已有导出任务正在进行", "An export is already running")
            return
        }
        guard let project = recentProjects.first(where: { $0.id == id }) else { return }
        cancelRenderedPreview(for: id)
        isExporting = true
        activeExportProjectID = id
        exportProgress = 0
        isCancellingExport = false
        exportMessages[id] = tr("正在导出...", "Exporting…")
        let progressTask = startExportProgressPolling(for: id)
        Task {
            defer {
                progressTask.cancel()
                exportProgress = 0
                isCancellingExport = false
                activeExportProjectID = nil
                isExporting = false
            }
            do {
                let outputURL = try await exportService.export(project: project)
                if recentProjects.first(where: { $0.id == id }) == project {
                    deleteGeneratedPreviewIfNeeded(renderedPreviewURLs[id])
                    renderedPreviewURLs[id] = outputURL
                    renderedPreviewMessages[id] = tr("导出完成，下面播放的是最新成片。", "Export finished — the player below shows the final video.")
                    exportMessages[id] = tr("导出完成：", "Exported to: ") + outputURL.path
                    statusMessage = tr("导出完成", "Export finished")
                } else {
                    exportMessages[id] = tr("旧版本导出完成：", "Exported an older version to: ") + outputURL.path + tr("。当前剪辑已修改，请重新导出最新版。", ". The edit has changed since — export again for the latest version.")
                    statusMessage = tr("旧版本导出完成", "Exported an older version")
                }
            } catch {
                if isCancellingExport {
                    exportMessages[id] = tr("已取消导出", "Export cancelled")
                    statusMessage = tr("已取消导出", "Export cancelled")
                } else {
                    exportMessages[id] = error.localizedDescription
                    statusMessage = tr("导出失败", "Export failed")
                }
                if let currentProject = recentProjects.first(where: { $0.id == id }) {
                    ensureRenderedPreview(for: currentProject)
                }
            }
        }
    }

    func cancelExportIntent(for id: UUID) {
        guard isExporting, activeExportProjectID == id else { return }
        isCancellingExport = true
        exportMessages[id] = tr("正在取消导出...", "Cancelling the export…")
        statusMessage = tr("正在取消导出", "Cancelling the export")
        exportService.cancelCurrentExport()
    }

    private func startExportProgressPolling(for id: UUID) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isExporting, self.activeExportProjectID == id else { return }
                exportProgress = exportService.progress
                exportMessages[id] = tr("正在导出 ", "Exporting ") + "\(Int(exportProgress * 100))%…"
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func exportMessage(for project: RecordingProject) -> String? {
        exportMessages[project.id]
    }

    func openCurrentVideo(for project: RecordingProject) {
        NSWorkspace.shared.open(previewURL(for: project))
    }

    func previewURL(for project: RecordingProject) -> URL {
        renderedPreviewURLs[project.id] ?? project.screenRecordingURL
    }

    func previewMessage(for project: RecordingProject) -> String? {
        renderedPreviewMessages[project.id]
    }

    func isRenderingPreview(for project: RecordingProject) -> Bool {
        renderedPreviewTasks[project.id] != nil
    }

    private func refreshRenderedPreview(for project: RecordingProject, force: Bool = false) {
        // Preview renders all share a single `previewExportService`, so at most one
        // may run at a time. Cancel every in-flight preview (including other
        // projects') before starting this one; otherwise two concurrent renders
        // clobber each other's export session and progress reporting.
        for inFlightProjectID in Array(renderedPreviewTasks.keys) {
            cancelRenderedPreview(for: inFlightProjectID)
        }
        deleteGeneratedPreviewIfNeeded(renderedPreviewURLs[project.id])
        renderedPreviewURLs[project.id] = nil

        guard force || project.needsRenderedPreview else {
            renderedPreviewMessages[project.id] = nil
            return
        }

        renderedPreviewMessages[project.id] = tr("正在生成带缩放、标注和摄像头的效果预览...", "Rendering a preview with zoom, annotations and camera…")
        renderedPreviewTasks[project.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let outputURL = try await previewExportService.export(project: project, prefix: "preview")
                if Task.isCancelled {
                    deleteGeneratedPreviewIfNeeded(outputURL)
                    return
                }
                renderedPreviewURLs[project.id] = outputURL
                renderedPreviewMessages[project.id] = tr("效果预览已生成，下面播放的是合成后的画面。", "Preview ready — the player below shows the composited result.")
                renderedPreviewTasks[project.id] = nil
            } catch {
                guard !Task.isCancelled else { return }
                renderedPreviewMessages[project.id] = tr("效果预览生成失败：", "Preview render failed: ") + error.localizedDescription + tr("。导出成片仍可手动重试。", ". You can still export manually.")
                renderedPreviewTasks[project.id] = nil
            }
        }
    }

    private func ensureRenderedPreview(for project: RecordingProject) {
        guard project.needsRenderedPreview else {
            renderedPreviewMessages[project.id] = nil
            return
        }
        guard renderedPreviewURLs[project.id] == nil,
              renderedPreviewTasks[project.id] == nil else {
            return
        }
        refreshRenderedPreview(for: project)
    }

    private func cancelRenderedPreview(for projectID: UUID) {
        guard renderedPreviewTasks[projectID] != nil else { return }
        renderedPreviewTasks[projectID]?.cancel()
        previewExportService.cancelCurrentExport()
        renderedPreviewTasks[projectID] = nil
        if renderedPreviewURLs[projectID] == nil {
            renderedPreviewMessages[projectID] = nil
        }
    }

    private func deleteGeneratedPreviewIfNeeded(_ url: URL?) {
        guard let url, url.lastPathComponent.hasPrefix("preview-") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadPreferences() -> RecordingPreferences {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey),
              let preferences = try? JSONDecoder().decode(RecordingPreferences.self, from: data) else {
            return .defaults
        }
        return preferences
    }

    private static func savePreferences(_ preferences: RecordingPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: preferencesKey)
    }

    private static func loadRecentProjects() -> [RecordingProject] {
        (try? RecordingProjectLibrary.load(from: recentProjectsURL, limit: recentProjectLimit)) ?? []
    }

    private static func saveRecentProjects(_ projects: [RecordingProject]) {
        try? RecordingProjectLibrary.save(projects, to: recentProjectsURL, limit: recentProjectLimit)
    }

    private static var recentProjectsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("简录", isDirectory: true)
            .appendingPathComponent("projects.json")
    }
}
