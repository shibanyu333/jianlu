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

    // MARK: - Capture sessions

    /// The app that was frontmost when the current capture session started. A capture
    /// panel has to activate 简录 to receive key events, and the moment that panel goes
    /// away AppKit picks the next active app on its own — often 简录 itself, which
    /// throws the main window in front of whatever the user was actually doing.
    /// Remembering where the focus came from lets us hand it straight back.
    private static var appBeforeCaptureSession: NSRunningApplication?
    private static var windowsStashedForCaptureSession: [NSWindow] = []
    private static var isCaptureSessionActive = false

    /// Call while 简录 is still in the background, before the capture panel activates
    /// it, so the app we remember is the one the user was really working in.
    static func beginCaptureSession() {
        guard !isCaptureSessionActive else { return }
        isCaptureSessionActive = true
        let frontmost = NSWorkspace.shared.frontmostApplication
        // Started from 简录's own window: there is nothing to hand focus back to.
        appBeforeCaptureSession = frontmost?.processIdentifier == getpid() ? nil : frontmost
        // Handing focus back is not enough on its own: the click that finishes a
        // screenshot is still being processed when we ask, and AppKit can re-activate
        // 简录 on its way out. So take our ordinary windows off screen for the length
        // of the session — an activation 简录 wins then has nothing to surface. The
        // full-screen capture panel is covering them anyway.
        windowsStashedForCaptureSession = NSApp.windows.filter(isStashableDuringCapture)
        for window in windowsStashedForCaptureSession {
            window.orderOut(nil)
        }
        let name = appBeforeCaptureSession?.localizedName ?? "JianLu"
        logger.info("Capture session began; focus came from \(name, privacy: .public), windows stashed: \(windowsStashedForCaptureSession.count)")
    }

    /// Call *before* the capture panel is ordered out, so AppKit never gets to choose a
    /// next active app by itself. `showingMainWindow` is for failures only, where the
    /// user has an error message waiting in the window.
    static func endCaptureSession(showingMainWindow: Bool = false) {
        guard isCaptureSessionActive else { return }
        isCaptureSessionActive = false
        let previousApp = appBeforeCaptureSession
        let stashedWindows = windowsStashedForCaptureSession
        appBeforeCaptureSession = nil
        windowsStashedForCaptureSession = []

        guard !showingMainWindow, let previousApp, !previousApp.isTerminated else {
            // Either the screenshot failed and its error needs reading, or it was
            // started from 简录 itself — both want the window back where it was.
            for window in stashedWindows {
                window.makeKeyAndOrderFront(nil)
            }
            if showingMainWindow {
                restoreMainWindows()
            }
            return
        }

        logger.info("Capture session ended; handing focus back")
        previousApp.activate()
        // Ask once more after the finishing click has been fully processed, then put
        // our windows back at the very bottom of the stack — visible again where they
        // were, never in front of the app the user actually went back to.
        DispatchQueue.main.async {
            if NSApp.isActive, !previousApp.isTerminated {
                previousApp.activate()
            }
            for window in stashedWindows {
                window.order(.below, relativeTo: 0)
            }
        }
    }

    /// The plain app windows a capture session hides: the main window, the fallback
    /// window and the settings window. Panels (the capture overlay, the recording
    /// control bar) run the capture itself and must stay.
    private static func isStashableDuringCapture(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel), window.canBecomeMain else { return false }
        return window.isVisible && !window.isMiniaturized
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
