import AppKit
import JianLuCore

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private weak var appState: AppState?
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "简录")
        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let recordingTitle = appState?.isRecording == true ? tr("停止录制", "Stop recording") : tr("选择区域", "Select area")
        menu.addItem(NSMenuItem(title: recordingTitle, action: #selector(toggleRecording), keyEquivalent: ""))

        let pauseTitle = appState?.isPaused == true ? tr("继续录制", "Resume") : tr("暂停录制", "Pause")
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
        pauseItem.isEnabled = appState?.isRecording == true
        menu.addItem(pauseItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("显示主窗口", "Show main window"), action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: tr("打开保存目录", "Open recordings folder"), action: #selector(openRecordingDirectory), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("退出简录", "Quit JianLu"), action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }
    }

    @objc private func toggleRecording() {
        appState?.toggleRecordingIntent()
    }

    @objc private func togglePause() {
        appState?.togglePauseIntent()
    }

    @objc private func showMainWindow() {
        AppWindowUtility.restoreOrCreateMainWindow()
    }

    @objc private func openRecordingDirectory() {
        appState?.openRecordingDirectory()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
