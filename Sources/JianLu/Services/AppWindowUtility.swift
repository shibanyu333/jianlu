import AppKit
import os
import SwiftUI

@MainActor
enum AppWindowUtility {
    private static var fallbackMainWindowController: NSWindowController?
    private static let logger = Logger(subsystem: "com.local.JianLu", category: "Window")

    static func minimizeMainWindows() {
        for window in NSApp.windows where isMainAppWindow(window) && window.isVisible {
            window.miniaturize(nil)
        }
    }

    static func restoreOrCreateMainWindow() {
        logger.info("Restoring or creating main window")
        let hasVisibleMainWindow = restoreMainWindows()
        if hasVisibleMainWindow {
            logger.info("Existing main window restored; skipping fallback main window")
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        showFallbackMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    static func restoreMainWindows() -> Bool {
        for window in NSApp.windows where isMainAppWindow(window) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        let hasVisibleMainWindow = NSApp.windows.contains { window in
            isMainAppWindow(window) && window.isVisible
        }
        logger.info("Main window restore visible result: \(hasVisibleMainWindow)")
        return hasVisibleMainWindow
    }

    private static func isMainAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.canBecomeKey
    }

    private static func showFallbackMainWindow() {
        let controller = fallbackMainWindowController ?? makeFallbackMainWindowController()
        fallbackMainWindowController = controller
        controller.window?.makeKeyAndOrderFront(nil)
        logger.info("Fallback main window ordered front, visible: \(controller.window?.isVisible == true)")
    }

    private static func makeFallbackMainWindowController() -> NSWindowController {
        let hostingView = NSHostingView(
            rootView: ContentView()
            .environmentObject(AppState.shared)
            .frame(minWidth: 760, minHeight: 520)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "简录"
        window.minSize = NSSize(width: 760, height: 520)
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }
}
