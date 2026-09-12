import AppKit
import SwiftUI

enum LauncherKeyboardAction: Equatable {
    case left
    case right
    case up
    case down
    case activate
    case cancel
}

/// Captures navigation keys before a focused search field consumes them. The
/// monitor is scoped to the hosting window and leaves all text input untouched.
struct LauncherKeyboardMonitor: NSViewRepresentable {
    let perform: (LauncherKeyboardAction) -> Bool
    let windowDidDeactivate: () -> Void
    let windowDidActivate: () -> Void
    let windowScreenDidChange: (NSScreen?) -> Void

    init(
        perform: @escaping (LauncherKeyboardAction) -> Bool,
        windowDidDeactivate: @escaping () -> Void = {},
        windowDidActivate: @escaping () -> Void = {},
        windowScreenDidChange: @escaping (NSScreen?) -> Void = { _ in }
    ) {
        self.perform = perform
        self.windowDidDeactivate = windowDidDeactivate
        self.windowDidActivate = windowDidActivate
        self.windowScreenDidChange = windowScreenDidChange
    }

    func makeNSView(context: Context) -> LauncherKeyboardMonitorView {
        let view = LauncherKeyboardMonitorView()
        view.perform = perform
        view.windowDidDeactivate = windowDidDeactivate
        view.windowDidActivate = windowDidActivate
        view.windowScreenDidChange = windowScreenDidChange
        return view
    }

    func updateNSView(_ view: LauncherKeyboardMonitorView, context: Context) {
        view.perform = perform
        view.windowDidDeactivate = windowDidDeactivate
        view.windowDidActivate = windowDidActivate
        view.windowScreenDidChange = windowScreenDidChange
    }
}

final class LauncherKeyboardMonitorView: NSView {
    var perform: ((LauncherKeyboardAction) -> Bool)?
    var windowDidDeactivate: (() -> Void)?
    var windowDidActivate: (() -> Void)?
    var windowScreenDidChange: ((NSScreen?) -> Void)?
    private var eventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        removeWindowObservers()
        guard let window else { return }
        windowScreenDidChange?(window.screen)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let action = Self.action(for: event),
                  self.perform?(action) == true else {
                return event
            }
            return nil
        }

        let center = NotificationCenter.default
        windowObservers.append(
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                // Alerts are attached sheets. They temporarily take key status
                // without ending the launcher presentation and must not clear
                // the alert that caused the transition.
                guard window?.attachedSheet == nil else { return }
                self?.windowDidDeactivate?()
            }
        )
        windowObservers.append(
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.windowDidActivate?()
            }
        )
        windowObservers.append(
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                self?.windowScreenDidChange?(window?.screen)
            }
        )
        windowObservers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak window] _ in
                self?.windowScreenDidChange?(window?.screen)
            }
        )
        windowObservers.append(
            center.addObserver(
                forName: NSApplication.didHideNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                // Covers orderOut while an attached alert already owns key
                // status and therefore produces no second window-resign event.
                self?.windowDidDeactivate?()
            }
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        removeMonitor()
        removeWindowObservers()
    }

    private func removeMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
    }

    private static func action(for event: NSEvent) -> LauncherKeyboardAction? {
        switch event.keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        case 36, 76: .activate
        case 53: .cancel
        default: nil
        }
    }
}
