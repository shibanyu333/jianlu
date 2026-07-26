import AppKit
import SwiftUI
import JianLuCore

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // Capture on top, then a two-pane workspace: the recording library on the left,
        // the editor for whichever recording is selected on the right. The editor used
        // to sit inline between the capture panel and the list, which meant it moved
        // around as banners appeared and pushed the list off screen.
        VStack(spacing: 0) {
            CaptureHeader()
            Divider()
            HSplitView {
                RecordingLibraryPane()
                EditorPane()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MainWindowMarker())
        .id(appState.preferences.language)
        .onAppear {
            appState.refreshPermissions()
        }
    }
}

private struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        markWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        markWindow(for: nsView)
    }

    private func markWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.identifier = AppWindowUtility.mainWindowIdentifier
            if window.title.isEmpty || window.title == "JianLu" {
                window.title = "简录 JianLu"
            }
            // Without this, SwiftUI lets the page slide under a transparent title bar,
            // which put the page heading right on top of the traffic lights. Reserve
            // the title bar and let the page own the heading.
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .hidden
        }
    }
}

// MARK: - Capture header

/// Everything about *making* a recording: the two primary actions, the live state
/// chips and any permission banners. It stays put above the editing workspace.
private struct CaptureHeader: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeroPanel()
            StatusChipRow()
            AlertStack()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Hero

/// The one thing the window is for: start a recording or take a screenshot. Everything
/// else on the page is status or history.
private struct HeroPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("简录 JianLu")
                        .font(.system(size: 28, weight: .semibold))
                    Text(appState.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                SettingsLink {
                    Label(tr("设置", "Settings"), systemImage: "gearshape")
                }
                .controlSize(.large)
            }

            HStack(spacing: 12) {
                PrimaryActionButton(
                    title: recordingButtonTitle,
                    subtitle: tr("选区域后开始录屏", "Pick an area, then record"),
                    systemImage: recordingButtonSymbol,
                    tint: appState.isRecording ? .red : .accentColor,
                    isBusy: appState.isStartingRecording || appState.isStoppingRecording || appState.isPreparingRegionSelection
                ) {
                    appState.toggleRecordingIntent()
                }
                .disabled(appState.isStoppingRecording || appState.isStartingRecording || appState.isPreparingRegionSelection)

                PrimaryActionButton(
                    title: screenshotButtonTitle,
                    subtitle: tr("按下即定格画面", "Freezes the screen instantly"),
                    systemImage: "camera.viewfinder",
                    tint: .teal,
                    isBusy: appState.isPreparingScreenshot
                ) {
                    appState.takeScreenshotIntent()
                }
                .disabled(
                    appState.isRecording
                        || appState.isStartingRecording
                        || appState.isStoppingRecording
                        || appState.isPreparingRegionSelection
                )
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var recordingButtonTitle: String {
        if appState.isStoppingRecording { return tr("正在停止", "Stopping…") }
        if appState.isStartingRecording { return tr("正在启动", "Starting…") }
        if appState.isPreparingRegionSelection { return tr("准备中", "Preparing…") }
        if appState.isRecording { return tr("停止录制", "Stop recording") }
        if appState.isSelectingRegion { return tr("确认区域", "Confirm area") }
        return tr("开始录屏", "Record screen")
    }

    private var screenshotButtonTitle: String {
        if appState.isPreparingScreenshot { return tr("准备截图", "Preparing…") }
        if appState.isSelectingScreenshot { return tr("确认截图", "Confirm shot") }
        return tr("截图", "Screenshot")
    }

    private var recordingButtonSymbol: String {
        if appState.isStartingRecording || appState.isPreparingRegionSelection { return "hourglass" }
        if appState.isRecording { return "stop.circle.fill" }
        if appState.isSelectingRegion { return "record.circle" }
        return "record.circle"
    }
}

private struct PrimaryActionButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 10))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status chips

/// Compact, clickable state: what is on, what is off, what still needs permission.
private struct StatusChipRow: View {
    @EnvironmentObject private var appState: AppState
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            StatusChip(
                title: tr("摄像头", "Camera"),
                detail: appState.cameraEnabled
                    ? appState.preferences.cameraShape.displayName + " · \(Int(appState.preferences.cameraFrame.width * 100))%"
                    : tr("已关闭", "Off"),
                systemImage: appState.cameraEnabled ? "video.fill" : "video.slash",
                isOn: appState.cameraEnabled
            ) {
                appState.toggleCameraIntent()
            }

