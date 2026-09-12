import Foundation

private struct ShellIntegrationCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func requireShellIntegration(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw ShellIntegrationCheckFailure(description: message)
    }
}

@main
private enum ShellIntegrationChecks {
    static func main() throws {
        try preferenceBootstrapNeverOvertakesNewerState()
        try shortcutFailureRollbackIsTransactional()
        print("Launch shell-integration checks passed (2/2)")
    }

    private static func preferenceBootstrapNeverOvertakesNewerState() throws {
        var gate = ShellPreferenceBootstrapGate()
        let initialRevision = gate.revision
        try requireShellIntegration(
            gate.acceptsBootstrap(capturedRevision: initialRevision),
            "An unchanged shell bootstrap was rejected"
        )

        gate.recordObservedPreference()
        try requireShellIntegration(
            !gate.acceptsBootstrap(capturedRevision: initialRevision),
            "A delayed disk bootstrap overwrote a newer published shell preference"
        )
        try requireShellIntegration(
            gate.acceptsBootstrap(capturedRevision: gate.revision),
            "The current shell bootstrap revision was not accepted"
        )
    }

    private static func shortcutFailureRollbackIsTransactional() throws {
        let active = LaunchShortcutDescriptor(
            keyCode: 12,
            modifiers: LaunchShortcutDescriptor.commandModifier,
            display: "⌘Q"
        )
        let failed = LaunchShortcutDescriptor(
            keyCode: 13,
            modifiers: LaunchShortcutDescriptor.optionModifier,
            display: "⌥W"
        )
        let replacement = LaunchShortcutDescriptor(
            keyCode: 14,
            modifiers: LaunchShortcutDescriptor.controlModifier,
            display: "⌃E"
        )
        guard let rollback = ShellShortcutRollbackRequest.make(
            failedDescriptor: failed,
            activeDescriptor: active
        ) else {
            throw ShellIntegrationCheckFailure(
                description: "A failed replacement did not create a rollback transaction"
            )
        }

        // This is the synchronous @Published/willSet frame: the model still
        // exposes the old value and must not be rewritten from inside its send.
        try requireShellIntegration(
            !rollback.shouldApply(
                currentPreference: active,
                activeDescriptor: active
            ),
            "Shortcut rollback ran inside the @Published willSet frame"
        )
        try requireShellIntegration(
            rollback.shouldApply(
                currentPreference: failed,
                activeDescriptor: active
            ),
            "A still-current failed shortcut was not restored transactionally"
        )
        try requireShellIntegration(
            !rollback.shouldApply(
                currentPreference: failed,
                activeDescriptor: replacement
            ),
            "A stale rollback overwrote a newer successful Carbon registration"
        )
        try requireShellIntegration(
            ShellShortcutRollbackRequest.make(
                failedDescriptor: active,
                activeDescriptor: active
            ) == nil,
            "Reapplying the active shortcut created a meaningless rollback"
        )
    }
}
