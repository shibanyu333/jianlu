import AppKit
import JianLuCore
import SwiftUI

/// A short-lived confirmation floating over whatever the user is looking at.
///
/// A capture session ends with 简录's own windows stashed and focus already handed back
/// to the app the user was really working in, so `statusMessage` in the main window is
/// invisible at exactly the moment it matters. Without this, pressing 保存 wrote a PNG
/// and looked like nothing at all — so the button got pressed again, and again.
@MainActor
final class CaptureToastWindowController {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    /// Bumped on every `show`, so a fade already in flight cannot close a newer toast.
    private var generation = 0

    private static let visibleDuration: TimeInterval = 2.6
    private static let fadeDuration: TimeInterval = 0.28
    private static let maxWidth: CGFloat = 420
    private static let topInset: CGFloat = 88

    /// - Parameter revealing: when set, clicking the toast shows the file in Finder.
    func show(title: String, detail: String? = nil, symbol: String = "checkmark.circle.fill", revealing url: URL? = nil) {
        generation &+= 1
        let token = generation
        dismissWorkItem?.cancel()

        let view = CaptureToastView(
            title: title,
            detail: detail,
            symbol: symbol,
            showsRevealHint: url != nil,
            onTap: { [weak self] in
                if let url {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame.size = hostingView.fittingSize
        let size = CGSize(
            width: min(Self.maxWidth, max(180, hostingView.fittingSize.width)),
            height: max(44, hostingView.fittingSize.height)
        )
        hostingView.frame.size = size

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hostingView
        panel.setFrame(CGRect(origin: origin(for: size), size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            self?.fadeOut(token: token)
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    func hide() {
        generation &+= 1
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let panel else { return }
        self.panel = nil
        panel.close()
    }

    private func fadeOut(token: Int) {
        guard token == generation, let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit runs this on the main thread, but the closure itself is nonisolated.
            MainActor.assumeIsolated {
                guard let self, token == self.generation else { return }
                self.hide()
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 48),
            // Non-activating: a confirmation must never pull focus away from the app the
            // capture session just handed it back to.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the capture overlay and the recording control bar, so it is readable
        // even when one of those is still on screen.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.title = tr("截图提示", "Capture toast")
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Never let the confirmation land inside the next recording or screenshot.
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Top-centre of the screen the pointer is on — where the eye already is after a
    /// click on the editor toolbar, and clear of the toolbar itself.
    private func origin(for size: CGSize) -> CGPoint {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 720)
        return CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - Self.topInset - size.height
        )
    }
}

private struct CaptureToastView: View {
    let title: String
    let detail: String?
    let symbol: String
    let showsRevealHint: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(radius: 14, y: 4)
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .help(showsRevealHint
            ? tr("点按在访达中显示", "Click to show in Finder")
            : title)
    }
}
