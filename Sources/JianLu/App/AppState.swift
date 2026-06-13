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
    let overlayService = OverlayService()
    private let hotkeyService = HotkeyService()

    private var activeScreenRecordingURL: URL?
    private var activeCameraRecordingURL: URL?
    private var recordingStartedAt: Date?

    init() {
        hotkeyService.start { [weak self] action in
            self?.handleHotkey(action)
        }
    }

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
        if isRecording {
            overlayService.toggleCameraVisibility()
        }
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

            overlayService.beginRecording(
                cameraSession: cameraCaptureService.previewSession,
                cameraEnabled: cameraEnabled
            )
            activeScreenRecordingURL = try await captureService.startDisplayRecording()
            recordingStartedAt = Date()
            isRecording = true
            lastErrorMessage = nil
            statusMessage = "录制中：缩放、标注和摄像头头像框会写入成片"
        } catch {
            if cameraCaptureService.isRecording {
                try? cameraCaptureService.stopRecording()
            }
            overlayService.endRecording()
            activeScreenRecordingURL = nil
            activeCameraRecordingURL = nil
            recordingStartedAt = nil
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
                    events: overlayService.events,
                    timeline: .fullLength(duration: duration)
                )
                recentProjects.insert(project, at: 0)
            }

            activeScreenRecordingURL = nil
            activeCameraRecordingURL = nil
            recordingStartedAt = nil
            overlayService.endRecording()
            isRecording = false
            statusMessage = "录制已停止，可以进入剪辑和导出"
        } catch {
            lastErrorMessage = error.localizedDescription
            statusMessage = "停止录制失败：\(error.localizedDescription)"
        }
    }

    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .toggleZoom:
            overlayService.toggleZoom()
            statusMessage = "已切换缩放效果"
        case .zoomIn:
            overlayService.adjustZoom(by: 0.2)
            statusMessage = "缩放倍率 \(String(format: "%.1f", overlayService.zoomMagnification))x"
        case .zoomOut:
            overlayService.adjustZoom(by: -0.2)
            statusMessage = "缩放倍率 \(String(format: "%.1f", overlayService.zoomMagnification))x"
        case .selectTool(let tool):
            overlayService.selectTool(tool)
            statusMessage = "标注工具：\(tool.displayName)"
        case .undo:
            overlayService.undoLastAnnotation()
            statusMessage = "已撤销上一笔标注"
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
}
