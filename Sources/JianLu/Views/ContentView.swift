import SwiftUI
import JianLuCore

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            HStack(spacing: 0) {
                SidebarView()
                Divider()
                ScrollView {
                    MainDashboardView()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .onAppear {
            appState.refreshPermissions()
        }
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("简录")
                    .font(.title2.weight(.semibold))
                Text(appState.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                appState.requestPermissions()
            } label: {
                Label("检查权限", systemImage: "checkmark.shield")
            }

            Button {
                appState.toggleCameraIntent()
            } label: {
                Label(appState.cameraEnabled ? "关闭摄像头" : "开启摄像头", systemImage: "video")
            }
            .disabled(appState.isStartingRecording)

            Button {
                appState.toggleRecordingIntent()
            } label: {
                Label(
                    recordingButtonTitle,
                    systemImage: recordingButtonSymbol
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.isRecording ? .red : .accentColor)
            .disabled(appState.isStoppingRecording || appState.isStartingRecording || appState.isPreparingRegionSelection)
            .help(appState.permissionSnapshot.screenRecordingGranted ? "选择录制区域" : "点击后会请求屏幕录制权限")
        }
        .padding(20)
    }

    private var recordingButtonTitle: String {
        if appState.isStoppingRecording { return "正在停止" }
        if appState.isStartingRecording { return "正在启动" }
        if appState.isPreparingRegionSelection { return "准备中" }
        if appState.isRecording { return "停止录制" }
        if appState.isSelectingRegion { return "确认区域" }
        return "选择区域"
    }

    private var recordingButtonSymbol: String {
        if appState.isStartingRecording { return "hourglass" }
        if appState.isPreparingRegionSelection { return "hourglass" }
        if appState.isRecording { return "stop.circle.fill" }
        if appState.isSelectingRegion { return "record.circle" }
        return "viewfinder"
    }
}

private struct SidebarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("录制方案", systemImage: "rectangle.dashed.badge.record")
                .font(.headline)
            Label("最近视频", systemImage: "clock")
                .foregroundStyle(.secondary)
            Label("导出设置", systemImage: "square.and.arrow.up")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(width: 180, alignment: .leading)
    }
}

private struct MainDashboardView: View {
    @EnvironmentObject private var appState: AppState
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("客户方案讲解")
                .font(.largeTitle.weight(.semibold))
            Text("录屏、摄像头头像框、缩放重点、划线涂鸦和剪辑导出会在这里串成一个简单流程。")
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 14) {
                FeatureCard(title: "屏幕录制", detail: appState.preferences.includeAppInterface ? "会录入简录主界面。" : "默认避开简录主界面。", symbol: "display")
                FeatureCard(title: "摄像头头像框", detail: appState.cameraEnabled ? "圆形右下角，可拖动缩放，支持背景和美颜。" : "当前关闭，可随时开启。", symbol: "person.crop.circle")
                FeatureCard(title: "缩放和标注", detail: "快捷键缩放、画笔、高亮、直线和箭头重点。", symbol: "pencil.and.outline")
                FeatureCard(
                    title: "声音",
                    detail: appState.preferences.microphoneEnabled
                        ? (appState.preferences.microphoneNoiseReductionEnabled ? "麦克风已开启，导出时使用降噪讲解音轨。" : "麦克风已开启，会录入讲解声音。")
                        : "麦克风已关闭。",
                    symbol: "mic"
                )
            }

            RecordingOptionsPanel()
            PermissionPanel(snapshot: appState.permissionSnapshot)
            if !appState.permissionSnapshot.screenRecordingGranted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("屏幕录制授权后，通常需要退出并重新打开简录。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        appState.openScreenRecordingSettings()
                    } label: {
                        Label("打开系统设置", systemImage: "gear")
                    }
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if !appState.permissionSnapshot.shortcutMonitoringGranted {
                HStack {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.orange)
                    Text("按住缩放和点击缩放需要“辅助功能”和“输入监控”权限，否则录制时收不到快捷键和鼠标点击。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        appState.openShortcutMonitoringSettings()
                    } label: {
                        Label("打开快捷键权限设置", systemImage: "gear")
                    }
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if let lastErrorMessage = appState.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let selectedProject = appState.selectedProject {
                EditorView(project: selectedProject)
            }
            RecentProjectsView(projects: appState.recentProjects)
        }
        .padding(28)
    }
}

private struct RecordingOptionsPanel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("录制设置")
                .font(.headline)

            Toggle(isOn: $appState.preferences.includeAppInterface) {
                Label("录入简录界面", systemImage: "macwindow")
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $appState.preferences.microphoneEnabled) {
                Label("录入麦克风", systemImage: appState.preferences.microphoneEnabled ? "mic" : "mic.slash")
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $appState.preferences.microphoneNoiseReductionEnabled) {
                Label("麦克风降噪", systemImage: "waveform.badge.magnifyingglass")
            }
            .toggleStyle(.checkbox)
            .disabled(!appState.preferences.microphoneEnabled)

            HStack(spacing: 10) {
                Label("默认保存目录", systemImage: "folder")
                    .font(.callout.weight(.medium))
                Text(appState.recordingDirectoryDisplayPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    appState.openRecordingDirectory()
                } label: {
                    Label("打开", systemImage: "arrow.up.forward.app")
                }
                Button {
                    appState.chooseRecordingDirectory()
                } label: {
                    Label("更改", systemImage: "folder.badge.gearshape")
                }
            }

            HStack {
                Label("摄像头背景、美颜和虚化在设置菜单里调整", systemImage: "slider.horizontal.3")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsLink {
                    Label("打开设置", systemImage: "gearshape")
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FeatureCard: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PermissionPanel: View {
    let snapshot: PermissionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("权限状态")
                .font(.headline)
            HStack(spacing: 12) {
                PermissionBadge(title: "屏幕录制", isGranted: snapshot.screenRecordingGranted)
                PermissionBadge(title: "摄像头", isGranted: snapshot.cameraGranted)
                PermissionBadge(title: "麦克风", isGranted: snapshot.microphoneGranted)
                PermissionBadge(title: "辅助功能", isGranted: snapshot.shortcutAccessibilityGranted)
                PermissionBadge(title: "输入监控", isGranted: snapshot.shortcutInputMonitoringGranted)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PermissionBadge: View {
    let title: String
    let isGranted: Bool

    var body: some View {
        Label(title, systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(isGranted ? .green : .orange)
            .font(.callout)
    }
}

private struct RecentProjectsView: View {
    @EnvironmentObject private var appState: AppState
    let projects: [RecordingProject]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最近录制")
                .font(.headline)

            if projects.isEmpty {
                Text("录制完成后会出现在这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(projects.prefix(3)) { project in
                    Button {
                        appState.selectProject(project.id)
                    } label: {
                        HStack {
                            Image(systemName: "movieclapper")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.screenRecordingURL.lastPathComponent)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text("时长 \(Int(project.duration.rounded())) 秒")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
