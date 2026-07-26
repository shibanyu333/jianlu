import JianLuCore
import SwiftUI

extension Color {
    /// Build a SwiftUI color from a stored annotation hex using the same parsing and
    /// highlighter-opacity rule as the export renderers, so the live overlay preview
    /// and the exported video show identical annotation colors.
    init(annotationHex hex: String, tool: AnnotationTool) {
        let rgba = AnnotationStyle.rgba(hex: hex, tool: tool)
        self = Color(
            .sRGB,
            red: Double(rgba.red),
            green: Double(rgba.green),
            blue: Double(rgba.blue),
            opacity: Double(rgba.alpha)
        )
    }
}
