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
    var shortcutAccessibilityGranted: Bool
    var shortcutInputMonitoringGranted: Bool
    var shortcutMonitoringGranted: Bool

    var missingDescriptions: [String] {
        var missing: [String] = []
        if !screenRecordingGranted { missing.append("屏幕录制") }
        if !cameraGranted { missing.append("摄像头") }
        if !microphoneGranted { missing.append("麦克风") }
        if !shortcutMonitoringGranted {
            var shortcutParts: [String] = []
            if !shortcutAccessibilityGranted { shortcutParts.append("辅助功能") }
            if !shortcutInputMonitoringGranted { shortcutParts.append("输入监控") }
            missing.append("快捷键监听\(shortcutParts.isEmpty ? "" : "（\(shortcutParts.joined(separator: "、"))）")")
        }
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
        let accessibilityGranted = AXIsProcessTrusted()
        let inputMonitoringGranted = CGPreflightListenEventAccess()
        return PermissionSnapshot(
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            cameraGranted: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            shortcutAccessibilityGranted: accessibilityGranted,
            shortcutInputMonitoringGranted: inputMonitoringGranted,
            shortcutMonitoringGranted: accessibilityGranted && inputMonitoringGranted
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
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    static func openShortcutMonitoringSettings() {
        let anchor = CGPreflightListenEventAccess() ? "Privacy_Accessibility" : "Privacy_ListenEvent"
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
