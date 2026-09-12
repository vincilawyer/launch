import Carbon
import Foundation

/// Registers system-wide shortcuts without requiring Accessibility permission.
///
/// Registration can fail when another application or macOS already owns a
/// shortcut. `apply` reports a recoverable error and deliberately keeps the
/// previous registration alive in that case.
@MainActor
final class HotKeyManager: @unchecked Sendable {
    enum RegistrationError: Error, Equatable, Sendable {
        case eventHandlerUnavailable
        case invalidShortcut
        case registrationFailed(OSStatus)
    }

    typealias Handler = @MainActor @Sendable () -> Void

    private static let signature: OSType = 0x4C_4E_43_48 // "LNCH"

    private struct Registration {
        let descriptor: LaunchShortcutDescriptor
        let identifier: UInt32
        let reference: EventHotKeyRef
        let handler: Handler
    }

    private var eventHandler: EventHandlerRef?
    private var registration: Registration?
    private var nextIdentifier: UInt32 = 1

    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]
    private static let modifierOnlyKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_Shift), UInt32(kVK_CapsLock),
        UInt32(kVK_Option), UInt32(kVK_Control), UInt32(kVK_RightShift),
        UInt32(kVK_RightOption), UInt32(kVK_RightControl), UInt32(kVK_Function),
    ]

    init() {
        installEventHandler()
    }

    deinit {
        if let registration {
            UnregisterEventHotKey(registration.reference)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    var activeDescriptor: LaunchShortcutDescriptor? {
        registration?.descriptor
    }

    /// Atomically applies a configurable shortcut. A new combination is
    /// registered before the old reference is removed, so a conflict or Carbon
    /// failure leaves the previously working shortcut intact.
    @discardableResult
    func apply(
        _ proposedDescriptor: LaunchShortcutDescriptor,
        handler: @escaping Handler
    ) -> Result<LaunchShortcutDescriptor, RegistrationError> {
        let descriptor = proposedDescriptor.normalized()
        guard descriptor.enabled else {
            unregister()
            return .success(descriptor)
        }
        guard Self.isValid(descriptor) else { return .failure(.invalidShortcut) }
        guard eventHandler != nil else { return .failure(.eventHandlerUnavailable) }

        if let existing = registration,
           existing.descriptor.keyCode == descriptor.keyCode,
           existing.descriptor.modifiers == descriptor.modifiers {
            registration = Registration(
                descriptor: descriptor,
                identifier: existing.identifier,
                reference: existing.reference,
                handler: handler
            )
            return .success(descriptor)
        }

        let identifierValue = nextIdentifier
        nextIdentifier &+= 1
        if nextIdentifier == 0 { nextIdentifier = 1 }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(
            signature: Self.signature,
            id: identifierValue
        )
        let status = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            return .failure(.registrationFailed(status))
        }

        let previous = registration
        registration = Registration(
            descriptor: descriptor,
            identifier: identifierValue,
            reference: reference,
            handler: handler
        )
        if let previous {
            UnregisterEventHotKey(previous.reference)
        }
        return .success(descriptor)
    }

    func unregister() {
        if let registration {
            UnregisterEventHotKey(registration.reference)
        }
        registration = nil
    }

    static func isValid(_ descriptor: LaunchShortcutDescriptor) -> Bool {
        guard descriptor.enabled,
              descriptor.keyCode <= 127,
              !modifierOnlyKeyCodes.contains(descriptor.keyCode),
              descriptor.modifiers & ~LaunchShortcutDescriptor.allowedModifierMask == 0 else {
            return false
        }
        if functionKeyCodes.contains(descriptor.keyCode) {
            return true
        }
        // Bare letters, digits, Space, Escape, Return, Tab, Delete and arrows
        // would steal ordinary input or navigation. All non-function keys must
        // therefore include at least one conventional modifier.
        return descriptor.modifiers != 0
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            launchHotKeyEventHandler,
            1,
            &eventType,
            userData,
            &eventHandler
        )

        if status != noErr {
            eventHandler = nil
        }
    }

    private func invoke(identifier: EventHotKeyID) {
        guard identifier.signature == Self.signature,
              let registration,
              registration.identifier == identifier.id else {
            return
        }
        registration.handler()
    }

    fileprivate nonisolated func receive(identifier: EventHotKeyID) {
        Task { @MainActor [weak self] in
            self?.invoke(identifier: identifier)
        }
    }
}

private let launchHotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }

    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.receive(identifier: identifier)
    return noErr
}
