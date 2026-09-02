import AudioToolbox
import AVFoundation
import Foundation
import JianLuCore

enum MicrophoneCaptureError: LocalizedError {
    case alreadyRecording
    case notRecording
    case cannotCreateAudioFile
    /// The chosen microphone cannot drive the voice-processing unit, so this take has
    /// to go down the plain ScreenCaptureKit path — which records that microphone
    /// perfectly well, just without system noise reduction.
    case deviceCannotDoNoiseReduction(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            tr("麦克风正在录制中。", "The microphone is already recording.")
        case .notRecording:
            tr("当前没有正在进行的麦克风录制。", "No microphone recording is running.")
        case .cannotCreateAudioFile:
            tr("无法创建麦克风音频文件。", "Could not create the microphone audio file.")
        case .deviceCannotDoNoiseReduction(let name):
            tr("「", "\"") + name + tr("」不支持系统降噪（降噪需要麦克风同时是输出设备）。", "\" cannot do system noise reduction (it needs a microphone that is also an output device).")
        }
    }
}

@MainActor
final class MicrophoneCaptureService: ObservableObject {
    @Published private(set) var isRecording = false
    /// Non-fatal problems from the last start — a missing microphone, a device the
    /// engine refused, noise reduction the hardware cannot do. The recording controller
    /// shows all of them; a take that quietly used the wrong microphone is worse than
    /// a take with a warning on it.
    private(set) var startupWarnings: [String] = []
    /// Set when the realtime audio writer dropped samples during the take; read by
    /// the recording controller after stop so silent audio loss isn't hidden.
    private(set) var lastWriteFailureMessage: String?

    /// Rebuilt for every take. The engine's audio unit keeps whatever device it was
    /// last pointed at, so reusing one instance would leave a later "follow the system
    /// default" take still recording the device the previous take picked.
    private var engine = AVAudioEngine()
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

        engine = AVAudioEngine()
        let input = engine.inputNode
        startupWarnings = []
        lastWriteFailureMessage = nil
        do {
            if preferences.microphoneNoiseReductionEnabled {
                do {
                    try input.setVoiceProcessingEnabled(true)
                } catch {
                    startupWarnings.append(tr("当前麦克风不支持系统降噪，已继续使用普通麦克风录制。", "This microphone does not support system noise reduction; recording continues without it."))
                }
            } else {
                try? input.setVoiceProcessingEnabled(false)
            }

            // Must happen after voice processing is toggled (that swaps the underlying
            // audio unit and takes the device with it) and before the format is read
            // (the format is the device's).
            try selectInputDevice(preferences.microphoneDeviceID)

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

    /// Points the engine at the chosen input device.
    ///
    /// Two things make this narrower than it looks. The engine's input and output nodes
    /// are one shared duplex unit, so `setDeviceID` sets *both* scopes — a microphone
    /// with no output streams cannot be its device at all. And left alone, that unit
    /// already pairs the default input with the default output, which is the only
    /// arrangement in which every plain microphone gets noise reduction. So: when the
    /// pick is already the system default, don't touch the engine; when it is a device
    /// the unit cannot drive, bail out to the plain capture path, which records that
    /// microphone fine and only loses noise reduction.
    private func selectInputDevice(_ deviceID: String?) throws {
        let requestedID = (deviceID?.isEmpty ?? true) ? nil : deviceID
        guard let resolved = MediaDeviceCatalog.microphone(preferredID: requestedID) else {
            startupWarnings.append(tr("没有找到可用麦克风，本次讲解声音可能缺失。", "No microphone available — this take may have no narration."))
            return
        }
        if let requestedID, resolved.uniqueID != requestedID {
            startupWarnings.append(
                tr("所选麦克风已断开，本次改用系统默认麦克风「", "The selected microphone is disconnected — recording with the system default \"")
                    + resolved.localizedName
                    + tr("」。", "\" instead.")
            )
        }
        guard resolved.uniqueID != MediaDeviceCatalog.systemDefaultMicrophoneID() else { return }

        guard let audioDeviceID = MediaDeviceCatalog.audioDeviceID(forUniqueID: resolved.uniqueID) else {
            startupWarnings.append(tr("无法切换到所选麦克风，本次使用系统当前输入设备。", "Could not switch to that microphone — recording with the system's current input instead."))
            return
        }
        guard MediaDeviceCatalog.canBackVoiceProcessing(audioDeviceID) else {
            throw MicrophoneCaptureError.deviceCannotDoNoiseReduction(resolved.localizedName)
        }
        try engine.inputNode.auAudioUnit.setDeviceID(audioDeviceID)
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
