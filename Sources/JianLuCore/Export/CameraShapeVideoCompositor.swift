@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

public final class CameraShapeVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing = true
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    public let screenTrackID: CMPersistentTrackID
    public let cameraTrackID: CMPersistentTrackID?
    public let renderSize: CGSize
    /// points→pixels scale for absolute annotation metrics (line width, arrow head,
    /// corner radius). Keeps exported strokes the same visual thickness the presenter
    /// saw in the live overlay instead of half-size on Retina recordings.
    public let strokeScale: CGFloat
    public let zoomStates: [ZoomEvent]
    public let zoomRegions: [ExportZoomRegion]
    public let annotationEvents: [EffectEvent]
    public let cameraStates: [CameraLayoutEvent]

    public init(
        timeRange: CMTimeRange,
        screenTrackID: CMPersistentTrackID,
        cameraTrackID: CMPersistentTrackID?,
        renderSize: CGSize,
        strokeScale: CGFloat = 1,
        zoomStates: [ZoomEvent],
        annotationEvents: [EffectEvent] = [],
        cameraStates: [CameraLayoutEvent]
    ) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.renderSize = renderSize
        self.strokeScale = max(0.01, strokeScale)
        let sortedZoomStates = zoomStates.sorted { $0.time < $1.time }
        self.zoomStates = sortedZoomStates
        self.zoomRegions = ExportZoomTimeline.regions(
            from: sortedZoomStates,
            duration: CMTimeGetSeconds(timeRange.duration)
        )
        self.annotationEvents = annotationEvents.enumerated().sorted { lhs, rhs in
            if abs(lhs.element.time - rhs.element.time) > 0.000001 {
                return lhs.element.time < rhs.element.time
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        self.cameraStates = cameraStates.sorted { $0.time < $1.time }

        var trackIDs: [NSValue] = [NSNumber(value: screenTrackID)]
        if let cameraTrackID {
            trackIDs.append(NSNumber(value: cameraTrackID))
        }
        requiredSourceTrackIDs = trackIDs
    }
}

