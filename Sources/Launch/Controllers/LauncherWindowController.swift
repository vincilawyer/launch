import AppKit
import QuartzCore
import SwiftUI

/// Borderless key-capable panel used for the Launch grid.
private final class LauncherPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

}

/// A non-activating top-edge shield. It sits above the system menu/status bar,
/// but its frame is only the menu-bar strip, so the Dock remains untouched.
private final class LauncherMenuBarCoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private struct LauncherMenuBarCoverContent: View {
    let screen: NSScreen

    var body: some View {
        let screenSize = screen.frame.size
        GeometryReader { _ in
            // Render the exact full-screen launcher backdrop and crop its top
            // edge. This keeps wallpaper aspect-fill, blur, material and
            // gradients continuous across the separate cover window.
            LauncherBackdrop(screen: screen)
                .frame(width: screenSize.width, height: screenSize.height)
                .position(x: screenSize.width / 2, y: screenSize.height / 2)
        }
        .clipped()
        .preferredColorScheme(.dark)
    }
}

@MainActor
private final class LauncherMenuBarCoverView: NSView {
    var onClick: (() -> Void)?

    private let hostingView: NSHostingView<AnyView>

    init(screen: NSScreen) {
        hostingView = NSHostingView(
            rootView: AnyView(LauncherMenuBarCoverContent(screen: screen))
        )
        super.init(frame: .zero)

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}

/// Public AppKit raw-touch surface for exact local finger counting. It wraps
/// the hosting view, so unhandled trackpad touches rise through the responder
/// chain without changing mouse/keyboard hit testing.
private final class LauncherTouchCaptureView: NSView {
    var onTouches: (([TrackpadTouchSample], TrackpadTouchPhase, TimeInterval) -> Void)?
    private var stableIDs: [StableTouchIdentityKey: Int] = [:]
    private var nextStableID = 1

    init(contentView: NSView) {
        super.init(frame: .zero)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func touchesBegan(with event: NSEvent) {
        emitTouches(from: event, phase: .began)
        super.touchesBegan(with: event)
    }

    override func touchesMoved(with event: NSEvent) {
        emitTouches(from: event, phase: .changed)
        super.touchesMoved(with: event)
    }

    override func touchesEnded(with event: NSEvent) {
        emitTouches(from: event, phase: .ended)
        super.touchesEnded(with: event)
    }

    override func touchesCancelled(with event: NSEvent) {
        emitTouches(from: event, phase: .cancelled)
        resetStableIDs()
        super.touchesCancelled(with: event)
    }

    private func emitTouches(from event: NSEvent, phase: TrackpadTouchPhase) {
        let samples = event.touches(matching: .touching, in: self).map { touch in
            let identity = StableTouchIdentityKey(touch.identity)
            let stableID: Int
            if let existing = stableIDs[identity] {
                stableID = existing
            } else {
                stableID = nextStableID
                nextStableID += 1
                stableIDs[identity] = stableID
            }
            return TrackpadTouchSample(
                id: stableID,
                x: Double(touch.normalizedPosition.x),
                y: Double(touch.normalizedPosition.y)
            )
        }
        onTouches?(samples, phase, event.timestamp)
        if samples.isEmpty {
            resetStableIDs()
        }
    }

    private func resetStableIDs() {
        stableIDs.removeAll(keepingCapacity: true)
        nextStableID = 1
    }
}

@MainActor
final class LauncherWindowController: NSWindowController, NSWindowDelegate {
    var onDismiss: (() -> Void)?
    var onKeyStatusChanged: ((Bool) -> Void)?
    var onTrackpadTouches: (([TrackpadTouchSample], TrackpadTouchPhase, TimeInterval) -> Void)? {
        didSet { touchCaptureView?.onTouches = onTrackpadTouches }
    }

    private weak var touchCaptureView: LauncherTouchCaptureView?
    private var menuBarCoverWindow: LauncherMenuBarCoverPanel?
    private var menuBarCoverTransitionGeneration: UInt64 = 0
    private var transitionGeneration: UInt64 = 0

    init<Content: View>(rootView: Content) {
        let panel = LauncherPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
        ]
        // Keep Launch above ordinary application windows without covering the
        // Dock. On macOS the modal-panel level is 8, below the Dock level (20),
        // while mainMenu + 1 is 25 and therefore obscures a visible Dock.
        panel.level = LauncherWindowLevelPolicy.launcher
        let hostingController = NSHostingController(rootView: AnyView(rootView))
        let touchCaptureView = LauncherTouchCaptureView(contentView: hostingController.view)
        let containerController = NSViewController()
        containerController.addChild(hostingController)
        containerController.view = touchCaptureView
        panel.contentViewController = containerController

