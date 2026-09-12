import Foundation

/// The small subset of preferences that changes process-wide shell behavior.
/// Keeping this snapshot separate lets AppDelegate bootstrap the menu item and
/// Carbon registration without waiting for the application inventory scan.
struct ShellPreferenceSnapshot: Equatable, Sendable {
    let showMenuBarIcon: Bool
    let globalShortcut: LaunchShortcutDescriptor

    init(preferences: LaunchPreferences) {
        showMenuBarIcon = preferences.showMenuBarIcon
        globalShortcut = preferences.globalShortcut.normalized()
    }
}

/// Prevents an asynchronous disk bootstrap from overwriting a newer preference
/// value that the model has already published.
struct ShellPreferenceBootstrapGate: Sendable {
    typealias Revision = UInt64

    private(set) var revision: Revision = 0

    mutating func recordObservedPreference() {
        revision &+= 1
    }

    func acceptsBootstrap(capturedRevision: Revision) -> Bool {
        capturedRevision == revision
    }
}

/// Describes a rollback after Carbon rejected a newly requested shortcut.
/// `@Published` emits from `willSet`, so rollback decisions must use the value
/// carried by the publisher instead of reading the still-old model property.
struct ShellShortcutRollbackRequest: Equatable, Sendable {
    let failedDescriptor: LaunchShortcutDescriptor
    let restorationDescriptor: LaunchShortcutDescriptor

    static func make(
        failedDescriptor: LaunchShortcutDescriptor,
        activeDescriptor: LaunchShortcutDescriptor?
    ) -> ShellShortcutRollbackRequest? {
        guard let activeDescriptor = activeDescriptor?.normalized(),
              activeDescriptor != failedDescriptor.normalized() else {
            return nil
        }
        return ShellShortcutRollbackRequest(
            failedDescriptor: failedDescriptor.normalized(),
            restorationDescriptor: activeDescriptor
        )
    }

    func shouldApply(
        currentPreference: LaunchShortcutDescriptor,
        activeDescriptor: LaunchShortcutDescriptor?
    ) -> Bool {
        currentPreference.normalized() == failedDescriptor
            && activeDescriptor?.normalized() == restorationDescriptor
    }
}