            StatusChip(
                title: tr("麦克风", "Microphone"),
                detail: appState.preferences.microphoneEnabled
                    ? (appState.preferences.microphoneNoiseReductionEnabled ? tr("已开启 · 降噪", "On · noise reduction") : tr("已开启", "On"))
                    : tr("已关闭", "Off"),
                systemImage: appState.preferences.microphoneEnabled ? "mic.fill" : "mic.slash",
                isOn: appState.preferences.microphoneEnabled
            ) {
                appState.preferences.microphoneEnabled.toggle()
            }

            StatusChip(
                title: tr("鼠标放大", "Mouse zoom"),
                detail: appState.preferences.zoomMouseButton == .off
                    ? tr("已关闭", "Off")
                    : appState.preferences.zoomMouseButton.displayName,
                systemImage: "plus.magnifyingglass",
                isOn: appState.preferences.zoomMouseButton != .off
            ) {
                appState.preferences.zoomMouseButton = appState.preferences.zoomMouseButton == .off ? .middle : .off
            }

            StatusChip(
                title: tr("截图", "Screenshot"),
                detail: appState.preferences.screenshotFreezesScreen
                    ? tr("按下即定格", "Freezes on press")
                    : tr("实时画面", "Live screen"),
                systemImage: "camera.viewfinder",
                isOn: appState.preferences.screenshotFreezesScreen
            ) {
                appState.preferences.screenshotFreezesScreen.toggle()
            }

            StatusChip(
                title: tr("权限", "Permissions"),
                detail: appState.permissionSnapshot.missingDescriptions.isEmpty
                    ? tr("已就绪", "All granted")
                    : tr("缺少 ", "Missing ") + "\(appState.permissionSnapshot.missingDescriptions.count)",
                systemImage: appState.permissionSnapshot.missingDescriptions.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                isOn: appState.permissionSnapshot.missingDescriptions.isEmpty
            ) {
                appState.requestPermissions()
            }
        }
    }
}

private struct StatusChip: View {
    let title: String
    let detail: String
    let systemImage: String
    let isOn: Bool
    var action: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.callout)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isOn ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 1)
        }

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - Alerts

private struct AlertStack: View {
    @EnvironmentObject private var appState: AppState

    /// The header is a fixed band above the workspace, so an empty banner stack has to
    /// take up no room at all — otherwise it eats a stack spacing worth of editor.
    private var hasAlerts: Bool {
        !appState.permissionSnapshot.screenRecordingGranted
            || !appState.permissionSnapshot.shortcutMonitoringGranted
            || appState.captureShortcutNeedsInterception
            || appState.lastErrorMessage != nil
    }

    var body: some View {
        if hasAlerts {
            banners
        }
    }

    private var banners: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !appState.permissionSnapshot.screenRecordingGranted {
                AlertBanner(
                    title: tr("还没有屏幕录制权限", "Screen recording is not allowed yet"),
                    detail: tr("授权后通常需要退出并重新打开简录。", "macOS usually only applies it after you relaunch JianLu."),
                    systemImage: "exclamationmark.triangle.fill"
                ) {
                    Button(tr("打开系统设置", "Open System Settings")) {
                        appState.openScreenRecordingSettings()
                    }
                }
            }

            if !appState.permissionSnapshot.shortcutMonitoringGranted {
                AlertBanner(
                    title: tr("快捷键权限未就绪", "Shortcut monitoring is incomplete"),
                    detail: appState.permissionSnapshot.shortcutRecoveryMessage,
                    systemImage: "keyboard"
                ) {
                    if !appState.permissionSnapshot.shortcutAccessibilityGranted {
                        Button(tr("辅助功能", "Accessibility")) {
                            appState.openAccessibilitySettings()
                        }
                    }
                    if !appState.permissionSnapshot.shortcutInputMonitoringGranted {
                        Button(tr("输入监控", "Input Monitoring")) {
                            appState.openInputMonitoringSettings()
                        }
                    }
                }
            }

