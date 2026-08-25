import CoreGraphics
import Foundation

/// Which grip of a selected markup a drag is holding.
public enum ScreenshotMarkupHandle: Hashable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    /// First point of a line/arrow.
    case start
    /// Last point of a line/arrow — the end an arrow head sits on.
    case end
}

/// Moving and resizing markup that has already been placed. Kept in the core, in
/// normalized screenshot coordinates, so the screenshot editor never has to reimplement
/// (or drift from) the maths that decides where a markup ends up.
public extension ScreenshotMarkup {
    /// Smallest normalized side a shape can be dragged down to.
    static let minimumNormalizedSize = 0.004

    /// Moves the markup by a normalized translation, clamped so it stays on the image.
    func moved(by translation: CGSize) -> ScreenshotMarkup {
        switch self {
        case .stroke(var annotation):
            let xs = annotation.points.map(\.point.x)
            let ys = annotation.points.map(\.point.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
                return self
            }
            // Clamp the whole shape, not each point, so it slides along the edge
            // instead of collapsing against it.
            let dx = min(max(Double(translation.width), -minX), 1 - maxX)
            let dy = min(max(Double(translation.height), -minY), 1 - maxY)
            annotation.points = annotation.points.map {
                StrokePoint(time: $0.time, point: NormalizedPoint(x: $0.point.x + dx, y: $0.point.y + dy))
            }
            return .stroke(annotation)
        case .text(var text):
            text.anchor = NormalizedPoint(
                x: Self.clamp01(text.anchor.x + Double(translation.width)),
                y: Self.clamp01(text.anchor.y + Double(translation.height))
            )
            return .text(text)
        case .mosaic(var mosaic):
            let dx = min(max(Double(translation.width), -mosaic.rect.x), 1 - mosaic.rect.x - mosaic.rect.width)
            let dy = min(max(Double(translation.height), -mosaic.rect.y), 1 - mosaic.rect.y - mosaic.rect.height)
            mosaic.rect.x += dx
            mosaic.rect.y += dy
            return .mosaic(mosaic)
        }
    }

    /// Drags one grip to `point`. Freehand strokes and text come back unchanged —
    /// they have no grips and can only be moved.
    func resized(handle: ScreenshotMarkupHandle, to point: NormalizedPoint) -> ScreenshotMarkup {
        switch self {
        case .stroke(var annotation):
            switch annotation.tool {
            case .rectangle, .ellipse:
                guard let first = annotation.points.first?.point, let last = annotation.points.last?.point else {
                    return self
                }
                let rect = Self.resizedCorners(
                    minX: min(first.x, last.x),
                    minY: min(first.y, last.y),
                    maxX: max(first.x, last.x),
                    maxY: max(first.y, last.y),
                    handle: handle,
                    to: point
                )
                annotation.points = [
                    StrokePoint(time: 0, point: NormalizedPoint(x: rect.x, y: rect.y)),
                    StrokePoint(time: 0, point: NormalizedPoint(x: rect.x + rect.width, y: rect.y + rect.height))
                ]
                return .stroke(annotation)
            case .line, .arrow:
                guard annotation.points.count >= 2 else { return self }
                let clamped = NormalizedPoint(x: Self.clamp01(point.x), y: Self.clamp01(point.y))
                switch handle {
                case .start:
                    annotation.points[0] = StrokePoint(time: annotation.points[0].time, point: clamped)
                case .end:
                    let index = annotation.points.count - 1
                    annotation.points[index] = StrokePoint(time: annotation.points[index].time, point: clamped)
                case .topLeft, .topRight, .bottomLeft, .bottomRight:
                    return self
                }
                return .stroke(annotation)
            case .pen, .highlight:
                return self
            }
        case .text:
            return self
        case .mosaic(var mosaic):
            mosaic.rect = Self.resizedCorners(
                minX: mosaic.rect.x,
                minY: mosaic.rect.y,
                maxX: mosaic.rect.x + mosaic.rect.width,
                maxY: mosaic.rect.y + mosaic.rect.height,
                handle: handle,
                to: point
            )
            return .mosaic(mosaic)
        }
    }

    private static func resizedCorners(
        minX: Double,
        minY: Double,
        maxX: Double,
        maxY: Double,
        handle: ScreenshotMarkupHandle,
        to point: NormalizedPoint
    ) -> NormalizedRect {
        var left = minX
        var top = minY
        var right = maxX
        var bottom = maxY
        let x = clamp01(point.x)
        let y = clamp01(point.y)

        switch handle {
        case .topLeft:
            left = x
            top = y
        case .topRight:
            right = x
            top = y
        case .bottomLeft:
            left = x
            bottom = y
        case .bottomRight:
            right = x
            bottom = y
        case .start, .end:
            break
        }

        // Dragging a grip past the opposite side flips the box instead of inverting it.
        return NormalizedRect(
            x: min(left, right),
            y: min(top, bottom),
            width: max(minimumNormalizedSize, abs(right - left)),
            height: max(minimumNormalizedSize, abs(bottom - top))
        )
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(0, value), 1)
    }
}
