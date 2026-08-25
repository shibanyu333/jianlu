import AppKit
import CoreGraphics
import Foundation
import JianLuCore
import SwiftUI

struct ScreenshotMarkupHandleSpec: Identifiable {
    let handle: ScreenshotMarkupHandle
    let position: CGPoint

    var id: ScreenshotMarkupHandle { handle }
}

/// Geometry for the inline screenshot editor, shared by drawing, hit-testing and the
/// selection chrome so a markup is always grabbable exactly where it is painted.
/// Everything works in view points inside `imageRect` — the same space
/// `ScreenshotInlineMarkupLayer` draws in.
enum ScreenshotMarkupGeometry {
    /// How far from a markup's outline a click still counts as a hit.
    static let hitTolerance: CGFloat = 9
    static let handleRadius: CGFloat = 5
    /// Grips are easier to grab than the outline they sit on.
    static let handleHitRadius: CGFloat = 11

    // MARK: - Coordinate conversion

    static func viewPoint(_ point: NormalizedPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: imageRect.minX + CGFloat(point.x) * imageRect.width,
            y: imageRect.minY + CGFloat(point.y) * imageRect.height
        )
    }

    static func normalizedPoint(_ point: CGPoint, in imageRect: CGRect) -> NormalizedPoint {
        NormalizedPoint(
            x: min(max(0, (point.x - imageRect.minX) / max(1, imageRect.width)), 1),
            y: min(max(0, (point.y - imageRect.minY) / max(1, imageRect.height)), 1)
        )
    }

    static func normalizedTranslation(_ translation: CGSize, in imageRect: CGRect) -> CGSize {
        CGSize(
            width: translation.width / max(1, imageRect.width),
            height: translation.height / max(1, imageRect.height)
        )
    }

    static func viewRect(_ rect: NormalizedRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + CGFloat(rect.x) * imageRect.width,
            y: imageRect.minY + CGFloat(rect.y) * imageRect.height,
            width: CGFloat(rect.width) * imageRect.width,
            height: CGFloat(rect.height) * imageRect.height
        )
    }

    // MARK: - Paths

    /// The stroke's outline. The inline editor strokes this path and hit-tests
    /// against it, so what you see is what you can grab.
    static func path(for annotation: AnnotationEvent, in imageRect: CGRect) -> Path {
        let points = annotation.points.map { viewPoint($0.point, in: imageRect) }
        var path = Path()
        guard let first = points.first else { return path }

        switch annotation.tool {
        case .rectangle, .ellipse:
            guard let last = points.last else { return path }
            let rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            if annotation.tool == .ellipse {
                path.addEllipse(in: rect)
            } else {
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
            }
        case .line, .arrow:
            path.move(to: first)
            if let last = points.last {
                path.addLine(to: last)
            }
        case .pen, .highlight:
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        return path
    }

    // MARK: - Bounds and handles

    static func boundingRect(for markup: ScreenshotMarkup, in imageRect: CGRect) -> CGRect {
        switch markup {
        case .stroke(let annotation):
            let points = annotation.points.map { viewPoint($0.point, in: imageRect) }
            guard let first = points.first else { return .zero }
            let minX = points.reduce(first.x) { min($0, $1.x) }
            let maxX = points.reduce(first.x) { max($0, $1.x) }
            let minY = points.reduce(first.y) { min($0, $1.y) }
            let maxY = points.reduce(first.y) { max($0, $1.y) }
            let padding = CGFloat(annotation.lineWidth) / 2
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -padding, dy: -padding)
        case .text(let text):
            let origin = viewPoint(text.anchor, in: imageRect)
            return CGRect(origin: origin, size: textSize(for: text))
        case .mosaic(let mosaic):
            return viewRect(mosaic.rect, in: imageRect)
        }
    }

    /// The grips shown on a selected markup. Freehand strokes and text have none —
    /// they can be moved but not resized.
    static func handles(for markup: ScreenshotMarkup, in imageRect: CGRect) -> [ScreenshotMarkupHandleSpec] {
        switch markup {
        case .stroke(let annotation):
            let points = annotation.points.map { viewPoint($0.point, in: imageRect) }
            guard let first = points.first, let last = points.last else { return [] }
            switch annotation.tool {
            case .rectangle, .ellipse:
                let rect = CGRect(
                    x: min(first.x, last.x),
                    y: min(first.y, last.y),
                    width: abs(last.x - first.x),
                    height: abs(last.y - first.y)
                )
                return cornerHandles(of: rect)
            case .line, .arrow:
                return [
                    ScreenshotMarkupHandleSpec(handle: .start, position: first),
                    ScreenshotMarkupHandleSpec(handle: .end, position: last)
                ]
            case .pen, .highlight:
                return []
            }
        case .text:
            return []
        case .mosaic(let mosaic):
            return cornerHandles(of: viewRect(mosaic.rect, in: imageRect))
        }
    }

    static func handle(for markup: ScreenshotMarkup, at location: CGPoint, in imageRect: CGRect) -> ScreenshotMarkupHandle? {
        handles(for: markup, in: imageRect)
            .first { hypot($0.position.x - location.x, $0.position.y - location.y) <= handleHitRadius }?
            .handle
    }

    private static func cornerHandles(of rect: CGRect) -> [ScreenshotMarkupHandleSpec] {
        [
            ScreenshotMarkupHandleSpec(handle: .topLeft, position: CGPoint(x: rect.minX, y: rect.minY)),
            ScreenshotMarkupHandleSpec(handle: .topRight, position: CGPoint(x: rect.maxX, y: rect.minY)),
            ScreenshotMarkupHandleSpec(handle: .bottomLeft, position: CGPoint(x: rect.minX, y: rect.maxY)),
            ScreenshotMarkupHandleSpec(handle: .bottomRight, position: CGPoint(x: rect.maxX, y: rect.maxY))
        ]
    }

    // MARK: - Hit testing

    /// Strokes are grabbed by their outline; `includingInterior` also grabs closed
    /// shapes anywhere inside them, which is what select mode wants. While a drawing
    /// tool is active the interior stays free so a click inside an empty rectangle
    /// starts a new markup instead of dragging the old one away.
    static func hitTest(
        _ markup: ScreenshotMarkup,
        at location: CGPoint,
        in imageRect: CGRect,
        includingInterior: Bool = false
    ) -> Bool {
        switch markup {
        case .stroke(let annotation):
            let grabWidth = max(CGFloat(annotation.lineWidth), hitTolerance * 2)
            let shape = path(for: annotation, in: imageRect)
            let isClosedShape = annotation.tool == .rectangle || annotation.tool == .ellipse
            if includingInterior, isClosedShape, shape.contains(location) { return true }
            let outline = shape
                .strokedPath(StrokeStyle(lineWidth: grabWidth, lineCap: .round, lineJoin: .round))
            if outline.contains(location) { return true }
            guard annotation.tool == .arrow, annotation.points.count >= 2 else { return false }
            // The arrow head sticks out past the shaft's end cap.
            let end = viewPoint(annotation.points[annotation.points.count - 1].point, in: imageRect)
            return hypot(end.x - location.x, end.y - location.y) <= AnnotationStyle.arrowHeadLength
        case .text, .mosaic:
            return boundingRect(for: markup, in: imageRect)
                .insetBy(dx: -hitTolerance / 2, dy: -hitTolerance / 2)
                .contains(location)
        }
    }

    /// Matches the font `ScreenshotInlineMarkupLayer` draws text markup with.
    static func textSize(for text: ScreenshotTextMarkup) -> CGSize {
        let font = NSFont.systemFont(ofSize: CGFloat(text.fontSize), weight: .semibold)
        let measured = (text.text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: max(12, measured.width), height: max(CGFloat(text.fontSize), measured.height))
    }
}
