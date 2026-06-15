import JianLuCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("录制") {
                Toggle("录入简录界面", isOn: $appState.preferences.includeAppInterface)
                Toggle("录入麦克风", isOn: $appState.preferences.microphoneEnabled)
                Toggle("麦克风降噪", isOn: $appState.preferences.microphoneNoiseReductionEnabled)
                    .disabled(!appState.preferences.microphoneEnabled)

                HStack {
                    Text("默认保存目录")
                    Spacer()
                    Text(appState.recordingDirectoryDisplayPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("更改...") {
                        appState.chooseRecordingDirectory()
                    }
                }
            }

            Section("截图") {
                Toggle("完成截图后自动复制到剪切板", isOn: $appState.preferences.screenshotAutoCopyOnFinish)
                Text("区域或全屏截图进入内联编辑后，点击“完成”会按此设置处理最终图片。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("摄像头") {
                Toggle("默认显示摄像头头像框", isOn: $appState.cameraEnabled)

                Picker("默认头像形状", selection: $appState.preferences.cameraShape) {
                    ForEach(CameraFrameShape.allCases, id: \.self) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("默认头像大小")
                    Slider(
                        value: cameraSizeBinding,
                        in: NormalizedRect.minCameraFrameSize...NormalizedRect.maxCameraFrameSize
                    )
                    Text("\(Int(appState.preferences.cameraFrame.width * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                Picker("头像框背景", selection: $appState.preferences.cameraBackgroundStyle) {
                    ForEach(CameraBackgroundStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                Picker("背景虚化", selection: $appState.preferences.cameraBackgroundBlur) {
                    ForEach(CameraBackgroundBlur.allCases, id: \.self) { blur in
                        Text(blur.displayName).tag(blur)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("轻度美颜")
                    Slider(value: $appState.preferences.cameraBeautyLevel, in: 0...1)
                    Text("\(Int(appState.preferences.cameraBeautyLevel * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section("快捷键") {
                Picker("按住缩放快捷键", selection: $appState.preferences.zoomShortcut) {
                    ForEach(ZoomShortcut.allCases, id: \.self) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                Picker("截图/录屏快捷键", selection: $appState.preferences.captureShortcutPreset) {
                    ForEach(CaptureShortcutPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                Text(appState.preferences.captureShortcutPreset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ShortcutRow(title: "鼠标放大模式", shortcut: "顶部栏按钮")
                ShortcutRow(title: "区域截图", shortcut: appState.preferences.captureShortcutPreset == .macReplacement ? "⇧⌘4" : "^ + ⌥ + ⌘ + 4")
                ShortcutRow(title: "全屏截图", shortcut: appState.preferences.captureShortcutPreset == .macReplacement ? "⇧⌘3" : "截图按钮")
                ShortcutRow(title: "录屏入口", shortcut: appState.preferences.captureShortcutPreset == .macReplacement ? "⇧⌘5" : "^ + ⌥ + ⌘ + R")
                ShortcutRow(title: "画笔/高亮/直线/箭头", shortcut: "^ + ⌥ + ⌘ + P/H/L/A")
                ShortcutRow(title: "方框/圆框", shortcut: "^ + ⌥ + ⌘ + B/O")
                ShortcutRow(title: "清除全部标注", shortcut: "^ + ⌥ + ⌘ + X")
                ShortcutRow(title: "停止录制", shortcut: "^ + ⌥ + ⌘ + R")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560, height: 500)
    }

    private var cameraSizeBinding: Binding<Double> {
        Binding(
            get: {
                appState.preferences.cameraFrame.width
            },
            set: { size in
                appState.updateDefaultCameraSize(size)
            }
        )
    }
}

private struct ShortcutRow: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
