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
            "麦克风正在录制中。"
        case .notRecording:
            "当前没有正在进行的麦克风录制。"
        case .cannotCreateAudioFile:
            "无法创建麦克风音频文件。"
        }
    }
}

@MainActor
final class MicrophoneCaptureService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var lastErrorMessage: String?

    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
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
        do {
            if preferences.microphoneNoiseReductionEnabled {
                do {
                    try input.setVoiceProcessingEnabled(true)
                } catch {
                    lastErrorMessage = "当前麦克风不支持系统降噪，已继续使用普通麦克风录制。"
                }
            } else {
                try? input.setVoiceProcessingEnabled(false)
            }

            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0 else {
                throw MicrophoneCaptureError.cannotCreateAudioFile
            }

            let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
            outputFile = file
            currentOutputURL = outputURL

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [file] buffer, _ in
                try? file.write(from: buffer)
            }

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
        outputFile = nil
        currentOutputURL = nil
        isRecording = false
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    private func cleanupAfterFailedStart(outputURL: URL) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        outputFile = nil
        currentOutputURL = nil
        isRecording = false
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        try? FileManager.default.removeItem(at: outputURL)
    }
}
