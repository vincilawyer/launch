import AppKit
import Carbon
import SwiftUI

@MainActor
struct LauncherGlobalShortcutEditor: View {
    @Binding var shortcut: LaunchShortcutDescriptor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRecording = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LaunchText.value("显示或隐藏启动台", "Show or hide 启动台"))
                        .font(.body)
                    Text(
                        shortcut.enabled
                            ? LaunchText.value(
                                "在任何应用中按下这个快捷键。",
                                "Press this shortcut from any application."
                            )
                            : LaunchText.value(
                                "全局快捷键已停用，仍可从菜单栏或应用程序文件夹打开启动台。",
                                "The global shortcut is off. You can still open 启动台 from the menu bar or Applications folder."
                            )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                shortcutCapsule

                if shortcut.enabled && !isRecording {
                    Button {
                        clearShortcut()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(LaunchText.value("清除快捷键", "Clear shortcut"))
                    .accessibilityLabel(
                        LaunchText.value("清除全局快捷键", "Clear global shortcut")
                    )
                }

                Button(
                    isRecording
                        ? LaunchText.value("取消", "Cancel")
                        : LaunchText.value("更改…", "Change…")
                ) {
                    validationMessage = nil
                    isRecording.toggle()
                }
                .controlSize(.small)
            }

            if !isDefaultShortcut || isRecording {
                HStack(spacing: 8) {
                    if !isDefaultShortcut {
                        Button(LaunchText.value("恢复默认", "Restore Default")) {
                            shortcut = .optionSpace
                            isRecording = false
                            validationMessage = nil
                        }
                    }

                    Spacer()

                    if isRecording {
                        Text(LaunchText.value("按 Esc 取消", "Press Esc to cancel"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }

            if isRecording {
                LauncherShortcutCaptureView(
                    record: record,
                    cancel: {
                        isRecording = false
                        validationMessage = nil
                    },
                    clear: {
                        clearShortcut()
                    },
                    invalid: {
                        validationMessage = LaunchText.value(
                            "普通按键需同时按住 Command、Option、Control 或 Shift；F 功能键可单独使用。",
                            "Use Command, Option, Control, or Shift with a regular key. Function keys can be used alone."
                        )
                    }
                )
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isRecording
        )
    }

    private var isDefaultShortcut: Bool {
        let value = shortcut.normalized()
        let defaultValue = LaunchShortcutDescriptor.optionSpace
        return value.enabled == defaultValue.enabled
            && value.keyCode == defaultValue.keyCode
            && value.modifiers == defaultValue.modifiers
    }

    private func clearShortcut() {
        shortcut = .disabled
        isRecording = false
        validationMessage = nil
    }

    private var shortcutCapsule: some View {
        Text(
            isRecording
                ? LaunchText.value("请按新快捷键", "Press new shortcut")
                : shortcut.enabled
                    ? shortcut.displayName
                    : LaunchText.value("未设置", "Not Set")
        )
        .font(.system(.callout, design: .rounded, weight: .semibold))
        .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
        .padding(.horizontal, 10)
        .frame(minWidth: 74, minHeight: 28)
        .background(
            isRecording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isRecording ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        }
        .accessibilityLabel(
            shortcut.enabled
                ? LaunchText.value("当前快捷键：\(shortcut.displayName)", "Current shortcut: \(shortcut.displayName)")
                : LaunchText.value("快捷键未设置", "Shortcut not set")
        )
    }

    private func record(_ event: NSEvent) {
        guard let descriptor = LauncherShortcutEventFormatter.descriptor(for: event) else {
            validationMessage = LaunchText.value(
                "这个按键组合不能用作全局快捷键。",
                "That key combination cannot be used as a global shortcut."
            )
            return
        }
        shortcut = descriptor
        isRecording = false
        validationMessage = nil
    }
}

@MainActor
private struct LauncherShortcutCaptureView: NSViewRepresentable {
    let record: (NSEvent) -> Void
    let cancel: () -> Void
    let clear: () -> Void
    let invalid: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        configure(view)
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        configure(view)
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    private func configure(_ view: CaptureView) {
        view.onWindowDeactivated = cancel
        view.onKeyDown = { event in
            if event.keyCode == UInt16(kVK_Escape) {
                cancel()
            } else if event.keyCode == UInt16(kVK_Delete)
                        || event.keyCode == UInt16(kVK_ForwardDelete) {
                clear()
            } else if LauncherShortcutEventFormatter.isValid(event) {
                record(event)
            } else {
                invalid()
            }
        }
    }

    final class CaptureView: NSView {
        var onKeyDown: ((NSEvent) -> Void)?
        var onWindowDeactivated: (() -> Void)?
        private var windowObservers: [NSObjectProtocol] = []

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeWindowObservers()
            guard let window else { return }

            let center = NotificationCenter.default
            for name in [
                NSWindow.didResignKeyNotification,
                NSWindow.willCloseNotification,
            ] {
                windowObservers.append(
                    center.addObserver(
                        forName: name,
                        object: window,
                        queue: .main
                    ) { [weak self] _ in
                        self?.onWindowDeactivated?()
                    }
                )
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }

        deinit {
            // `deinit` is nonisolated even though NSView is main-actor bound;
            // remove the opaque tokens inline so this stays Swift 6 clean.
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        override func keyDown(with event: NSEvent) {
            onKeyDown?(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // Command-key combinations normally reach the app/window menu
            // before `keyDown`. While recording, consume them here so ⌘Q,
            // ⌘W, ⌘, and similar valid shortcuts are captured instead of
            // quitting, closing the window, or opening another command.
            onKeyDown?(event)
            return true
        }

        private func removeWindowObservers() {
            let center = NotificationCenter.default
            windowObservers.forEach(center.removeObserver)
            windowObservers.removeAll()
        }
    }
}

private enum LauncherShortcutEventFormatter {
    static func isValid(_ event: NSEvent) -> Bool {
        let modifiers = relevantModifiers(event.modifierFlags)
        return modifiers != 0 || isFunctionKey(event.keyCode)
    }

    static func descriptor(for event: NSEvent) -> LaunchShortcutDescriptor? {
        guard isValid(event), let key = keyDisplay(for: event) else { return nil }
        let modifiers = relevantModifiers(event.modifierFlags)
        return LaunchShortcutDescriptor(
            enabled: true,
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            display: modifierDisplay(event.modifierFlags) + key
        )
    }

    private static func relevantModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private static func modifierDisplay(_ flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    private static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeyNames[keyCode] != nil
    }

    private static func keyDisplay(for event: NSEvent) -> String? {
        if let functionName = functionKeyNames[event.keyCode] {
            return functionName
        }

        switch Int(event.keyCode) {
        case kVK_Space:
            return LaunchText.value("空格", "Space")
        case kVK_Return:
            return "↩"
        case kVK_Tab:
            return "⇥"
        case kVK_LeftArrow:
            return "←"
        case kVK_RightArrow:
            return "→"
        case kVK_UpArrow:
            return "↑"
        case kVK_DownArrow:
            return "↓"
        case kVK_Home:
            return "Home"
        case kVK_End:
            return "End"
        case kVK_PageUp:
            return "Page Up"
        case kVK_PageDown:
            return "Page Down"
        default:
            let text = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            return text?.isEmpty == false ? text : nil
        }
    }

    private static let functionKeyNames: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2",
        UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14",
        UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20"
    ]
}
