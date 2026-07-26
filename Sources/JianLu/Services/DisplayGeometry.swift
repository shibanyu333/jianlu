import AppKit
@preconcurrency import ScreenCaptureKit

/// Point/pixel geometry of a captured display.
///
/// `SCDisplay.width`/`height` are in **points**, not pixels — a 1470×956 point Retina
/// screen whose panel is 2560×1664 still reports 1470×956. Passing them in as the
/// pixel size made every capture scale come out as 1.0, so screen recordings,
/// screenshots and the live-zoom fallback snapshot were all grabbed at 1× (half the
/// linear resolution on Retina, i.e. visibly soft footage). The real backing scale has
/// to come from `NSScreen.backingScaleFactor`.
///
/// `SCStreamConfiguration.sourceRect` stays in points; only `width`/`height` — the
/// output buffer size — are pixels.
@MainActor
enum DisplayGeometry {
    static func pointSize(for display: SCDisplay) -> CGSize {
        screen(for: display)?.frame.size ?? CGSize(width: display.width, height: display.height)
    }

    static func pixelSize(for display: SCDisplay) -> CGSize {
        let points = pointSize(for: display)
        let scale = max(1, screen(for: display)?.backingScaleFactor ?? 1)
        return CGSize(width: points.width * scale, height: points.height * scale)
    }

    private static func screen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 == display.displayID
        }
    }
}
