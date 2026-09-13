import AppKit
import Combine
import Foundation

/// Identifies one specific error presentation. A delayed dismissal can retain
/// this value and clear only the message it was created for, rather than
/// accidentally removing a newer error.
struct LauncherErrorToken: Hashable, Sendable {
    fileprivate let generation: UInt64
}

/// Main-actor state shared by the full-screen launcher, settings, and app shell.
@MainActor
final class LauncherModel: ObservableObject {
    private struct CachedApplicationIcon {
        let application: InstalledApplication
        let image: NSImage
    }

    @Published private(set) var applications: [String: InstalledApplication] = [:]
    @Published private(set) var layout: LaunchLayout = .empty
    @Published var preferences: LaunchPreferences = .default
    @Published var searchText = "" {
        didSet {
            if searchText != oldValue {
                cancelPageInteraction()
                currentPage = 0
                openFolderID = nil
            }
        }
    }
    @Published private(set) var currentPage = 0
    @Published private(set) var pageInteraction: LauncherPageInteractionState = .idle
    @Published var openFolderID: UUID?
    @Published private(set) var isScanning = false
    @Published private(set) var rebuildingWeChatCompanionApplicationID: String?
    @Published private(set) var errorMessage: String? {
        didSet {
            nextErrorGeneration &+= 1
            if nextErrorGeneration == 0 { nextErrorGeneration = 1 }
            errorToken = errorMessage == nil
                ? nil
                : LauncherErrorToken(generation: nextErrorGeneration)
        }
    }
    private(set) var errorToken: LauncherErrorToken?

    /// The app shell installs this callback so Escape/background clicks can hide
    /// the borderless launcher without coupling the model to a window.
    var onDismissRequested: (() -> Void)?
    var onSettingsRequested: (() -> Void)?

    let launchAtLoginManager: LaunchAtLoginManager

    private let scanner: AppScanner
    private let store: LayoutStore
    private let directoryMonitor: ApplicationDirectoryMonitor
    private let weChatCompanionRefreshService: WeChatCompanionRefreshService
    private var hasStarted = false
    private var didLoadPersistentState = false
    /// True only when an incomplete first scan was used to populate an empty
    /// saved layout for presentation. That provisional layout is useful in
    /// memory, but must never replace the stable snapshot until a complete scan
    /// can reconcile every installed application.
    private var isUsingProvisionalPartialLayout = false
    private var rescanPending = false
    private var iconCache: [String: CachedApplicationIcon] = [:]
    private var searchEntryIDs: [String: UUID] = [:]
    private var appliedGridRows = LaunchPreferences.default.rows
    private var appliedGridColumns = LaunchPreferences.default.columns
    private var pendingPersistenceTask: Task<Void, Never>?
    private var nextErrorGeneration: UInt64 = 0

    init(
        scanner: AppScanner = AppScanner(),
        store: LayoutStore = LayoutStore(),
        launchAtLoginManager: LaunchAtLoginManager? = nil,
        directoryMonitor: ApplicationDirectoryMonitor = ApplicationDirectoryMonitor(),
        weChatCompanionRefreshService: WeChatCompanionRefreshService? = nil
    ) {
        self.scanner = scanner
        self.store = store
        self.launchAtLoginManager = launchAtLoginManager ?? LaunchAtLoginManager()
        self.directoryMonitor = directoryMonitor
        self.weChatCompanionRefreshService = weChatCompanionRefreshService
            ?? WeChatCompanionRefreshService()
    }

    deinit {
        directoryMonitor.stop()
    }

    // MARK: - Presentation state

    var allApplications: [InstalledApplication] {
        applications.values.sorted(by: applicationSort)
    }

    var hiddenApplications: [InstalledApplication] {
        preferences.hiddenApplicationIDs
            .compactMap { applications[$0] }
            .sorted(by: applicationSort)
    }

    /// A single source for application-management UI. Visible rows form the
    /// first group and hidden rows the second; each group uses the localized
    /// application name (then stable ID as a tie-breaker). Visibility is
    /// derived from the persisted hidden-ID set rather than mirrored in a
    /// second mutable collection.
    var managedApplications: [ManagedApplication] {
        let rows = allApplications.map { application in
            ManagedApplication(
                application: application,
                isVisible: !preferences.hiddenApplicationIDs.contains(application.id)
            )
        }
        return rows.filter(\.isVisible) + rows.filter { !$0.isVisible }
    }

