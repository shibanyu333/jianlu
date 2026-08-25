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

        // Recordings no longer pop the main window open, so this line is where the
        // "recording stopped" result actually reaches the user.
        if let status = currentStatusLine {
            let statusLineItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            statusLineItem.isEnabled = false
            menu.addItem(statusLineItem)
            menu.addItem(.separator())
        }

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

    /// The current status message, trimmed to one short line for the menu.
    private var currentStatusLine: String? {
        guard let message = appState?.statusMessage.split(separator: "\n").first.map(String.init) else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 42 ? String(trimmed.prefix(42)) + "…" : trimmed
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
