import CoreGraphics
import Foundation

public struct ZoomLensGeometry: Equatable, Sendable {
    public var lensSize: CGSize

    public init(lensSize: CGSize) {
        self.lensSize = lensSize
    }

    public static func normalizedFocus(
        mouseLocation: CGPoint,
        screenFrame: CGRect,
        recordingRegion: RecordingRegion?
    ) -> NormalizedPoint {
        let capture = recordingRegion?.isUsable == true
            ? CGRect(
                x: recordingRegion?.x ?? 0,
                y: recordingRegion?.y ?? 0,
                width: recordingRegion?.width ?? screenFrame.width,
                height: recordingRegion?.height ?? screenFrame.height
            )
            : CGRect(origin: .zero, size: screenFrame.size)

        let xInScreen = mouseLocation.x - screenFrame.minX
        let yFromTop = screenFrame.maxY - mouseLocation.y
        return NormalizedPoint(
            x: min(max(0, (xInScreen - capture.minX) / max(1, capture.width)), 1),
            y: min(max(0, (yFromTop - capture.minY) / max(1, capture.height)), 1)
        )
    }

    public func focusPoint(in captureRect: CGRect, focus: NormalizedPoint) -> CGPoint {
        CGPoint(
            x: captureRect.minX + focus.x * captureRect.width,
            y: captureRect.minY + focus.y * captureRect.height
        )
    }

    /// Where the live overlay must draw the full captured frame so the magnified
    /// picture matches the exported video pixel for pixel.
    ///
    /// The frame is derived from the very same transform the export compositor
    /// applies (`ExportZoomTimeline.transform`), just in the overlay's y-down space,
    /// so "what the presenter sees magnified" and "what the finished video shows"
    /// can never drift apart.
    public func zoomedRegionImageFrame(
        captureSize: CGSize,
        focus: NormalizedPoint,
        magnification: Double
    ) -> CGRect {
        let baseRect = CGRect(
            x: 0,
            y: 0,
            width: max(1, captureSize.width),
            height: max(1, captureSize.height)
        )
        let effect = ExportZoomEffect(
            depth: max(1, magnification),
            focusX: focus.x,
            focusY: focus.y
        )
        return baseRect.applying(ExportZoomTimeline.transform(for: effect, in: baseRect))
    }
}
