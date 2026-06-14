import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
@preconcurrency import Vision

public final class CameraFrameProcessor: @unchecked Sendable {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var photoBackgroundCache: [CameraBackgroundStyle: CIImage] = [:]
    private lazy var segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    public init() {}

    public func makePreviewImage(from pixelBuffer: CVPixelBuffer, preferences: RecordingPreferences) -> CGImage? {
        let image = processedImage(from: pixelBuffer, preferences: preferences)
        return ciContext.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: colorSpace)
    }

    public func processedImage(from pixelBuffer: CVPixelBuffer, preferences: RecordingPreferences) -> CIImage {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = source.extent
        var image = source

        if preferences.cameraBackgroundStyle != .original || preferences.cameraBackgroundBlur != .off {
            if let mask = personMask(for: pixelBuffer, extent: extent) {
                let background = backgroundImage(for: source, extent: extent, preferences: preferences)
                image = source.applyingFilter(
                    "CIBlendWithMask",
                    parameters: [
                        kCIInputBackgroundImageKey: background,
                        "inputMaskImage": mask
                    ]
                )
            } else if preferences.cameraBackgroundStyle != .original {
                image = fallbackBlendedImage(for: source, extent: extent, preferences: preferences)
            } else if preferences.cameraBackgroundBlur != .off {
                image = source
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: preferences.cameraBackgroundBlur.radius])
                    .cropped(to: extent)
            }
        }

        return beautified(image.cropped(to: extent), preferences: preferences)
    }

    private func fallbackBlendedImage(for source: CIImage, extent: CGRect, preferences: RecordingPreferences) -> CIImage {
        let background = backgroundImage(for: source, extent: extent, preferences: preferences)
        let foregroundAlpha = source.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.78)
            ]
        )
        return foregroundAlpha
            .applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: background])
            .cropped(to: extent)
    }

    private func backgroundImage(for source: CIImage, extent: CGRect, preferences: RecordingPreferences) -> CIImage {
        switch preferences.cameraBackgroundStyle {
        case .original:
            let radius = preferences.cameraBackgroundBlur.radius
            guard radius > 0 else { return source }
            return source
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
        case .studioBlue:
            return gradient(
                top: CIColor(red: 0.08, green: 0.22, blue: 0.52),
                bottom: CIColor(red: 0.02, green: 0.08, blue: 0.20),
                extent: extent
            )
        case .softGray:
            return gradient(
                top: CIColor(red: 0.82, green: 0.84, blue: 0.87),
                bottom: CIColor(red: 0.53, green: 0.57, blue: 0.62),
                extent: extent
            )
        case .warmSunset:
            return gradient(
                top: CIColor(red: 0.93, green: 0.56, blue: 0.35),
                bottom: CIColor(red: 0.33, green: 0.16, blue: 0.30),
                extent: extent
            )
        case .mint:
            return gradient(
                top: CIColor(red: 0.55, green: 0.78, blue: 0.70),
                bottom: CIColor(red: 0.10, green: 0.29, blue: 0.26),
                extent: extent
            )
        case .graphite:
            return gradient(
                top: CIColor(red: 0.18, green: 0.19, blue: 0.22),
                bottom: CIColor(red: 0.04, green: 0.05, blue: 0.06),
                extent: extent
            )
        case .office, .bookshelf, .meetingRoom, .cityWindow, .lightStudio:
            if let photo = photoBackground(preferences.cameraBackgroundStyle, extent: extent, preferences: preferences) {
                return photo
            }
            return sceneBackground(preferences.cameraBackgroundStyle, extent: extent, preferences: preferences)
        }
    }

    private func photoBackground(_ style: CameraBackgroundStyle, extent: CGRect, preferences: RecordingPreferences) -> CIImage? {
        guard let image = cachedPhotoBackground(for: style) else { return nil }
        let scale = max(
            extent.width / max(1, image.extent.width),
            extent.height / max(1, image.extent.height)
        )
        let scaledWidth = image.extent.width * scale
        let scaledHeight = image.extent.height * scale
        var fitted = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(
                by: CGAffineTransform(
                    translationX: extent.midX - scaledWidth / 2,
                    y: extent.midY - scaledHeight / 2
                )
            )
            .cropped(to: extent)

        let blurRadius = preferences.cameraBackgroundBlur.radius * 0.16
        if blurRadius > 0 {
            fitted = fitted
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                .cropped(to: extent)
        }
        return fitted
    }

    private func cachedPhotoBackground(for style: CameraBackgroundStyle) -> CIImage? {
        if let cached = photoBackgroundCache[style] {
            return cached
        }
        guard let resourceName = photoResourceName(for: style),
              let url = photoResourceURL(named: resourceName),
              let image = CIImage(contentsOf: url, options: [.colorSpace: colorSpace]) else {
            return nil
        }
        photoBackgroundCache[style] = image
        return image
    }

    private func photoResourceURL(named resourceName: String) -> URL? {
        Bundle.module.url(
            forResource: resourceName,
            withExtension: "png",
            subdirectory: "CameraBackgrounds"
        ) ?? Bundle.module.url(forResource: resourceName, withExtension: "png")
    }

    private func photoResourceName(for style: CameraBackgroundStyle) -> String? {
        switch style {
        case .office:
            "office-photo"
        case .bookshelf:
            "bookshelf-photo"
        case .meetingRoom:
            "meeting-room-photo"
        case .cityWindow:
            "city-window-photo"
        case .lightStudio:
            "light-studio-photo"
        default:
            nil
        }
    }

    private func sceneBackground(_ style: CameraBackgroundStyle, extent: CGRect, preferences: RecordingPreferences) -> CIImage {
        let width = max(16, Int(extent.width.rounded(.up)))
        let height = max(16, Int(extent.height.rounded(.up)))
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return gradient(
                top: CIColor(red: 0.72, green: 0.74, blue: 0.78),
                bottom: CIColor(red: 0.40, green: 0.43, blue: 0.48),
                extent: extent
            )
        }

        let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        drawScene(style, in: canvas, context: context)

        guard let cgImage = context.makeImage() else {
            return CIImage(color: CIColor(red: 0.64, green: 0.66, blue: 0.70)).cropped(to: extent)
        }

        var image = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        let blurRadius = preferences.cameraBackgroundBlur.radius * 0.28
        if blurRadius > 0 {
            image = image
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                .cropped(to: extent)
        }
        return image
    }

    private func drawScene(_ style: CameraBackgroundStyle, in rect: CGRect, context: CGContext) {
        switch style {
        case .office:
            drawOfficeScene(in: rect, context: context)
        case .bookshelf:
            drawBookshelfScene(in: rect, context: context)
        case .meetingRoom:
            drawMeetingRoomScene(in: rect, context: context)
        case .cityWindow:
            drawCityWindowScene(in: rect, context: context)
        case .lightStudio:
            drawLightStudioScene(in: rect, context: context)
        default:
            context.setFillColor(cgColor(red: 0.65, green: 0.67, blue: 0.70))
            context.fill(rect)
        }
    }

    private func drawOfficeScene(in rect: CGRect, context: CGContext) {
        fill(rect, color: cgColor(red: 0.80, green: 0.82, blue: 0.78), context: context)
        fill(CGRect(x: rect.width * 0.05, y: rect.height * 0.44, width: rect.width * 0.28, height: rect.height * 0.42), color: cgColor(red: 0.84, green: 0.90, blue: 0.93), context: context)
        fill(CGRect(x: rect.width * 0.07, y: rect.height * 0.46, width: rect.width * 0.24, height: rect.height * 0.38), color: cgColor(red: 0.58, green: 0.70, blue: 0.78), context: context)
        fill(CGRect(x: rect.width * 0.60, y: rect.height * 0.48, width: rect.width * 0.30, height: rect.height * 0.22), color: cgColor(red: 0.68, green: 0.64, blue: 0.58), context: context)
        fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.24), color: cgColor(red: 0.45, green: 0.38, blue: 0.30), context: context)
        fill(CGRect(x: rect.width * 0.58, y: rect.height * 0.18, width: rect.width * 0.24, height: rect.height * 0.06), color: cgColor(red: 0.20, green: 0.23, blue: 0.24), context: context)
        fill(CGRect(x: rect.width * 0.82, y: rect.height * 0.22, width: rect.width * 0.05, height: rect.height * 0.18), color: cgColor(red: 0.12, green: 0.32, blue: 0.22), context: context)
    }

    private func drawBookshelfScene(in rect: CGRect, context: CGContext) {
        fill(rect, color: cgColor(red: 0.50, green: 0.42, blue: 0.33), context: context)
        for row in 0..<4 {
            let shelfY = rect.height * (0.18 + CGFloat(row) * 0.19)
            fill(CGRect(x: rect.width * 0.08, y: shelfY, width: rect.width * 0.84, height: rect.height * 0.035), color: cgColor(red: 0.26, green: 0.18, blue: 0.12), context: context)
            for column in 0..<10 {
                let bookX = rect.width * (0.10 + CGFloat(column) * 0.078)
                let bookHeight = rect.height * (0.10 + CGFloat((row + column) % 3) * 0.022)
                let palette = CGFloat((row * 3 + column) % 5)
                fill(
                    CGRect(x: bookX, y: shelfY + rect.height * 0.035, width: rect.width * 0.044, height: bookHeight),
                    color: shelfBookColor(index: palette),
                    context: context
                )
            }
        }
        fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.18), color: cgColor(red: 0.28, green: 0.22, blue: 0.18), context: context)
    }

    private func drawMeetingRoomScene(in rect: CGRect, context: CGContext) {
        fill(rect, color: cgColor(red: 0.70, green: 0.73, blue: 0.75), context: context)
        fill(CGRect(x: rect.width * 0.14, y: rect.height * 0.48, width: rect.width * 0.72, height: rect.height * 0.24), color: cgColor(red: 0.86, green: 0.88, blue: 0.86), context: context)
        fill(CGRect(x: rect.width * 0.18, y: rect.height * 0.52, width: rect.width * 0.64, height: rect.height * 0.16), color: cgColor(red: 0.55, green: 0.67, blue: 0.75), context: context)
        fill(CGRect(x: rect.width * 0.16, y: rect.height * 0.12, width: rect.width * 0.68, height: rect.height * 0.17), color: cgColor(red: 0.37, green: 0.31, blue: 0.25), context: context)
        for column in 0..<4 {
            fill(CGRect(x: rect.width * (0.20 + CGFloat(column) * 0.16), y: rect.height * 0.06, width: rect.width * 0.08, height: rect.height * 0.11), color: cgColor(red: 0.13, green: 0.15, blue: 0.16), context: context)
        }
    }

    private func drawCityWindowScene(in rect: CGRect, context: CGContext) {
        fill(rect, color: cgColor(red: 0.70, green: 0.77, blue: 0.84), context: context)
        fill(CGRect(x: rect.width * 0.08, y: rect.height * 0.20, width: rect.width * 0.84, height: rect.height * 0.60), color: cgColor(red: 0.84, green: 0.90, blue: 0.94), context: context)
        for column in 0..<7 {
            let buildingHeight = rect.height * (0.18 + CGFloat((column * 2) % 4) * 0.06)
            fill(CGRect(x: rect.width * (0.12 + CGFloat(column) * 0.11), y: rect.height * 0.20, width: rect.width * 0.08, height: buildingHeight), color: cgColor(red: 0.40, green: 0.47, blue: 0.54), context: context)
        }
        fill(CGRect(x: rect.width * 0.08, y: rect.height * 0.18, width: rect.width * 0.84, height: rect.height * 0.035), color: cgColor(red: 0.21, green: 0.23, blue: 0.25), context: context)
        fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.18), color: cgColor(red: 0.58, green: 0.54, blue: 0.49), context: context)
    }

    private func drawLightStudioScene(in rect: CGRect, context: CGContext) {
        fill(rect, color: cgColor(red: 0.88, green: 0.89, blue: 0.86), context: context)
        fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.28), color: cgColor(red: 0.72, green: 0.70, blue: 0.66), context: context)
        fill(CGRect(x: rect.width * 0.12, y: rect.height * 0.36, width: rect.width * 0.17, height: rect.height * 0.34), color: cgColor(red: 0.94, green: 0.92, blue: 0.86), context: context)
        fill(CGRect(x: rect.width * 0.72, y: rect.height * 0.33, width: rect.width * 0.16, height: rect.height * 0.42), color: cgColor(red: 0.95, green: 0.93, blue: 0.88), context: context)
        fill(CGRect(x: rect.width * 0.40, y: rect.height * 0.22, width: rect.width * 0.20, height: rect.height * 0.06), color: cgColor(red: 0.42, green: 0.43, blue: 0.43), context: context)
    }

    private func fill(_ rect: CGRect, color: CGColor, context: CGContext) {
        context.setFillColor(color)
        context.fill(rect)
    }

    private func shelfBookColor(index: CGFloat) -> CGColor {
        switch Int(index) {
        case 0:
            cgColor(red: 0.50, green: 0.16, blue: 0.14)
        case 1:
            cgColor(red: 0.14, green: 0.29, blue: 0.47)
        case 2:
            cgColor(red: 0.78, green: 0.58, blue: 0.22)
        case 3:
            cgColor(red: 0.24, green: 0.42, blue: 0.28)
        default:
            cgColor(red: 0.72, green: 0.70, blue: 0.62)
        }
    }

    private func cgColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha]) ?? CGColor(gray: 0.5, alpha: alpha)
    }

    private func gradient(top: CIColor, bottom: CIColor, extent: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CILinearGradient") else {
            return CIImage(color: bottom).cropped(to: extent)
        }

        filter.setValue(CIVector(x: extent.midX, y: extent.maxY), forKey: "inputPoint0")
        filter.setValue(CIVector(x: extent.midX, y: extent.minY), forKey: "inputPoint1")
        filter.setValue(top, forKey: "inputColor0")
        filter.setValue(bottom, forKey: "inputColor1")
        return filter.outputImage?.cropped(to: extent) ?? CIImage(color: bottom).cropped(to: extent)
    }

    private func personMask(for pixelBuffer: CVPixelBuffer, extent: CGRect) -> CIImage? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([segmentationRequest])
            guard let observation = segmentationRequest.results?.first as? VNPixelBufferObservation else {
                return nil
            }

            let rawMask = CIImage(cvPixelBuffer: observation.pixelBuffer)
            let scale = CGAffineTransform(
                scaleX: extent.width / max(1, rawMask.extent.width),
                y: extent.height / max(1, rawMask.extent.height)
            )
            return rawMask
                .transformed(by: scale)
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2])
                .cropped(to: extent)
        } catch {
            return nil
        }
    }

    private func beautified(_ image: CIImage, preferences: RecordingPreferences) -> CIImage {
        let level = min(max(preferences.cameraBeautyLevel, 0), 1)
        guard level > 0 else { return image }

        return image
            .applyingFilter(
                "CINoiseReduction",
                parameters: [
                    "inputNoiseLevel": 0.015 + level * 0.02,
                    "inputSharpness": 0.45
                ]
            )
            .applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputBrightnessKey: 0.02 * level,
                    kCIInputSaturationKey: 1 + 0.06 * level,
                    kCIInputContrastKey: 1 - 0.04 * level
                ]
            )
            .cropped(to: image.extent)
    }
}
