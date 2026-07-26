import JianLuCore
import SwiftUI

/// The camera bubble outline, shared by the live recording overlay and the settings
/// preview so both draw exactly what `CameraShapeVideoCompositor` masks on export.
///
/// The rect itself carries the aspect ratio: `NormalizedRect.cameraBubbleRect(in:shape:)`
/// hands a square box to 圆形/方形/圆角方形 and an aspect-following box to 椭圆, so one
/// ellipse path covers both round shapes.
struct CameraFrameClipShape: Shape {
    let shape: CameraFrameShape

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .circle, .ellipse:
            Path(ellipseIn: rect)
        case .square:
            Path(rect)
        case .roundedSquare:
            // Proportional radius so the live preview matches the export mask
            // (min side × 0.14) at any bubble size, instead of a fixed 18pt.
            Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.14)
        }
    }
}
