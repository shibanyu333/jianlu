import JianLuCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label(tr("通用", "General"), systemImage: "gearshape") }
            RecordingSettingsTab()
                .tabItem { Label(tr("录制", "Recording"), systemImage: "record.circle") }
            CameraSettingsTab()
                .tabItem { Label(tr("摄像头", "Camera"), systemImage: "person.crop.circle.badge.video") }
            ShortcutSettingsTab()
                .tabItem { Label(tr("快捷键", "Shortcuts"), systemImage: "keyboard") }
            ScreenshotSettingsTab()
                .tabItem { Label(tr("截图", "Screenshot"), systemImage: "camera.viewfinder") }
        }
        .frame(width: 560, height: 500)
        // Re-render every label when the language preference changes.
        .id(appState.preferences.language)
    }
}

// MARK: - 通用 / General

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                Picker(tr("界面语言", "Language"), selection: $appState.preferences.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } header: {
                SettingsSectionHeader(tr("外观", "Appearance"), systemImage: "globe")
            } footer: {
                SettingsFootnote(tr("立即生效，无需重启。", "Applies immediately, no restart needed."))
            }

            Section {
                Toggle(tr("开机时自动启动简录", "Launch JianLu at login"), isOn: launchAtLoginBinding)
                if appState.launchAtLoginState == .requiresApproval {
                    Button {
                        appState.openLoginItemsSettings()
                    } label: {
                        Label(tr("在系统设置中批准", "Approve in System Settings"), systemImage: "checkmark.shield")
                    }
                }
            } header: {
                SettingsSectionHeader(tr("启动", "Startup"), systemImage: "power")
            } footer: {
                SettingsFootnote(
                    appState.launchAtLoginState == .requiresApproval
                        ? tr(
                            "macOS 还需要你在「系统设置 › 通用 › 登录项」里批准简录，之后才会真正自动启动。",
                            "macOS still needs you to approve JianLu in System Settings › General › Login Items before it actually starts automatically."
                        )
                        : tr(
                            "登录 Mac 后自动启动简录，菜单栏图标随时可用；也可以随时在「系统设置 › 通用 › 登录项」里关闭。",
                            "JianLu starts when you log in, so the menu bar icon is always ready. You can also turn this off in System Settings › General › Login Items."
                        )
                )
            }

            Section {
                SettingsRow(tr("默认保存目录", "Save recordings to")) {
                    HStack(spacing: 8) {
                        Text(appState.recordingDirectoryDisplayPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(appState.recordingDirectoryDisplayPath)
                        Button(tr("更改…", "Change…")) {
                            appState.chooseRecordingDirectory()
                        }
                    }
                }
                Button {
                    appState.openRecordingDirectory()
                } label: {
                    Label(tr("在访达中打开", "Reveal in Finder"), systemImage: "folder")
                }
            } header: {
                SettingsSectionHeader(tr("文件", "Files"), systemImage: "folder")
            }
        }
        .formStyle(.grouped)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.launchAtLoginState.isOn },
            set: { appState.setLaunchAtLogin($0) }
        )
    }
}

// MARK: - 录制 / Recording

