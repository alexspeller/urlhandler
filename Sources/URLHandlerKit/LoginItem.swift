import Foundation
import ServiceManagement

/// Registers the app to launch at login via SMAppService (macOS 13+), so the agent is always
/// resident and even the first click after a reboot is handled instantly.
public enum LoginItem {
    public static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    public static func register() throws {
        try SMAppService.mainApp.register()
    }

    public static func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval in System Settings"
        case .notFound: return "not found (run from the installed .app)"
        @unknown default: return "unknown"
        }
    }
}
