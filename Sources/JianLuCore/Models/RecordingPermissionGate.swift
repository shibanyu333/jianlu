import Foundation

public struct RecordingPermissionState: Equatable, Sendable {
    public var screenRecordingGranted: Bool
    public var cameraGranted: Bool
    public var microphoneGranted: Bool

    public init(screenRecordingGranted: Bool, cameraGranted: Bool, microphoneGranted: Bool) {
        self.screenRecordingGranted = screenRecordingGranted
        self.cameraGranted = cameraGranted
        self.microphoneGranted = microphoneGranted
    }
}

public enum RecordingStartDecision: Equatable, Sendable {
    case allowed
    case needsScreenRecordingPermission
    case missingMediaPermissions([String])
}

public enum RecordingPermissionGate {
    public static func decision(
        for state: RecordingPermissionState,
        cameraEnabled: Bool,
        microphoneEnabled: Bool = true
    ) -> RecordingStartDecision {
        guard state.screenRecordingGranted else {
            return .needsScreenRecordingPermission
        }

        var missing: [String] = []
        if cameraEnabled && !state.cameraGranted {
            missing.append("摄像头")
        }
        if microphoneEnabled && !state.microphoneGranted {
            missing.append("麦克风")
        }

        if missing.isEmpty {
            return .allowed
        }
        return .missingMediaPermissions(missing)
    }
}
