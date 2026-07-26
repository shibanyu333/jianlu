import CoreGraphics
import Foundation

/// Single source of truth for annotation colors and absolute stroke metrics so the
/// live SwiftUI overlay preview and the export renderers stay visually identical.
///
/// The absolute metrics below are authored in **points** (matching the live overlay
/// coordinate space). Export renderers draw into a pixel-resolution buffer, so they
/// must multiply these by the points→pixels scale for the current recording/region
/// before use — otherwise strokes and text come out half-size on Retina displays.
public enum AnnotationStyle {
    /// Highlighter opacity, applied identically live and on export.
    public static let highlightAlpha: CGFloat = 0.55
    /// Pen/shape stroke width in points.
    public static let penLineWidth: CGFloat = 5
    /// Highlighter stroke width in points.
    public static let highlightLineWidth: CGFloat = 18
    /// Arrow head leg length in points.
    public static let arrowHeadLength: CGFloat = 18
    /// Corner radius used by the rectangle tool, in points.
    public static let rectangleCornerRadius: CGFloat = 4
    /// Default text size in points.
    public static let defaultTextFontSize: CGFloat = 24

    public static let penColorHex = "#FF3B30"
    public static let highlightColorHex = "#FFD43B"

    public struct RGBA: Equatable, Sendable {
        public var red: CGFloat
        public var green: CGFloat
        public var blue: CGFloat
        public var alpha: CGFloat

        public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    /// Resolve a stored `colorHex` to concrete RGBA components, applying the
    /// highlighter opacity cap so both render paths agree exactly.
    public static func rgba(hex: String, tool: AnnotationTool) -> RGBA {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&value) else {
            return defaultRGBA(for: tool)
        }

        switch trimmed.count {
        case 6:
            return RGBA(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: tool == .highlight ? highlightAlpha : 1
            )
        case 8:
            let parsedAlpha = CGFloat(value & 0xFF) / 255
            return RGBA(
                red: CGFloat((value >> 24) & 0xFF) / 255,
                green: CGFloat((value >> 16) & 0xFF) / 255,
                blue: CGFloat((value >> 8) & 0xFF) / 255,
                alpha: tool == .highlight ? min(parsedAlpha, highlightAlpha) : parsedAlpha
            )
        default:
            return defaultRGBA(for: tool)
        }
    }

    public static func cgColor(hex: String, tool: AnnotationTool) -> CGColor {
        let rgba = rgba(hex: hex, tool: tool)
        return CGColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }

    public static func defaultRGBA(for tool: AnnotationTool) -> RGBA {
        switch tool {
        case .highlight:
            RGBA(red: 1.0, green: 0.83, blue: 0.23, alpha: highlightAlpha)
        case .pen, .line, .arrow, .rectangle, .ellipse:
            RGBA(red: 1.0, green: 0.23, blue: 0.19, alpha: 1)
        }
    }

    /// Line width in points for the given tool, matching the live overlay.
    public static func lineWidth(for tool: AnnotationTool, stored: Double) -> CGFloat {
        stored > 0 ? CGFloat(stored) : (tool == .highlight ? highlightLineWidth : penLineWidth)
    }
}
