import CoreGraphics
import Foundation

public struct ZoomLensGeometry: Equatable, Sendable {
    public var lensSize: CGSize

    public init(lensSize: CGSize) {
        self.lensSize = lensSize
    }

    public static func lensDiameter(for captureSize: CGSize) -> CGFloat {
        let shortestSide = min(captureSize.width, captureSize.height)
        guard shortestSide.isFinite, shortestSide > 0 else { return 180 }
        return min(280, max(72, shortestSide - 16))
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

    public func clampedLensCenter(in captureRect: CGRect, focus: NormalizedPoint) -> CGPoint {
        let point = focusPoint(in: captureRect, focus: focus)
        let halfWidth = lensSize.width / 2
        let halfHeight = lensSize.height / 2

        if captureRect.width <= lensSize.width || captureRect.height <= lensSize.height {
            return point
        }

        return CGPoint(
            x: min(max(captureRect.minX + halfWidth, point.x), captureRect.maxX - halfWidth),
            y: min(max(captureRect.minY + halfHeight, point.y), captureRect.maxY - halfHeight)
        )
    }

    public func zoomedImageFrame(
        captureSize: CGSize,
        focus: NormalizedPoint,
        magnification: Double
    ) -> CGRect {
        let scale = max(1.2, CGFloat(magnification))
        let imageSize = CGSize(
            width: max(1, captureSize.width) * scale,
            height: max(1, captureSize.height) * scale
        )
        return CGRect(
            x: lensSize.width / 2 - focus.x * imageSize.width,
            y: lensSize.height / 2 - focus.y * imageSize.height,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    public func zoomedRegionImageFrame(
        captureSize: CGSize,
        focus: NormalizedPoint,
        magnification: Double
    ) -> CGRect {
        let scale = max(1.2, CGFloat(magnification))
        let baseWidth = max(1, captureSize.width)
        let baseHeight = max(1, captureSize.height)
        let imageSize = CGSize(
            width: baseWidth * scale,
            height: baseHeight * scale
        )
        return CGRect(
            x: (1 - scale) * CGFloat(focus.x) * baseWidth,
            y: (1 - scale) * CGFloat(focus.y) * baseHeight,
            width: imageSize.width,
            height: imageSize.height
        )
    }
}
