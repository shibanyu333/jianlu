import AppKit
import SwiftUI

@MainActor
final class ScreenshotEditorWindowController {
    private var window: NSWindow?

    func show(
        image: CGImage,
        onSave: @escaping (CGImage) -> Void,
        onCopy: @escaping (CGImage) -> Void,
        onClose: @escaping () -> Void
    ) {
        hide()

        let closeHandler: () -> Void = { [weak self] in
            onClose()
            self?.hide()
        }
        let model = ScreenshotEditorModel(
            image: image,
            onSave: onSave,
            onCopy: onCopy,
            onClose: closeHandler
        )
        let window = ScreenshotEditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "截图标注"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 780, height: 520)
        window.onClose = closeHandler
        window.contentView = NSHostingView(rootView: ScreenshotEditorView(model: model))
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class ScreenshotEditorWindow: NSWindow {
    var onClose: (() -> Void)?
    private var isClosing = false

    override func close() {
        guard !isClosing else {
            super.close()
            return
        }

        isClosing = true
        onClose?()
        super.close()
        isClosing = false
    }
}