            if appState.captureShortcutNeedsInterception {
                AlertBanner(
                    title: tr("「替代系统快捷键」尚未生效", "Shortcut replacement is not active"),
                    detail: tr("⇧⌘3/4/5 仍会触发 macOS 原生截图，需开启辅助功能并重启简录。", "⇧⌘3/4/5 still trigger the macOS originals; grant Accessibility and relaunch JianLu."),
                    systemImage: "exclamationmark.triangle.fill"
                ) {
                    Button(tr("打开辅助功能", "Open Accessibility")) {
                        appState.openAccessibilitySettings()
                    }
                    Button(tr("重启简录", "Relaunch")) {
                        appState.relaunchApp()
                    }
                }
            }

            if let lastErrorMessage = appState.lastErrorMessage {
                AlertBanner(
                    title: tr("提示", "Heads up"),
                    detail: lastErrorMessage,
                    systemImage: "info.circle.fill"
                ) {
                    Button(tr("知道了", "Dismiss")) {
                        appState.lastErrorMessage = nil
                    }
                }
            }
        }
    }
}

private struct AlertBanner<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                actions()
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        }
    }
}

// MARK: - Recording library pane

/// Left pane of the workspace: every finished recording, one row each. Clicking a row
/// loads it into the editor on the right; the trash button retires it for good.
private struct RecordingLibraryPane: View {
    @EnvironmentObject private var appState: AppState
    @State private var projectPendingDeletion: RecordingProject?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(tr("最近录制", "Recent recordings"), systemImage: "clock")
                    .font(.headline)
                Spacer(minLength: 8)
                if !appState.recentProjects.isEmpty {
                    Button {
                        appState.openRecordingDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help(tr("在访达中打开", "Reveal in Finder"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if appState.recentProjects.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "movieclapper")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(tr("录制完成后会出现在这里", "Your recordings will show up here"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.recentProjects) { project in
                            RecentProjectRow(
                                project: project,
                                isSelected: project.id == appState.selectedProject?.id,
                                onSelect: {
                                    appState.selectProject(project.id)
                                },
                                onDelete: {
                                    projectPendingDeletion = project
                                }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 250, idealWidth: 300, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
        .alert(
            tr("删除这段录制？", "Delete this recording?"),
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            presenting: projectPendingDeletion
        ) { project in
            // Return keeps the footage. The window activates itself on launch and after
            // a recording, so a keystroke meant for another app can land in this dialog;
            // deleting has to need a deliberate click, never a stray Return.
            Button(tr("取消", "Cancel"), role: .cancel) {
                projectPendingDeletion = nil
            }
            .keyboardShortcut(.defaultAction)
            Button(tr("移到废纸篓", "Move to Trash"), role: .destructive) {
                appState.deleteProject(project.id)
                projectPendingDeletion = nil
            }
        } message: { project in
            Text(
                project.screenRecordingURL.lastPathComponent + "\n"
                    + tr(
                        "屏幕、摄像头、麦克风源文件和效果预览都会移到废纸篓，可以在访达里找回。已导出的成片不受影响。",
                        "The screen, camera and microphone files plus the rendered preview go to the Trash, so Finder can bring them back. Movies you already exported are left alone."
                    )
            )
        }
    }
}

private struct RecentProjectRow: View {
    let project: RecordingProject
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "movieclapper")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.screenRecordingURL.lastPathComponent)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 8) {
                            Text(durationText)
                            Text(project.createdAt.formatted(date: .abbreviated, time: .shortened))
                            if isSelected {
                                Text(tr("当前剪辑", "Editing"))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(tr("删除这段录制（移到废纸篓）", "Delete this recording (moves it to the Trash)"))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
        }
        .contextMenu {
            Button(tr("剪辑这段录制", "Edit this recording"), action: onSelect)
            Button(tr("删除（移到废纸篓）", "Delete (move to Trash)"), role: .destructive, action: onDelete)
        }
    }

    private var durationText: String {
        let seconds = Int(project.duration.rounded())
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0
            ? String(format: "%d:%02d", minutes, remainder)
            : tr("\(remainder) 秒", "\(remainder)s")
    }
}

// MARK: - Editor pane

/// Right pane of the workspace: the editor for the selected recording, or an invitation
/// to pick one when the library is empty.
private struct EditorPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let selectedProject = appState.selectedProject {
                EditorView(project: selectedProject)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(tr("先录一段，再在这里剪辑和导出", "Record something, then trim and export it here"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }
}
