import CoreGraphics
import CoreText
import Foundation

public enum ScreenshotMarkupRenderer {
    /// - Parameter scale: points→pixels ratio between the editor view (where markup
    ///   metrics like line width and font size were authored, in points) and the
    ///   pixel-resolution `baseImage`. Pass `baseImage.width / editorPointWidth` so
    ///   strokes and text are not rendered half-size on Retina captures.
    public static func render(baseImage: CGImage, markups: [ScreenshotMarkup], scale: CGFloat = 1) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        guard width > 0, height > 0 else { return nil }
        guard let baseWithMosaic = imageByApplyingMosaics(to: baseImage, markups: markups) else {
            return nil
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let renderSize = CGSize(width: width, height: height)
        let markupScale = max(0.01, scale)
        let rect = CGRect(origin: .zero, size: renderSize)
        context.draw(baseWithMosaic, in: rect)

        for markup in markups {
            switch markup {
            case .stroke(let annotation):
                draw(annotation, in: context, renderSize: renderSize, scale: markupScale)
            case .text(let text):
                draw(text, in: context, renderSize: renderSize, scale: markupScale)
            case .mosaic:
                break
            }
        }

        return context.makeImage()
    }

    private static func imageByApplyingMosaics(to baseImage: CGImage, markups: [ScreenshotMarkup]) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        let mosaics = markups.compactMap { markup -> ScreenshotMosaicMarkup? in
            if case .mosaic(let mosaic) = markup { return mosaic }
            return nil
        }

        // Let CoreGraphics own the backing store instead of a Swift array whose
        // pointer must not escape `withUnsafeMutableBytes`; the previous `&bytes`
        // form let the context outlive the pointer's guaranteed lifetime (UB).
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard !mosaics.isEmpty else { return context.makeImage() }
        guard let data = context.data else { return context.makeImage() }

        let bytesPerRow = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        for mosaic in mosaics {
            apply(mosaic, to: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
        }
        return context.makeImage()
    }

    private static func apply(
        _ mosaic: ScreenshotMosaicMarkup,
        to pixels: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
        let rect = pixelRect(for: mosaic.rect, width: width, height: height)
        guard rect.width > 0, rect.height > 0 else { return }
        let blockSize = max(2, Int(mosaic.blockSize.rounded()))

        for blockY in stride(from: rect.minY, to: rect.maxY, by: blockSize) {
            for blockX in stride(from: rect.minX, to: rect.maxX, by: blockSize) {
                let maxY = min(rect.maxY, blockY + blockSize)
                let maxX = min(rect.maxX, blockX + blockSize)
                var red = 0
                var green = 0
                var blue = 0
                var alpha = 0
                var count = 0

                for y in blockY..<maxY {
                    for x in blockX..<maxX {
                        let offset = y * bytesPerRow + x * 4
                        red += Int(pixels[offset])
                        green += Int(pixels[offset + 1])
                        blue += Int(pixels[offset + 2])
                        alpha += Int(pixels[offset + 3])
                        count += 1
                    }
                }

                guard count > 0 else { continue }
                let averaged = (
                    r: UInt8(red / count),
                    g: UInt8(green / count),
                    b: UInt8(blue / count),
                    a: UInt8(alpha / count)
                )
                for y in blockY..<maxY {
                    for x in blockX..<maxX {
                        let offset = y * bytesPerRow + x * 4
                        pixels[offset] = averaged.r
                        pixels[offset + 1] = averaged.g
                        pixels[offset + 2] = averaged.b
                        pixels[offset + 3] = averaged.a
                    }
                }
            }
        }
    }

    private static func pixelRect(for rect: NormalizedRect, width: Int, height: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int) {
        let minX = min(max(0, rect.x), 1)
        let minY = min(max(0, rect.y), 1)
        let maxX = min(max(0, rect.x + rect.width), 1)
        let maxY = min(max(0, rect.y + rect.height), 1)
        let pixelMinX = min(width, max(0, Int((minX * Double(width)).rounded(.down))))
        let pixelMinY = min(height, max(0, Int((minY * Double(height)).rounded(.down))))
        let pixelMaxX = min(width, max(pixelMinX, Int((maxX * Double(width)).rounded(.up))))
        let pixelMaxY = min(height, max(pixelMinY, Int((maxY * Double(height)).rounded(.up))))
        return (
            minX: pixelMinX,
            minY: pixelMinY,
            maxX: pixelMaxX,
            maxY: pixelMaxY,
            width: max(0, pixelMaxX - pixelMinX),
            height: max(0, pixelMaxY - pixelMinY)
        )
    }

    private static func draw(_ annotation: AnnotationEvent, in context: CGContext, renderSize: CGSize, scale: CGFloat) {
        let points = annotation.points.map {
            CGPoint(
                x: CGFloat($0.point.x) * renderSize.width,
                y: (1 - CGFloat($0.point.y)) * renderSize.height
            )
        }
        guard let first = points.first else { return }

        let path = CGMutablePath()
        path.move(to: first)

        switch annotation.tool {
        case .rectangle, .ellipse:
            guard let last = points.last else { return }
            let rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            if annotation.tool == .ellipse {
                path.addEllipse(in: rect)
            } else {
                let corner = AnnotationStyle.rectangleCornerRadius * scale
                path.addRoundedRect(in: rect, cornerWidth: corner, cornerHeight: corner)
            }
        case .line, .arrow:
            guard let last = points.last else { return }
            path.addLine(to: last)
            if annotation.tool == .arrow {
                addArrowHead(to: path, from: points.dropLast().last ?? first, to: last, scale: scale)
            }
        case .pen, .highlight:
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }

        context.setStrokeColor(AnnotationStyle.cgColor(hex: annotation.colorHex, tool: annotation.tool))
        context.setLineWidth(AnnotationStyle.lineWidth(for: annotation.tool, stored: annotation.lineWidth) * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    private static func draw(_ text: ScreenshotTextMarkup, in context: CGContext, renderSize: CGSize, scale: CGFloat) {
        let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let fontSize = CGFloat(max(8, text.fontSize)) * scale
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let rgba = AnnotationStyle.rgba(hex: text.colorHex, tool: .pen)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: trimmed, attributes: attributes))
        let x = CGFloat(min(max(0, text.anchor.x), 1)) * renderSize.width
        let topY = CGFloat(min(max(0, text.anchor.y), 1)) * renderSize.height
        // The live editor anchors text by its top-left. Place the baseline one ascent
        // below that top edge (not one full font size) so the glyphs land where the
        // presenter positioned them.
        let ascent = CTFontGetAscent(font)
        let baselineY = max(0, renderSize.height - topY - ascent)

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: baselineY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func addArrowHead(to path: CGMutablePath, from start: CGPoint, to end: CGPoint, scale: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = AnnotationStyle.arrowHeadLength * scale
        let spread: CGFloat = .pi / 7
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
    }
}