private struct RecordingSettingsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle(tr("录入简录界面", "Include JianLu's own windows"), isOn: $appState.preferences.includeAppInterface)
                Toggle(tr("录入麦克风", "Record microphone"), isOn: $appState.preferences.microphoneEnabled)
                Toggle(tr("麦克风降噪", "Noise reduction"), isOn: $appState.preferences.microphoneNoiseReductionEnabled)
                    .disabled(!appState.preferences.microphoneEnabled)
            } header: {
                SettingsSectionHeader(tr("画面与声音", "Picture & sound"), systemImage: "waveform")
            } footer: {
                SettingsFootnote(
                    tr(
                        "关闭「录入简录界面」时，简录自己的窗口不会出现在录制画面里。",
                        "With JianLu's own windows excluded, the app never appears in your recording."
                    )
                )
            }

            Section {
                Toggle(
                    tr("录制结束后打开主窗口", "Open the main window when recording stops"),
                    isOn: $appState.preferences.openMainWindowAfterRecording
                )
            } header: {
                SettingsSectionHeader(tr("窗口", "Window"), systemImage: "macwindow")
            } footer: {
                SettingsFootnote(
                    tr(
                        "默认关闭：录制结束后简录留在后台，不会抢走你正在用的窗口。随时点菜单栏图标 →「显示主窗口」即可剪辑导出。",
                        "Off by default: when a recording stops JianLu stays in the background instead of stealing focus. Use the menu bar icon › Show main window whenever you want to edit and export."
                    )
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 摄像头 / Camera

private struct CameraSettingsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                CameraAvatarPreview(
                    frame: appState.preferences.cameraFrame,
                    shape: appState.preferences.cameraShape
                )
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                SettingsSectionHeader(tr("预览", "Preview"), systemImage: "eye")
            } footer: {
                SettingsFootnote(
                    tr(
                        "按 16:9 录制画面预览：「圆形」是正圆，「椭圆」跟随画面比例变扁。",
                        "Shown on a 16:9 canvas: Circle stays a true circle, Oval follows the frame's aspect ratio."
                    )
                )
            }

            Section {
                Toggle(tr("默认显示摄像头头像框", "Show camera bubble by default"), isOn: $appState.cameraEnabled)

                Picker(tr("头像形状", "Shape"), selection: $appState.preferences.cameraShape) {
                    ForEach(CameraFrameShape.allCases, id: \.self) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
                .pickerStyle(.segmented)

                SettingsSlider(
                    title: tr("头像大小", "Size"),
                    value: cameraSizeBinding,
                    range: NormalizedRect.minCameraFrameSize...NormalizedRect.maxCameraFrameSize
                )
            } header: {
                SettingsSectionHeader(tr("外观", "Appearance"), systemImage: "person.crop.circle")
            }

            Section {
                Picker(tr("背景", "Background"), selection: $appState.preferences.cameraBackgroundStyle) {
                    ForEach(CameraBackgroundStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                if appState.preferences.cameraBackgroundStyle.usesCustomImage {
                    SettingsRow(tr("图片", "Image")) {
                        HStack(spacing: 8) {
                            Text(appState.cameraBackgroundImageName ?? tr("尚未选择", "None chosen"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button(tr("选择…", "Choose…")) {
                                appState.chooseCameraBackgroundImage()
                            }
                            if appState.cameraBackgroundImageName != nil {
                                Button(tr("移除", "Remove")) {
                                    appState.clearCameraBackgroundImage()
                                }
                            }
                        }
                    }
                }

                Picker(tr("背景虚化", "Blur"), selection: $appState.preferences.cameraBackgroundBlur) {
                    ForEach(CameraBackgroundBlur.allCases, id: \.self) { blur in
                        Text(blur.displayName).tag(blur)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                SettingsSectionHeader(tr("背景", "Background"), systemImage: "photo")
            } footer: {
                SettingsFootnote(
                    appState.preferences.cameraBackgroundStyle.usesCustomImage
                        ? tr(
                            "选中的图片会拷贝到简录的支持目录，即使原文件被移动或删除，导出成片依然可用。",
                            "Your picture is copied into JianLu's support folder, so exports keep working even if the original moves or is deleted."
                        )
                        : tr(
                            "背景替换需要摄像头里能识别到人像；识别不到时会自动退回原始画面。",
                            "Background replacement needs a detectable person; JianLu falls back to the raw camera feed when there is none."
                        )
                )
            }

            Section {
                SettingsSlider(title: tr("磨皮", "Smoothing"), value: $appState.preferences.cameraBeauty.smoothing, range: 0...1)
                SettingsSlider(title: tr("美白", "Whitening"), value: $appState.preferences.cameraBeauty.whitening, range: 0...1)
                SettingsSlider(title: tr("瘦脸", "Face slimming"), value: $appState.preferences.cameraBeauty.faceSlimming, range: 0...1)
                HStack {
                    Spacer()
                    Button(tr("自然", "Natural")) {
                        appState.preferences.cameraBeauty = .natural
                    }
                    Button(tr("全部关闭", "Turn all off")) {
                        appState.preferences.cameraBeauty = .off
                    }
                }
                .controlSize(.small)
            } header: {
                SettingsSectionHeader(tr("美颜", "Retouch"), systemImage: "sparkles")
            } footer: {
                SettingsFootnote(
                    tr(
                        "磨皮柔化皮肤纹理，美白提亮肤色，瘦脸会收窄识别到的脸部两侧；录制中调整会实时生效，导出成片沿用同一套处理。",
                        "Smoothing softens skin texture, whitening lifts skin tone, and face slimming narrows the sides of the detected face. Changes apply live and the export uses the same pipeline."
                    )
                )
            }
        }
        .formStyle(.grouped)
    }

    private var cameraSizeBinding: Binding<Double> {
        Binding(
            get: { appState.preferences.cameraFrame.width },
            set: { appState.updateDefaultCameraSize($0) }
        )
    }
}

/// A 16:9 stand-in for the recording canvas with the avatar drawn through the very
/// same geometry and outline the overlay and the export use, so the difference
/// between 圆形 and 椭圆 is visible before recording starts.
private struct CameraAvatarPreview: View {
    let frame: NormalizedRect
    let shape: CameraFrameShape

    private let canvasWidth: CGFloat = 280

    var body: some View {
        let canvasSize = CGSize(width: canvasWidth, height: canvasWidth * 9 / 16)
        let bubble = frame.cameraBubbleRect(in: canvasSize, shape: shape)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.14))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)

            CameraFrameClipShape(shape: shape)
                .fill(Color.accentColor.opacity(0.55))
                .overlay {
                    CameraFrameClipShape(shape: shape)
                        .stroke(.white.opacity(0.9), lineWidth: 2)
                }
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: min(bubble.width, bubble.height) * 0.5))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: bubble.width, height: bubble.height)
                .offset(x: bubble.minX, y: bubble.minY)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .animation(.easeInOut(duration: 0.15), value: shape)
        .animation(.easeInOut(duration: 0.15), value: bubble)
    }
}

