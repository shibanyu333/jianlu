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
            "没有找到可录制的显示器。"
        case .failedToAddRecordingOutput:
            "无法创建屏幕录制输出。"
        case .notRecording:
            "当前没有正在进行的屏幕录制。"
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
        region: RecordingRegion?,
        directoryPath: String?
    ) async throws -> URL {
        let outputURL = try RecordingFileStore.makeRecordingURL(prefix: "screen", directoryPath: directoryPath)
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
        configuration.width = max(80, Int(sourceRect == .zero ? Double(display.width) : sourceRect.width))
        configuration.height = max(80, Int(sourceRect == .zero ? Double(display.height) : sourceRect.height))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 8
        configuration.showsCursor = true
        configuration.showMouseClicks = true
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        let captureMicrophoneInScreenRecording = microphoneEnabled && !microphoneNoiseReductionEnabled
        configuration.captureMicrophone = captureMicrophoneInScreenRecording
        configuration.microphoneCaptureDeviceID = captureMicrophoneInScreenRecording ? AVCaptureDevice.default(for: .audio)?.uniqueID : nil

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .hevc

        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: delegateProxy)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegateProxy)
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
        return region.sourceRect(
            displayPixelWidth: Double(display.width),
            displayPixelHeight: Double(display.height),
            displayPointWidth: displayPointSize.width,
            displayPointHeight: displayPointSize.height
        )
    }

    private func pointSize(for display: SCDisplay) -> CGSize {
        let screen = NSScreen.screens.first { $0.displayID == display.displayID }
        return screen?.frame.size ?? CGSize(width: display.width, height: display.height)
    }

    func stopDisplayRecording() async throws {
        guard let stream else {
            throw CaptureServiceError.notRecording
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
        self.stream = nil
        self.recordingOutput = nil
        frameOutput.reset()
        isRecording = false
    }

    func latestScreenFrame() -> CGImage? {
        frameOutput.latestImage()
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

private final class LatestScreenFrameOutput: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private let ciContext = CIContext()
    private var image: CGImage?
    private var lastFrameTime: CFTimeInterval = 0

    func latestImage() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return image
    }

    func reset() {
        lock.lock()
        image = nil
        lastFrameTime = 0
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
        let shouldSkip = now - lastFrameTime < 0.08
        lock.unlock()
        guard !shouldSkip else { return }

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
