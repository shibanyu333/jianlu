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
            tr("没有找到可用摄像头。", "No camera available.")
        case .cannotAddInput:
            tr("无法接入摄像头。", "Could not open the camera.")
        case .cannotAddOutput:
            tr("无法创建摄像头录制输出。", "Could not create the camera output.")
        case .cannotCreateWriter:
            tr("无法创建摄像头视频写入器。", "Could not create the camera writer.")
        case .notRecording:
            tr("当前没有正在进行的摄像头录制。", "No camera recording is running.")
        }
    }
}

@MainActor
final class CameraCaptureService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var processedPreviewImage: CGImage?
    /// `uniqueID` of the camera the session is actually feeding on, which is not always
    /// the one that was asked for — an unplugged pick falls back to the system default.
    @Published private(set) var activeDeviceID: String?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let delegateProxy = CameraCaptureDelegateProxy()
    private let sampleCoordinator = CameraSampleCoordinator(previewPreferences: .defaults)
    private let sessionQueue = DispatchQueue(label: "com.local.JianLu.camera-session")
    private let videoQueue = DispatchQueue(label: "com.local.JianLu.camera-video")
    private var configured = false
    private var videoInput: AVCaptureDeviceInput?
    private var preferredDeviceID: String?
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

    /// Remembers which camera to use and, when the session is already live, swaps the
    /// input under it so the bubble changes immediately.
    ///
    /// Refuses to swap mid-recording on purpose: the writer fixes its dimensions from
    /// the first frame, so a camera with a different resolution would spend the rest of
    /// the take cropped into that frame. `AppState` disables the picker for the same
    /// reason; this guard is what makes it true rather than merely displayed.
    func selectDevice(_ deviceID: String?) {
        let normalized = (deviceID?.isEmpty ?? true) ? nil : deviceID
        guard preferredDeviceID != normalized else { return }
        preferredDeviceID = normalized
        guard configured, !hasActiveRecording else { return }
        applyPreferredDevice()
    }

    func configureIfNeeded() throws {
        guard !configured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let camera = MediaDeviceCatalog.camera(preferredID: preferredDeviceID) else {
            session.commitConfiguration()
            throw CameraCaptureError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)
        videoInput = input
        activeDeviceID = camera.uniqueID

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

        applyMirroring()

        session.commitConfiguration()
        configured = true
    }

    /// Swaps the running session's input to whatever `preferredDeviceID` now resolves
    /// to. Keeps the old input when the new one cannot be opened, so a bad pick leaves
    /// a working camera rather than a black bubble.
    private func applyPreferredDevice() {
        guard let camera = MediaDeviceCatalog.camera(preferredID: preferredDeviceID) else {
            lastErrorMessage = CameraCaptureError.noCamera.errorDescription
            return
        }
        guard camera.uniqueID != activeDeviceID else { return }

        let previousInput = videoInput
        session.beginConfiguration()
        if let previousInput {
            session.removeInput(previousInput)
        }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                throw CameraCaptureError.cannotAddInput
            }
            session.addInput(input)
            videoInput = input
            activeDeviceID = camera.uniqueID
            lastErrorMessage = nil
        } catch {
            if let previousInput, session.canAddInput(previousInput) {
                session.addInput(previousInput)
            }
            lastErrorMessage = error.localizedDescription
        }
        session.commitConfiguration()

        // The connection is rebuilt with the new input, so the explicit mirroring the
        // export pipeline assumes has to be reapplied every swap.
        applyMirroring()
        // The previous device's last processed frame would otherwise stay on screen
        // until the new camera delivers one.
        processedPreviewImage = nil
    }

    private func applyMirroring() {
        guard let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
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
            selectDevice(preferences.cameraDeviceID)
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
        // Drop the last composited preview frame so a stopped bubble doesn't freeze
        // on the final processed image.
        processedPreviewImage = nil

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

        lastPreviewUpdateTime = now

        // While recording, the writer already ran person segmentation for this exact
        // frame (with the same preferences). Reuse its processed output instead of
        // running Vision a second time on the same buffer — the duplicate pass was
        // dropping frames whenever background replacement or beauty was on.
        writerLock.lock()
        let activeWriter = writer
        writerLock.unlock()
        if let activeWriter, let image = activeWriter.makePreviewImage() {
            previewImageHandler?(image)
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
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
    private let previewLock = NSLock()
    private var lastProcessedImage: CIImage?

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

    /// A CGImage of the most recently processed frame, so the live preview can reuse
    /// the writer's segmentation instead of running Vision again on the same buffer.
    func makePreviewImage() -> CGImage? {
        previewLock.lock()
        let image = lastProcessedImage
        previewLock.unlock()
        guard let image else { return nil }
        return ciContext.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: colorSpace)
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
                previewLock.lock()
                lastProcessedImage = image
                previewLock.unlock()
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
            || cameraBeauty.isEnabled
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