        super.init(window: panel)
        self.touchCaptureView = touchCaptureView
        panel.delegate = self
        panel.onCancel = { [weak self] in
            self?.onDismiss?()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    var isPresented: Bool {
        window?.isVisible == true
    }

    func setMenuBarCoverVisible(_ isVisible: Bool) {
        guard isVisible,
              let screen = window?.screen ?? NSScreen.main else {
            menuBarCoverTransitionGeneration &+= 1
            menuBarCoverWindow?.orderOut(nil)
            menuBarCoverWindow?.alphaValue = 1
            return
        }

        let cover = menuBarCoverWindow ?? makeMenuBarCoverWindow()
        menuBarCoverWindow = cover
        let wasVisible = cover.isVisible
        let coverFrame = MenuBarCoverGeometry.frame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top
        )
        cover.setFrame(coverFrame, display: true)
        let coverView = LauncherMenuBarCoverView(screen: screen)
        coverView.onClick = { [weak self] in
            self?.onDismiss?()
        }
        cover.contentView = coverView
        menuBarCoverTransitionGeneration &+= 1
        let generation = menuBarCoverTransitionGeneration
        if !wasVisible {
            cover.alphaValue = NSWorkspace.shared
                .accessibilityDisplayShouldReduceMotion ? 1 : 0
        }
        cover.orderFront(nil)

        guard !wasVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            cover.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cover.animator().alphaValue = 1
        } completionHandler: { [weak self, weak cover] in
            Task { @MainActor in
                guard let self,
                      self.menuBarCoverTransitionGeneration == generation,
                      let cover,
                      cover.isVisible else { return }
                cover.alphaValue = 1
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onKeyStatusChanged?(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        onKeyStatusChanged?(false)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if menuBarCoverWindow?.isVisible == true {
            setMenuBarCoverVisible(true)
        }
    }

    func show(on screen: NSScreen? = nil) {
        guard let window else { return }
        transitionGeneration &+= 1
        let generation = transitionGeneration
        let wasVisible = window.isVisible
        let targetScreen = screen ?? Self.screenContainingMouse() ?? NSScreen.main
        if let targetScreen {
            window.setFrame(targetScreen.frame, display: true)
        }

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !wasVisible {
            window.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        }
        window.makeKeyAndOrderFront(nil)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              window.alphaValue < 0.999 else {
            window.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let self,
                      self.transitionGeneration == generation,
                      let window,
                      window.isVisible else { return }
                window.alphaValue = 1
            }
        }
    }

    func hide(animated: Bool = true, completion: (() -> Void)? = nil) {
        setMenuBarCoverVisible(false)
        guard let window, window.isVisible else {
            completion?()
            return
        }
        transitionGeneration &+= 1
        let generation = transitionGeneration

        let finish = { [weak self, weak window] in
            guard let self,
                  self.transitionGeneration == generation,
                  let window else { return }
            window.orderOut(nil)
            window.alphaValue = 1
            completion?()
        }

        guard animated,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              window.alphaValue > 0.001 else {
            finish()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in finish() }
        }
    }

    func toggle() {
        if isPresented {
            onDismiss?()
        } else {
            show()
        }
    }

    private static func screenContainingMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    private func makeMenuBarCoverWindow() -> LauncherMenuBarCoverPanel {
        let cover = LauncherMenuBarCoverPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        cover.backgroundColor = .black
        cover.isOpaque = true
        cover.hasShadow = false
        cover.hidesOnDeactivate = true
        cover.isReleasedWhenClosed = false
        cover.ignoresMouseEvents = false
        cover.animationBehavior = .none
        cover.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
        ]
        cover.level = LauncherWindowLevelPolicy.menuBarCover
        return cover
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init<Content: View>(rootView: Content) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = LaunchText.value("Launch 设置", "Launch Settings")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 480)
        window.collectionBehavior = [.moveToActiveSpace]
        window.level = LauncherWindowLevelPolicy.settings
        window.hidesOnDeactivate = true
        window.contentViewController = NSHostingController(rootView: AnyView(rootView))
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func show() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