// MARK: - 快捷键 / Shortcuts

private struct ShortcutSettingsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                Picker(tr("按住缩放快捷键", "Hold-to-zoom key"), selection: $appState.preferences.zoomShortcut) {
                    ForEach(ZoomShortcut.allCases, id: \.self) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                Picker(tr("鼠标放大按键", "Zoom mouse button"), selection: $appState.preferences.zoomMouseButton) {
                    ForEach(ZoomMouseButton.allCases, id: \.self) { button in
                        Text(button.displayName).tag(button)
                    }
                }
            } header: {
                SettingsSectionHeader(tr("放大", "Zoom"), systemImage: "plus.magnifyingglass")
            } footer: {
                SettingsFootnote(zoomMouseButtonFootnote)
            }

            Section {
                Picker(tr("截图/录屏快捷键", "Capture shortcuts"), selection: $appState.preferences.captureShortcutPreset) {
                    ForEach(CaptureShortcutPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                if appState.preferences.captureShortcutPreset == .macReplacement {
                    CaptureReplacementStatusView()
                }
            } header: {
                SettingsSectionHeader(tr("截图与录屏", "Capture"), systemImage: "camera")
            } footer: {
                SettingsFootnote(appState.preferences.captureShortcutPreset.detail)
            }

            Section {
                ShortcutRow(
                    title: tr("鼠标放大", "Mouse zoom"),
                    shortcut: appState.preferences.zoomMouseButton == .off
                        ? tr("顶部栏按钮", "Toolbar button")
                        : tr("单击", "Click ") + appState.preferences.zoomMouseButton.displayName
                )
                ShortcutRow(title: tr("按住缩放", "Hold to zoom"), shortcut: appState.preferences.zoomShortcut.displayName)
                ShortcutRow(title: tr("放大/缩小倍率", "Zoom in / out"), shortcut: "⌃⌥⌘ = / -")
                ShortcutRow(title: tr("区域截图", "Region screenshot"), shortcut: isMacReplacement ? "⇧⌘4" : "⌃⌥⌘4")
                ShortcutRow(title: tr("全屏截图", "Full screenshot"), shortcut: isMacReplacement ? "⇧⌘3" : tr("截图按钮", "Toolbar button"))
                ShortcutRow(title: tr("录屏入口 / 停止录制", "Start / stop recording"), shortcut: isMacReplacement ? "⇧⌘5" : "⌃⌥⌘R")
                ShortcutRow(title: tr("画笔/高亮/直线/箭头", "Pen / highlight / line / arrow"), shortcut: "⌃⌥⌘ P/H/L/A")
                ShortcutRow(title: tr("方框/圆框", "Rectangle / ellipse"), shortcut: "⌃⌥⌘ B/O")
                ShortcutRow(title: tr("撤销一笔/清除全部", "Undo / clear annotations"), shortcut: "⌃⌥⌘ U/X")
                ShortcutRow(title: tr("摄像头开关/切换形状", "Toggle camera / shape"), shortcut: "⌃⌥⌘ C/S")
            } header: {
                SettingsSectionHeader(tr("全部快捷键", "All shortcuts"), systemImage: "list.bullet")
            }
        }
        .formStyle(.grouped)
    }

    private var isMacReplacement: Bool {
        appState.preferences.captureShortcutPreset == .macReplacement
    }

    private var zoomMouseButtonFootnote: String {
        guard appState.preferences.zoomMouseButton != .off else {
            return tr(
                "鼠标放大已关闭，录制时仍可用顶部栏的「鼠标放大」按钮。",
                "Mouse zoom is off; the floating bar's zoom button still works while recording."
            )
        }
        let button = appState.preferences.zoomMouseButton.displayName
        let base = tr(
            "录制时单击\(button)放大光标所在区域，再次单击还原；放大的区域与导出成片一致，点击照常传给当前应用。",
            "While recording, click the \(button.lowercased()) to magnify the area under the cursor and click again to restore. The magnified region matches the exported video, and the click still reaches the app underneath."
        )
        return appState.preferences.zoomMouseButton == .left
            ? base + tr("注意：左键会让每次点击都切换缩放，建议改用鼠标中键。", " Note: with the left button every click toggles the zoom — the middle button is a safer choice.")
            : base
    }
}

