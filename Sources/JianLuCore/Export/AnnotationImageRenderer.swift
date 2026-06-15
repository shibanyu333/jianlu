import CoreGraphics
import Foundation

public enum AnnotationImageRenderer {
    public static func render(baseImage: CGImage, annotations: [AnnotationEvent]) -> CGImage? {
        ScreenshotMarkupRenderer.render(
            baseImage: baseImage,
            markups: annotations.map { .stroke($0) }
        )
    }
}
