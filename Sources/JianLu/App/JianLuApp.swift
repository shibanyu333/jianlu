import AppKit
import SwiftUI

@main
struct JianLuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    init() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            AppWindowUtility.restoreOrCreateMainWindow()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("录制") {
                Button("选择区域/开始/停止录制") {
                    appState.toggleRecordingIntent()
                }
                .keyboardShortcut("r", modifiers: [.control, .option, .command])

                Button("暂停/继续录制") {
                    appState.togglePauseIntent()
                }
                .disabled(!appState.isRecording)

                Button("摄像头开关") {
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
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            AppWindowUtility.restoreOrCreateMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindowUtility.restoreOrCreateMainWindow()
        return false
    }
}
