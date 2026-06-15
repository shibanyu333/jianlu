import CoreGraphics
import CoreText
import Foundation

public enum ScreenshotMarkupRenderer {
    public static func render(baseImage: CGImage, markups: [ScreenshotMarkup]) -> CGImage? {
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
        let rect = CGRect(origin: .zero, size: renderSize)
        context.draw(baseWithMosaic, in: rect)

        for markup in markups {
            switch markup {
            case .stroke(let annotation):
                draw(annotation, in: context, renderSize: renderSize)
            case .text(let text):
                draw(text, in: context, renderSize: renderSize)
            case .mosaic:
                break
            }
        }

        return context.makeImage()
    }

    private static func imageByApplyingMosaics(to baseImage: CGImage, markups: [ScreenshotMarkup]) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for markup in markups {
            if case .mosaic(let mosaic) = markup {
                apply(mosaic, to: &bytes, width: width, height: height)
            }
        }
        return context.makeImage()
    }

    private static func apply(_ mosaic: ScreenshotMosaicMarkup, to bytes: inout [UInt8], width: Int, height: Int) {
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
                        let offset = (y * width + x) * 4
                        red += Int(bytes[offset])
                        green += Int(bytes[offset + 1])
                        blue += Int(bytes[offset + 2])
                        alpha += Int(bytes[offset + 3])
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
                        let offset = (y * width + x) * 4
                        bytes[offset] = averaged.r
                        bytes[offset + 1] = averaged.g
                        bytes[offset + 2] = averaged.b
                        bytes[offset + 3] = averaged.a
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

    private static func draw(_ annotation: AnnotationEvent, in context: CGContext, renderSize: CGSize) {
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
                path.addRoundedRect(in: rect, cornerWidth: 4, cornerHeight: 4)
            }
        case .line, .arrow:
            guard let last = points.last else { return }
            path.addLine(to: last)
            if annotation.tool == .arrow {
                addArrowHead(to: path, from: points.dropLast().last ?? first, to: last)
            }
        case .pen, .highlight:
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }

        context.setStrokeColor(color(for: annotation.colorHex, tool: annotation.tool))
        context.setLineWidth(CGFloat(annotation.lineWidth))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    private static func draw(_ text: ScreenshotTextMarkup, in context: CGContext, renderSize: CGSize) {
        let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let fontSize = CGFloat(max(8, text.fontSize))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(for: text.colorHex, tool: .pen)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: trimmed, attributes: attributes))
        let x = CGFloat(min(max(0, text.anchor.x), 1)) * renderSize.width
        let topY = CGFloat(min(max(0, text.anchor.y), 1)) * renderSize.height
        let baselineY = max(0, renderSize.height - topY - fontSize)

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: baselineY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func addArrowHead(to path: CGMutablePath, from start: CGPoint, to end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length: CGFloat = 18
        let spread: CGFloat = .pi / 7
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
    }

    private static func color(for colorHex: String, tool: AnnotationTool) -> CGColor {
        let trimmed = colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&value) else {
            return defaultColor(for: tool)
        }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        switch trimmed.count {
        case 6:
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
            alpha = tool == .highlight ? 0.55 : 1
        case 8:
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            let parsedAlpha = CGFloat(value & 0xFF) / 255
            alpha = tool == .highlight ? min(parsedAlpha, 0.55) : parsedAlpha
        default:
            return defaultColor(for: tool)
        }

        return CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func defaultColor(for tool: AnnotationTool) -> CGColor {
        switch tool {
        case .highlight:
            CGColor(red: 1.0, green: 0.83, blue: 0.23, alpha: 0.55)
        case .pen, .line, .arrow, .rectangle, .ellipse:
            CGColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1)
        }
    }
}
