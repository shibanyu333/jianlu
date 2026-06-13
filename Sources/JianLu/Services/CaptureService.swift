@preconcurrency import AVFoundation
import CoreMedia
import Foundation
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
    private let delegateProxy = CaptureServiceDelegateProxy()

    override init() {
        super.init()
        delegateProxy.owner = self
    }

    func startDisplayRecording() async throws -> URL {
        let outputURL = try RecordingFileStore.makeRecordingURL(prefix: "screen")
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureServiceError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = max(1280, display.width)
        configuration.height = max(720, display.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 8
        configuration.showsCursor = true
        configuration.showMouseClicks = true
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .hevc

        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: delegateProxy)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegateProxy)
        try stream.addRecordingOutput(recordingOutput)

        self.stream = stream
        self.recordingOutput = recordingOutput
        try await stream.startCapture()
        isRecording = true
        lastErrorMessage = nil
        return outputURL
    }

    func stopDisplayRecording() async throws {
        guard let stream else {
            throw CaptureServiceError.notRecording
        }

        try await stream.stopCapture()
        self.stream = nil
        self.recordingOutput = nil
        isRecording = false
    }

    fileprivate func handleFailure(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        isRecording = false
    }

    fileprivate func handleStarted() {
        lastErrorMessage = nil
    }

    fileprivate func handleFinished() {
        isRecording = false
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
