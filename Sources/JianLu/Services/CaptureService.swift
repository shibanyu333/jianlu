@preconcurrency import AVFoundation
import AppKit
import CoreImage
import CoreMedia
import Foundation
import JianLuCore
import os
@preconcurrency import ScreenCaptureKit

enum CaptureServiceError: LocalizedError {
    case noDisplay
    case failedToAddRecordingOutput
    case notRecording

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            tr("没有找到可录制的显示器。", "No display available to record.")
        case .failedToAddRecordingOutput:
            tr("无法创建屏幕录制输出。", "Could not create the screen recording output.")
        case .notRecording:
            tr("当前没有正在进行的屏幕录制。", "No screen recording is running.")
        }
    }
}

@MainActor
final class CaptureService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastErrorMessage: String?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let frameOutput = LatestScreenFrameOutput()
    private let frameOutputQueue = DispatchQueue(label: "com.local.JianLu.capture.latestFrame")
    private let delegateProxy = CaptureServiceDelegateProxy()
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private let logger = Logger(subsystem: "com.local.JianLu", category: "Capture")

    override init() {
        super.init()
        delegateProxy.owner = self
    }

    func startDisplayRecording(
        includeAppWindows: Bool,
        microphoneEnabled: Bool,
        microphoneNoiseReductionEnabled: Bool,
        microphoneDeviceID: String?,
        region: RecordingRegion?,
        directoryPath: String?
    ) async throws -> URL {
        let outputURL = try RecordingFileStore.makeRecordingURL(prefix: "screen", directoryPath: directoryPath)
        var createdStream: SCStream?
        do {
            let content = try await SCShareableContent.current
            guard let display = display(in: content, matching: region) else {
                throw CaptureServiceError.noDisplay
            }

            let excludedWindows = includeAppWindows ? [] : content.windows.filter { window in
                window.owningApplication?.processID == getpid()
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let configuration = SCStreamConfiguration()
            let sourceRect = sourceRect(for: region, display: display)
            if sourceRect != .zero {
                configuration.sourceRect = sourceRect
            }
            let outputSize = outputSize(for: region, display: display)
            configuration.width = max(80, Int(outputSize.width.rounded()))
            configuration.height = max(80, Int(outputSize.height.rounded()))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 8
            configuration.showsCursor = true
            configuration.showMouseClicks = true
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = false
            let captureMicrophoneInScreenRecording = microphoneEnabled && !microphoneNoiseReductionEnabled
            configuration.captureMicrophone = captureMicrophoneInScreenRecording
            configuration.microphoneCaptureDeviceID = captureMicrophoneInScreenRecording
                ? MediaDeviceCatalog.microphone(preferredID: microphoneDeviceID)?.uniqueID
                : nil

            let recordingConfiguration = SCRecordingOutputConfiguration()
            recordingConfiguration.outputURL = outputURL
            recordingConfiguration.outputFileType = .mov
            recordingConfiguration.videoCodecType = .hevc

            let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: delegateProxy)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegateProxy)
            createdStream = stream
            do {
                try stream.addStreamOutput(frameOutput, type: .screen, sampleHandlerQueue: frameOutputQueue)
            } catch {
                logger.warning("Live zoom frame output could not be attached: \(error.localizedDescription, privacy: .public)")
            }
            try stream.addRecordingOutput(recordingOutput)

            self.stream = stream
            self.recordingOutput = recordingOutput
            frameOutput.reset()
            try await stream.startCapture()
            isRecording = true
            lastErrorMessage = nil
            return outputURL
        } catch {
            await cleanupAfterFailedStart(stream: createdStream, outputURL: outputURL)
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    private func display(in content: SCShareableContent, matching region: RecordingRegion?) -> SCDisplay? {
        guard let region else {
            return content.displays.first
        }
        return content.displays.first { $0.displayID == region.displayID } ?? content.displays.first
    }

    private func sourceRect(for region: RecordingRegion?, display: SCDisplay) -> CGRect {
        guard let region, region.isUsable else { return .zero }

        let displayPointSize = pointSize(for: display)
        return region.screenCaptureSourceRect(
            displayPointWidth: displayPointSize.width,
            displayPointHeight: displayPointSize.height
        )
    }

    private func outputSize(for region: RecordingRegion?, display: SCDisplay) -> CGSize {
        // Pixels, from the real backing scale — SCDisplay reports points, so deriving
        // the scale from it recorded everything at 1× (see DisplayGeometry).
        let displayPixelSize = DisplayGeometry.pixelSize(for: display)
        guard let region, region.isUsable else {
            return displayPixelSize
        }

        let displayPointSize = pointSize(for: display)
        return region.screenCaptureOutputSize(
            displayPixelWidth: displayPixelSize.width,
            displayPixelHeight: displayPixelSize.height,
            displayPointWidth: displayPointSize.width,
            displayPointHeight: displayPointSize.height
        )
    }

    private func pointSize(for display: SCDisplay) -> CGSize {
        DisplayGeometry.pointSize(for: display)
    }

    func stopDisplayRecording() async throws {
        guard let stream else {
            throw CaptureServiceError.notRecording
        }
        defer {
            cleanupAfterStop()
        }

        try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            Task { @MainActor in
                do {
                    try await stream.stopCapture()
                } catch {
                    completeStop(with: .failure(error))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if stopContinuation != nil {
                    completeStop(with: .success(()))
                }
            }
        }
    }

    func latestScreenFrame() -> CGImage? {
        frameOutput.latestImage()
    }

    func waitForFirstScreenFrame(timeout: TimeInterval = 0.45) async {
        let deadline = Date().addingTimeInterval(timeout)
        while frameOutput.latestImage() == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if frameOutput.latestImage() == nil {
            logger.warning("Live zoom first frame did not arrive before timeout; snapshot fallback remains enabled")
        } else {
            logger.info("Live zoom first frame is ready")
        }
    }

    private func cleanupAfterStop() {
        stream = nil
        recordingOutput = nil
        frameOutput.reset()
        stopContinuation = nil
        isRecording = false
    }

    private func cleanupAfterFailedStart(stream: SCStream?, outputURL: URL) async {
        isRecording = false
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil
        recordingOutput = nil
        frameOutput.reset()
        stopContinuation = nil
        try? FileManager.default.removeItem(at: outputURL)
    }

    fileprivate func handleFailure(_ error: Error) {
        if stopContinuation != nil {
            completeStop(with: .failure(error))
            return
        }

        lastErrorMessage = error.localizedDescription
        isRecording = false
    }

    fileprivate func handleStarted() {
        lastErrorMessage = nil
    }

    fileprivate func handleFinished() {
        if stopContinuation != nil {
            completeStop(with: .success(()))
            return
        }

        isRecording = false
    }

    private func completeStop(with result: Result<Void, Error>) {
        guard let continuation = stopContinuation else { return }
        stopContinuation = nil

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

/// Keeps the most recent screen frame around for the live zoom preview.
///
/// Converting a frame to a CGImage is expensive — a Retina region is ~17 MB per frame,
/// so doing it 30 times a second costs hundreds of MB/s of pixel work. Only the live
/// zoom ever reads these frames, and most recordings never zoom at all, so conversion
/// is demand-driven: asking for a frame keeps the pipeline warm for a moment, and it
/// goes idle again as soon as nobody is looking.
private final class LatestScreenFrameOutput: NSObject, SCStreamOutput {
    /// How long a single `latestImage()` call keeps frames flowing.
    private static let demandWindow: CFTimeInterval = 1.0
    /// Frames older than this are treated as missing, so a zoom never opens on a stale
    /// picture from an earlier zoom — the caller falls back to a fresh snapshot.
    private static let freshnessWindow: CFTimeInterval = 0.5

    private let lock = NSLock()
    private let ciContext = CIContext()
    private var image: CGImage?
    private var lastFrameTime: CFTimeInterval = 0
    private var lastDemandTime: CFTimeInterval = 0

    func latestImage() -> CGImage? {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        lastDemandTime = now
        guard now - lastFrameTime < Self.freshnessWindow else { return nil }
        return image
    }

    func reset() {
        lock.lock()
        image = nil
        lastFrameTime = 0
        lastDemandTime = 0
        lock.unlock()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        // Cap at ~30fps to match the live-zoom preview refresh timer. The previous
        // 0.08s (~12.5fps) cap made magnified content visibly stutter and the cursor
        // ghost while the presenter moved during a zoom.
        let isTooSoon = now - lastFrameTime < (1.0 / 30.0)
        // Nobody has asked for a frame recently, so skip the conversion entirely.
        let isIdle = now - lastDemandTime > Self.demandWindow
        lock.unlock()
        guard !isTooSoon, !isIdle else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(
            ciImage,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        ) else {
            return
        }

        lock.lock()
        image = cgImage
        lastFrameTime = now
        lock.unlock()
    }
}

private extension NSScreen {
    var displayID: UInt32 {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    }
}

private final class CaptureServiceDelegateProxy: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    weak var owner: CaptureService?

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak owner] in
            owner?.handleStarted()
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak owner] in
            owner?.handleFailure(error)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak owner] in
            owner?.handleFinished()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak owner] in
            owner?.handleFailure(error)
        }
    }
}
