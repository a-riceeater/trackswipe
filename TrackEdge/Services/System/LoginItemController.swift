import Foundation
import ServiceManagement
import os

/// "Open at Login" backed directly by `SMAppService.mainApp` (macOS 13+). The UI binds to `status`
/// read from the OS, never to a separately stored boolean.
enum LoginItemController {
    enum Status: Equatable, Sendable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)

        var isOn: Bool { self == .enabled || self == .requiresApproval }

        var description: String {
            switch self {
            case .enabled: return "Enabled"
            case .disabled: return "Off"
            case .requiresApproval: return "Waiting for approval in System Settings › Login Items"
            case let .unavailable(reason): return reason
            }
        }
    }

    private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "LoginItem")

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Registers/unregisters and returns the resulting OS status.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Status {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
            let current = status
            if current == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            if enabled && current == .disabled {
                return .unavailable("Could not register: \(error.localizedDescription)")
            }
            return current
        }
        let result = status
        if result == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return result
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
