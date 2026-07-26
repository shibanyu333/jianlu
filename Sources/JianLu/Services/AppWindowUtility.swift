import AppKit
import os
import SwiftUI

@MainActor
enum AppWindowUtility {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("com.local.JianLu.mainWindow")

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
        let windows = NSApp.windows.filter(isMainAppWindow)
        guard let window = primaryMainWindow(from: windows) else {
            logger.info("Main window restore visible result: false")
            return false
        }

        for extraWindow in windows where extraWindow !== window {
            extraWindow.orderOut(nil)
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let hasVisibleMainWindow = window.isVisible
        logger.info("Main window restore visible result: \(hasVisibleMainWindow)")
        return hasVisibleMainWindow
    }

    private static func isMainAppWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel), window.canBecomeKey else { return false }
        return window.identifier == mainWindowIdentifier || window.title == "简录"
    }

    private static func primaryMainWindow(from windows: [NSWindow]) -> NSWindow? {
        windows.first { !isFallbackMainWindow($0) && $0.isVisible && !$0.isMiniaturized }
            ?? windows.first { !isFallbackMainWindow($0) }
            ?? windows.first
    }

    private static func isFallbackMainWindow(_ window: NSWindow) -> Bool {
        fallbackMainWindowController?.window === window
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
            .frame(minWidth: 1000, minHeight: 700)
        )
        let window = NSWindow(
            // The window has to fit the capture header plus the library/editor split.
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "简录"
        window.identifier = mainWindowIdentifier
        window.minSize = NSSize(width: 1000, height: 700)
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }
}
