@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import JianLuCore
@preconcurrency import Vision

enum CameraCaptureError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case cannotCreateWriter
    case notRecording

    var errorDescription: String? {
        switch self {
        case .noCamera:
            "没有找到可用摄像头。"
        case .cannotAddInput:
            "无法接入摄像头。"
        case .cannotAddOutput:
            "无法创建摄像头录制输出。"
        case .cannotCreateWriter:
            "无法创建摄像头视频写入器。"
        case .notRecording:
            "当前没有正在进行的摄像头录制。"
        }
    }
}

@MainActor
final class CameraCaptureService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastErrorMessage: String?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let delegateProxy = CameraCaptureDelegateProxy()
    private let sessionQueue = DispatchQueue(label: "com.local.JianLu.camera-session")
    private let videoQueue = DispatchQueue(label: "com.local.JianLu.camera-video")
    private var configured = false
    private var sampleWriter: CameraSampleWriter?
    private(set) var currentOutputURL: URL?

    override init() {
        super.init()
        delegateProxy.sampleHandler = { _ in }
    }

    var previewSession: AVCaptureSession {
        session
    }

    var hasActiveRecording: Bool {
        sampleWriter != nil
    }

    func configureIfNeeded() throws {
        guard !configured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            throw CameraCaptureError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(delegateProxy, queue: videoQueue)

        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CameraCaptureError.cannotAddOutput
        }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }

        session.commitConfiguration()
        configured = true
    }

    func startPreviewIfNeeded() {
        do {
            try configureIfNeeded()
            sessionQueue.async { [session] in
                if !session.isRunning {
                    session.startRunning()
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func startRecording(preferences: RecordingPreferences) async throws -> URL {
        try configureIfNeeded()
        await startSessionIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)

        let outputURL = try RecordingFileStore.makeRecordingURL(
            prefix: "camera",
            directoryPath: preferences.recordingDirectoryPath
        )
        let writer = try CameraSampleWriter(outputURL: outputURL, preferences: preferences)
        sampleWriter = writer
        currentOutputURL = outputURL
        delegateProxy.sampleHandler = { [weak writer] sampleBuffer in
            writer?.append(sampleBuffer)
        }

        isRecording = true
        lastErrorMessage = nil
        return outputURL
    }

    private func startSessionIfNeeded() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                if !session.isRunning {
                    session.startRunning()
                }
                continuation.resume()
            }
        }
    }

    func stopRecording() async throws {
        guard let writer = sampleWriter else {
            throw CameraCaptureError.notRecording
        }

        isRecording = false
        delegateProxy.sampleHandler = { _ in }

        do {
            try await finish(writer: writer)
            sampleWriter = nil
            currentOutputURL = nil
            lastErrorMessage = nil
            await stopSessionIfRunning()
        } catch {
            sampleWriter = nil
            currentOutputURL = nil
            lastErrorMessage = error.localizedDescription
            await stopSessionIfRunning()
            throw error
        }
    }

    private func finish(writer: CameraSampleWriter) async throws {
        try await withCheckedThrowingContinuation { continuation in
            videoQueue.async { [writer] in
                writer.finish { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func stopSessionIfRunning() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                if session.isRunning {
                    session.stopRunning()
                }
                continuation.resume()
            }
        }
    }
}

