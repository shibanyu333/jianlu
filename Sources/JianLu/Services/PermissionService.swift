import AVFoundation
import CoreGraphics
import Foundation

struct PermissionSnapshot {
    var screenRecordingGranted: Bool
    var cameraGranted: Bool
    var microphoneGranted: Bool

    var missingDescriptions: [String] {
        var missing: [String] = []
        if !screenRecordingGranted { missing.append("屏幕录制") }
        if !cameraGranted { missing.append("摄像头") }
        if !microphoneGranted { missing.append("麦克风") }
        return missing
    }
}

enum PermissionService {
    static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            cameraGranted: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        )
    }

    static func requestMediaAccess() async -> PermissionSnapshot {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return snapshot()
    }

    static func requestScreenRecordingAccess() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }
}
