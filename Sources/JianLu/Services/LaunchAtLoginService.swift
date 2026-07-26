import Foundation
import JianLuCore
import ServiceManagement
import os

/// Launch-at-login, backed by `SMAppService` — macOS owns the truth here (the user can
/// also flip it in System Settings › General › Login Items), so this reads the live
/// status instead of persisting a preference that could drift out of sync.
@MainActor
enum LaunchAtLoginService {
    private static let logger = Logger(subsystem: "com.local.JianLu", category: "LoginItem")

    enum State {
        case enabled
        case disabled
        /// Registered, but macOS still wants the user to approve it in System Settings.
        case requiresApproval

        var isOn: Bool {
            self != .disabled
        }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        default:
            .disabled
        }
    }

    /// Returns an error message to show the user, or nil on success.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status != .notRegistered else { return nil }
                try SMAppService.mainApp.unregister()
            }
            logger.info("Login item set to \(enabled)")
            return nil
        } catch {
            logger.warning("Login item change failed: \(error.localizedDescription, privacy: .public)")
            return tr("无法修改开机自启动：", "Could not change the login item: ") + error.localizedDescription
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
