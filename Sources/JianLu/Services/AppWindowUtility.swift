import AppKit

@MainActor
enum AppWindowUtility {
    static func minimizeMainWindows() {
        for window in NSApp.windows where isMainAppWindow(window) && window.isVisible {
            window.miniaturize(nil)
        }
    }

    static func restoreMainWindows() {
        for window in NSApp.windows where isMainAppWindow(window) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func isMainAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.canBecomeKey
    }
}
