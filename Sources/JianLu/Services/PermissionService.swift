import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import JianLuCore

struct PermissionSnapshot {
    var screenRecordingGranted: Bool
    var cameraGranted: Bool
    var microphoneGranted: Bool
    var shortcutMonitoringGranted: Bool

    var missingDescriptions: [String] {
        var missing: [String] = []
        if !screenRecordingGranted { missing.append("屏幕录制") }
        if !cameraGranted { missing.append("摄像头") }
        if !microphoneGranted { missing.append("麦克风") }
        if !shortcutMonitoringGranted { missing.append("快捷键监听") }
        return missing
    }

    var recordingState: RecordingPermissionState {
        RecordingPermissionState(
            screenRecordingGranted: screenRecordingGranted,
            cameraGranted: cameraGranted,
            microphoneGranted: microphoneGranted
        )
    }
}

enum PermissionService {
    static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            cameraGranted: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            shortcutMonitoringGranted: AXIsProcessTrusted()
        )
    }

    static func requestMediaAccess(cameraEnabled: Bool = true, microphoneEnabled: Bool = true) async -> PermissionSnapshot {
        if cameraEnabled && AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if microphoneEnabled && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return snapshot()
    }

    static func requestScreenRecordingAccess() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    static func requestShortcutMonitoringAccess() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    static func openShortcutMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
