import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            HStack(spacing: 0) {
                SidebarView()
                Divider()
                MainDashboardView()
            }
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
                appState.toggleCameraIntent()
            } label: {
                Label(appState.cameraEnabled ? "关闭摄像头" : "开启摄像头", systemImage: "video")
            }

            Button {
                appState.toggleRecordingIntent()
            } label: {
                Label(appState.isRecording ? "停止录制" : "开始录制", systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.isRecording ? .red : .accentColor)
        }
        .padding(20)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("客户方案讲解")
                .font(.largeTitle.weight(.semibold))
            Text("录屏、摄像头头像框、缩放重点、划线涂鸦和剪辑导出会在这里串成一个简单流程。")
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                FeatureCard(title: "屏幕录制", detail: "录制整屏或窗口，支持系统音和麦克风。", symbol: "display")
                FeatureCard(title: "摄像头头像框", detail: appState.cameraEnabled ? "默认圆形右下角，可拖动缩放。" : "当前关闭，可随时开启。", symbol: "person.crop.circle")
                FeatureCard(title: "缩放和标注", detail: "快捷键缩放、画笔、高亮、直线和箭头重点。", symbol: "pencil.and.outline")
                FeatureCard(title: "录后剪辑", detail: "裁头尾、分割删除片段、预览并导出。", symbol: "timeline.selection")
            }

            Spacer()
        }
        .padding(28)
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
