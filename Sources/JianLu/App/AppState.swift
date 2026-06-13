import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var cameraEnabled = true
    @Published var statusMessage = "准备录制客户方案讲解"

    func toggleRecordingIntent() {
        isRecording.toggle()
        statusMessage = isRecording ? "录制中，快捷键和悬浮工具可用" : "录制已停止，准备进入剪辑"
    }

    func toggleCameraIntent() {
        cameraEnabled.toggle()
        statusMessage = cameraEnabled ? "摄像头头像框已开启" : "摄像头头像框已关闭"
    }
}
