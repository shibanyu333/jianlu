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
    public let zoomStates: [ZoomEvent]
    public let cameraStates: [CameraLayoutEvent]

    public init(
        timeRange: CMTimeRange,
        screenTrackID: CMPersistentTrackID,
        cameraTrackID: CMPersistentTrackID?,
        renderSize: CGSize,
        zoomStates: [ZoomEvent],
        cameraStates: [CameraLayoutEvent]
    ) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.renderSize = renderSize
        self.zoomStates = zoomStates
        self.cameraStates = cameraStates

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
            var image = normalizedImage(from: screenBuffer, renderSize: instruction.renderSize)
            image = zoomedScreenImage(
                image,
                at: CMTimeGetSeconds(request.compositionTime),
                states: instruction.zoomStates,
                renderSize: instruction.renderSize
            )

            if let cameraTrackID = instruction.cameraTrackID,
               let cameraBuffer = request.sourceFrame(byTrackID: cameraTrackID),
               let cameraState = state(at: CMTimeGetSeconds(request.compositionTime), in: instruction.cameraStates),
               cameraState.isVisible {
                let cameraImage = normalizedImage(from: cameraBuffer)
                image = compositeCamera(
                    cameraImage,
                    over: image,
                    state: cameraState,
                    renderSize: instruction.renderSize
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

    private func zoomedScreenImage(
        _ image: CIImage,
        at time: TimeInterval,
        states: [ZoomEvent],
        renderSize: CGSize
    ) -> CIImage {
        let state = interpolatedZoomState(at: time, in: states)
        let scale = CGFloat(min(max(state.magnification, 1), 3))
        guard scale > 1.001 else {
            return image
        }

        let focusX = CGFloat(state.focus.x) * renderSize.width
        let focusY = (1 - CGFloat(state.focus.y)) * renderSize.height
        let transform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: renderSize.width / 2 - focusX * scale,
            ty: renderSize.height / 2 - focusY * scale
        )
        return image
            .transformed(by: transform)
            .cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    private func compositeCamera(
        _ cameraImage: CIImage,
        over baseImage: CIImage,
        state: CameraLayoutEvent,
        renderSize: CGSize
    ) -> CIImage {
        let targetRect = cameraTargetRect(frame: state.frame, renderSize: renderSize)
        guard targetRect.width > 1, targetRect.height > 1 else {
            return baseImage
        }

        let fittedCamera = aspectFill(cameraImage, into: targetRect)
        let shapedCamera = maskedCamera(fittedCamera, shape: state.shape, targetRect: targetRect)
        return shapedCamera.composited(over: baseImage)
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
        case .circle, .roundedSquare:
            let radius: CGFloat
            switch shape {
            case .circle:
                radius = min(targetRect.width, targetRect.height) / 2
            case .roundedSquare:
                radius = min(targetRect.width, targetRect.height) * 0.14
            case .square:
                radius = 0
            }
            guard let mask = roundedRectangleMask(in: targetRect, radius: radius) else {
                return image.cropped(to: targetRect)
            }
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

    private func cameraTargetRect(frame: NormalizedRect, renderSize: CGSize) -> CGRect {
        CGRect(
            x: renderSize.width * frame.x,
            y: renderSize.height * (1 - frame.y - frame.height),
            width: renderSize.width * frame.width,
            height: renderSize.height * frame.height
        )
    }

    private func interpolatedZoomState(at time: TimeInterval, in states: [ZoomEvent]) -> ZoomEvent {
        let sortedStates = states.sorted { $0.time < $1.time }
        guard var previous = sortedStates.first else {
            return ZoomEvent(
                time: 0,
                magnification: 1,
                focus: NormalizedPoint(x: 0.5, y: 0.5)
            )
        }

        guard time > previous.time else {
            return previous
        }

        for state in sortedStates.dropFirst() {
            if time <= state.time {
                let duration = max(0.001, state.time - previous.time)
                let progress = min(max((time - previous.time) / duration, 0), 1)
                return ZoomEvent(
                    time: time,
                    magnification: previous.magnification + (state.magnification - previous.magnification) * progress,
                    focus: NormalizedPoint(
                        x: previous.focus.x + (state.focus.x - previous.focus.x) * progress,
                        y: previous.focus.y + (state.focus.y - previous.focus.y) * progress
                    )
                )
            }
            previous = state
        }

        return previous
    }

    private func state(at time: TimeInterval, in states: [CameraLayoutEvent]) -> CameraLayoutEvent? {
        states.last { $0.time <= time } ?? states.first
    }
}
