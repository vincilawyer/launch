import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: LauncherModel!
    private var launcherWindowController: LauncherWindowController!
    private var settingsWindowController: SettingsWindowController!
    private var hotKeyManager: HotKeyManager!
    private var trackpadGestureManager: TrackpadGestureManager!
    private var statusItem: NSStatusItem?
    private var preferenceObservation: AnyCancellable?
    private var shellPreferenceBootstrapTask: Task<Void, Never>?
    private var shellPreferenceBootstrapGate = ShellPreferenceBootstrapGate()
    private var appliedShortcut: LaunchShortcutDescriptor?
    private var isRollingBackShortcut = false
    private var activePageSequenceID: UInt64?
    private var pageInteractionCompletionTask: Task<Void, Never>?
    private var launcherGesturesEnabled = false
    private var isSettingsFocusTransition = false
    private var launcherDismissalInProgress = false
    private var focusLossCheckGeneration: UInt64 = 0
    private var trackedLauncherMenus: [ObjectIdentifier: Int] = [:]
    private var isLauncherMenuTransitionInProgress = false

    private var isLauncherMenuTracking: Bool {
        !trackedLauncherMenus.isEmpty
    }

    private weak var toggleMenuItem: NSMenuItem?
    private weak var scanMenuItem: NSMenuItem?
    private weak var launchAtLoginMenuItem: NSMenuItem?
    private var isPreparingToTerminate = false

    /// `main.swift` is a synchronous top-level entry point. Construction itself
    /// has no UI side effects; all AppKit work begins in the main-actor delegate
    /// callback below.
    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let store = LayoutStore()
        let model = LauncherModel(store: store)
        self.model = model

        let launcherController = LauncherWindowController(
            rootView: LauncherView(model: model)
        )
        launcherController.onDismiss = { [weak self] in
            self?.hideLauncher()
        }
        launcherController.onKeyStatusChanged = { [weak self] isKey in
            self?.launcherKeyStatusDidChange(isKey)
        }
        model.onDismissRequested = { [weak self] in
            self?.hideLauncher()
        }
        model.onSettingsRequested = { [weak self] in
            self?.showSettings()
        }
        launcherWindowController = launcherController

        let settingsController = SettingsWindowController(
            rootView: SettingsView(
                model: model,
                launchAtLoginManager: model.launchAtLoginManager
            )
        )
        settingsController.onClose = { [weak self] in
            guard let self else { return }
            self.isSettingsFocusTransition = false
            self.focusLossCheckGeneration &+= 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let canRestoreLauncher = NSApp.isActive
                    && self.launcherWindowController?.isPresented == true
                self.launcherGesturesEnabled = canRestoreLauncher
                if canRestoreLauncher {
                    self.launcherWindowController?.window?.makeKeyAndOrderFront(nil)
                }
                self.updateMenuBarCover()
            }
        }
        settingsWindowController = settingsController

        configureGlobalShortcuts()
        observeShellPreferences()
        bootstrapShellPreferences(from: store)
        configureTrackpadGestures()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        model.start()

        // UI acceptance builds opt in to presenting immediately so they can
        // exercise the launcher with an isolated data directory. Production
        // launches never set this environment variable.
        if ProcessInfo.processInfo.environment["LAUNCH_SHOW_ON_START"] == "1" {
            DispatchQueue.main.async { [weak self] in
                self?.showLauncher()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopInputForTermination()
        NotificationCenter.default.removeObserver(
            self,
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    func applicationDidResignActive(_ notification: Notification) {
        LaunchGestureDiagnostics.log(
            "lifecycle application-resigned-active: launcher-visible=\(launcherWindowController?.isPresented == true ? 1 : 0)"
        )
        trackpadGestureManager?.cancelPendingPinchPresentation()
        trackedLauncherMenus.removeAll(keepingCapacity: true)
        isLauncherMenuTransitionInProgress = false
        focusLossCheckGeneration &+= 1
        dismissLauncherForFocusLoss()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateMenuBarCover()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        updateMenuBarCover()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showLauncher()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate else { return .terminateLater }
        isPreparingToTerminate = true
        stopInputForTermination()
        launcherWindowController?.hide(animated: false)
        settingsWindowController?.window?.orderOut(nil)

        Task { @MainActor [weak self, weak sender] in
            if let model = self?.model {
                await model.flushPersistence()
            }
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleMenuItem?.title = launcherWindowController?.isPresented == true
            ? LaunchText.value("隐藏启动台", "Hide 启动台")
            : LaunchText.value("显示启动台", "Show 启动台")
        scanMenuItem?.title = model?.isScanning == true
            ? LaunchText.value("正在扫描应用…", "Scanning Applications…")
            : LaunchText.value("重新扫描应用", "Scan Applications Again")
        scanMenuItem?.isEnabled = model?.isScanning != true

        model?.launchAtLoginManager.refresh()
        launchAtLoginMenuItem?.state = model?.launchAtLoginManager.isEnabled == true ? .on : .off
        launchAtLoginMenuItem?.isEnabled = model?.launchAtLoginManager.isAvailable == true
    }

    // MARK: - Commands

    @objc private func toggleLauncher(_ sender: Any? = nil) {
        guard !isPreparingToTerminate else { return }
        if launcherWindowController.isPresented {
            hideLauncher()
        } else {
            showLauncher()
        }
    }

    @objc private func showLauncher(_ sender: Any? = nil) {
        guard !isPreparingToTerminate else { return }
        trackpadGestureManager?.cancelPendingPinchPresentation()
        trackedLauncherMenus.removeAll(keepingCapacity: true)
        isLauncherMenuTransitionInProgress = false
        focusLossCheckGeneration &+= 1
        launcherDismissalInProgress = false
        launcherGesturesEnabled = false
        cancelPageInteraction()
        model.prepareForPresentation()
        launcherWindowController.show()
        launcherGesturesEnabled = true
        updateMenuBarCover()
    }

    @objc private func hideLauncher(_ sender: Any? = nil) {
        dismissLauncher(hideApplicationWhenComplete: true)
    }

    private func dismissLauncher(hideApplicationWhenComplete: Bool) {
        trackpadGestureManager?.cancelPendingPinchPresentation()
        trackedLauncherMenus.removeAll(keepingCapacity: true)
        isLauncherMenuTransitionInProgress = false
        focusLossCheckGeneration &+= 1
        guard !launcherDismissalInProgress else { return }
        launcherDismissalInProgress = true
        launcherGesturesEnabled = false
        launcherWindowController?.setMenuBarCoverVisible(false)
        cancelPageInteraction()
        guard launcherWindowController?.isPresented == true else {
            launcherDismissalInProgress = false
            if hideApplicationWhenComplete,
               settingsWindowController?.window?.isVisible != true {
                NSApp.hide(nil)
            }
            return
        }
        launcherWindowController?.hide { [weak self] in
            guard let self else { return }
            self.launcherDismissalInProgress = false
            if hideApplicationWhenComplete,
               self.settingsWindowController?.window?.isVisible != true {
                NSApp.hide(nil)
            }
        }
    }

    @objc private func showSettings(_ sender: Any? = nil) {
        guard !isPreparingToTerminate else { return }
        trackpadGestureManager?.cancelPendingPinchPresentation()
        // Keep the launcher hosting view alive behind Settings. Tearing it down
        // from the gear's mouse-up action triggers a SwiftUI use-after-free on
        // macOS 26. Settings is placed above the launcher by its controller.
        isSettingsFocusTransition = true
        focusLossCheckGeneration &+= 1
        launcherGesturesEnabled = false
        launcherWindowController?.setMenuBarCoverVisible(false)
        cancelPageInteraction()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settingsWindowController.show()
        }
    }

    @objc private func rescanApplications(_ sender: Any? = nil) {
        model.rescan()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any? = nil) {
        model.preferences.launchAtLogin.toggle()
        model.savePreferences()
    }

    @objc private func quit(_ sender: Any? = nil) {
        NSApp.terminate(nil)
    }

    // MARK: - Menu bar and shortcuts

    private func configureStatusItem() {
        guard statusItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "square.grid.3x3.fill",
                accessibilityDescription: "启动台"
            )
            button.image?.isTemplate = true
            button.toolTip = "启动台"
        }

        let menu = NSMenu(title: "启动台")
        menu.delegate = self

        let toggleItem = NSMenuItem(
            title: LaunchText.value("显示启动台", "Show 启动台"),
            action: #selector(toggleLauncher(_:)),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        self.toggleMenuItem = toggleItem

        let scanItem = NSMenuItem(
            title: LaunchText.value("重新扫描应用", "Scan Applications Again"),
            action: #selector(rescanApplications(_:)),
            keyEquivalent: "r"
        )
        scanItem.target = self
        scanItem.keyEquivalentModifierMask = [.command]
        menu.addItem(scanItem)
        self.scanMenuItem = scanItem

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: LaunchText.value("登录时打开", "Open at Login"),
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        menu.addItem(loginItem)
        launchAtLoginMenuItem = loginItem

        let settingsItem = NSMenuItem(
            title: LaunchText.value("设置…", "Settings…"),
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: LaunchText.value("退出启动台", "Quit 启动台"),
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func configureGlobalShortcuts() {
        hotKeyManager = HotKeyManager()
    }

    private func observeShellPreferences() {
        preferenceObservation = model.$preferences
            // The model starts with in-memory defaults. Applying that first value
            // would briefly recreate a hidden status item and register Option-
            // Space before the persisted preference arrives.
            .dropFirst()
            .map(ShellPreferenceSnapshot.init(preferences:))
            .removeDuplicates()
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.shellPreferenceBootstrapGate.recordObservedPreference()
                self.applyShellPreferences(snapshot)
            }
    }

    private func bootstrapShellPreferences(from store: LayoutStore) {
        shellPreferenceBootstrapTask?.cancel()
        let capturedRevision = shellPreferenceBootstrapGate.revision
        shellPreferenceBootstrapTask = Task { @MainActor [weak self, store] in
            let preferences: LaunchPreferences
            do {
                preferences = try await store.loadPreferences()
            } catch {
                // LauncherModel owns the user-facing recovery error. More
                // importantly, never turn a failed read into active defaults.
                return
            }
            guard !Task.isCancelled,
                  let self,
                  !self.isPreparingToTerminate,
                  self.shellPreferenceBootstrapGate.acceptsBootstrap(
                    capturedRevision: capturedRevision
                  ) else { return }
            self.shellPreferenceBootstrapTask = nil
            self.applyShellPreferences(
                ShellPreferenceSnapshot(preferences: preferences)
            )
        }
    }

    private func applyShellPreferences(_ snapshot: ShellPreferenceSnapshot) {
        guard !isPreparingToTerminate else { return }
        setStatusItemVisible(snapshot.showMenuBarIcon)
        applyGlobalShortcut(snapshot.globalShortcut)
    }

    private func setStatusItemVisible(_ isVisible: Bool) {
        if isVisible {
            configureStatusItem()
            return
        }
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        toggleMenuItem = nil
        scanMenuItem = nil
        launchAtLoginMenuItem = nil
    }

    private func applyGlobalShortcut(_ descriptor: LaunchShortcutDescriptor) {
        guard !isRollingBackShortcut else { return }
        let normalized = descriptor.normalized()
        let result = hotKeyManager.apply(normalized) { [weak self] in
            self?.toggleLauncher()
        }
        switch result {
        case let .success(applied):
            appliedShortcut = applied
            statusItem?.button?.toolTip = "启动台"
        case let .failure(error):
            if let rollback = ShellShortcutRollbackRequest.make(
                failedDescriptor: normalized,
                activeDescriptor: appliedShortcut
            ) {
                // `@Published` delivers from willSet, so the model still exposes
                // the old value in this synchronous stack frame. Reconcile on
                // the next turn and apply only if neither the preference nor the
                // actual Carbon registration changed in the meantime.
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          !self.isPreparingToTerminate,
                          rollback.shouldApply(
                            currentPreference: self.model.preferences.globalShortcut,
                            activeDescriptor: self.appliedShortcut
                          ) else { return }
                    self.isRollingBackShortcut = true
                    self.model.preferences.globalShortcut = rollback.restorationDescriptor
                    self.isRollingBackShortcut = false
                    self.model.savePreferences()
                }
            }
            let message: String
            switch error {
            case .invalidShortcut:
                message = LaunchText.value(
                    "这个快捷键不能使用。普通按键需要至少一个修饰键，或使用 F1–F20。",
                    "That shortcut cannot be used. Add a modifier to ordinary keys, or use F1–F20."
                )
            case .eventHandlerUnavailable:
                message = LaunchText.value(
                    "无法启用全局快捷键，原来的快捷键已保留。",
                    "The global shortcut could not be enabled; the previous shortcut was kept."
                )
            case .registrationFailed:
                message = LaunchText.value(
                    "这个快捷键已被 macOS 或其他应用占用，原来的快捷键已保留。",
                    "That shortcut is already used by macOS or another app; the previous shortcut was kept."
                )
            }
            model.reportShellError(message)
            statusItem?.button?.toolTip = "启动台 — \(message)"
        }
    }

    private func configureTrackpadGestures() {
        let manager = TrackpadGestureManager(
            isLauncherVisible: { [weak self] in
                self?.launcherWindowController?.isPresented == true
            },
            isLauncherInteractive: { [weak self] in
                guard let self else { return false }
                return self.launcherGesturesEnabled
                    && self.launcherWindowController?.isPresented == true
                    && NSApp.isActive
                    && !self.isLauncherMenuTracking
                    && !self.isLauncherMenuTransitionInProgress
                    && self.settingsWindowController?.window?.isVisible != true
                    && self.launcherWindowController?.window?.attachedSheet == nil
            },
            showLauncher: { [weak self] in
                self?.showLauncher()
            },
            hideLauncher: { [weak self] in
                self?.hideLauncher()
            },
            handlePageGesture: { [weak self] event in
                self?.handlePageGesture(event)
            }
        )
        trackpadGestureManager = manager
        launcherWindowController.onTrackpadTouches = { [weak manager] samples, phase, timestamp in
            manager?.handleLauncherTouches(samples, phase: phase, timestamp: timestamp)
        }
        manager.start()
    }

    private func stopInputForTermination() {
        launcherGesturesEnabled = false
        launcherWindowController?.setMenuBarCoverVisible(false)
        trackpadGestureManager?.cancelPendingPinchPresentation()
        cancelPageInteraction()
        launcherWindowController?.onTrackpadTouches = nil
        trackpadGestureManager?.stop()
        hotKeyManager?.unregister()
        preferenceObservation?.cancel()
        preferenceObservation = nil
        setStatusItemVisible(false)
        shellPreferenceBootstrapTask?.cancel()
        shellPreferenceBootstrapTask = nil
    }

    private func handlePageGesture(_ event: TrackpadPageGestureEvent) {
        switch event.phase {
        case .began:
            pageInteractionCompletionTask?.cancel()
            pageInteractionCompletionTask = nil
            model.cancelPageInteraction()
            activePageSequenceID = event.sequenceID
            guard model.beginPageInteraction() else {
                LaunchGestureDiagnostics.log(
                    "model rejected page begin: sequence=\(event.sequenceID) page=\(model.currentPage)"
                )
                activePageSequenceID = nil
                return
            }
            LaunchGestureDiagnostics.log(
                "model accepted page begin: sequence=\(event.sequenceID) page=\(model.currentPage)"
            )
            model.updatePageInteraction(
                translation: event.progress,
                velocity: event.velocity,
                pageExtent: 1
            )

        case .changed:
            guard activePageSequenceID == event.sequenceID else { return }
            model.updatePageInteraction(
                translation: event.progress,
                velocity: event.velocity,
                pageExtent: 1
            )

        case .ended:
            guard activePageSequenceID == event.sequenceID else { return }
            activePageSequenceID = nil
            model.updatePageInteraction(
                translation: event.progress,
                velocity: event.velocity,
                pageExtent: 1
            )
            let predictedTranslation = TrackpadPageCommitPolicy.predictedTranslation(
                progress: event.progress,
                velocity: event.velocity
            )
            let destination = model.endPageInteraction(
                predictedTranslation: predictedTranslation,
                velocity: event.velocity,
                pageExtent: 1
            )
            LaunchGestureDiagnostics.log(
                "model resolved page end: sequence=\(event.sequenceID) measured=\(String(format: "%.3f", event.progress)) predicted=\(String(format: "%.3f", predictedTranslation)) destination=\(destination.map(String.init) ?? "none") current=\(model.currentPage)"
            )
            pageInteractionCompletionTask?.cancel()
            pageInteractionCompletionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 260_000_000)
                guard !Task.isCancelled else { return }
                self?.model?.completePageInteraction()
                self?.pageInteractionCompletionTask = nil
            }

        case .cancelled:
            guard activePageSequenceID == event.sequenceID else { return }
            cancelPageInteraction(resetGestureDelivery: false)
        }
    }

    private func cancelPageInteraction(resetGestureDelivery: Bool = true) {
        pageInteractionCompletionTask?.cancel()
        pageInteractionCompletionTask = nil
        activePageSequenceID = nil
        model?.cancelPageInteraction()
        if resetGestureDelivery {
            trackpadGestureManager?.cancelActivePageGestureDelivery()
        }
    }

    private func launcherKeyStatusDidChange(_ isKey: Bool) {
        updateMenuBarCover()
        focusLossCheckGeneration &+= 1
        guard !isKey else { return }
        let generation = focusLossCheckGeneration

        // AppKit may report resign-key before the replacement Settings window
        // or attached sheet has finished becoming key. Re-evaluate once on the
        // next run-loop turn so controlled in-app transitions are not mistaken
        // for genuine focus loss.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  generation == self.focusLossCheckGeneration,
                  self.launcherWindowController?.isPresented == true,
                  self.launcherWindowController?.window?.isKeyWindow != true,
                  !self.launcherDismissalInProgress else { return }

            let launcherWindow = self.launcherWindowController?.window
            let keyWindow = NSApp.keyWindow
            let keyWindowIsLauncherSheet: Bool
            if let launcherWindow, let sheetParent = keyWindow?.sheetParent {
                keyWindowIsLauncherSheet = sheetParent === launcherWindow
            } else {
                keyWindowIsLauncherSheet = false
            }
            let hasControlledSheet = launcherWindow?.attachedSheet != nil
                || keyWindowIsLauncherSheet
            let preservesLauncher = self.isSettingsFocusTransition
                || self.isLauncherMenuTracking
                || self.isLauncherMenuTransitionInProgress
                || self.settingsWindowController?.window?.isVisible == true
                || hasControlledSheet
            guard !preservesLauncher else { return }
            self.dismissLauncherForFocusLoss()
        }
    }

    private func dismissLauncherForFocusLoss() {
        guard launcherWindowController?.isPresented == true else {
            launcherWindowController?.setMenuBarCoverVisible(false)
            cancelPageInteraction()
            return
        }
        LaunchGestureDiagnostics.log("launcher dismissed after uncontrolled focus loss")
        dismissLauncher(hideApplicationWhenComplete: false)
    }

    private func updateMenuBarCover() {
        let shouldShowCover = launcherGesturesEnabled
            && launcherWindowController?.isPresented == true
            && launcherWindowController?.window?.isKeyWindow == true
            && launcherWindowController?.window?.attachedSheet == nil
            && settingsWindowController?.window?.isVisible != true
            && NSApp.isActive
        launcherWindowController?.setMenuBarCoverVisible(shouldShowCover)
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              NSApp.isActive,
              launcherWindowController?.isPresented == true,
              !launcherDismissalInProgress else { return }

        let identifier = ObjectIdentifier(menu)
        trackedLauncherMenus[identifier, default: 0] += 1
        isLauncherMenuTransitionInProgress = true

        // Context menus temporarily take key status away from their source
        // window. Invalidate any queued focus-loss decision until AppKit has
        // finished dispatching the selected menu action.
        focusLossCheckGeneration &+= 1
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        let identifier = ObjectIdentifier(menu)
        guard let depth = trackedLauncherMenus[identifier] else { return }
        if depth > 1 {
            trackedLauncherMenus[identifier] = depth - 1
        } else {
            trackedLauncherMenus.removeValue(forKey: identifier)
        }
        guard !isLauncherMenuTracking else { return }

        focusLossCheckGeneration &+= 1

        // Menu actions can synchronously change SwiftUI state, while the
        // resulting alert/sheet is attached only after menu tracking unwinds.
        // Reconcile on the next turn: preserve any controlled replacement
        // window, otherwise return key status to the still-active launcher.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isLauncherMenuTracking else { return }
            self.isLauncherMenuTransitionInProgress = false
            self.focusLossCheckGeneration &+= 1

            guard self.launcherWindowController?.isPresented == true,
                  !self.launcherDismissalInProgress else { return }

            guard NSApp.isActive else {
                self.dismissLauncherForFocusLoss()
                return
            }

            let launcherWindow = self.launcherWindowController?.window
            let keyWindow = NSApp.keyWindow
            let keyWindowIsLauncherSheet: Bool
            if let launcherWindow, let sheetParent = keyWindow?.sheetParent {
                keyWindowIsLauncherSheet = sheetParent === launcherWindow
            } else {
                keyWindowIsLauncherSheet = false
            }
            let hasControlledPresentation = self.isSettingsFocusTransition
                || self.settingsWindowController?.window?.isVisible == true
                || launcherWindow?.attachedSheet != nil
                || keyWindowIsLauncherSheet
                || (keyWindow != nil && keyWindow !== launcherWindow)

            if !hasControlledPresentation,
               launcherWindow?.isKeyWindow != true {
                launcherWindow?.makeKeyAndOrderFront(nil)
            }
            self.updateMenuBarCover()
        }
    }

}
