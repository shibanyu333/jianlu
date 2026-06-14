import CoreGraphics
import Foundation

public enum AnnotationImageRenderer {
    public static func render(baseImage: CGImage, annotations: [AnnotationEvent]) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        guard width > 0, height > 0,
              let context = CGContext(
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
        context.draw(baseImage, in: rect)
        for annotation in annotations {
            draw(annotation, in: context, renderSize: renderSize)
        }
        return context.makeImage()
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

        context.setStrokeColor(annotationColor(for: annotation))
        context.setLineWidth(CGFloat(annotation.lineWidth))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
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

    private static func annotationColor(for annotation: AnnotationEvent) -> CGColor {
        let trimmed = annotation.colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&value) else {
            return defaultAnnotationColor(for: annotation.tool)
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
            alpha = annotation.tool == .highlight ? 0.55 : 1
        case 8:
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            let parsedAlpha = CGFloat(value & 0xFF) / 255
            alpha = annotation.tool == .highlight ? min(parsedAlpha, 0.55) : parsedAlpha
        default:
            return defaultAnnotationColor(for: annotation.tool)
        }

        return CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func defaultAnnotationColor(for tool: AnnotationTool) -> CGColor {
        switch tool {
        case .highlight:
            CGColor(red: 1.0, green: 0.83, blue: 0.23, alpha: 0.55)
        case .pen, .line, .arrow, .rectangle, .ellipse:
            CGColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1)
        }
    }
}
