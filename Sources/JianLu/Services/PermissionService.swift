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
        if !screenRecordingGranted { missing.append(tr("屏幕录制", "Screen Recording")) }
        if !cameraGranted { missing.append(tr("摄像头", "Camera")) }
        if !microphoneGranted { missing.append(tr("麦克风", "Microphone")) }
        if !shortcutMonitoringGranted {
            var shortcutParts: [String] = []
            if !shortcutAccessibilityGranted { shortcutParts.append(tr("辅助功能", "Accessibility")) }
            if !shortcutInputMonitoringGranted { shortcutParts.append(tr("输入监控", "Input Monitoring")) }
            missing.append("快捷键监听\(shortcutParts.isEmpty ? "" : "（\(shortcutParts.joined(separator: "、"))）")")
        }
        return missing
    }

    var shortcutRecoveryMessage: String {
        switch (shortcutAccessibilityGranted, shortcutInputMonitoringGranted) {
        case (true, true):
            "快捷键权限已就绪。"
        case (true, false):
            "辅助功能已开启，还缺“输入监控”。如果输入监控列表没有“简录”，请点“+”添加当前 App：\(Bundle.main.bundleURL.path)，然后重新打开 App。"
        case (false, true):
            "输入监控已开启，还缺“辅助功能”。若系统设置里已打开开关，请删除旧“简录”条目后重新添加当前 App。"
        case (false, false):
            "还缺“辅助功能”和“输入监控”。若开关已打开仍提示缺失，请删除旧“简录”条目；输入监控列表为空时点“+”添加当前 App。"
        }
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

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
