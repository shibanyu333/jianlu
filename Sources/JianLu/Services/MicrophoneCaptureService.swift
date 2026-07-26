import AVFoundation
import Foundation
import JianLuCore

enum MicrophoneCaptureError: LocalizedError {
    case alreadyRecording
    case notRecording
    case cannotCreateAudioFile

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            tr("麦克风正在录制中。", "The microphone is already recording.")
        case .notRecording:
            tr("当前没有正在进行的麦克风录制。", "No microphone recording is running.")
        case .cannotCreateAudioFile:
            tr("无法创建麦克风音频文件。", "Could not create the microphone audio file.")
        }
    }
}

@MainActor
final class MicrophoneCaptureService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastErrorMessage: String?
    /// Set when the realtime audio writer dropped samples during the take; read by
    /// the recording controller after stop so silent audio loss isn't hidden.
    private(set) var lastWriteFailureMessage: String?

    private let engine = AVAudioEngine()
    private var outputWriter: MicrophoneSampleWriter?
    private(set) var currentOutputURL: URL?

    var hasActiveRecording: Bool {
        isRecording
    }

    func startRecording(preferences: RecordingPreferences) throws -> URL {
        guard !isRecording else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        let outputURL = try RecordingFileStore.makeRecordingURL(
            prefix: "microphone",
            extension: "caf",
            directoryPath: preferences.recordingDirectoryPath
        )

        let input = engine.inputNode
        lastErrorMessage = nil
        lastWriteFailureMessage = nil
        do {
            if preferences.microphoneNoiseReductionEnabled {
                do {
                    try input.setVoiceProcessingEnabled(true)
                } catch {
                    lastErrorMessage = tr("当前麦克风不支持系统降噪，已继续使用普通麦克风录制。", "This microphone does not support system noise reduction; recording continues without it.")
                }
            } else {
                try? input.setVoiceProcessingEnabled(false)
            }

            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0 else {
                throw MicrophoneCaptureError.cannotCreateAudioFile
            }

            let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
            let writer = MicrophoneSampleWriter(file: file)
            outputWriter = writer
            currentOutputURL = outputURL

            input.removeTap(onBus: 0)
            input.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: format,
                block: makeMicrophoneTapBlock(writer: writer)
            )

            try engine.start()
            isRecording = true
            return outputURL
        } catch {
            cleanupAfterFailedStart(outputURL: outputURL)
            throw error
        }
    }

    func stopRecording() throws {
        guard isRecording else {
            throw MicrophoneCaptureError.notRecording
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let writeFailure = outputWriter?.firstWriteFailure {
            lastWriteFailureMessage = "麦克风录音写入失败，部分讲解声音可能缺失：\(writeFailure.localizedDescription)"
        }
        outputWriter = nil
        currentOutputURL = nil
        isRecording = false
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    private func cleanupAfterFailedStart(outputURL: URL) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputWriter = nil
        currentOutputURL = nil
        isRecording = false
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        try? FileManager.default.removeItem(at: outputURL)
    }
}

private final class MicrophoneSampleWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let failureLock = NSLock()
    private var storedFailure: Error?

    init(file: AVAudioFile) {
        self.file = file
    }

    /// The first write error seen on the realtime audio tap thread, if any.
    var firstWriteFailure: Error? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return storedFailure
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        do {
            try file.write(from: buffer)
        } catch {
            // Runs on the realtime audio thread: don't touch the main actor here,
            // just remember the first failure so stopRecording can surface it.
            failureLock.lock()
            if storedFailure == nil {
                storedFailure = error
            }
            failureLock.unlock()
        }
    }
}

private func makeMicrophoneTapBlock(writer: MicrophoneSampleWriter) -> AVAudioNodeTapBlock {
    { buffer, _ in
        writer.write(buffer)
    }
}
