import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import JianLuCore

/// One selectable capture device.
///
/// `id` is the AVFoundation `uniqueID`, which is deliberately the only identifier the
/// app persists: it is what `AVCaptureDeviceInput` needs for the camera, what
/// `SCStreamConfiguration.microphoneCaptureDeviceID` needs for the screen recorder's
/// microphone track, and — on macOS an audio device's `uniqueID` *is* its CoreAudio
/// UID — what resolves to the `AudioDeviceID` the noise-reduced `AVAudioEngine` path
/// needs. One stored string, three capture paths.
struct MediaDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// The live list of cameras and microphones the user can pick from, refreshed whenever
/// hardware is plugged or unplugged.
@MainActor
final class MediaDeviceCatalog: ObservableObject {
    static let shared = MediaDeviceCatalog()

    @Published private(set) var cameras: [MediaDevice] = []
    @Published private(set) var microphones: [MediaDevice] = []

    /// `.external` is what a Continuity Camera iPhone actually reports on macOS 15,
    /// so it has to be listed alongside `.continuityCamera`.
    private static let cameraDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .external,
        .continuityCamera,
        .deskViewCamera
    ]

    private static let microphoneDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .microphone,
        .external
    ]

    /// There is exactly one catalog, alive for the whole process, so its device-change
    /// observers never need tearing down.
    private init() {
        refresh()
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    MediaDeviceCatalog.shared.refresh()
                }
            }
        }
    }

    /// Re-reads both device lists. Cheap enough to call whenever a settings pane
    /// appears — CoreAudio-only changes (a default input swap) never post an
    /// `AVCaptureDevice` notification.
    func refresh() {
        cameras = Self.devices(types: Self.cameraDeviceTypes, mediaType: .video)
        microphones = Self.devices(types: Self.microphoneDeviceTypes, mediaType: .audio)
    }

    /// The display name for a stored ID, or `nil` when that device is not plugged in
    /// right now. Callers use `nil` to tell the user their pick is unavailable instead
    /// of silently pretending the default device was what they chose.
    func name(forCameraID id: String) -> String? {
        cameras.first { $0.id == id }?.name
    }

    func name(forMicrophoneID id: String) -> String? {
        microphones.first { $0.id == id }?.name
    }

    private static func devices(
        types: [AVCaptureDevice.DeviceType],
        mediaType: AVMediaType
    ) -> [MediaDevice] {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: mediaType,
            position: .unspecified
        ).devices

        var seen = Set<String>()
        return discovered.compactMap { device in
            guard device.isConnected, seen.insert(device.uniqueID).inserted else { return nil }
            return MediaDevice(id: device.uniqueID, name: device.localizedName)
        }
    }
}

// MARK: - Resolution

extension MediaDeviceCatalog {
    /// The camera to record with: the user's pick when it is connected, otherwise
    /// whatever macOS considers the default so a missing device degrades to a working
    /// recording rather than to no camera at all.
    static func camera(preferredID: String?) -> AVCaptureDevice? {
        device(preferredID: preferredID, mediaType: .video) ?? AVCaptureDevice.default(for: .video)
    }

    static func microphone(preferredID: String?) -> AVCaptureDevice? {
        device(preferredID: preferredID, mediaType: .audio) ?? AVCaptureDevice.default(for: .audio)
    }

    /// Whether a stored pick is currently usable. `nil` (follow the system) always is.
    static func isAvailable(preferredID: String?, mediaType: AVMediaType) -> Bool {
        guard let preferredID, !preferredID.isEmpty else { return true }
        return device(preferredID: preferredID, mediaType: mediaType) != nil
    }

    private static func device(preferredID: String?, mediaType: AVMediaType) -> AVCaptureDevice? {
        guard let preferredID, !preferredID.isEmpty else { return nil }
        guard let device = AVCaptureDevice(uniqueID: preferredID),
              device.hasMediaType(mediaType),
              device.isConnected else { return nil }
        return device
    }

    /// `uniqueID` of whatever macOS currently treats as the default input.
    static func systemDefaultMicrophoneID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    /// Whether a CoreAudio device can back `AVAudioEngine`'s voice-processing unit.
    ///
    /// The engine's input and output nodes share one duplex audio unit
    /// (`inputNode.auAudioUnit === outputNode.auAudioUnit`, verified at runtime), so
    /// forcing it onto a microphone with no output streams cannot work: measured on
    /// macOS 15, `setDeviceID` either refuses with `-10851` or the engine throws
    /// `-10875` initializing the output node. Checking the streams up front turns that
    /// into a clear message and a clean fallback instead of an OSStatus.
    static func canBackVoiceProcessing(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// Translates an AVFoundation audio `uniqueID` into the CoreAudio `AudioDeviceID`
    /// that `AUAudioUnit.setDeviceID` wants. Returns `nil` when the device is gone.
    static func audioDeviceID(forUniqueID uniqueID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uniqueID as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }
}