// MARK: - 截图 / Screenshot

private struct ScreenshotSettingsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle(tr("截图时冻结画面", "Freeze the screen when capturing"), isOn: $appState.preferences.screenshotFreezesScreen)
            } header: {
                SettingsSectionHeader(tr("取景", "Framing"), systemImage: "viewfinder")
            } footer: {
                SettingsFootnote(
                    appState.preferences.screenshotFreezesScreen
                        ? tr(
                            "按下截图快捷键的瞬间先把整屏定格，之后在这张静止画面上框选——播放中的视频、动画和会自动消失的菜单都停住，截到的就是你按下那一刻看到的内容。",
                            "The whole screen is frozen the instant you press the shortcut, and you select on that still frame — playing video, animations and menus that would vanish all stay put, so you capture exactly what you saw."
                        )
                        : tr(
                            "已关闭：在实时画面上框选（与 macOS 原生截图一致），画面内容可能在框选期间继续变化。",
                            "Off: you select over the live screen, like the macOS original, so content can keep changing while you drag."
                        )
                )
            }

            Section {
                Toggle(tr("完成截图后自动复制到剪切板", "Copy to clipboard when finished"), isOn: $appState.preferences.screenshotAutoCopyOnFinish)
            } header: {
                SettingsSectionHeader(tr("完成后的处理", "After capture"), systemImage: "doc.on.clipboard")
            } footer: {
                SettingsFootnote(
                    tr(
                        "区域或全屏截图进入内联编辑后，点击「完成」会按此设置处理最终图片。",
                        "After annotating, the Done button follows this setting."
                    )
                )
            }

            Section {
                ShortcutRow(title: tr("标注", "Annotate"), shortcut: tr("画笔 高亮 直线 箭头", "Pen Highlight Line Arrow"))
                ShortcutRow(title: tr("形状", "Shapes"), shortcut: tr("方框 圆框", "Rectangle Ellipse"))
                ShortcutRow(title: tr("文字与隐私", "Text & privacy"), shortcut: tr("文字 马赛克", "Text Mosaic"))
            } header: {
                SettingsSectionHeader(tr("编辑器可用工具", "Editor tools"), systemImage: "pencil.tip.crop.circle")
            } footer: {
                SettingsFootnote(
                    tr(
                        "截图后在编辑器顶部工具栏选择，标注完成可复制或另存为 PNG。",
                        "Pick a tool from the editor toolbar; when you are done you can copy the result or save it as a PNG."
                    )
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 共用组件 / Shared building blocks

private struct SettingsSectionHeader: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        LabeledContent(title) {
            content()
        }
    }
}

private struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                Text("\(Int(value * 100))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

private struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CaptureReplacementStatusView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.captureShortcutNeedsInterception {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(tr("替换尚未生效：⇧⌘3/4/5 仍会触发 macOS 原生截图。", "Not active yet — ⇧⌘3/4/5 still trigger the macOS originals."))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)

                Text(
                    tr(
                        "需要「辅助功能」权限来拦截系统快捷键。授权后 macOS 通常要重启 App 才会真正接管。",
                        "Intercepting system shortcuts needs Accessibility access, and macOS usually only applies it after a relaunch."
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button {
                        appState.openAccessibilitySettings()
                    } label: {
                        Label(tr("打开辅助功能", "Open Accessibility"), systemImage: "figure.walk.motion")
                    }
                    Button {
                        appState.relaunchApp()
                    } label: {
                        Label(tr("重启简录", "Relaunch JianLu"), systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Label {
                Text(tr("替换已生效：⇧⌘3/4/5 由简录接管。", "Active — ⇧⌘3/4/5 are handled by JianLu."))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
            }
            .foregroundStyle(.green)
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let shortcut: String

    var body: some View {
        LabeledContent(title) {
            Text(shortcut)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
