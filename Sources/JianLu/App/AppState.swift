import AppKit
import Foundation
import JianLuCore

@MainActor
final class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var cameraEnabled = true {
        didSet {
            guard preferences.cameraEnabled != cameraEnabled else { return }
            preferences.cameraEnabled = cameraEnabled
        }
    }
    @Published var statusMessage = "准备录制客户方案讲解"
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
    @Published var isStoppingRecording = false
    @Published var isPreparingRegionSelection = false
    @Published var isSelectingRegion = false
    @Published var isPaused = false
    @Published var renderedPreviewURLs: [UUID: URL] = [:]
    @Published var renderedPreviewMessages: [UUID: String] = [:]
    @Published var preferences: RecordingPreferences = AppState.loadPreferences() {
        didSet {
            AppState.savePreferences(preferences)
        }
    }

    let captureService = CaptureService()
    let cameraCaptureService = CameraCaptureService()
    let microphoneCaptureService = MicrophoneCaptureService()
    let overlayService = OverlayService()
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
    private var recordingStartedAt: Date?
    private var pauseStartedAt: TimeInterval?
    private var pausedRanges: [(start: TimeInterval, end: TimeInterval)] = []
    private var renderedPreviewTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        cameraEnabled = preferences.cameraEnabled
        selectedProjectID = recentProjects.first?.id
        hotkeyService.start(
            zoomShortcutProvider: { [weak self] in
                self?.preferences.zoomShortcut ?? .controlOptionCommandZ
            },
            handler: { [weak self] action in
                self?.handleHotkey(action)
            }
        )
        statusBarController = StatusBarController(appState: self)
        if let firstProject = recentProjects.first {
            ensureRenderedPreview(for: firstProject)
        }
    }

    func toggleRecordingIntent() {
        guard !isStoppingRecording else {
            statusMessage = "正在停止录制，请稍候"
            return
        }
        guard !isPreparingRegionSelection else {
            statusMessage = "正在准备选择区域，请稍候"
            return
        }

        if isRecording {
            Task {
                await stopRecording()
            }
        } else if isSelectingRegion {
            regionSelectionController.confirmSelection()
        } else {
            isPreparingRegionSelection = true
            statusMessage = "正在检查权限并准备选择区域..."
            Task {
                await beginRegionSelection()
            }
        }
    }

    func toggleCameraIntent() {
        cameraEnabled.toggle()
        statusMessage = cameraEnabled ? "摄像头头像框已开启" : "摄像头头像框已关闭"
        if isRecording {
            overlayService.toggleCameraVisibility()
        }
    }

    func requestPermissions() {
        let snapshotBeforeRequest = PermissionService.snapshot()
        if !snapshotBeforeRequest.screenRecordingGranted {
            PermissionService.requestScreenRecordingAccess()
            statusMessage = "请在系统设置中允许“简录”屏幕录制权限，然后重新打开 App"
        }
        if !snapshotBeforeRequest.shortcutMonitoringGranted {
            PermissionService.requestShortcutMonitoringAccess()
            statusMessage = "请在系统设置中允许“简录”辅助功能权限，否则缩放快捷键不会生效"
        }

        Task {
            permissionSnapshot = await PermissionService.requestMediaAccess(
                cameraEnabled: cameraEnabled,
                microphoneEnabled: preferences.microphoneEnabled
            )
            if permissionSnapshot.missingDescriptions.isEmpty {
                statusMessage = "权限已就绪，可以开始录制"
            } else {
                statusMessage = "还缺少权限：\(permissionSnapshot.missingDescriptions.joined(separator: "、"))"
            }
        }
    }

    func refreshPermissions() {
        permissionSnapshot = PermissionService.snapshot()
    }

    func openScreenRecordingSettings() {
        PermissionService.openScreenRecordingSettings()
    }

    func openShortcutMonitoringSettings() {
        PermissionService.openShortcutMonitoringSettings()
    }

    private func beginRegionSelection() async {
        guard await ensureRecordingPermissions() else {
            isPreparingRegionSelection = false
            return
        }

        isPreparingRegionSelection = false
        isSelectingRegion = true
        lastErrorMessage = nil
        statusMessage = "拖拽选择录制区域，然后点击“开始录制”"
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
        statusMessage = "已取消录制"
        AppWindowUtility.restoreMainWindows()
    }

    private func ensureRecordingPermissions() async -> Bool {
        refreshPermissions()
        if !permissionSnapshot.screenRecordingGranted {
            PermissionService.requestScreenRecordingAccess()
            refreshPermissions()
            statusMessage = "请在系统设置中允许“简录”屏幕录制权限，然后重新打开 App 再开始录制"
            lastErrorMessage = "屏幕录制权限尚未就绪。macOS 授权后通常需要重新打开 App。"
            isRecording = false
            return false
        }
        if !permissionSnapshot.shortcutMonitoringGranted {
            PermissionService.requestShortcutMonitoringAccess()
            refreshPermissions()
            statusMessage = "请在系统设置中允许“简录”辅助功能权限，然后再开始录制"
            lastErrorMessage = "缩放快捷键和点击缩放需要“辅助功能”权限；未授权时全局鼠标/键盘事件收不到。"
            isRecording = false
            return false
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
            statusMessage = "请在系统设置中允许“简录”屏幕录制权限，然后重新打开 App 再开始录制"
            lastErrorMessage = "屏幕录制权限尚未就绪。macOS 授权后通常需要重新打开 App。"
            isRecording = false
            return false
        case .missingMediaPermissions(let missing):
            statusMessage = "请先允许权限：\(missing.joined(separator: "、"))"
            lastErrorMessage = "缺少权限：\(missing.joined(separator: "、"))"
            isRecording = false
            return false
        }
    }

    private func startRecording(region: RecordingRegion) async {
        regionSelectionController.hide()
        isSelectingRegion = false
        preferences.lastSelectedRegion = region
        AppWindowUtility.minimizeMainWindows()
        var startupWarnings: [String] = []
        var cameraEnabledForRecording = cameraEnabled

        do {
            if cameraEnabled {
                do {
                    activeCameraRecordingURL = try await cameraCaptureService.startRecording(preferences: preferences)
                } catch {
                    cameraEnabledForRecording = false
                    activeCameraRecordingURL = nil
                    startupWarnings.append("摄像头不可用，已继续只录屏幕：\(error.localizedDescription)")
                }
            }

            overlayService.beginRecording(
                cameraSession: cameraCaptureService.previewSession,
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
                }
            )
            activeScreenRecordingURL = try await captureService.startDisplayRecording(
                includeAppWindows: preferences.includeAppInterface,
                microphoneEnabled: preferences.microphoneEnabled,
                microphoneNoiseReductionEnabled: preferences.microphoneNoiseReductionEnabled,
                region: region,
                directoryPath: preferences.recordingDirectoryPath
            )
            if preferences.microphoneEnabled && preferences.microphoneNoiseReductionEnabled {
                do {
                    activeMicrophoneRecordingURL = try microphoneCaptureService.startRecording(preferences: preferences)
                } catch {
                    activeMicrophoneRecordingURL = nil
                    startupWarnings.append("麦克风降噪不可用，已继续录制屏幕和系统声音：\(error.localizedDescription)")
                }
            }
            let startedAt = Date()
            recordingStartedAt = startedAt
            overlayService.alignRecordingClock(to: startedAt)
            pauseStartedAt = nil
            pausedRanges = []
            isPaused = false
            overlayService.setPaused(false)
            isRecording = true
            lastErrorMessage = startupWarnings.isEmpty ? nil : startupWarnings.joined(separator: "\n")
            statusMessage = startupWarnings.isEmpty ? "录制中：顶部快捷栏可暂停或结束录制" : "录制中：部分设备已自动降级"
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
            overlayService.endRecording()
            AppWindowUtility.restoreMainWindows()
            activeScreenRecordingURL = nil
            activeCameraRecordingURL = nil
            activeMicrophoneRecordingURL = nil
            recordingStartedAt = nil
            pauseStartedAt = nil
            pausedRanges = []
            isPaused = false
            lastErrorMessage = error.localizedDescription
            statusMessage = "启动录制失败：\(error.localizedDescription)"
            isRecording = false
        }
    }

    private func stopRecording() async {
        guard !isStoppingRecording else { return }

        isStoppingRecording = true
        statusMessage = "正在停止录制..."
        defer {
            isStoppingRecording = false
        }

        do {
            closeActivePauseIfNeeded()
            try await captureService.stopDisplayRecording()
            var stopWarnings: [String] = []
            var noExportableSegmentMessage: String?
            if cameraCaptureService.hasActiveRecording {
                do {
                    try await cameraCaptureService.stopRecording()
                } catch {
                    activeCameraRecordingURL = nil
                    stopWarnings.append("摄像头视频保存失败，已保留屏幕录制：\(error.localizedDescription)")
                }
            }
            if microphoneCaptureService.hasActiveRecording {
                do {
                    try microphoneCaptureService.stopRecording()
                } catch {
                    activeMicrophoneRecordingURL = nil
                    stopWarnings.append("降噪麦克风音轨保存失败，已保留屏幕录制：\(error.localizedDescription)")
                }
            }

            if let screenURL = activeScreenRecordingURL {
                let duration = max(0.1, Date().timeIntervalSince(recordingStartedAt ?? Date()))
                let timeline = timelineExcludingPausedRanges(duration: duration)
                if timeline.segments.isEmpty {
                    noExportableSegmentMessage = "录制内容全部处于暂停状态，未生成剪辑项目。原始录屏已保存：\(screenURL.path)"
                } else {
                    let project = RecordingProject(
                        screenRecordingURL: screenURL,
                        cameraRecordingURL: activeCameraRecordingURL,
                        microphoneRecordingURL: activeMicrophoneRecordingURL,
                        sourceDuration: duration,
                        preferences: preferences,
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
            recordingStartedAt = nil
            pauseStartedAt = nil
            pausedRanges = []
            overlayService.endRecording()
            isRecording = false
            isPaused = false
            let messages = stopWarnings + [noExportableSegmentMessage].compactMap { $0 }
            lastErrorMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
            if noExportableSegmentMessage != nil {
                statusMessage = "录制已停止，没有可导出的片段"
            } else {
                statusMessage = stopWarnings.isEmpty ? "录制已停止，可以进入剪辑和导出" : "录制已停止，部分附加轨道已跳过"
            }
            AppWindowUtility.restoreMainWindows()
        } catch {
            if cameraCaptureService.hasActiveRecording {
                try? await cameraCaptureService.stopRecording()
            }
            if microphoneCaptureService.hasActiveRecording {
                try? microphoneCaptureService.stopRecording()
            }
            activeScreenRecordingURL = nil
            activeCameraRecordingURL = nil
            activeMicrophoneRecordingURL = nil
            recordingStartedAt = nil
            pauseStartedAt = nil
            pausedRanges = []
            overlayService.endRecording()
            isRecording = false
            isPaused = false
            AppWindowUtility.restoreMainWindows()
            lastErrorMessage = error.localizedDescription
            statusMessage = "停止录制失败：\(error.localizedDescription)"
        }
    }

    func togglePauseIntent() {
        guard isRecording, !isStoppingRecording else { return }

        if isPaused {
            closeActivePauseIfNeeded()
            isPaused = false
            overlayService.setPaused(false)
            statusMessage = "已继续录制"
        } else {
            pauseStartedAt = currentRecordingTime
            isPaused = true
            overlayService.setPaused(true)
            statusMessage = "录制已暂停，导出会自动跳过暂停段"
        }
    }

    func chooseRecordingDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择默认保存目录"
        panel.prompt = "使用此目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = RecordingFileStore.recordingsDirectory(path: preferences.recordingDirectoryPath)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.recordingDirectoryPath = url.path
        statusMessage = "默认保存目录已更新"
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

    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .beginHoldZoom:
            guard isRecording else { return }
            guard !isPaused else {
                statusMessage = "录制已暂停，继续后可使用缩放"
                return
            }
            overlayService.beginHoldZoom()
            statusMessage = "按住缩放：以鼠标位置放大"
        case .endHoldZoom:
            guard isRecording else { return }
            overlayService.endHoldZoom()
            statusMessage = "缩放已恢复"
        case .beginClickZoom:
            guard isRecording else { return }
            guard !isPaused else { return }
            overlayService.beginClickZoom()
        case .endClickZoom:
            guard isRecording else { return }
            overlayService.endClickZoom()
        case .zoomIn:
            overlayService.adjustZoom(by: 0.2)
            statusMessage = "临时缩放倍率 \(String(format: "%.1f", overlayService.zoomMagnification))x"
        case .zoomOut:
            overlayService.adjustZoom(by: -0.2)
            statusMessage = "临时缩放倍率 \(String(format: "%.1f", overlayService.zoomMagnification))x"
        case .selectTool(let tool):
            overlayService.selectTool(tool)
            if overlayService.selectedTool == nil {
                statusMessage = "标注工具已关闭，鼠标会穿透到其他软件"
            } else {
                statusMessage = "标注工具：\(tool.displayName)，再次选择可关闭"
            }
        case .undo:
            guard !isPaused else {
                statusMessage = "录制已暂停，继续后再撤销标注"
                return
            }
            overlayService.undoLastAnnotation()
            statusMessage = "已撤销上一笔标注"
        case .clearAnnotations:
            guard !isPaused else {
                statusMessage = "录制已暂停，继续后再清除标注"
                return
            }
            overlayService.clearAllAnnotations()
            statusMessage = "已清除全部标注"
        case .toggleCamera:
            toggleCameraIntent()
        case .toggleCameraShape:
            overlayService.toggleCameraShape()
            statusMessage = "摄像头形状：\(overlayService.cameraShape.displayName)"
        case .stopRecording:
            if isRecording {
                toggleRecordingIntent()
            }
        }
    }

    private var currentRecordingTime: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    var selectedProject: RecordingProject? {
        guard let selectedProjectID else { return recentProjects.first }
        return recentProjects.first { $0.id == selectedProjectID }
    }

    func selectProject(_ id: UUID) {
        selectedProjectID = id
        if let project = recentProjects.first(where: { $0.id == id }) {
            ensureRenderedPreview(for: project)
        }
    }

    func splitProject(_ id: UUID, atExportRatio ratio: Double) {
        guard !isExporting else {
            statusMessage = "正在导出，完成后再剪辑"
            return
        }
        guard let index = recentProjects.firstIndex(where: { $0.id == id }) else { return }
        let clampedRatio = min(max(0, ratio), 1)
        let exportTime = recentProjects[index].timeline.totalExportDuration * clampedRatio
        guard recentProjects[index].timeline.canSplit(atExportTime: exportTime) else {
            statusMessage = "请选择片段中间位置再分割"
            return
        }
        guard let sourceTime = recentProjects[index].timeline.sourceTime(forExportTime: exportTime) else {
            return
        }

        if recentProjects[index].timeline.split(at: sourceTime) {
            recentProjects = recentProjects
            exportMessages[id] = nil
            refreshRenderedPreview(for: recentProjects[index], force: true)
            statusMessage = "已在 \(Int(sourceTime)) 秒处分割"
        }
    }

    func deleteLastSegment(_ id: UUID) {
        guard !isExporting else {
            statusMessage = "正在导出，完成后再剪辑"
            return
        }
        guard let index = recentProjects.firstIndex(where: { $0.id == id }),
              let lastSegment = recentProjects[index].timeline.segments.last,
              recentProjects[index].timeline.segments.count > 1 else {
            statusMessage = "至少保留一个片段"
            return
        }

        if recentProjects[index].timeline.deleteSegment(id: lastSegment.id) {
            recentProjects = recentProjects
            exportMessages[id] = nil
            refreshRenderedPreview(for: recentProjects[index], force: true)
            statusMessage = "已删除最后一个片段"
        }
    }

    func exportProject(_ id: UUID) {
        guard !isExporting else {
            statusMessage = "已有导出任务正在进行"
            return
        }
        guard let project = recentProjects.first(where: { $0.id == id }) else { return }
        cancelRenderedPreview(for: id)
        isExporting = true
        exportMessages[id] = "正在导出..."
        Task {
            defer {
                isExporting = false
            }
            do {
                let outputURL = try await exportService.export(project: project)
                if recentProjects.first(where: { $0.id == id }) == project {
                    exportMessages[id] = "导出完成：\(outputURL.path)"
                    statusMessage = "导出完成"
                } else {
                    exportMessages[id] = "旧版本导出完成：\(outputURL.path)。当前剪辑已修改，请重新导出最新版。"
                    statusMessage = "旧版本导出完成"
                }
            } catch {
                exportMessages[id] = error.localizedDescription
                statusMessage = "导出失败"
            }
        }
    }

    func exportMessage(for project: RecordingProject) -> String? {
        exportMessages[project.id]
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
        cancelRenderedPreview(for: project.id)
        renderedPreviewURLs[project.id] = nil

        guard force || project.needsRenderedPreview else {
            renderedPreviewMessages[project.id] = nil
            return
        }

        renderedPreviewMessages[project.id] = "正在生成带缩放、标注和摄像头的效果预览..."
        renderedPreviewTasks[project.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let outputURL = try await previewExportService.export(project: project, prefix: "preview")
                guard !Task.isCancelled else { return }
                renderedPreviewURLs[project.id] = outputURL
                renderedPreviewMessages[project.id] = "效果预览已生成，下面播放的是合成后的画面。"
                renderedPreviewTasks[project.id] = nil
            } catch {
                guard !Task.isCancelled else { return }
                renderedPreviewMessages[project.id] = "效果预览生成失败：\(error.localizedDescription)。导出成片仍可手动重试。"
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
        renderedPreviewTasks[projectID] = nil
        if renderedPreviewURLs[projectID] == nil {
            renderedPreviewMessages[projectID] = nil
        }
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
