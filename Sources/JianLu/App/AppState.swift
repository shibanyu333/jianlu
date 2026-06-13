import Foundation
import JianLuCore

@MainActor
final class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var cameraEnabled = true
    @Published var statusMessage = "准备录制客户方案讲解"
    @Published var permissionSnapshot = PermissionService.snapshot()
    @Published var recentProjects: [RecordingProject] = []
    @Published var lastErrorMessage: String?

    let captureService = CaptureService()
    let cameraCaptureService = CameraCaptureService()

    private var activeScreenRecordingURL: URL?
    private var activeCameraRecordingURL: URL?
    private var recordingStartedAt: Date?
    private var pendingEvents: [EffectEvent] = [
        .cameraLayout(
            CameraLayoutEvent(
                time: 0,
                frame: .defaultCameraFrame,
                shape: .circle,
                isVisible: true
            )
        )
    ]

    func toggleRecordingIntent() {
        Task {
            if isRecording {
                await stopRecording()
            } else {
                await startRecording()
            }
        }
    }

    func toggleCameraIntent() {
        cameraEnabled.toggle()
        statusMessage = cameraEnabled ? "摄像头头像框已开启" : "摄像头头像框已关闭"
        pendingEvents.append(
            .cameraLayout(
                CameraLayoutEvent(
                    time: currentRecordingTime,
                    frame: .defaultCameraFrame,
                    shape: .circle,
                    isVisible: cameraEnabled
                )
            )
        )
    }

    func requestPermissions() {
        PermissionService.requestScreenRecordingAccess()
        Task {
            permissionSnapshot = await PermissionService.requestMediaAccess()
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

    private func startRecording() async {
        refreshPermissions()
        if !permissionSnapshot.screenRecordingGranted {
            PermissionService.requestScreenRecordingAccess()
        }

        do {
            if cameraEnabled {
                cameraCaptureService.startPreviewIfNeeded()
                activeCameraRecordingURL = try cameraCaptureService.startRecording()
            }

            activeScreenRecordingURL = try await captureService.startDisplayRecording()
            recordingStartedAt = Date()
            isRecording = true
            lastErrorMessage = nil
            statusMessage = "录制中：缩放、标注和摄像头头像框会写入成片"
        } catch {
            lastErrorMessage = error.localizedDescription
            statusMessage = "启动录制失败：\(error.localizedDescription)"
            isRecording = false
        }
    }

    private func stopRecording() async {
        do {
            try await captureService.stopDisplayRecording()
            if cameraCaptureService.isRecording {
                try cameraCaptureService.stopRecording()
            }

            if let screenURL = activeScreenRecordingURL {
                let duration = max(0.1, Date().timeIntervalSince(recordingStartedAt ?? Date()))
                let project = RecordingProject(
                    screenRecordingURL: screenURL,
                    cameraRecordingURL: activeCameraRecordingURL,
                    events: pendingEvents,
                    timeline: .fullLength(duration: duration)
                )
                recentProjects.insert(project, at: 0)
            }

            activeScreenRecordingURL = nil
            activeCameraRecordingURL = nil
            recordingStartedAt = nil
            pendingEvents = []
            isRecording = false
            statusMessage = "录制已停止，可以进入剪辑和导出"
        } catch {
            lastErrorMessage = error.localizedDescription
            statusMessage = "停止录制失败：\(error.localizedDescription)"
        }
    }

    private var currentRecordingTime: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }
}
