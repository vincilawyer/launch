import AppKit
import Combine
import ServiceManagement

/// Small, failure-tolerant wrapper around macOS' supported login-item API.
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var isAvailable = true
    @Published private(set) var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
            // `swift run` and unit tests do not have a login-item-capable bundle.
            isAvailable = false
            isEnabled = false
            requiresApproval = false
            return
        }

        apply(SMAppService.mainApp.status)
    }

    /// Requests the desired state and returns the effective state afterwards.
    /// Errors are surfaced for settings UI but never make application startup fail.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil

        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
            isAvailable = false
            isEnabled = false
            requiresApproval = false
            return false
        }

        let currentStatus = SMAppService.mainApp.status
        apply(currentStatus)

        // `.notFound` means ServiceManagement cannot resolve this app service.
        // Registration and unregistration are both unsafe/no-op in that state.
        guard isAvailable else { return false }

        do {
            switch (enabled, currentStatus) {
            case (true, .notRegistered):
                try SMAppService.mainApp.register()

            case (false, .enabled), (false, .requiresApproval):
                try SMAppService.mainApp.unregister()

            case (true, .enabled), (true, .requiresApproval), (false, .notRegistered):
                break

            case (_, .notFound):
                break

            @unknown default:
                // A future status must not trigger a potentially destructive
                // register/unregister operation until its semantics are known.
                break
            }
        } catch {
            lastError = error.localizedDescription
        }

        apply(SMAppService.mainApp.status)
        return isEnabled
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func apply(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered:
            isAvailable = true
            isEnabled = false
            requiresApproval = false

        case .enabled:
            isAvailable = true
            isEnabled = true
            requiresApproval = false

        case .requiresApproval:
            // The item is registered. Keep the toggle on while directing the
            // user to approve it in System Settings.
            isAvailable = true
            isEnabled = true
            requiresApproval = true

        case .notFound:
            isAvailable = false
            isEnabled = false
            requiresApproval = false

        @unknown default:
            isAvailable = false
            isEnabled = false
            requiresApproval = false
        }
    }
}
