@preconcurrency import AVFoundation
import Foundation

enum CameraCaptureError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case notRecording

    var errorDescription: String? {
        switch self {
        case .noCamera:
            "没有找到可用摄像头。"
        case .cannotAddInput:
            "无法接入摄像头。"
        case .cannotAddOutput:
            "无法创建摄像头录制输出。"
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
    private let movieOutput = AVCaptureMovieFileOutput()
    private let delegateProxy = CameraCaptureDelegateProxy()
    private var configured = false
    private(set) var currentOutputURL: URL?

    override init() {
        super.init()
        delegateProxy.owner = self
    }

    var previewSession: AVCaptureSession {
        session
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

        guard session.canAddOutput(movieOutput) else {
            session.commitConfiguration()
            throw CameraCaptureError.cannotAddOutput
        }
        session.addOutput(movieOutput)

        session.commitConfiguration()
        configured = true
    }

    func startPreviewIfNeeded() {
        do {
            try configureIfNeeded()
            if !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [session] in
                    session.startRunning()
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func startRecording() throws -> URL {
        try configureIfNeeded()
        if !session.isRunning {
            session.startRunning()
        }

        let outputURL = try RecordingFileStore.makeRecordingURL(prefix: "camera")
        currentOutputURL = outputURL
        movieOutput.startRecording(to: outputURL, recordingDelegate: delegateProxy)
        isRecording = true
        lastErrorMessage = nil
        return outputURL
    }

    func stopRecording() throws {
        guard movieOutput.isRecording else {
            throw CameraCaptureError.notRecording
        }
        movieOutput.stopRecording()
    }

    fileprivate func handleFinished(error: Error?) {
        if let error {
            lastErrorMessage = error.localizedDescription
        }
        isRecording = false
    }
}

private final class CameraCaptureDelegateProxy: NSObject, AVCaptureFileOutputRecordingDelegate {
    weak var owner: CameraCaptureService?

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor [weak owner] in
            owner?.handleFinished(error: error)
        }
    }
}
