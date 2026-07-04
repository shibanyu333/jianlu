@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import JianLuCore
import QuartzCore

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
    @Published private(set) var processedPreviewImage: CGImage?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let delegateProxy = CameraCaptureDelegateProxy()
    private let sampleCoordinator = CameraSampleCoordinator(previewPreferences: .defaults)
    private let sessionQueue = DispatchQueue(label: "com.local.JianLu.camera-session")
    private let videoQueue = DispatchQueue(label: "com.local.JianLu.camera-video")
    private var configured = false
    private var sampleWriter: CameraSampleWriter?
    private(set) var currentOutputURL: URL?

    override init() {
        super.init()
        sampleCoordinator.previewImageHandler = { [weak self] image in
            Task { @MainActor [weak self] in
                self?.processedPreviewImage = image
            }
        }
        delegateProxy.sampleHandler = { [sampleCoordinator] sampleBuffer in
            sampleCoordinator.append(sampleBuffer)
        }
    }

    var previewSession: AVCaptureSession {
        session
    }

    var hasActiveRecording: Bool {
        sampleWriter != nil
    }

    func updatePreviewPreferences(_ preferences: RecordingPreferences) {
        sampleCoordinator.updatePreviewPreferences(preferences)
    }

    func updateRecordingPreferences(_ preferences: RecordingPreferences) {
        sampleCoordinator.updateRecordingPreferences(preferences)
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
        var outputURL: URL?
        do {
            try configureIfNeeded()
            await startSessionIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)

            let recordingURL = try RecordingFileStore.makeRecordingURL(
                prefix: "camera",
                directoryPath: preferences.recordingDirectoryPath
            )
            outputURL = recordingURL
            let writer = try CameraSampleWriter(outputURL: recordingURL, preferences: preferences)
            sampleWriter = writer
            currentOutputURL = recordingURL
            sampleCoordinator.setWriter(writer)

            isRecording = true
            lastErrorMessage = nil
            return recordingURL
        } catch {
            await cleanupAfterFailedStart(outputURL: outputURL)
            lastErrorMessage = error.localizedDescription
            throw error
        }
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
        let failedOutputURL = currentOutputURL

        isRecording = false
        sampleCoordinator.clearWriter()

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
            if let failedOutputURL {
                try? FileManager.default.removeItem(at: failedOutputURL)
            }
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

    private func cleanupAfterFailedStart(outputURL: URL?) async {
        isRecording = false
        sampleWriter = nil
        currentOutputURL = nil
        sampleCoordinator.clearWriter()
        await stopSessionIfRunning()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }
}

private final class CameraSampleCoordinator: @unchecked Sendable {
    var previewImageHandler: (@Sendable (CGImage?) -> Void)?

    private let processor = CameraFrameProcessor()
    private let preferencesLock = NSLock()
    private let writerLock = NSLock()
    private var previewPreferences: RecordingPreferences
    private var writer: CameraSampleWriter?
    private var lastPreviewUpdateTime: TimeInterval = 0
    private let previewFrameInterval: TimeInterval = 1.0 / 15.0

    init(previewPreferences: RecordingPreferences) {
        self.previewPreferences = previewPreferences
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        // `writer` is mutated from the main actor (start/stop/failed-start) while
        // frames arrive here on the camera video queue. Take a strong reference
        // under the lock, then release it before doing the per-frame work so a
        // concurrent `clearWriter()` can't race the ARC release of this reference.
        writerLock.lock()
        let writer = self.writer
        writerLock.unlock()
        writer?.append(sampleBuffer)
        publishProcessedPreviewIfNeeded(from: sampleBuffer)
    }

    func setWriter(_ writer: CameraSampleWriter) {
        writerLock.lock()
        self.writer = writer
        writerLock.unlock()
    }

    func clearWriter() {
        writerLock.lock()
        writer = nil
        writerLock.unlock()
    }

    func updatePreviewPreferences(_ preferences: RecordingPreferences) {
        preferencesLock.lock()
        previewPreferences = preferences
        let needsProcessedPreview = preferences.needsProcessedCameraPreview
        preferencesLock.unlock()

        if !needsProcessedPreview {
            previewImageHandler?(nil)
        }
    }

    func updateRecordingPreferences(_ preferences: RecordingPreferences) {
        writerLock.lock()
        let writer = self.writer
        writerLock.unlock()
        writer?.updatePreferences(preferences)
    }

    private func publishProcessedPreviewIfNeeded(from sampleBuffer: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastPreviewUpdateTime >= previewFrameInterval else { return }

        preferencesLock.lock()
        let preferences = previewPreferences
        preferencesLock.unlock()

        guard preferences.needsProcessedCameraPreview else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastPreviewUpdateTime = now
        guard let image = processor.makePreviewImage(from: pixelBuffer, preferences: preferences) else { return }
        previewImageHandler?(image)
    }
}

private final class CameraSampleWriter: @unchecked Sendable {
    private let outputURL: URL
    private let preferencesLock = NSLock()
    private var preferences: RecordingPreferences
    private let processor = CameraFrameProcessor()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstSampleTime: CMTime?
    private var lastError: Error?
    private var isFinishing = false

    init(outputURL: URL, preferences: RecordingPreferences) throws {
        self.outputURL = outputURL
        self.preferences = preferences
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
    }

    func updatePreferences(_ preferences: RecordingPreferences) {
        preferencesLock.lock()
        self.preferences = preferences
        preferencesLock.unlock()
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

                let image = processor.processedImage(from: pixelBuffer, preferences: currentPreferences())
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

    func finish(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
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
        nonisolated(unsafe) let finishingWriter = assetWriter
        finishingWriter.finishWriting { [completion] in
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

    private func currentPreferences() -> RecordingPreferences {
        preferencesLock.lock()
        let preferences = preferences
        preferencesLock.unlock()
        return preferences
    }

    private func markFailed(_ error: Error) {
        lastError = error
        isFinishing = true
        assetWriter?.cancelWriting()
    }
}

private extension RecordingPreferences {
    var needsProcessedCameraPreview: Bool {
        cameraBackgroundStyle != .original
            || cameraBackgroundBlur != .off
            || cameraBeautyLevel > 0
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