public final class CameraShapeVideoCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(label: "com.local.JianLu.camera-shape-compositor")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_32BGRA
            ]
        ]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            self?.render(asyncVideoCompositionRequest)
        }
    }

    public func cancelAllPendingVideoCompositionRequests() {
        renderQueue.sync {}
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? CameraShapeVideoCompositionInstruction,
                  let outputBuffer = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "JianLuVideoCompositor", code: 1))
                return
            }

            guard let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID) else {
                request.finish(with: NSError(domain: "JianLuVideoCompositor", code: 2))
                return
            }

            let renderRect = CGRect(origin: .zero, size: instruction.renderSize)
            let compositionTime = CMTimeGetSeconds(request.compositionTime)
            var image = normalizedImage(from: screenBuffer, renderSize: instruction.renderSize)

            // Layer order must mirror the live overlay exactly: the zoom magnifies
            // ONLY the screen content, then annotations and the camera bubble sit on
            // top at their fixed full-frame positions (they do not get scaled or
            // pushed off-frame by the zoom). Previously the camera and annotations
            // were composited first and then the whole frame was zoomed, so the
            // bubble drifted and annotations diverged from what was recorded.
            image = zoomedImage(
                image,
                at: compositionTime,
                states: instruction.zoomStates,
                regions: instruction.zoomRegions,
                renderSize: instruction.renderSize
            )

            image = compositeAnnotations(
                over: image,
                at: compositionTime,
                events: instruction.annotationEvents,
                renderSize: instruction.renderSize,
                strokeScale: instruction.strokeScale
            )

            if let cameraTrackID = instruction.cameraTrackID,
               let cameraBuffer = request.sourceFrame(byTrackID: cameraTrackID),
               let cameraState = state(at: compositionTime, in: instruction.cameraStates),
               cameraState.isVisible {
                let cameraImage = normalizedImage(from: cameraBuffer)
                image = compositeCamera(
                    cameraImage,
                    over: image,
                    state: cameraState,
                    renderSize: instruction.renderSize,
                    strokeScale: instruction.strokeScale
                )
            }

            ciContext.render(
                image.cropped(to: renderRect),
                to: outputBuffer,
                bounds: renderRect,
                colorSpace: colorSpace
            )
            request.finish(withComposedVideoFrame: outputBuffer)
        }
    }

    private func normalizedImage(from buffer: CVPixelBuffer, renderSize: CGSize? = nil) -> CIImage {
        var image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))

        guard let renderSize else {
            return image.cropped(to: CGRect(origin: .zero, size: extent.size))
        }

        let scale = CGAffineTransform(
            scaleX: renderSize.width / max(1, extent.width),
            y: renderSize.height / max(1, extent.height)
        )
        return image
            .transformed(by: scale)
            .cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    private func zoomedImage(
        _ image: CIImage,
        at time: TimeInterval,
        states: [ZoomEvent],
        regions: [ExportZoomRegion],
        renderSize: CGSize
    ) -> CIImage {
        let renderRect = CGRect(origin: .zero, size: renderSize)
        let effect = ExportZoomTimeline.activeEffect(regions: regions, states: states, at: time)
        let transform = ExportZoomTimeline.transform(for: effect, in: renderRect, flipsY: true)
        guard transform != .identity else {
            return image
        }

        return image
            .transformed(by: transform)
            .cropped(to: renderRect)
    }

    private func compositeAnnotations(
        over baseImage: CIImage,
        at time: TimeInterval,
        events: [EffectEvent],
        renderSize: CGSize,
        strokeScale: CGFloat
    ) -> CIImage {
        guard !events.isEmpty,
              let overlay = annotationOverlayImage(at: time, events: events, renderSize: renderSize, strokeScale: strokeScale) else {
            return baseImage
        }

        return overlay.composited(over: baseImage)
    }

    private func annotationOverlayImage(
        at time: TimeInterval,
        events: [EffectEvent],
        renderSize: CGSize,
        strokeScale: CGFloat
    ) -> CIImage? {
        let annotations = activeAnnotations(at: time, events: events)
        guard !annotations.isEmpty else { return nil }

        let width = max(1, Int(renderSize.width.rounded(.up)))
        let height = max(1, Int(renderSize.height.rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(
            x: CGFloat(width) / max(1, renderSize.width),
            y: CGFloat(height) / max(1, renderSize.height)
        )
        context.translateBy(x: 0, y: renderSize.height)
        context.scaleBy(x: 1, y: -1)

        for annotation in annotations {
            draw(annotation, in: context, renderSize: renderSize, strokeScale: strokeScale)
        }

        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    private func activeAnnotations(at time: TimeInterval, events: [EffectEvent]) -> [AnnotationEvent] {
        let eventCutoff = time + 0.0001
        var activeByID: [UUID: AnnotationEvent] = [:]
        var order: [UUID] = []

        for event in events {
            guard event.time <= eventCutoff else { break }
            switch event {
            case .annotation(let annotation):
                if activeByID[annotation.id] == nil {
                    order.append(annotation.id)
                }
                activeByID[annotation.id] = annotation
            case .annotationClear:
                activeByID.removeAll()
                order.removeAll()
            case .cameraLayout, .zoom:
                break
            }
        }

        return order.compactMap { activeByID[$0] }
    }

    private func draw(_ annotation: AnnotationEvent, in context: CGContext, renderSize: CGSize, strokeScale: CGFloat) {
        let points = annotation.points.map {
            CGPoint(
                x: CGFloat($0.point.x) * renderSize.width,
                y: CGFloat($0.point.y) * renderSize.height
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
                let corner = AnnotationStyle.rectangleCornerRadius * strokeScale
                path.addRoundedRect(in: rect, cornerWidth: corner, cornerHeight: corner)
            }
        case .line, .arrow:
            guard let last = points.last else { return }
            path.addLine(to: last)
            if annotation.tool == .arrow {
                addArrowHead(to: path, from: points.dropLast().last ?? first, to: last, scale: strokeScale)
            }
        case .pen, .highlight:
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }

        context.setStrokeColor(AnnotationStyle.cgColor(hex: annotation.colorHex, tool: annotation.tool))
        context.setLineWidth(AnnotationStyle.lineWidth(for: annotation.tool, stored: annotation.lineWidth) * strokeScale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }

    private func addArrowHead(to path: CGMutablePath, from start: CGPoint, to end: CGPoint, scale: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = AnnotationStyle.arrowHeadLength * scale
        let spread: CGFloat = .pi / 7
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
    }

    private func compositeCamera(
        _ cameraImage: CIImage,
        over baseImage: CIImage,
        state: CameraLayoutEvent,
        renderSize: CGSize,
        strokeScale: CGFloat
    ) -> CIImage {
        let targetRect = cameraTargetRect(frame: state.frame, shape: state.shape, renderSize: renderSize)
        guard targetRect.width > 1, targetRect.height > 1 else {
            return baseImage
        }

        let fittedCamera = aspectFill(cameraImage, into: targetRect)
        let shapedCamera = maskedCamera(fittedCamera, shape: state.shape, targetRect: targetRect)
        var composited = shapedCamera.composited(over: baseImage)
        if let border = cameraBorderImage(shape: state.shape, targetRect: targetRect, strokeScale: strokeScale) {
            composited = border.composited(over: composited)
        }
        return composited
    }

    /// The white bubble border the live preview draws (3pt stroke). Rendered here so
    /// the exported bubble matches the overlay instead of appearing borderless.
    private func cameraBorderImage(shape: CameraFrameShape, targetRect: CGRect, strokeScale: CGFloat) -> CIImage? {
        let lineWidth = max(1, 3 * strokeScale)
        let inset = lineWidth / 2
        let strokeRect = targetRect.insetBy(dx: inset, dy: inset)
        guard strokeRect.width > 1, strokeRect.height > 1 else { return nil }

        let width = max(1, Int(targetRect.width.rounded(.up)))
        let height = max(1, Int(targetRect.height.rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Draw in a local, target-rect-origin space, then translate the resulting
        // image back to the bubble's position in the full frame.
        let localRect = strokeRect.offsetBy(dx: -targetRect.minX, dy: -targetRect.minY)
        let path = cameraShapePath(shape: shape, in: localRect)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.setLineWidth(lineWidth)
        context.addPath(path)
        context.strokePath()

        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: targetRect.minX, y: targetRect.minY))
            .cropped(to: targetRect)
    }

    private func cameraShapePath(shape: CameraFrameShape, in rect: CGRect) -> CGPath {
        switch shape {
        case .circle, .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        case .square:
            return CGPath(rect: rect, transform: nil)
        case .roundedSquare:
            let radius = min(rect.width, rect.height) * 0.14
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }

    private func aspectFill(_ image: CIImage, into targetRect: CGRect) -> CIImage {
        let extent = image.extent
        let scale = max(
            targetRect.width / max(1, extent.width),
            targetRect.height / max(1, extent.height)
        )
        let scaledSize = CGSize(width: extent.width * scale, height: extent.height * scale)
        let cropOrigin = CGPoint(
            x: (scaledSize.width - targetRect.width) / 2,
            y: (scaledSize.height - targetRect.height) / 2
        )

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(origin: cropOrigin, size: targetRect.size))
            .transformed(by: CGAffineTransform(
                translationX: targetRect.minX - cropOrigin.x,
                y: targetRect.minY - cropOrigin.y
            ))
            .cropped(to: targetRect)
    }

    private func maskedCamera(_ image: CIImage, shape: CameraFrameShape, targetRect: CGRect) -> CIImage {
        switch shape {
        case .square:
            return image.cropped(to: targetRect)
        case .circle, .ellipse:
            // A true ellipse mask matching the live overlay's Path(ellipseIn:). The
            // target rect is square for 圆形 (so this is a real circle) and keeps the
            // frame's aspect ratio for 椭圆.
            guard let mask = shapeMask(shape: shape, in: targetRect) else {
                return image.cropped(to: targetRect)
            }
            return blend(image, mask: mask, targetRect: targetRect)
        case .roundedSquare:
            guard let mask = shapeMask(shape: .roundedSquare, in: targetRect) else {
                return image.cropped(to: targetRect)
            }
            return blend(image, mask: mask, targetRect: targetRect)
        }
    }

    private func blend(_ image: CIImage, mask: CIImage, targetRect: CGRect) -> CIImage {
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: targetRect)
        return image
            .applyingFilter(
                "CIBlendWithAlphaMask",
                parameters: [
                    kCIInputBackgroundImageKey: transparent,
                    "inputMaskImage": mask
                ]
            )
            .cropped(to: targetRect)
    }

    private func shapeMask(shape: CameraFrameShape, in rect: CGRect) -> CIImage? {
        switch shape {
        case .roundedSquare:
            let radius = min(rect.width, rect.height) * 0.14
            return roundedRectangleMask(in: rect, radius: radius)
        case .circle, .ellipse:
            return ellipseMask(in: rect)
        case .square:
            return roundedRectangleMask(in: rect, radius: 0)
        }
    }

    private func roundedRectangleMask(in rect: CGRect, radius: CGFloat) -> CIImage? {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return nil
        }
        filter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor")
        return filter.outputImage?.cropped(to: rect)
    }

    private func ellipseMask(in rect: CGRect) -> CIImage? {
        let width = max(1, Int(rect.width.rounded(.up)))
        let height = max(1, Int(rect.height.rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .cropped(to: rect)
    }

    private func cameraTargetRect(frame: NormalizedRect, shape: CameraFrameShape, renderSize: CGSize) -> CGRect {
        // Shared bubble geometry (see NormalizedRect.cameraBubbleRect) returns a
        // top-left-origin rect; CIImage space is bottom-left, so flip Y here.
        let topLeft = frame.cameraBubbleRect(in: renderSize, shape: shape)
        return CGRect(
            x: topLeft.minX,
            y: renderSize.height - topLeft.maxY,
            width: topLeft.width,
            height: topLeft.height
        )
    }

    private func state(at time: TimeInterval, in states: [CameraLayoutEvent]) -> CameraLayoutEvent? {
        states.last { $0.time <= time } ?? states.first
    }
}
