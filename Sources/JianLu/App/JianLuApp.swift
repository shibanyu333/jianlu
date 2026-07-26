import AppKit
import JianLuCore
import SwiftUI

@main
struct JianLuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu(tr("录制", "Capture")) {
                Button(tr("区域截图", "Region screenshot")) {
                    appState.takeScreenshotIntent()
                }
                .keyboardShortcut("4", modifiers: [.control, .option, .command])

                Button(tr("选择区域/开始/停止录制", "Select area / start / stop recording")) {
                    appState.toggleRecordingIntent()
                }
                .keyboardShortcut("r", modifiers: [.control, .option, .command])

                Button(tr("暂停/继续录制", "Pause / resume recording")) {
                    appState.togglePauseIntent()
                }
                .disabled(!appState.isRecording)

                Button(tr("摄像头开关", "Toggle camera")) {
                    appState.toggleCameraIntent()
                }
                .keyboardShortcut("c", modifiers: [.control, .option, .command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            AppWindowUtility.restoreOrCreateMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindowUtility.restoreOrCreateMainWindow()
        return false
    }
}