private final class CameraSampleWriter {
    private let outputURL: URL
    private let preferences: RecordingPreferences
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstSampleTime: CMTime?
    private var lastError: Error?
    private var isFinishing = false
    private lazy var segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    init(outputURL: URL, preferences: RecordingPreferences) throws {
        self.outputURL = outputURL
        self.preferences = preferences
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishing, lastError == nil else { return }

        autoreleasepool {
            do {
                try configureWriterIfNeeded(for: sampleBuffer)
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                      let assetWriter,
                      let writerInput,
                      let pixelBufferAdaptor else {
                    throw CameraCaptureError.cannotCreateWriter
                }

                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if firstSampleTime == nil {
                    guard assetWriter.startWriting() else {
                        throw assetWriter.error ?? CameraCaptureError.cannotCreateWriter
                    }
                    assetWriter.startSession(atSourceTime: presentationTime)
                    firstSampleTime = presentationTime
                }

                guard assetWriter.status == .writing else {
                    throw assetWriter.error ?? CameraCaptureError.cannotCreateWriter
                }
                guard writerInput.isReadyForMoreMediaData else { return }
                guard let bufferPool = pixelBufferAdaptor.pixelBufferPool else {
                    throw CameraCaptureError.cannotCreateWriter
                }

                var outputBuffer: CVPixelBuffer?
                let createResult = CVPixelBufferPoolCreatePixelBuffer(nil, bufferPool, &outputBuffer)
                guard createResult == kCVReturnSuccess, let outputBuffer else {
                    throw CameraCaptureError.cannotCreateWriter
                }

                let image = processedImage(from: pixelBuffer)
                ciContext.render(
                    image,
                    to: outputBuffer,
                    bounds: image.extent,
                    colorSpace: colorSpace
                )

                if !pixelBufferAdaptor.append(outputBuffer, withPresentationTime: presentationTime) {
                    throw assetWriter.error ?? CameraCaptureError.cannotCreateWriter
                }
            } catch {
                markFailed(error)
            }
        }
    }

    func finish(_ completion: @escaping (Result<Void, Error>) -> Void) {
        isFinishing = true

        if let lastError {
            assetWriter?.cancelWriting()
            completion(.failure(lastError))
            return
        }

        guard let assetWriter, let writerInput else {
            completion(.failure(CameraCaptureError.cannotCreateWriter))
            return
        }

        guard assetWriter.status == .writing else {
            let error = assetWriter.error ?? CameraCaptureError.cannotCreateWriter
            assetWriter.cancelWriting()
            completion(.failure(error))
            return
        }

        writerInput.markAsFinished()
        let finishingWriter = assetWriter
        finishingWriter.finishWriting {
            if finishingWriter.status == .completed {
                completion(.success(()))
            } else {
                completion(.failure(finishingWriter.error ?? CameraCaptureError.cannotCreateWriter))
            }
        }
    }

    private func configureWriterIfNeeded(for sampleBuffer: CMSampleBuffer) throws {
        guard assetWriter == nil else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw CameraCaptureError.cannotCreateWriter
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let width = max(1, Int(dimensions.width))
        let height = max(1, Int(dimensions.height))

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: width * height * 6
                ]
            ]
        )
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw CameraCaptureError.cannotCreateWriter
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        assetWriter = writer
        writerInput = input
        pixelBufferAdaptor = adaptor
    }

    private func processedImage(from pixelBuffer: CVPixelBuffer) -> CIImage {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = source.extent
        var image = source

        if preferences.cameraBackgroundStyle != .original || preferences.cameraBackgroundBlur != .off {
            if let mask = personMask(for: pixelBuffer, extent: extent) {
                let background = backgroundImage(for: source, extent: extent)
                image = source.applyingFilter(
                    "CIBlendWithMask",
                    parameters: [
                        kCIInputBackgroundImageKey: background,
                        "inputMaskImage": mask
                    ]
                )
            } else if preferences.cameraBackgroundBlur != .off {
                image = source
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: preferences.cameraBackgroundBlur.radius])
                    .cropped(to: extent)
            }
        }

        return beautified(image.cropped(to: extent))
    }

    private func backgroundImage(for source: CIImage, extent: CGRect) -> CIImage {
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
            return sceneBackground(preferences.cameraBackgroundStyle, extent: extent)
        }
    }

    private func sceneBackground(_ style: CameraBackgroundStyle, extent: CGRect) -> CIImage {
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

    private func beautified(_ image: CIImage) -> CIImage {
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

    private func markFailed(_ error: Error) {
        lastError = error
        isFinishing = true
        assetWriter?.cancelWriting()
    }
}

private final class CameraCaptureDelegateProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var sampleHandler: ((CMSampleBuffer) -> Void)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        sampleHandler?(sampleBuffer)
    }
}
