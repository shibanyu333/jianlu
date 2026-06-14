@preconcurrency import ScreenCaptureKit
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import JianLuCore
import UniformTypeIdentifiers

enum ScreenshotCaptureServiceError: LocalizedError {
    case noDisplay
    case failedToEncodePNG

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "没有找到可截图的显示器。"
        case .failedToEncodePNG:
            "无法写入截图 PNG 文件。"
        }
    }
}

@MainActor
final class ScreenshotCaptureService {
    func capture(region: RecordingRegion?, includeAppWindows: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.current
        guard let display = display(in: content, matching: region) else {
            throw ScreenshotCaptureServiceError.noDisplay
        }

        let excludedWindows = includeAppWindows ? [] : content.windows.filter { window in
            window.owningApplication?.processID == getpid()
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let configuration = SCStreamConfiguration()
        let sourceRect = sourceRect(for: region, display: display)
        if sourceRect != .zero {
            configuration.sourceRect = sourceRect
        }
        let outputSize = outputSize(for: region, display: display)
        configuration.width = max(20, Int(outputSize.width.rounded()))
        configuration.height = max(20, Int(outputSize.height.rounded()))
        configuration.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotCaptureServiceError.failedToEncodePNG
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotCaptureServiceError.failedToEncodePNG
        }
    }

    private func display(in content: SCShareableContent, matching region: RecordingRegion?) -> SCDisplay? {
        guard let region else {
            return content.displays.first
        }
        return content.displays.first { $0.displayID == region.displayID } ?? content.displays.first
    }

    private func sourceRect(for region: RecordingRegion?, display: SCDisplay) -> CGRect {
        guard let region else { return .zero }

        let displayPointSize = pointSize(for: display)
        let width = min(max(1, region.width), max(1, displayPointSize.width))
        let height = min(max(1, region.height), max(1, displayPointSize.height))
        let x = min(max(0, region.x), max(0, displayPointSize.width - width))
        let y = min(max(0, region.y), max(0, displayPointSize.height - height))
        return CGRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    private func outputSize(for region: RecordingRegion?, display: SCDisplay) -> CGSize {
        guard let region else {
            return CGSize(width: display.width, height: display.height)
        }

        let displayPointSize = pointSize(for: display)
        let sourceRect = sourceRect(for: region, display: display)
        let scaleX = Double(display.width) / max(1, displayPointSize.width)
        let scaleY = Double(display.height) / max(1, displayPointSize.height)
        return CGSize(
            width: min(max(1, sourceRect.width * scaleX), max(1, Double(display.width))),
            height: min(max(1, sourceRect.height * scaleY), max(1, Double(display.height)))
        )
    }

    private func pointSize(for display: SCDisplay) -> CGSize {
        let screen = NSScreen.screens.first { screen in
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 == display.displayID
        }
        return screen?.frame.size ?? CGSize(width: display.width, height: display.height)
    }
}