    /// Returns a freshly derived management list for the supplied query. Rows
    /// keep their stable application identity while visibility always comes
    /// from the current preference value, so a filtered sheet never has to
    /// retain a stale `ManagedApplication` snapshot.
    func managedApplications(matching query: String) -> [ManagedApplication] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return managedApplications }
        return managedApplications.filter {
            applicationMatchesSearch($0.application, query: normalizedQuery)
        }
    }

    /// Live visibility lookup for bindings whose row identity outlives the
    /// value snapshot that originally constructed the row.
    func isApplicationVisible(_ applicationID: String) -> Bool {
        applications[applicationID] != nil
            && !preferences.hiddenApplicationIDs.contains(applicationID)
    }

    /// All top-level items, or flattened application results while searching.
    var visibleEntries: [LaunchEntry] {
        let query = normalizedSearchText
        guard !query.isEmpty else { return layout.pages.flatMap { $0 } }

        return orderedVisibleApplicationIDs.compactMap { applicationID in
            guard let application = applications[applicationID],
                  applicationMatchesSearch(application, query: query) else {
                return nil
            }
            return LaunchEntry(id: searchEntryID(for: applicationID), kind: .application(applicationID))
        }
    }

    var currentPageEntries: [LaunchEntry] {
        if normalizedSearchText.isEmpty {
            guard layout.pages.indices.contains(currentPage) else { return [] }
            return layout.pages[currentPage]
        }

        let capacity = max(1, preferences.pageCapacity)
        let start = min(currentPage * capacity, visibleEntries.count)
        let end = min(start + capacity, visibleEntries.count)
        return Array(visibleEntries[start..<end])
    }

    var pageCount: Int {
        guard !normalizedSearchText.isEmpty else {
            return max(1, layout.pages.count)
        }
        let capacity = max(1, preferences.pageCapacity)
        return max(1, (visibleEntries.count + capacity - 1) / capacity)
    }

    var currentFolder: LaunchFolder? {
        guard let openFolderID else { return nil }
        return folder(withID: openFolderID)
    }

    var launchAtLoginIsAvailable: Bool { launchAtLoginManager.isAvailable }
    var launchAtLoginRequiresApproval: Bool { launchAtLoginManager.requiresApproval }
    var launchAtLoginError: String? { launchAtLoginManager.lastError }

    func application(for entry: LaunchEntry) -> InstalledApplication? {
        guard let applicationID = entry.applicationID else { return nil }
        return applications[applicationID]
    }

    func applications(in folder: LaunchFolder) -> [InstalledApplication] {
        folder.applicationIDs.compactMap { applications[$0] }
    }

    func icon(for applicationID: String) -> NSImage? {
        guard let application = applications[applicationID] else { return nil }
        if let cached = iconCache[applicationID],
           cached.application == application {
            return cached.image
        }

        let icon = application.iconURL.flatMap(NSImage.init(contentsOf:))
            ?? NSWorkspace.shared.icon(forFile: application.bundleURL.path)
        iconCache[applicationID] = CachedApplicationIcon(
            application: application,
            image: icon
        )
        return icon
    }

    func selectPage(_ page: Int) {
        cancelPageInteraction()
        currentPage = min(max(0, page), max(0, pageCount - 1))
        openFolderID = nil
    }

    /// Changes the main-grid page while a folder-member drag remains active.
    /// Unlike ordinary page selection, this intentionally preserves the open
    /// folder so its pointer recognizer can receive the eventual mouse-up and
    /// commit one atomic move. This is transient UI state only: it does not
    /// mutate or persist the layout.
    func selectPageKeepingFolderOpen(_ page: Int) {
        cancelPageInteraction()
        currentPage = min(max(0, page), max(0, pageCount - 1))
    }

    func showNextPage() {
        selectPage(currentPage + 1)
    }

    func showPreviousPage() {
        selectPage(currentPage - 1)
    }

    /// Starts one continuously tracked page gesture. Folder overlays do not
    /// participate in top-level paging; search results may still span pages.
    @discardableResult
    func beginPageInteraction() -> Bool {
        guard openFolderID == nil else { return false }
        var interaction = pageInteraction
        let began = interaction.begin(at: currentPage, pageCount: pageCount)
        pageInteraction = interaction
        return began
    }

    func updatePageInteraction(
        translation: Double,
        velocity: Double = 0,
        pageExtent: Double
    ) {
        var interaction = pageInteraction
        interaction.update(
            translation: translation,
            velocity: velocity,
            pageExtent: pageExtent,
            pageCount: pageCount
        )
        pageInteraction = interaction
    }

    /// Resolves and commits the destination once. The interaction remains in
    /// `settling` until the view's animation calls `completePageInteraction()`.
    @discardableResult
    func endPageInteraction(
        predictedTranslation: Double? = nil,
        velocity: Double? = nil,
        pageExtent: Double
    ) -> Int? {
        var interaction = pageInteraction
        guard let destination = interaction.end(
            predictedTranslation: predictedTranslation,
            velocity: velocity,
            pageExtent: pageExtent,
            pageCount: pageCount
        ) else {
            return nil
        }

        pageInteraction = interaction
        currentPage = destination
        openFolderID = nil
        return destination
    }

    func completePageInteraction() {
        guard pageInteraction.phase != .idle else { return }
        var interaction = pageInteraction
        interaction.complete()
        pageInteraction = interaction
    }

    func cancelPageInteraction() {
        guard pageInteraction.phase != .idle else { return }
        var interaction = pageInteraction
        interaction.cancel()
        pageInteraction = interaction
    }

    func prepareForPresentation() {
        cancelPageInteraction()
        searchText = ""
        openFolderID = nil
        clampCurrentPage()
    }

    func dismissLauncher() {
        cancelPageInteraction()
        searchText = ""
        openFolderID = nil
        onDismissRequested?()
    }

    func showSettings() {
        onSettingsRequested?()
    }

    // MARK: - Loading and launching

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        directoryMonitor.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.rescan()
            }
        }
        rescan()
    }

    func rescan() {
        guard !isScanning else {
            rescanPending = true
            return
        }
        isScanning = true
        Task { [weak self] in
            await self?.performScan()
        }
    }

    /// Awaitable form used by tests and callers that need a completed scan.
    func rescanNow() async {
        guard !isScanning else {
            rescanPending = true
            return
        }
        isScanning = true
        await performScan()
    }

    /// Call only after an application bundle has been replaced successfully.
    /// A refreshed bundle can keep the same stable identifier and icon path, so
    /// the ordinary scan cannot infer that its cached `NSImage` is stale.
    /// Evict first, then request a scan; an in-flight scan records the request
    /// and immediately performs another pass when it finishes.
    func applicationBundleDidRefresh(_ applicationID: String) {
        iconCache.removeValue(forKey: applicationID)
        rescan()
    }

    func launch(_ applicationID: String) {
        guard let application = applications[applicationID] else {
            errorMessage = LaunchText.value("这个应用已不在电脑上。", "This application is no longer installed.")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: application.bundleURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.errorMessage = LaunchText.value(
                    "无法打开 \(application.name)：\(error.localizedDescription)",
                    "Could not open \(application.name): \(error.localizedDescription)"
                )
            }
        }
        dismissLauncher()
    }

    var isRebuildingWeChatCompanion: Bool {
        rebuildingWeChatCompanionApplicationID != nil
    }

    /// The rebuild action is deliberately exposed only for Tencent's primary
    /// WeChat bundle. A matching filename, localized name or icon is never
    /// sufficient to authorize replacing an application in /Applications.
    func canRebuildWeChatCompanion(_ applicationID: String) -> Bool {
        guard let application = applications[applicationID] else { return false }
        return WeChatDualLaunchPolicy.isPrimaryBundleIdentifier(
            application.bundleIdentifier
        )
    }

    /// Rebuilds a fresh companion from the current /Applications/WeChat.app.
    /// The service keeps the previous companion recoverable until the verified
    /// replacement has launched successfully.
    func rebuildWeChatCompanion(_ applicationID: String) async {
        guard canRebuildWeChatCompanion(applicationID),
              rebuildingWeChatCompanionApplicationID == nil else {
            return
        }
        rebuildingWeChatCompanionApplicationID = applicationID
        defer { rebuildingWeChatCompanionApplicationID = nil }

        do {
            let outcome = try await weChatCompanionRefreshService
                .rebuildAndLaunch()
            // The companion keeps a stable bundle identifier across rebuilds,
            // so a key-preserving cache filter would otherwise retain the old
            // badged icon indefinitely.
            iconCache.removeValue(
                forKey: WeChatDualLaunchPolicy.companionBundleIdentifier
            )
            await rescanNow()
            if let warning = outcome.cleanupWarning {
                errorMessage = LaunchText.value(
                    warning.chineseDescription,
                    warning.englishDescription
                )
            } else {
                dismissLauncher()
            }
        } catch is CancellationError {
            return
        } catch let error as WeChatCompanionRefreshServiceError {
            errorMessage = LaunchText.value(
                error.chineseDescription,
                error.englishDescription
            )
        } catch {
            errorMessage = LaunchText.value(
                "重建微信双开版失败：\(error.localizedDescription)",
                "Could not rebuild the WeChat companion: \(error.localizedDescription)"
            )
        }
    }

    func clearError() {
        errorMessage = nil
    }

    /// Clears a delayed/automatic dismissal only when no newer error has
    /// replaced the message. Manual dismissal should continue using
    /// `clearError()`.
    @discardableResult
    func clearError(ifCurrent token: LauncherErrorToken) -> Bool {
        guard errorToken == token else { return false }
        errorMessage = nil
        return true
    }

    /// Lets the shell surface shortcut/menu-bar integration failures through
    /// the launcher's existing error presentation without owning model state.
    @discardableResult
    func reportShellError(_ message: String) -> LauncherErrorToken? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = trimmed.isEmpty ? nil : trimmed
        return errorToken
    }

    /// Only user-installed application bundles are offered for removal. System
    /// applications and Launch itself never receive a delete control.
    func canUninstall(_ applicationID: String) -> Bool {
        guard let application = applications[applicationID] else { return false }
        let bundleURL = application.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let bundlePath = bundleURL.path
        let ownBundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL

        guard bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              bundleURL != ownBundleURL,
              !bundlePath.hasPrefix("/System/"),
              !bundlePath.hasPrefix("/usr/"),
              !bundlePath.hasPrefix("/bin/"),
              !bundlePath.hasPrefix("/sbin/") else {
            return false
        }
        return FileManager.default.fileExists(atPath: bundlePath)
    }

    /// Moves an application bundle to the Trash using AppKit's Finder-style,
    /// recoverable file operation. The confirmation UI lives in LauncherView.
    func moveApplicationToTrash(_ applicationID: String) async {
        guard canUninstall(applicationID),
              let application = applications[applicationID] else {
            errorMessage = LaunchText.value(
                "这个应用受系统保护，无法从启动台卸载。",
                "This application is protected and cannot be removed from 启动台."
            )
            return
        }

        let bundleURL = application.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSWorkspace.shared.recycle([bundleURL]) { [weak self] recycledURLs, error in
                Task { @MainActor [weak self] in
                    defer { continuation.resume() }
                    guard let self else { return }

                    if let error {
                        self.errorMessage = LaunchText.value(
                            "无法将 \(application.name) 移到废纸篓：\(error.localizedDescription)",
                            "Could not move \(application.name) to the Trash: \(error.localizedDescription)"
                        )
                        return
                    }

                    guard recycledURLs[bundleURL] != nil else {
                        self.errorMessage = LaunchText.value(
                            "\(application.name) 没有被移到废纸篓。",
                            "\(application.name) was not moved to the Trash."
                        )
                        return
                    }

                    self.preferences.hiddenApplicationIDs.remove(applicationID)
                    self.removeApplicationEverywhere(applicationID)
                    self.collapseSmallFolders()
                    self.repackPages()
                    self.applications.removeValue(forKey: applicationID)
                    self.iconCache.removeValue(forKey: applicationID)
                    self.persist()
                    self.rescan()
                }
            }
        }
    }

    // MARK: - Folders

    func openFolder(_ id: UUID) {
        guard folder(withID: id) != nil else { return }
        cancelPageInteraction()
        openFolderID = id
    }

    func closeFolder() {
        openFolderID = nil
    }

    func createFolder(from sourceID: String, onto targetID: String) {
        guard sourceID != targetID,
              applications[sourceID] != nil,
              applications[targetID] != nil,
              !preferences.hiddenApplicationIDs.contains(sourceID),
              !preferences.hiddenApplicationIDs.contains(targetID),
              let folder = layout.createFolder(
                from: sourceID,
                onto: targetID,
                name: LaunchText.value("新建文件夹", "New Folder"),
                pageCapacity: preferences.pageCapacity
              ) else {
            return
        }

        cancelPageInteraction()
        if let location = layout.folderLocation(folder.id) {
            currentPage = location.page
        }
        openFolderID = folder.id
        persist()
    }

    func addToFolder(appID: String, folderID: UUID) {
        _ = addToFolder(appID: appID, folderID: folderID, before: nil)
    }

    /// Moves a top-level app into one exact folder position as a single layout
    /// mutation and persisted snapshot. `nil` appends. The method deliberately
    /// leaves `openFolderID` unchanged so hover-preview UI can decide when to
    /// present the real folder after a successful mouse-up.
    @discardableResult
    func addToFolder(
        appID: String,
        folderID: UUID,
        before targetApplicationID: String?
    ) -> Bool {
        guard normalizedSearchText.isEmpty,
              applications[appID] != nil,
              !preferences.hiddenApplicationIDs.contains(appID),
              let location = layout.addTopLevelApplication(
                appID,
                toFolder: folderID,
                before: targetApplicationID,
                pageCapacity: preferences.pageCapacity
              ) else {
            return false
        }

        cancelPageInteraction()
        currentPage = location.page
        persist()
        return true
    }

    /// Moves a member out of its folder to one precise top-level location.
    /// `targetEntryID == nil` means the end of `destinationPage`; otherwise the
    /// target may be an entry UUID, folder UUID, or top-level application ID.
    /// Stale, hidden, cross-page-target, and duplicate commits are strict no-ops.
    @discardableResult
    func moveApplicationOutOfFolder(
        appID: String,
        folderID: UUID,
        destinationPage: Int,
        before targetEntryID: String?
    ) -> Bool {
        guard normalizedSearchText.isEmpty,
              applications[appID] != nil,
              !preferences.hiddenApplicationIDs.contains(appID),
              let location = layout.moveApplicationOutOfFolder(
                appID,
                fromFolder: folderID,
                destinationPage: destinationPage,
                before: targetEntryID,
                pageCapacity: preferences.pageCapacity
              ) else {
            return false
        }

        cancelPageInteraction()
        currentPage = location.page
        openFolderID = nil
        persist()
        return true
    }

    /// Moves a member directly between two folders as one persisted mutation.
    /// The source overlay closes on success; callers may explicitly open the
    /// destination afterwards if desired.
    @discardableResult
    func moveApplication(
        appID: String,
        fromFolderID: UUID,
        toFolderID: UUID
    ) -> Bool {
        guard applications[appID] != nil,
              !preferences.hiddenApplicationIDs.contains(appID),
              let location = layout.moveApplication(
                appID,
                fromFolder: fromFolderID,
                toFolder: toFolderID,
                pageCapacity: preferences.pageCapacity
              ) else {
            return false
        }

        cancelPageInteraction()
        currentPage = location.page
        openFolderID = nil
        persist()
        return true
    }

    func renameFolder(_ id: UUID, to proposedName: String) {
        guard let location = folderLocation(id),
              case var .folder(folder) = layout.pages[location.page][location.index].kind else {
            return
        }

        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = name.isEmpty ? LaunchText.value("文件夹", "Folder") : name
        layout.pages[location.page][location.index].kind = .folder(folder)
        persist()
    }

    /// Dissolves a folder while keeping all of its applications in the grid.
    func removeFolder(_ id: UUID) {
        guard let location = folderLocation(id),
              case let .folder(folder) = layout.pages[location.page][location.index].kind else {
            return
        }

        let entries = folder.applicationIDs.map { LaunchEntry.application($0) }
        layout.pages[location.page].replaceSubrange(location.index...location.index, with: entries)
        openFolderID = nil
        repackPages()
        persist()
    }

    func removeFromFolder(appID: String, folderID: UUID) {
        guard let location = folderLocation(folderID),
              case let .folder(folder) = layout.pages[location.page][location.index].kind,
              folder.applicationIDs.contains(appID) else {
            return
        }

        let page = layout.pages[location.page]
        let nextEntryID = page.indices.contains(location.index + 1)
            ? page[location.index + 1].id.uuidString
            : nil
        guard layout.moveApplicationOutOfFolder(
            appID,
            fromFolder: folderID,
            destinationPage: location.page,
            before: nextEntryID,
            pageCapacity: preferences.pageCapacity
        ) != nil else {
            return
        }

        if layout.folderLocation(folderID) == nil {
            openFolderID = nil
        }
        cancelPageInteraction()
        persist()
    }

    func reorderApplication(in folderID: UUID, draggedID: String, before targetID: String?) {
        guard layout.reorderApplication(
            inFolder: folderID,
            draggedID: draggedID,
            before: targetID
        ) else {
            return
        }
        persist()
    }

    // MARK: - Hiding and ordering

    func hide(_ applicationID: String) {
        hide(Set([applicationID]))
    }

    func hide(_ applicationIDs: Set<String>) {
        let validIDs = applicationIDs.filter {
            applications[$0] != nil && !preferences.hiddenApplicationIDs.contains($0)
        }
        guard !validIDs.isEmpty else { return }

        var updatedPreferences = preferences
        updatedPreferences.hiddenApplicationIDs.formUnion(validIDs)
        preferences = updatedPreferences
        for applicationID in validIDs {
            removeApplicationEverywhere(applicationID)
        }
        collapseSmallFolders()
        repackPages()
        persist()
    }

    func unhide(_ applicationID: String) {
        var updatedPreferences = preferences
        guard updatedPreferences.hiddenApplicationIDs.remove(applicationID) != nil else { return }
        preferences = updatedPreferences
        layout = layout.reconciled(
            with: allApplications,
            preferences: preferences
        )
        persist()
    }

    /// Updates one row from `managedApplications`. Returns false when the app is
    /// unknown or already has the requested visibility.
    @discardableResult
    func setApplicationVisibility(
        _ applicationID: String,
        isVisible: Bool
    ) -> Bool {
        guard applications[applicationID] != nil else { return false }
        let currentlyVisible = !preferences.hiddenApplicationIDs.contains(applicationID)
        guard currentlyVisible != isVisible else { return false }

        if isVisible {
            unhide(applicationID)
        } else {
            hide(applicationID)
        }
        return true
    }

    /// SwiftUI `onMove`-style ordering for the currently displayed layout page.
    func moveEntry(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard normalizedSearchText.isEmpty,
              layout.pages.indices.contains(currentPage),
              !offsets.isEmpty else {
            return
        }

        var page = layout.pages[currentPage]
        let validOffsets = offsets.filter { page.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return }

        let moving = validOffsets.map { page[$0] }
        for index in validOffsets.reversed() {
            page.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertion = min(max(0, destination - removedBeforeDestination), page.count)
        page.insert(contentsOf: moving, at: insertion)
        layout.pages[currentPage] = page
        cancelPageInteraction()
        persist()
    }

    /// Drag-and-drop ordering. IDs may be entry UUID strings or application IDs.
    func reorder(draggedID: String, before targetID: String?) {
        guard normalizedSearchText.isEmpty,
              let location = layout.reorderEntry(
                matching: draggedID,
                before: targetID,
                destinationPage: currentPage,
                pageCapacity: preferences.pageCapacity
              ) else {
            return
        }

        cancelPageInteraction()
        currentPage = location.page
        persist()
    }

    // MARK: - Preferences and persistence

    func savePreferences() {
        preferences.rows = min(max(preferences.rows, 2), 10)
        preferences.columns = min(max(preferences.columns, 3), 12)
        preferences.iconSize = min(max(preferences.iconSize, 40), 160)
        preferences.globalShortcut = preferences.globalShortcut.normalized()
        let gridShapeChanged = preferences.rows != appliedGridRows
            || preferences.columns != appliedGridColumns

        if launchAtLoginManager.isAvailable {
            let effectiveState = launchAtLoginManager.setEnabled(preferences.launchAtLogin)
            preferences.launchAtLogin = effectiveState
        }

        // Only a capacity change requires flattening and rebuilding pages.
        // Visual/general settings must preserve the user's manual page groups.
        if gridShapeChanged {
            repackPages()
            appliedGridRows = preferences.rows
            appliedGridColumns = preferences.columns
        }
        persist()
    }

    func openLoginItemsSettings() {
        launchAtLoginManager.openLoginItemsSettings()
    }

    /// Ensures the latest in-memory snapshot has reached disk.
    func flushPersistence() async {
        // If startup could not decode the saved snapshot, never replace it with
        // the model's empty/default state during application termination.
        // A provisional first-scan layout is likewise derived from an incomplete
        // inventory and is intentionally memory-only until a complete scan.
        guard didLoadPersistentState, !isUsingProvisionalPartialLayout else {
            return
        }

        // Wait for every queued snapshot first. `persist()` chains tasks so an
        // older write can never finish after a newer one.
        await pendingPersistenceTask?.value

        do {
            try await store.save(layout: layout, preferences: preferences)
        } catch {
            errorMessage = LaunchText.value(
                "无法保存布局：\(error.localizedDescription)",
                "Could not save your layout: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Private loading

    private func performScan() async {
        defer {
            isScanning = false
            if rescanPending {
                rescanPending = false
                rescan()
            }
        }

        let scanResult = await scanner.scanApplications()
        let scannedApplications = scanResult.applications

        if scanResult.isComplete {
            applications = Dictionary(
                scannedApplications.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            iconCache = iconCache.filter { applications[$0.key] != nil }
        } else {
            // Preserve previously known applications when a filesystem error made
            // this inventory partial. The next complete scan may recover them.
            for application in scannedApplications {
                applications[application.id] = application
            }
        }

        for application in scannedApplications {
            if searchEntryIDs[application.id] == nil {
                searchEntryIDs[application.id] = UUID()
            }
        }

        do {
            if didLoadPersistentState, scanResult.isComplete {
                if isUsingProvisionalPartialLayout {
                    // Reconcile the memory-only layout now that absence is
                    // trustworthy. Save explicitly even when reconciliation
                    // produces the same value: the disk snapshot still contains
                    // the original empty layout and may also be missing preference
                    // changes the user made while persistence was gated.
                    let reconciled = layout.reconciled(
                        with: scannedApplications,
                        preferences: preferences
                    )
                    layout = reconciled
                    try await store.save(
                        layout: reconciled,
                        preferences: preferences
                    )
                    isUsingProvisionalPartialLayout = false
                } else {
                    layout = try await store.reconcileAndSave(
                        layout: layout,
                        scanResult: scanResult,
                        preferences: preferences
                    )
                }
            } else if didLoadPersistentState, isUsingProvisionalPartialLayout {
                // Partial rescans can safely add newly confirmed applications to
                // the provisional view because the applications dictionary keeps
                // every previously confirmed ID. They still cannot remove or save
                // anything until a complete inventory arrives.
                layout = layout.reconciled(
                    with: allApplications,
                    preferences: preferences
                )
            } else if !didLoadPersistentState {
                let stored = scanResult.isComplete
                    ? try await store.loadAndReconcile(scanResult: scanResult)
                    : try await store.load()
                layout = stored.layout
                preferences = stored.preferences
                appliedGridRows = preferences.rows
                appliedGridColumns = preferences.columns

                if !scanResult.isComplete,
                   stored.layout.pages.allSatisfy({ $0.isEmpty }) {
                    // A brand-new user must not see a permanently empty launcher
                    // merely because one unrelated bundle is temporarily
                    // unreadable. Show only confirmed, non-hidden applications in
                    // memory. The flag is set even when every confirmed app is
                    // hidden so an unhide or later mutation still cannot persist a
                    // partial-derived layout.
                    isUsingProvisionalPartialLayout = true
                    layout = stored.layout.reconciled(
                        with: allApplications,
                        preferences: preferences
                    )
                }

                didLoadPersistentState = true
                synchronizeLaunchAtLogin()
            }

            if let issue = scanResult.issues.first {
                if isUsingProvisionalPartialLayout {
                    errorMessage = LaunchText.value(
                        "应用扫描未完成；已临时显示确认的应用，磁盘布局未更改：\(issue.message)",
                        "The application scan was incomplete. Confirmed applications are shown temporarily and the saved layout was not changed: \(issue.message)"
                    )
                } else {
                    errorMessage = LaunchText.value(
                        "应用扫描未完成，已保留现有布局：\(issue.message)",
                        "The application scan was incomplete. Your existing layout was preserved: \(issue.message)"
                    )
                }
            } else {
                errorMessage = nil
            }
        } catch {
            // Loading and saving failures must never turn defaults into an
            // automatic replacement for data that may still be recoverable.
            errorMessage = LaunchText.value(
                "无法读取或保存布局；磁盘上的数据未被替换：\(error.localizedDescription)",
                "Could not load or save your layout. The on-disk data was not replaced: \(error.localizedDescription)"
            )
        }

        if let openFolderID, layout.folderLocation(openFolderID) == nil {
            self.openFolderID = nil
        }
        clampCurrentPage()
    }

    private func synchronizeLaunchAtLogin() {
        launchAtLoginManager.refresh()
        guard launchAtLoginManager.isAvailable else { return }
        let effectiveState = launchAtLoginManager.setEnabled(preferences.launchAtLogin)
        if effectiveState != preferences.launchAtLogin {
            preferences.launchAtLogin = effectiveState
            persist()
        }
    }

    private func persist() {
        // A failed initial load leaves recovery to the user. UI changes made
        // while that error is visible must not destroy the undecodable file.
        // Likewise, never serialize an in-memory layout derived from a partial
        // first scan. A later complete scan commits the coherent result once.
        guard didLoadPersistentState, !isUsingProvisionalPartialLayout else {
            return
        }

        let snapshotLayout = layout
        let snapshotPreferences = preferences
        let previousTask = pendingPersistenceTask
        pendingPersistenceTask = Task { [weak self, store] in
            await previousTask?.value
            do {
                try await store.save(
                    layout: snapshotLayout,
                    preferences: snapshotPreferences
                )
            } catch {
                self?.errorMessage = LaunchText.value(
                    "无法保存布局：\(error.localizedDescription)",
                    "Could not save your layout: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Private layout helpers

    private struct EntryLocation {
        var page: Int
        var index: Int
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var orderedVisibleApplicationIDs: [String] {
        var seen = Set<String>()
        return layout.applicationIDs.filter { seen.insert($0).inserted }
    }

    private func searchEntryID(for applicationID: String) -> UUID {
        if let existing = searchEntryIDs[applicationID] {
            return existing
        }
        let created = UUID()
        searchEntryIDs[applicationID] = created
        return created
    }

    private func applicationMatchesSearch(_ application: InstalledApplication, query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        if application.name.range(of: query, options: options) != nil { return true }
        return application.bundleIdentifier?.range(of: query, options: options) != nil
    }

    private func applicationSort(_ lhs: InstalledApplication, _ rhs: InstalledApplication) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        let identifierOrder = lhs.id.localizedStandardCompare(rhs.id)
        if identifierOrder != .orderedSame {
            return identifierOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func folder(withID id: UUID) -> LaunchFolder? {
        guard let location = folderLocation(id),
              case let .folder(folder) = layout.pages[location.page][location.index].kind else {
            return nil
        }
        return folder
    }

    private func folderLocation(_ id: UUID) -> EntryLocation? {
        for pageIndex in layout.pages.indices {
            if let itemIndex = layout.pages[pageIndex].firstIndex(where: { $0.folder?.id == id }) {
                return EntryLocation(page: pageIndex, index: itemIndex)
            }
        }
        return nil
    }

    private func topLevelApplicationLocation(_ id: String) -> EntryLocation? {
        for pageIndex in layout.pages.indices {
            if let itemIndex = layout.pages[pageIndex].firstIndex(where: { $0.applicationID == id }) {
                return EntryLocation(page: pageIndex, index: itemIndex)
            }
        }
        return nil
    }

    private func entryLocation(matching id: String) -> EntryLocation? {
        let uuid = UUID(uuidString: id)
        for pageIndex in layout.pages.indices {
            if let itemIndex = layout.pages[pageIndex].firstIndex(where: { entry in
                entry.id == uuid || entry.applicationID == id
            }) {
                return EntryLocation(page: pageIndex, index: itemIndex)
            }
        }
        return nil
    }

    private func removeApplicationEverywhere(_ id: String, excludingFolderID: UUID? = nil) {
        for pageIndex in layout.pages.indices {
            var rebuiltPage: [LaunchEntry] = []

            for entry in layout.pages[pageIndex] {
                switch entry.kind {
                case let .application(applicationID):
                    if applicationID != id {
                        rebuiltPage.append(entry)
                    }

                case var .folder(folder):
                    if folder.id != excludingFolderID {
                        folder.applicationIDs.removeAll { $0 == id }
                    }
                    if !folder.applicationIDs.isEmpty {
                        rebuiltPage.append(LaunchEntry(id: entry.id, kind: .folder(folder)))
                    }
                }
            }
            layout.pages[pageIndex] = rebuiltPage
        }
    }

    private func collapseSmallFolders() {
        for pageIndex in layout.pages.indices {
            layout.pages[pageIndex] = layout.pages[pageIndex].flatMap { entry in
                guard case let .folder(folder) = entry.kind else { return [entry] }
                switch folder.applicationIDs.count {
                case 0:
                    return []
                case 1:
                    return [
                        LaunchEntry(
                            id: entry.id,
                            kind: .application(folder.applicationIDs[0])
                        )
                    ]
                default:
                    return [entry]
                }
            }
        }
        if let openFolderID, folder(withID: openFolderID) == nil {
            self.openFolderID = nil
        }
    }

    private func repackPages() {
        layout.compactPages(pageCapacity: preferences.pageCapacity)
        cleanUpPages()
    }

    private func cleanUpPages() {
        layout.pages.removeAll { $0.isEmpty }
        if layout.pages.isEmpty {
            layout.pages = [[]]
        }
        clampCurrentPage()
    }

    private func clampCurrentPage() {
        cancelPageInteraction()
        currentPage = min(max(0, currentPage), max(0, pageCount - 1))
    }
}

/// Sheet-scoped presentation state for application visibility controls.
///
/// `NSSwitch` finishes its AppKit action after invoking the SwiftUI binding
/// setter. Moving that same row between two filtered groups synchronously can
/// therefore leave the reused control displaying its old captured value. This
/// adapter publishes a pending visual value immediately, keeps the row in its
/// current group for the remainder of that action, then commits to
/// `LauncherModel` on the next main-actor turn. The model remains the persisted
/// source of truth; pending values are presentation-only and coalesce per ID.
@MainActor
final class LauncherApplicationManagerState: ObservableObject {
    @Published var searchText = ""
    @Published private(set) var rows: [ManagedApplication]

    private let model: LauncherModel
    private var subscriptions = Set<AnyCancellable>()
    private var pendingVisibility: [String: Bool] = [:]
    private var pendingGenerations: [String: UInt64] = [:]
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    private var nextGeneration: UInt64 = 0

    init(model: LauncherModel) {
        self.model = model
        rows = model.managedApplications

        model.$applications
            .combineLatest(model.$preferences)
            .sink { [weak self] applications, preferences in
                self?.synchronize(
                    applications: applications,
                    preferences: preferences
                )
            }
            .store(in: &subscriptions)
    }

    deinit {
        for task in pendingTasks.values { task.cancel() }
    }

    var filteredRows: [ManagedApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { Self.matches($0.application, query: query) }
    }

    var visibleRows: [ManagedApplication] {
        filteredRows.filter(\.isVisible)
    }

    var hiddenRows: [ManagedApplication] {
        filteredRows.filter { !$0.isVisible }
    }

    var applicationCount: Int { rows.count }
    var visibleCount: Int { rows.lazy.filter(\.isVisible).count }

    /// Pending-aware value intended for a Toggle/Binding getter. Grouping uses
    /// committed `rows`, so requesting a change redraws the switch immediately
    /// without removing it from the hierarchy during its own AppKit action.
    func visualVisibility(for applicationID: String) -> Bool {
        if let pending = pendingVisibility[applicationID] { return pending }
        return rows.first(where: { $0.id == applicationID })?.isVisible ?? false
    }

    /// Schedules one visibility mutation after the current control action.
    /// Repeated requests for the same row coalesce to the last desired value.
    @discardableResult
    func requestVisibility(
        _ applicationID: String,
        isVisible: Bool
    ) -> Bool {
        guard rows.contains(where: { $0.id == applicationID }),
              visualVisibility(for: applicationID) != isVisible else {
            return false
        }

        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        let generation = nextGeneration
        pendingTasks[applicationID]?.cancel()
        pendingVisibility[applicationID] = isVisible
        pendingGenerations[applicationID] = generation

        // Publish only the pending visual value. The row remains in its current
        // committed group until the next main-actor turn.
        objectWillChange.send()

        let task = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.pendingGenerations[applicationID] == generation,
                  self.pendingVisibility[applicationID] == isVisible else {
                return
            }

            self.pendingTasks[applicationID] = nil
            self.pendingGenerations[applicationID] = nil
            self.pendingVisibility[applicationID] = nil

            if self.model.isApplicationVisible(applicationID) != isVisible {
                _ = self.model.setApplicationVisibility(
                    applicationID,
                    isVisible: isVisible
                )
            } else {
                self.synchronizeFromModel()
            }
        }
        pendingTasks[applicationID] = task
        return true
    }

    /// Deterministic test/teardown hook; production UI does not need to await.
    func waitForPendingVisibilityChanges() async {
        let tasks = Array(pendingTasks.values)
        for task in tasks { await task.value }
    }

    private func synchronizeFromModel() {
        synchronize(
            applications: model.applications,
            preferences: model.preferences
        )
    }

    private func synchronize(
        applications: [String: InstalledApplication],
        preferences: LaunchPreferences
    ) {
        let sortedApplications = applications.values.sorted(by: Self.applicationSort)
        let updatedRows = sortedApplications.map { application in
            ManagedApplication(
                application: application,
                isVisible: !preferences.hiddenApplicationIDs.contains(application.id)
            )
        }
        rows = updatedRows.filter(\.isVisible)
            + updatedRows.filter { !$0.isVisible }
    }

    private static func matches(
        _ application: InstalledApplication,
        query: String
    ) -> Bool {
        let options: String.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive,
            .widthInsensitive,
        ]
        if application.name.range(of: query, options: options) != nil {
            return true
        }
        return application.bundleIdentifier?.range(of: query, options: options) != nil
    }

    private static func applicationSort(
        _ lhs: InstalledApplication,
        _ rhs: InstalledApplication
    ) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        let identifierOrder = lhs.id.localizedStandardCompare(rhs.id)
        if identifierOrder != .orderedSame {
            return identifierOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}
