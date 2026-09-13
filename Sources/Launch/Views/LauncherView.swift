import AppKit
import SwiftUI

private struct LauncherGridMetrics {
    let columns: Int
    let iconSize: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let gridWidth: CGFloat
    let gridHeight: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let searchCenterOffset: CGFloat
    let errorBannerBottomInset: CGFloat
    let cancelDropFrameInRoot: CGRect
    let cancelDropFrameInGrid: CGRect
}

private struct LauncherVisibleInsets: Equatable {
    let left: CGFloat
    let right: CGFloat
    let bottom: CGFloat
}

private enum LauncherScreenGeometry {
    static func visibleInsets(
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> LauncherVisibleInsets {
        LauncherVisibleInsets(
            left: max(0, visibleFrame.minX - screenFrame.minX),
            right: max(0, screenFrame.maxX - visibleFrame.maxX),
            bottom: max(0, visibleFrame.minY - screenFrame.minY)
        )
    }

    /// Returns a global display-space x coordinate. On a notched display the
    /// gap between the two auxiliary top areas is the camera housing itself, so
    /// its midpoint is the stable optical center even when the two areas have
    /// different widths. Without a notch, the visible frame accounts for a
    /// side Dock. Horizontal safe-area bounds are always respected.
    static func visualSearchCenterX(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaInsets: NSEdgeInsets,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) -> CGFloat {
        let usableMinX = max(
            screenFrame.minX + max(0, safeAreaInsets.left),
            visibleFrame.minX
        )
        let usableMaxX = min(
            screenFrame.maxX - max(0, safeAreaInsets.right),
            visibleFrame.maxX
        )
        guard usableMaxX > usableMinX else { return screenFrame.midX }

        let fallback = (usableMinX + usableMaxX) / 2
        let opticalCenter: CGFloat
        if let leftArea = auxiliaryTopLeftArea,
           let rightArea = auxiliaryTopRightArea,
           leftArea.maxX <= rightArea.minX {
            opticalCenter = (leftArea.maxX + rightArea.minX) / 2
        } else {
            opticalCenter = fallback
        }

        let minimumCenter = usableMinX + LauncherChromeLayout.searchWidth / 2
        let maximumCenter = usableMaxX - LauncherChromeLayout.searchTrailingExtent
        guard minimumCenter <= maximumCenter else { return fallback }
        return min(max(minimumCenter, opticalCenter), maximumCenter)
    }

    static func localSearchCenterX(
        displayCenterX: CGFloat,
        screenFrame: CGRect,
        launcherWidth: CGFloat
    ) -> CGFloat {
        guard screenFrame.width > 0 else { return launcherWidth / 2 }
        let normalized = (displayCenterX - screenFrame.minX) / screenFrame.width
        return min(max(0, normalized), 1) * launcherWidth
    }

    /// Measures the top area unavailable to centered chrome. `safeAreaInsets`
    /// is the authoritative camera-housing clearance. When macOS also exposes
    /// both auxiliary areas, their shared lower edge captures a deeper top
    /// band on displays whose menu/notch geometry is not represented by one
    /// fixed inset value.
    static func topObstructionDepth(
        screenFrame: CGRect,
        safeAreaInsets: NSEdgeInsets,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) -> CGFloat {
        var depth = max(0, safeAreaInsets.top)
        if let leftArea = auxiliaryTopLeftArea,
           let rightArea = auxiliaryTopRightArea,
           !leftArea.isEmpty,
           !rightArea.isEmpty,
           leftArea.maxX <= rightArea.minX {
            let auxiliaryDepth = max(
                0,
                screenFrame.maxY - min(leftArea.minY, rightArea.minY)
            )
            depth = max(depth, auxiliaryDepth)
        }
        return depth
    }

    static func topChromePadding(
        base: CGFloat,
        maximum: CGFloat,
        screenFrame: CGRect,
        safeAreaInsets: NSEdgeInsets,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?,
        obstructionGap: CGFloat
    ) -> CGFloat {
        let obstruction = topObstructionDepth(
            screenFrame: screenFrame,
            safeAreaInsets: safeAreaInsets,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea
        )
        let preferred = obstruction > 0
            ? obstruction + max(0, obstructionGap)
            : base
        return min(maximum, max(base, preferred))
    }

    static func dockSafeBottomPadding(
        base: CGFloat,
        visibleBottomInset: CGFloat,
        labelSafety: CGFloat,
        iconSafety: CGFloat
    ) -> CGFloat {
        max(base, visibleBottomInset + labelSafety + iconSafety)
    }

    static func errorBannerBottomInset(bottomPadding: CGFloat) -> CGFloat {
        bottomPadding
            + LauncherChromeLayout.pageDotsHeight
            + LauncherChromeLayout.errorBannerGap
    }
}

#if DEBUG
private enum LauncherScreenGeometryDebugChecks {
    private static let runOnce: Void = {
        assert(LauncherChromeLayout.pageDotHitSize >= 44)
        assert(LauncherDragTuning.cancelDropSize.height >= 44)
        let frame = CGRect(x: 100, y: 50, width: 1_440, height: 900)
        let noInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        assert(
            LauncherScreenGeometry.visualSearchCenterX(
                screenFrame: frame,
                visibleFrame: frame,
                safeAreaInsets: noInsets,
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil
            ) == frame.midX
        )

        let leftDock = CGRect(x: 180, y: 50, width: 1_360, height: 900)
        let dockCentered = LauncherScreenGeometry.visualSearchCenterX(
            screenFrame: frame,
            visibleFrame: leftDock,
            safeAreaInsets: noInsets,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        assert(abs(dockCentered - leftDock.midX) < 0.001)

        let asymmetricNotchCenter = LauncherScreenGeometry.visualSearchCenterX(
            screenFrame: frame,
            visibleFrame: frame,
            safeAreaInsets: noInsets,
            auxiliaryTopLeftArea: CGRect(x: 130, y: 910, width: 640, height: 40),
            auxiliaryTopRightArea: CGRect(x: 870, y: 910, width: 590, height: 40)
        )
        assert(abs(asymmetricNotchCenter - frame.midX) < 0.001)

        let ordinaryTopPadding = LauncherScreenGeometry.topChromePadding(
            base: 34,
            maximum: 120,
            screenFrame: frame,
            safeAreaInsets: noInsets,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            obstructionGap: LauncherChromeLayout.notchVerticalGap
        )
        assert(ordinaryTopPadding == 34)

        // The vertical result comes from the actual 40-point auxiliary top
        // band, not from either area's asymmetric horizontal width.
        let notchedTopPadding = LauncherScreenGeometry.topChromePadding(
            base: 34,
            maximum: 120,
            screenFrame: frame,
            safeAreaInsets: NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: CGRect(x: 130, y: 910, width: 640, height: 40),
            auxiliaryTopRightArea: CGRect(x: 870, y: 910, width: 590, height: 40),
            obstructionGap: LauncherChromeLayout.notchVerticalGap
        )
        assert(notchedTopPadding == 64)
        assert(notchedTopPadding - 40 == LauncherChromeLayout.notchVerticalGap)

        // Some macOS/display combinations expose only safeAreaInsets and no
        // auxiliary notch rectangles. They must retain the same visible gap.
        let safeAreaOnlyTopPadding = LauncherScreenGeometry.topChromePadding(
            base: 34,
            maximum: 120,
            screenFrame: frame,
            safeAreaInsets: NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            obstructionGap: LauncherChromeLayout.notchVerticalGap
        )
        assert(safeAreaOnlyTopPadding == 56)

        let insets = LauncherScreenGeometry.visibleInsets(
            screenFrame: frame,
            visibleFrame: CGRect(x: 100, y: 130, width: 1_440, height: 820)
        )
        assert(insets == LauncherVisibleInsets(left: 0, right: 0, bottom: 80))

        let dockSafeBottom = LauncherScreenGeometry.dockSafeBottomPadding(
            base: 24,
            visibleBottomInset: insets.bottom,
            labelSafety: 12,
            iconSafety: 14
        )
        assert(dockSafeBottom == 106)
        assert(
            LauncherScreenGeometry.errorBannerBottomInset(
                bottomPadding: dockSafeBottom
            ) == 164
        )

        // At the 100 pt factory icon preference a bottom Dock still owns its
        // full visible-frame reserve, plus label and icon breathing room.
        let defaultIconDockSafeBottom = LauncherScreenGeometry.dockSafeBottomPadding(
            base: 24,
            visibleBottomInset: insets.bottom,
            labelSafety: 12,
            iconSafety: 12
        )
        assert(defaultIconDockSafeBottom == 104)
        assert(
            LauncherScreenGeometry.errorBannerBottomInset(
                bottomPadding: defaultIconDockSafeBottom
            ) == 162
        )
    }()

    static func run() {
        _ = runOnce
    }
}
#endif

private enum LauncherPointerPhase: Equatable {
    case pressing
    case dragging
    case ignored
}

private enum LauncherPagingEdge: Equatable {
    case previous
    case next
}

private enum LauncherDragTuning {
    /// Enough to reject ordinary click jitter while making a deliberate mouse
    /// or trackpad move feel immediate.
    static let activationDistance: CGFloat = 5
    static let combineDwellMilliseconds = 120
    /// Folder expansion is timed from the first stable centre hit, rather than
    /// after a second chained combine timer. This keeps the interaction both
    /// deliberate and visibly responsive.
    static let folderExpansionDwellMilliseconds = 220
    static let edgePageDwellMilliseconds = 340
    static let cancelDropSize = CGSize(width: 168, height: 44)
}

@MainActor
private enum LauncherDragDiagnostics {
    private static let environment = ProcessInfo.processInfo.environment
    private static let filePath = environment[
        "LAUNCH_DRAG_DIAGNOSTICS_PATH"
    ]?.trimmingCharacters(in: .whitespacesAndNewlines)
    private static let enabled = environment["LAUNCH_DRAG_DIAGNOSTICS"] == "1"
        || filePath?.isEmpty == false

    static func log(_ message: String) {
        guard enabled else { return }
        guard let data = "[LaunchDrag] \(message)\n".data(using: .utf8) else {
            return
        }

        // GUI processes do not reliably surface NSLog in a user's Console
        // query. stderr remains useful for terminal launches, while the optional
        // explicit path makes candidate-build diagnostics deterministic.
        FileHandle.standardError.write(data)
        guard let filePath, !filePath.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: filePath) {
            _ = FileManager.default.createFile(atPath: filePath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: filePath) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}

private func launcherEffectiveDragLocation(
    _ value: DragGesture.Value,
    clampedTo bounds: CGRect
) -> CGPoint {
    return CGPoint(
        x: min(max(bounds.minX, value.location.x), bounds.maxX),
        y: min(max(bounds.minY, value.location.y), bounds.maxY)
    )
}

private enum LauncherMainDropTarget: Equatable {
    case cancel
    case combine(entryID: UUID)
    case insertIntoFolder(entryID: UUID, beforeApplicationID: String?)
    case insertBefore(entryID: UUID)
    case insertAfter(entryID: UUID)
    case endOfPage
}

private enum LauncherFolderDropTarget: Equatable {
    case cancel
    case insertBefore(applicationID: String)
    case insertAfter(applicationID: String)
    case endOfFolder
    case moveOutBefore(entryID: UUID, pageIndex: Int)
    case moveOutAfter(entryID: UUID, pageIndex: Int)
    case moveOutEnd(pageIndex: Int)
    case moveIntoFolder(folderID: UUID, pageIndex: Int)
}

private extension LauncherFolderDropTarget {
    var isExternalFolderDropTarget: Bool {
        switch self {
        case .cancel, .moveOutBefore, .moveOutAfter, .moveOutEnd, .moveIntoFolder:
            return true
        case .insertBefore, .insertAfter, .endOfFolder:
            return false
        }
    }

    var dragStatus: LauncherFolderDragStatus? {
        switch self {
        case .cancel:
            return LauncherFolderDragStatus(
                title: LaunchText.value("取消", "Cancel"),
                systemImage: "xmark"
            )
        case .moveIntoFolder:
            return LauncherFolderDragStatus(
                title: LaunchText.value("放入文件夹", "Move to Folder"),
                systemImage: "folder.badge.plus"
            )
        case .moveOutBefore, .moveOutAfter, .moveOutEnd:
            return LauncherFolderDragStatus(
                title: LaunchText.value("移出文件夹", "Move Out"),
                systemImage: "arrow.up.forward.app"
            )
        case .endOfFolder:
            return LauncherFolderDragStatus(
                title: LaunchText.value("移到末尾", "Move to End"),
                systemImage: "arrow.down.to.line"
            )
        case .insertBefore, .insertAfter:
            return nil
        }
    }
}

private struct LauncherFolderExternalDragPreview: Equatable {
    let sourceApplicationID: String
    let placeholderEntryID: UUID
    var target: LauncherFolderDropTarget
}

private struct LauncherFolderDragStatus: Equatable {
    let title: String
    let systemImage: String
}

private struct LauncherMainPointerSession: Equatable {
    let id: UUID
    /// The page whose recognizer owns this mouse-down sequence. It stays
    /// hit-testable until mouse-up even if edge paging changes the destination.
    let gesturePageIndex: Int
    /// The page that will receive a reorder/combine operation on mouse-up.
    var pageIndex: Int
    let sourceEntryID: UUID?
    var phase: LauncherPointerPhase
    var longPressTriggered: Bool
    var dropTarget: LauncherMainDropTarget?
    var pendingCombineEntryID: UUID?
    var combineDwellID: UUID?
    var folderExpansionDwellID: UUID?
    var expandedFolderEntryID: UUID?
    var expandedFolderHasEnteredPanel: Bool
    var pagingEdge: LauncherPagingEdge?
    var edgeDwellID: UUID?
    var requiresEdgeExit: Bool
}

@MainActor
struct LauncherView: View {
    @ObservedObject var model: LauncherModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchIsFocused: Bool

    // Stored as an identity-only State reference so phase publications do not
    // invalidate LauncherView; only active icon leaves observe the clock.
    @State private var wiggleClock = LauncherWiggleClock()
    @State private var selectedEntryID: UUID?
    @State private var showsKeyboardSelection = false
    @State private var selectedFolderApplicationID: String?
    @State private var renameDraft = ""
    @State private var folderBeingRenamed: LaunchFolder?
    @State private var isEditing = false
    @State private var applicationPendingDeletion: InstalledApplication?
    @State private var applicationPendingWeChatRebuild: InstalledApplication?
    @State private var deletingApplicationIDs = Set<String>()
    @State private var mainGridGeometry = LauncherMainGridGeometryState()
    @State private var folderGridGeometry = LauncherFolderGridGeometryState()
    @State private var hoverFolderGeometry = LauncherFolderGridGeometryState()
    @State private var mainPointerSession: LauncherMainPointerSession?
    @State private var mainPointerLocation = LauncherPointerLocationState()
    @State private var staleMainPointerCleanupTask: Task<Void, Never>?
    @State private var launcherScreen: NSScreen?
    @State private var folderExternalDragPreview: LauncherFolderExternalDragPreview?
    @State private var folderDragIsActive = false
    @State private var folderPointerLocation = LauncherPointerLocationState()

    init(model: LauncherModel) {
#if DEBUG
        LauncherDropGeometryDebugChecks.run()
        LauncherTileLayoutDebugChecks.run()
        LauncherScreenGeometryDebugChecks.run()
#endif
        self.model = model
    }

    var body: some View {
        GeometryReader { geometry in
            launcherScene(in: geometry.size)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            mainPointerSession = nil
            selectFirstVisibleEntryIfNeeded()
            showsKeyboardSelection = false
            searchIsFocused = true
            wiggleClock.setActive(isEditing && !reduceMotion)
        }
        .onChange(of: model.currentPageEntries) { _, _ in
            if let sourceEntryID = mainPointerSession?.sourceEntryID,
               topLevelEntry(withID: sourceEntryID) == nil {
                cancelMainPointerSession()
            }
            selectFirstVisibleEntryIfNeeded()
            showsKeyboardSelection = false
        }
        .onChange(of: model.layout) { _, _ in
            // Reconciliation, hiding, rescans and any other external layout
            // mutation invalidate every cached drag identity and frame. Local
            // drops clear their session before mutating the model, so this only
            // quarantines an in-flight pointer sequence whose world changed.
            cancelMainPointerSession()
        }
        .onChange(of: model.currentPage) { _, pageIndex in
            // Edge paging updates the session's destination before publishing
            // the model page. Every other page change cancels this mouse-down.
            if let session = mainPointerSession,
               session.phase == .dragging,
               session.pageIndex == pageIndex {
                var updated = session
                // Give a stationary pointer an immediate, reversible preview
                // on the newly revealed page. Without this safe edge slot the
                // page would turn but no gap would appear until the mouse moved
                // again. A subsequent movement replaces this with the precise
                // frame-derived insertion or combine target.
                switch session.pagingEdge {
                case .previous:
                    if model.layout.pages.indices.contains(pageIndex),
                       let firstEntry = model.layout.pages[pageIndex].first {
                        updated.dropTarget = .insertBefore(entryID: firstEntry.id)
                    } else {
                        updated.dropTarget = .endOfPage
                    }
                case .next, nil:
                    updated.dropTarget = .endOfPage
                }
                updated.pendingCombineEntryID = nil
                updated.combineDwellID = nil
                updated.folderExpansionDwellID = nil
                if updated.expandedFolderEntryID != nil {
                    hoverFolderGeometry.reset()
                }
                updated.expandedFolderEntryID = nil
                updated.expandedFolderHasEnteredPanel = false
                mainPointerSession = updated
            } else {
                cancelMainPointerSession()
            }
        }
        .onChange(of: model.searchText) { _, _ in
            cancelMainPointerSession()
        }
        .onChange(of: model.pageInteraction.phase) { _, phase in
            if phase != .idle {
                cancelMainPointerSession()
            }
        }
        .onChange(of: model.openFolderID) { _, folderID in
            cancelMainPointerSession()
            folderExternalDragPreview = nil
            folderDragIsActive = false
            if folderID == nil {
                selectedFolderApplicationID = nil
            } else if let selectedFolderApplicationID,
                      model.currentFolder?.applicationIDs.contains(
                        selectedFolderApplicationID
                      ) == true {
                // Preserve the precise member selected by an atomic hover-folder
                // insertion. Ordinary folder opens still fall through to first.
            } else {
                selectedFolderApplicationID = model.currentFolder?.applicationIDs.first
            }
        }
        .onChange(of: isEditing) { _, editing in
            wiggleClock.setActive(editing && !reduceMotion)
        }
        .onChange(of: reduceMotion) { _, reduced in
            wiggleClock.setActive(isEditing && !reduced)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification
            )
        ) { _ in
            // A sheet already owns key status while an alert is visible, so
            // ordering the launcher out after another app becomes active does
            // not emit a second window-resign notification. Clear every
            // transient editing/alert/drag state on the application-level
            // transition so nothing stale can reappear next time Launch opens.
            resetTransientUIForDeactivation()
        }
        .onDisappear {
            staleMainPointerCleanupTask?.cancel()
            staleMainPointerCleanupTask = nil
            mainPointerSession = nil
            folderExternalDragPreview = nil
            folderDragIsActive = false
            wiggleClock.setActive(false)
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88),
            value: model.openFolderID
        )
        .alert(
            LaunchText.value("重命名文件夹", "Rename Folder"),
            isPresented: Binding(
                get: { folderBeingRenamed != nil },
                set: { if !$0 { folderBeingRenamed = nil } }
            )
        ) {
            TextField(LaunchText.value("文件夹名称", "Folder name"), text: $renameDraft)
            Button(LaunchText.value("取消", "Cancel"), role: .cancel) {
                folderBeingRenamed = nil
            }
            Button(LaunchText.value("重命名", "Rename")) {
                if let folderBeingRenamed {
                    model.renameFolder(folderBeingRenamed.id, to: renameDraft)
                }
                folderBeingRenamed = nil
            }
        } message: {
            Text(LaunchText.value("为这个文件夹输入名称。", "Choose a name for this folder."))
        }
        .alert(
            deletionTitle,
            isPresented: Binding(
                get: { applicationPendingDeletion != nil },
                set: { if !$0 { applicationPendingDeletion = nil } }
            ),
            presenting: applicationPendingDeletion
        ) { application in
            Button(LaunchText.value("取消", "Cancel"), role: .cancel) {
                applicationPendingDeletion = nil
            }
            Button(LaunchText.value("移到废纸篓", "Move to Trash"), role: .destructive) {
                moveApplicationToTrash(application)
            }
        } message: { _ in
            Text(
                LaunchText.value(
                    "要将此应用移到废纸篓吗？",
                    "Move this application to the Trash?"
                )
            )
        }
        .alert(
            LaunchText.value(
                "创建或更新微信双开版？",
                "Create or Update WeChat Companion?"
            ),
            isPresented: Binding(
                get: { applicationPendingWeChatRebuild != nil },
                set: { if !$0 { applicationPendingWeChatRebuild = nil } }
            ),
            presenting: applicationPendingWeChatRebuild
        ) { application in
            Button(LaunchText.value("取消", "Cancel"), role: .cancel) {
                applicationPendingWeChatRebuild = nil
            }
            Button(
                LaunchText.value("创建或更新", "Create or Update"),
                role: .destructive
            ) {
                rebuildWeChatCompanion(application)
            }
        } message: { _ in
            Text(
                LaunchText.value(
                    "每次都会从当前微信重建并替换旧双开版。这里只替换应用本体，聊天数据通常保存在应用之外。",
                    "This rebuilds the companion from the current WeChat app and replaces the old copy. Only the app itself is replaced; chat data is usually stored outside the app."
                )
            )
        }
    }

    private func launcherScene(in size: CGSize) -> some View {
        let metrics = gridMetrics(in: size)
        let presentsFolderChrome = model.currentFolder != nil
            && folderExternalDragPreview == nil
        let dragPresentationIsActive = mainPointerSession?.phase == .dragging
            || folderDragIsActive
        return ZStack {
            LauncherBackdrop(screen: launcherScreen ?? bestMatchingScreen(for: size))
                .contentShape(Rectangle())
                .onTapGesture(perform: handleBackgroundTap)

            launcherContent(
                metrics: metrics,
                hidesTopBar: dragPresentationIsActive
            )
                .blur(radius: presentsFolderChrome ? 2.5 : 0)
                .scaleEffect(presentsFolderChrome ? 0.988 : 1)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.2),
                    value: presentsFolderChrome
                )

            openFolderLayer(in: size, metrics: metrics)
            externalFolderDragLayer
            dragCancellationLayer(
                metrics: metrics,
                isActive: dragPresentationIsActive
            )
            weChatRebuildProgressLayer(metrics: metrics)
            errorLayer(metrics: metrics)

            LauncherKeyboardMonitor(
                perform: handleKeyboardAction,
                windowDidDeactivate: resetTransientUIForDeactivation,
                windowDidActivate: handleLauncherWindowActivation,
                windowScreenDidChange: { screen in
                    launcherScreen = screen
                }
            )
            .frame(width: 0, height: 0)
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: LauncherCoordinateSpaces.launcherRoot)
    }

    @ViewBuilder
    private func openFolderLayer(
        in size: CGSize,
        metrics: LauncherGridMetrics
    ) -> some View {
        if let folder = model.currentFolder {
            let externallyDragging = folderExternalDragPreview != nil
            Color.black.opacity(externallyDragging ? 0 : 0.24)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: model.closeFolder)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12),
                    value: externallyDragging
                )

            folderPanel(folder, in: size, metrics: metrics)
                // Opacity preserves the panel and its root DragGesture. Removing
                // it from the hierarchy here would lose the eventual mouse-up.
                .opacity(externallyDragging ? 0 : 1)
                .accessibilityHidden(externallyDragging)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12),
                    value: externallyDragging
                )
        }
    }

    private func folderPanel(
        _ folder: LaunchFolder,
        in size: CGSize,
        metrics: LauncherGridMetrics
    ) -> some View {
        LauncherFolderPanel(
            folder: folder,
            applications: model.applications,
            topLevelPages: model.layout.pages,
            currentPage: model.currentPage,
            launcherSize: size,
            mainIconSize: metrics.iconSize,
            mainGridGeometry: mainGridGeometry,
            gridGeometry: folderGridGeometry,
            pointerLocation: folderPointerLocation,
            wiggleClock: wiggleClock,
            cancelDropFrame: metrics.cancelDropFrameInRoot,
            dragIsActive: $folderDragIsActive,
            iconProvider: model.icon,
            iconSize: CGFloat(model.preferences.iconSize),
            showLabels: model.preferences.showLabels,
            isEditing: isEditing,
            deletingApplicationIDs: deletingApplicationIDs,
            selectedApplicationID: $selectedFolderApplicationID,
            canDelete: model.canUninstall,
            beginEditing: enterEditingMode,
            finishEditing: finishEditing,
            requestDelete: requestDeletion,
            launch: model.launch,
            hide: model.hide,
            canRebuildWeChatCompanion: model.canRebuildWeChatCompanion,
            isRebuildingWeChatCompanion: model.isRebuildingWeChatCompanion,
            requestWeChatCompanionRebuild: requestWeChatCompanionRebuild,
            removeFromFolder: { applicationID in
                model.removeFromFolder(appID: applicationID, folderID: folder.id)
            },
            reorder: { draggedID, targetID in
                model.reorderApplication(
                    in: folder.id,
                    draggedID: draggedID,
                    before: targetID
                )
            },
            moveOut: { applicationID, destinationPage, beforeEntryID in
                model.moveApplicationOutOfFolder(
                    appID: applicationID,
                    folderID: folder.id,
                    destinationPage: destinationPage,
                    before: beforeEntryID
                )
            },
            moveIntoFolder: { applicationID, destinationFolderID in
                model.moveApplication(
                    appID: applicationID,
                    fromFolderID: folder.id,
                    toFolderID: destinationFolderID
                )
            },
            selectPage: model.selectPageKeepingFolderOpen,
            externalDragPreview: $folderExternalDragPreview,
            rename: { beginRenaming(folder) },
            close: model.closeFolder
        )
        .frame(
            width: min(max(560, size.width * 0.72), 980),
            height: min(max(390, size.height * 0.62), 680)
        )
        .transition(
            reduceMotion
                ? .opacity
                : .scale(scale: 0.92).combined(with: .opacity)
        )
        .zIndex(2)
    }

    @ViewBuilder
    private var externalFolderDragLayer: some View {
        if let preview = folderExternalDragPreview,
           let application = model.applications[preview.sourceApplicationID] {
            LauncherFolderFloatingDragPreview(
                pointerLocation: folderPointerLocation,
                application: application,
                icon: model.icon(for: preview.sourceApplicationID),
                coordinateOffset: .zero,
                status: preview.target.dragStatus
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(3)
        }
    }

    private func dragCancellationLayer(
        metrics: LauncherGridMetrics,
        isActive: Bool
    ) -> some View {
        let isTargeted = mainPointerSession?.dropTarget == .cancel
            || folderExternalDragPreview?.target == .cancel
        return LauncherDragCancelZone(isTargeted: isTargeted)
            .frame(
                width: metrics.cancelDropFrameInRoot.width,
                height: metrics.cancelDropFrameInRoot.height
            )
            .position(
                x: metrics.cancelDropFrameInRoot.midX,
                y: metrics.cancelDropFrameInRoot.midY
            )
            .opacity(isActive ? 1 : 0)
            .scaleEffect(isActive ? 1 : 0.94)
            .offset(y: isActive ? 0 : -8)
            .animation(
                reduceMotion || !isActive
                    ? nil
                    : .easeOut(duration: 0.16),
                value: isActive
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(6)
    }

    @ViewBuilder
    private func errorLayer(metrics: LauncherGridMetrics) -> some View {
        if let errorMessage = model.errorMessage {
            let errorToken = model.errorToken
            VStack {
                Spacer()
                LauncherErrorBanner(
                    message: errorMessage,
                    dismiss: model.clearError
                )
                .frame(maxWidth: min(640, metrics.gridWidth))
                .padding(.bottom, metrics.errorBannerBottomInset)
            }
            .padding(.leading, metrics.leadingPadding)
            .padding(.trailing, metrics.trailingPadding)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(3)
            .task(id: errorToken) {
                guard let errorToken else { return }
                do {
                    try await Task.sleep(for: .milliseconds(4_600))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                model.clearError(ifCurrent: errorToken)
            }
        }
    }

    @ViewBuilder
    private func weChatRebuildProgressLayer(
        metrics: LauncherGridMetrics
    ) -> some View {
        if model.isRebuildingWeChatCompanion {
            VStack {
                Spacer()
                LauncherProgressBanner(
                    title: LaunchText.value(
                        "正在创建双开版…",
                        "Creating WeChat Companion…"
                    )
                )
                .frame(maxWidth: min(640, metrics.gridWidth))
                .padding(.bottom, metrics.errorBannerBottomInset)
            }
            .padding(.leading, metrics.leadingPadding)
            .padding(.trailing, metrics.trailingPadding)
            .transition(
                reduceMotion
                    ? .opacity
                    : .move(edge: .bottom).combined(with: .opacity)
            )
            .allowsHitTesting(false)
            .zIndex(4)
        }
    }

    private func launcherContent(
        metrics: LauncherGridMetrics,
        hidesTopBar: Bool
    ) -> some View {
        VStack(spacing: 0) {
            LauncherTopBar(
                searchText: $model.searchText,
                searchIsFocused: $searchIsFocused,
                isEditing: isEditing,
                searchCenterOffset: metrics.searchCenterOffset,
                showSettings: model.showSettings,
                finishEditing: finishEditing
            )
            .frame(width: metrics.gridWidth)
            .padding(.top, metrics.topPadding)
            // Keep this exact frame in layout throughout the drag. Only its
            // presentation changes, so grid and pointer coordinate spaces are
            // bit-for-bit stable while the cancel target replaces it visually.
            .opacity(hidesTopBar ? 0 : 1)
            .scaleEffect(hidesTopBar ? 0.985 : 1)
            .allowsHitTesting(!hidesTopBar)
            .accessibilityHidden(hidesTopBar)
            .animation(
                reduceMotion || hidesTopBar
                    ? nil
                    : .easeOut(duration: 0.14),
                value: hidesTopBar
            )

            Spacer(minLength: LauncherChromeLayout.gridTopGap)

            if model.isScanning && model.applications.isEmpty {
                LauncherLoadingView()
                    .frame(width: metrics.gridWidth, height: metrics.gridHeight)
            } else if model.currentPageEntries.isEmpty {
                LauncherEmptyView(
                    isSearching: !model.searchText.isEmpty,
                    clearSearch: { model.searchText = "" },
                    rescan: model.rescan
                )
                    .frame(width: metrics.gridWidth, height: metrics.gridHeight)
            } else {
                applicationGrid(metrics: metrics)
            }

            Spacer(minLength: LauncherChromeLayout.gridBottomGap)

            LauncherPageDots(
                pageCount: model.pageCount,
                currentPage: model.currentPage,
                selectPage: { page in
                    model.selectPage(page)
                    selectFirstVisibleEntryIfNeeded(force: true)
                }
            )
            .opacity(model.pageCount > 1 ? 1 : 0)
            .allowsHitTesting(model.pageCount > 1)
            .accessibilityHidden(model.pageCount <= 1)
            .padding(.bottom, metrics.bottomPadding)
        }
        .padding(.leading, metrics.leadingPadding)
        .padding(.trailing, metrics.trailingPadding)
    }

    private func applicationGrid(metrics: LauncherGridMetrics) -> some View {
        let columns = Array(
            repeating: GridItem(
                .flexible(minimum: 1),
                spacing: metrics.horizontalSpacing
            ),
            count: metrics.columns
        )
        let tileWidth = (
            metrics.gridWidth
                - metrics.horizontalSpacing * CGFloat(max(0, metrics.columns - 1))
        ) / CGFloat(metrics.columns)
        let pages = pageEntriesForDisplay
        let selectedPage = min(max(0, model.currentPage), max(0, pages.count - 1))
        let gesturePage = mainPointerSession?.gesturePageIndex
        let pagePosition = visualPagePosition(pageCount: pages.count)

        return HStack(spacing: 0) {
            ForEach(pages.indices, id: \.self) { pageIndex in
                applicationPage(
                    entries: pages[pageIndex],
                    pageIndex: pageIndex,
                    columns: columns,
                    tileWidth: tileWidth,
                    metrics: metrics
                )
                .frame(width: metrics.gridWidth, height: metrics.gridHeight)
                // Keep the recognizer that received mouse-down alive while an
                // edge page turn moves that page out of the viewport.
                .allowsHitTesting(pageIndex == selectedPage || pageIndex == gesturePage)
                .accessibilityHidden(pageIndex != selectedPage)
            }
        }
        .frame(
            width: metrics.gridWidth * CGFloat(max(1, pages.count)),
            height: metrics.gridHeight,
            alignment: .leading
        )
        .offset(x: -pagePosition * metrics.gridWidth)
        .animation(
            pageTransitionAnimation,
            value: pagePosition
        )
        .frame(
            width: metrics.gridWidth,
            height: metrics.gridHeight,
            alignment: .leading
        )
        .clipped()
        // Tile frames, DragGesture locations and the floating preview all use
        // this stable viewport. It does not move with the paged HStack.
        .coordinateSpace(name: LauncherCoordinateSpaces.mainGrid)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: LauncherMainGridFramePreferenceKey.self,
                        value: proxy.frame(in: .named(LauncherCoordinateSpaces.launcherRoot))
                    )
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                mainHoverFolderLayer(pageIndex: selectedPage, metrics: metrics)
                mainDragOverlay(pageIndex: selectedPage, metrics: metrics)
            }
        }
        .onPreferenceChange(LauncherTileFramePreferenceKey.self) { frames in
            mainGridGeometry.update(tileFrames: frames)
        }
        .onPreferenceChange(LauncherRootTileFramePreferenceKey.self) { frames in
            mainGridGeometry.update(rootTileFrames: frames)
        }
        .onPreferenceChange(LauncherMainGridFramePreferenceKey.self) { frame in
            mainGridGeometry.update(rootFrame: frame)
        }
        .onPreferenceChange(LauncherHoverFolderTileFramePreferenceKey.self) { frames in
            hoverFolderGeometry.update(tileFrames: frames)
        }
        .onPreferenceChange(LauncherHoverFolderPanelFramePreferenceKey.self) { frame in
            hoverFolderGeometry.update(panelFrame: frame)
        }
        .onPreferenceChange(LauncherHoverFolderViewportFramePreferenceKey.self) { frame in
            hoverFolderGeometry.update(viewportFrame: frame)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            LaunchText.value(
                "应用，第 \(model.currentPage + 1) 页，共 \(model.pageCount) 页",
                "Applications, page \(model.currentPage + 1) of \(model.pageCount)"
            )
        )
    }

    private func visualPagePosition(pageCount: Int) -> CGFloat {
        let lastPage = CGFloat(max(0, pageCount - 1))
        let interaction = model.pageInteraction
        switch interaction.phase {
        case .idle:
            return min(max(0, CGFloat(model.currentPage)), lastPage)

        case .tracking:
            let progressScale: CGFloat = reduceMotion ? 0.14 : 1
            let position = CGFloat(interaction.originPage)
                - CGFloat(interaction.progress) * progressScale
            // The model already rubber-bands physical edges. Keep a modest
            // visual overshoot so the page remains attached to the fingers.
            return min(max(-0.16, position), lastPage + 0.16)

        case .settling:
            return min(
                max(0, CGFloat(interaction.targetPage ?? model.currentPage)),
                lastPage
            )
        }
    }

    private var pageTransitionAnimation: Animation? {
        guard !reduceMotion else { return nil }
        switch model.pageInteraction.phase {
        case .tracking:
            return nil
        case .settling:
            return .timingCurve(0.18, 0.82, 0.22, 1, duration: 0.24)
        case .idle:
            return .timingCurve(0.2, 0.82, 0.2, 1, duration: 0.3)
        }
    }

    private func applicationPage(
        entries: [LaunchEntry],
        pageIndex: Int,
        columns: [GridItem],
        tileWidth: CGFloat,
        metrics: LauncherGridMetrics
    ) -> some View {
        let pageIsEditing = isEditing
            && model.openFolderID == nil
            && pageIndex == model.currentPage
        let pageIsDragging = mainPointerSession?.phase == .dragging
        let pageWiggleIsActive = pageIsEditing && !pageIsDragging && !reduceMotion
        let pageReportsGeometry = pageIndex == model.currentPage
            || pageIndex == mainPointerSession?.gesturePageIndex
        let pageReportsRootGeometry = pageReportsGeometry
            && model.currentFolder != nil
        let usedRows = LauncherTileLayout.usedRows(
            itemCount: entries.count,
            columns: metrics.columns
        )
        let requiredGridHeight = LauncherTileLayout.requiredGridHeight(
            itemCount: entries.count,
            columns: metrics.columns,
            iconSize: metrics.iconSize,
            spacing: metrics.verticalSpacing,
            showLabel: model.preferences.showLabels
        )
        // Preserve the ScrollView itself for the small-screen/large-icon
        // accessibility fallback, but do not let a normally fitting page
        // consume wheel gestures or rubber-band like a pageable surface.
        let pageOverflowsVertically = usedRows > 0
            && LauncherTileLayout.requiresVerticalScrolling(
                requiredHeight: requiredGridHeight,
                availableHeight: metrics.gridHeight
            )

        return ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                LazyVGrid(
                columns: columns,
                alignment: .center,
                spacing: metrics.verticalSpacing
            ) {
                ForEach(entries) { entry in
                    LauncherEntryTile(
                        entry: entry,
                        pageIndex: pageIndex,
                        applications: model.applications,
                        iconProvider: model.icon,
                        iconSize: metrics.iconSize,
                        tileWidth: tileWidth,
                        showLabel: model.preferences.showLabels,
                        isSelected: showsKeyboardSelection && selectedEntryID == entry.id,
                        isEditing: pageIsEditing,
                        isWiggling: pageWiggleIsActive,
                        wiggleClock: wiggleClock,
                        reportsDropGeometry: pageReportsGeometry,
                        reportsRootGeometry: pageReportsRootGeometry,
                        isBeingDragged: (
                            pageIsDragging
                                && mainPointerSession?.sourceEntryID == entry.id
                        ) || folderExternalDragPreview?.placeholderEntryID == entry.id,
                        dropIntent: mainDropIntent(
                            for: entry.id,
                            pageIndex: pageIndex
                        ),
                        combinePreviewSourceApplicationID: combinePreviewSourceApplicationID(
                            for: entry.id,
                            pageIndex: pageIndex
                        ),
                        canDelete: entry.applicationID.map(model.canUninstall) ?? false,
                        isDeleting: entry.applicationID.map(deletingApplicationIDs.contains) ?? false,
                        activate: {
                            selectedEntryID = entry.id
                            activate(entry)
                        },
                        requestDelete: {
                            guard let applicationID = entry.applicationID else { return }
                            requestDeletion(applicationID)
                        },
                        hideApplication: model.hide,
                        canRebuildWeChatCompanion: model.canRebuildWeChatCompanion,
                        isRebuildingWeChatCompanion: model.isRebuildingWeChatCompanion,
                        requestWeChatCompanionRebuild: requestWeChatCompanionRebuild,
                        renameFolder: beginRenaming,
                        removeFolder: model.removeFolder
                    )
                    .id(entry.id)
                }
                }
                .animation(
                reduceMotion ? nil : .smooth(duration: 0.2),
                value: entries.map(\.id)
            )
            .frame(
                maxWidth: .infinity,
                minHeight: metrics.gridHeight,
                alignment: .top
            )
            .contentShape(Rectangle())
                .simultaneousGesture(
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(LauncherCoordinateSpaces.mainGrid)
                )
                .onChanged { value in
                    handleMainPointerChanged(
                        value,
                        pageIndex: pageIndex,
                        metrics: metrics
                    )
                }
                .onEnded { value in
                    handleMainPointerEnded(
                        value,
                        pageIndex: pageIndex,
                        metrics: metrics
                    )
                },
                including: .all
                )
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(!pageOverflowsVertically)
            // This public size-aware policy also suppresses horizontal elasticity:
            // the vertical ScrollView's content never exceeds its fixed width.
            .scrollBounceBehavior(
                .basedOnSize,
                axes: [.horizontal, .vertical]
            )
            .frame(width: metrics.gridWidth, height: metrics.gridHeight)
            .accessibilityLabel(
                LaunchText.value("第 \(pageIndex + 1) 页", "Page \(pageIndex + 1)")
            )
            .onChange(of: selectedEntryID) { _, entryID in
                guard pageOverflowsVertically,
                      pageIndex == model.currentPage,
                      let entryID,
                      entries.contains(where: { $0.id == entryID }),
                      mainPointerSession?.phase != .dragging else {
                    return
                }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    scrollProxy.scrollTo(entryID, anchor: .center)
                }
            }
        }
    }

    private var pageEntriesForDisplay: [[LaunchEntry]] {
        let basePages = basePageEntriesForDisplay
        guard model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return basePages
        }

        if let preview = folderExternalDragPreview {
            let insertion: LauncherProvisionalInsertion<UUID>
            switch preview.target {
            case let .moveOutBefore(entryID, _):
                insertion = .before(entryID)
            case let .moveOutAfter(entryID, _):
                insertion = .after(entryID)
            case let .moveOutEnd(pageIndex):
                insertion = .end(pageIndex: pageIndex)
            case .cancel, .moveIntoFolder, .insertBefore, .insertAfter, .endOfFolder:
                return basePages
            }
            return LauncherDragPreviewLayout.pages(
                from: basePages,
                inserting: .application(
                    preview.sourceApplicationID,
                    id: preview.placeholderEntryID
                ),
                insertion: insertion,
                pageCapacity: model.preferences.pageCapacity
            )
        }

        guard let session = mainPointerSession,
              session.phase == .dragging,
              let sourceEntryID = session.sourceEntryID,
              let target = session.dropTarget else {
            return basePages
        }

        let insertion: LauncherProvisionalInsertion<UUID>
        switch target {
        case let .insertBefore(entryID):
            insertion = .before(entryID)
        case let .insertAfter(entryID):
            insertion = .after(entryID)
        case .endOfPage:
            insertion = .end(pageIndex: session.pageIndex)
        case .cancel, .combine, .insertIntoFolder:
            return basePages
        }

        return LauncherDragPreviewLayout.pages(
            from: basePages,
            moving: sourceEntryID,
            insertion: insertion,
            pageCapacity: model.preferences.pageCapacity
        )
    }

    private var basePageEntriesForDisplay: [[LaunchEntry]] {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return model.layout.pages.isEmpty ? [[]] : model.layout.pages
        }

        let entries = model.visibleEntries
        let capacity = max(1, model.preferences.pageCapacity)
        guard !entries.isEmpty else { return [[]] }
        return stride(from: 0, to: entries.count, by: capacity).map { start in
            let end = min(start + capacity, entries.count)
            return Array(entries[start..<end])
        }
    }

    private func gridMetrics(in size: CGSize) -> LauncherGridMetrics {
        let columns = max(1, model.preferences.columns)
        let rows = max(1, model.preferences.rows)
        let requestedIconSize = max(1, CGFloat(model.preferences.iconSize))

        let screen = launcherScreen ?? bestMatchingScreen(for: size)
        let screenFrame = screen?.frame ?? CGRect(origin: .zero, size: size)
        let visibleFrame = screen?.visibleFrame ?? screenFrame
        let safeAreaInsets = screen?.safeAreaInsets
            ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let screenInsets = LauncherScreenGeometry.visibleInsets(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
        let baseHorizontalPadding = min(130, max(18, size.width * 0.045))
        let leadingPadding = min(
            size.width * 0.28,
            baseHorizontalPadding + screenInsets.left
        )
        let trailingPadding = min(
            size.width * 0.28,
            baseHorizontalPadding + screenInsets.right
        )
        let gridWidth = max(
            1,
            min(1_480, size.width - leadingPadding - trailingPadding)
        )
        let baseTopPadding = min(54, max(22, size.height * 0.045))
        let topPadding = LauncherScreenGeometry.topChromePadding(
            base: baseTopPadding,
            maximum: size.height * 0.16,
            screenFrame: screenFrame,
            safeAreaInsets: safeAreaInsets,
            auxiliaryTopLeftArea: screen?.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen?.auxiliaryTopRightArea,
            obstructionGap: LauncherChromeLayout.notchVerticalGap
        )
        let baseBottomPadding = min(42, max(18, size.height * 0.035))
        let labelSafety: CGFloat = model.preferences.showLabels ? 12 : 6
        let iconSafety = min(20, max(8, requestedIconSize * 0.12))
        // `visibleFrame` excludes a visible Dock. Page dots sit above this
        // reserve, and the grid's height budget then scales oversized icons
        // down before their labels can intrude into it.
        let bottomPadding = LauncherScreenGeometry.dockSafeBottomPadding(
            base: baseBottomPadding,
            visibleBottomInset: screenInsets.bottom,
            labelSafety: labelSafety,
            iconSafety: iconSafety
        )

        // Search, page controls and their minimum surrounding gaps are kept out
        // of the grid's budget so large row counts cannot push chrome offscreen.
        let chromeHeight = topPadding
            + LauncherChromeLayout.topBarHeight
            + LauncherChromeLayout.gridTopGap
            + LauncherChromeLayout.gridBottomGap
            + LauncherChromeLayout.pageDotsHeight
            + bottomPadding
        let gridHeight = max(1, size.height - chromeHeight)
        let showLabels = model.preferences.showLabels
        let tileChromeHeight = LauncherTileLayout.chromeHeight(
            showLabel: showLabels
        )

        let horizontalSpacing: CGFloat
        if columns == 1 {
            horizontalSpacing = 0
        } else {
            let requestedRemaining = gridWidth
                - (requestedIconSize + LauncherTileLayout.iconChrome)
                    * CGFloat(columns)
            horizontalSpacing = min(
                70,
                max(4, requestedRemaining / CGFloat(columns - 1))
            )
        }

        let cellWidth = (
            gridWidth - horizontalSpacing * CGFloat(max(0, columns - 1))
        ) / CGFloat(columns)
        let widthFittedIconSize = max(
            8,
            cellWidth - LauncherTileLayout.iconChrome
        )

        let verticalSpacing: CGFloat
        if rows == 1 {
            verticalSpacing = 0
        } else {
            let requestedRemaining = gridHeight
                - (requestedIconSize + tileChromeHeight) * CGFloat(rows)
            verticalSpacing = min(
                38,
                max(4, requestedRemaining / CGFloat(rows - 1))
            )
        }

        let heightFittedIconSize = LauncherTileLayout.fittedIconSize(
            availableHeight: gridHeight,
            rows: rows,
            spacing: verticalSpacing,
            showLabel: showLabels
        )

        // Keep icons readable when height is unusually constrained; the grid is
        // vertically scrollable as a final fallback. Width never overflows.
        let heightAdjustedIconSize = min(
            requestedIconSize,
            max(24, heightFittedIconSize)
        )
        let iconSize = max(8, min(widthFittedIconSize, heightAdjustedIconSize))

        let displaySearchCenterX = LauncherScreenGeometry.visualSearchCenterX(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            safeAreaInsets: safeAreaInsets,
            auxiliaryTopLeftArea: screen?.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen?.auxiliaryTopRightArea
        )
        let launcherSearchCenterX = LauncherScreenGeometry.localSearchCenterX(
            displayCenterX: displaySearchCenterX,
            screenFrame: screenFrame,
            launcherWidth: size.width
        )
        let availableContentWidth = max(
            1,
            size.width - leadingPadding - trailingPadding
        )
        let topBarCenterX = leadingPadding + availableContentWidth / 2
        let minimumSearchOffset = -gridWidth / 2
            + LauncherChromeLayout.searchWidth / 2
        let maximumSearchOffset = gridWidth / 2
            - LauncherChromeLayout.searchTrailingExtent
        let rawSearchOffset = launcherSearchCenterX - topBarCenterX
        let searchCenterOffset: CGFloat
        if minimumSearchOffset <= maximumSearchOffset {
            searchCenterOffset = min(
                max(minimumSearchOffset, rawSearchOffset),
                maximumSearchOffset
            )
        } else {
            searchCenterOffset = 0
        }
        let errorBannerBottomInset = LauncherScreenGeometry
            .errorBannerBottomInset(bottomPadding: bottomPadding)
        let cancelDropFrameInRoot = CGRect(
            x: topBarCenterX + searchCenterOffset
                - LauncherDragTuning.cancelDropSize.width / 2,
            y: topPadding,
            width: LauncherDragTuning.cancelDropSize.width,
            height: LauncherDragTuning.cancelDropSize.height
        )
        let gridOrigin = CGPoint(
            x: topBarCenterX - gridWidth / 2,
            y: topPadding
                + LauncherChromeLayout.topBarHeight
                + LauncherChromeLayout.gridTopGap
        )
        let cancelDropFrameInGrid = cancelDropFrameInRoot.offsetBy(
            dx: -gridOrigin.x,
            dy: -gridOrigin.y
        )

        return LauncherGridMetrics(
            columns: columns,
            iconSize: iconSize,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing,
            leadingPadding: leadingPadding,
            trailingPadding: trailingPadding,
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            searchCenterOffset: searchCenterOffset,
            errorBannerBottomInset: errorBannerBottomInset,
            cancelDropFrameInRoot: cancelDropFrameInRoot,
            cancelDropFrameInGrid: cancelDropFrameInGrid
        )
    }

    private func bestMatchingScreen(for size: CGSize) -> NSScreen? {
        let candidates = NSScreen.screens
        guard !candidates.isEmpty else { return NSScreen.main }
        return candidates.min { lhs, rhs in
            let lhsDelta = abs(lhs.frame.width - size.width)
                + abs(lhs.frame.height - size.height)
            let rhsDelta = abs(rhs.frame.width - size.width)
                + abs(rhs.frame.height - size.height)
            return lhsDelta < rhsDelta
        }
    }

    private func handleBackgroundTap() {
        if model.openFolderID != nil {
            model.closeFolder()
        } else {
            dismissFromMainPage()
        }
    }

    private func dismissFromMainPage() {
        mainPointerSession = nil
        if isEditing {
            finishEditing()
            return
        }
        model.dismissLauncher()
    }

    private func resetTransientUIForDeactivation() {
        cancelMainPointerSession()
        folderExternalDragPreview = nil
        searchIsFocused = false

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isEditing = false
            applicationPendingDeletion = nil
            applicationPendingWeChatRebuild = nil
            folderBeingRenamed = nil
            renameDraft = ""
            folderDragIsActive = false
        }
    }

    private func handleLauncherWindowActivation() {
        scheduleStaleMainPointerCleanup()
        guard !isEditing,
              applicationPendingDeletion == nil,
              applicationPendingWeChatRebuild == nil,
              folderBeingRenamed == nil,
              model.openFolderID == nil else {
            return
        }
        Task { @MainActor in
            searchIsFocused = true
        }
    }

    /// A cancellation must survive until this recognizer's `onEnded`. Clearing
    /// the optional early would let a later callback from the same mouse-down
    /// construct a fresh session and accidentally launch or move an item.
    private func cancelMainPointerSession() {
        guard var session = mainPointerSession else { return }
        if session.expandedFolderEntryID != nil {
            hoverFolderGeometry.reset()
        }
        session.phase = .ignored
        session.dropTarget = nil
        session.pendingCombineEntryID = nil
        session.combineDwellID = nil
        session.folderExpansionDwellID = nil
        session.expandedFolderEntryID = nil
        session.expandedFolderHasEnteredPanel = false
        session.pagingEdge = nil
        session.edgeDwellID = nil
        session.requiresEdgeExit = true
        mainPointerSession = session
    }

    /// AppKit can cancel SwiftUI's drag recognizer when the launcher resigns
    /// key status, in which case `onEnded` is not guaranteed. Keep the ignored
    /// latch through the physical mouse-up, then clear it before another
    /// mouse-down can inherit the cancelled sequence.
    private func scheduleStaleMainPointerCleanup() {
        guard let session = mainPointerSession,
              session.phase == .ignored else {
            return
        }
        let sessionID = session.id
        staleMainPointerCleanupTask?.cancel()
        staleMainPointerCleanupTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let active = mainPointerSession,
                      active.id == sessionID,
                      active.phase == .ignored else {
                    return
                }

                if NSEvent.pressedMouseButtons & 1 == 0 {
                    // `handleMainPointerEnded` refuses to construct a session
                    // when this latch is absent, so a late cancelled tail is
                    // harmless after the physical button is known to be up.
                    mainPointerSession = nil
                    return
                }

                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private func handleMainPointerChanged(
        _ value: DragGesture.Value,
        pageIndex gesturePageIndex: Int,
        metrics: LauncherGridMetrics
    ) {
        if mainPointerSession == nil {
            guard gesturePageIndex == model.currentPage else { return }
            let sourceEntryID = mainEntryID(
                at: value.startLocation,
                pageIndex: gesturePageIndex
            )
            let startsOnBadge = sourceEntryID.map { entryID in
                mainPointerStartsOnEditBadge(
                    entryID: entryID,
                    pageIndex: gesturePageIndex,
                    location: value.startLocation,
                    iconSize: metrics.iconSize
                )
            } ?? false
            let pageGestureIsActive = model.pageInteraction.phase != .idle
            let sessionID = UUID()
            mainPointerSession = LauncherMainPointerSession(
                id: sessionID,
                gesturePageIndex: gesturePageIndex,
                pageIndex: gesturePageIndex,
                sourceEntryID: sourceEntryID,
                phase: startsOnBadge || pageGestureIsActive ? .ignored : .pressing,
                longPressTriggered: false,
                dropTarget: nil,
                pendingCombineEntryID: nil,
                combineDwellID: nil,
                folderExpansionDwellID: nil,
                expandedFolderEntryID: nil,
                expandedFolderHasEnteredPanel: false,
                pagingEdge: nil,
                edgeDwellID: nil,
                requiresEdgeExit: false
            )

            if sourceEntryID != nil,
               !startsOnBadge,
               !pageGestureIsActive,
               !isEditing,
               canOrganizeMainGrid {
                scheduleMainLongPress(sessionID: sessionID)
            }
        }

        guard var session = mainPointerSession,
              session.gesturePageIndex == gesturePageIndex else {
            return
        }
        let effectiveLocation = launcherEffectiveDragLocation(
            value,
            clampedTo: CGRect(
                x: 0,
                y: min(0, metrics.cancelDropFrameInGrid.minY),
                width: metrics.gridWidth,
                height: metrics.gridHeight
                    - min(0, metrics.cancelDropFrameInGrid.minY)
            )
        )
        mainPointerLocation.update(effectiveLocation)

        guard session.phase != .ignored else {
            mainPointerSession = session
            return
        }

        let distance = hypot(value.translation.width, value.translation.height)
        if session.phase == .pressing,
           distance > LauncherDragTuning.activationDistance {
            guard let sourceEntryID = session.sourceEntryID,
                  topLevelEntry(withID: sourceEntryID) != nil,
                  canOrganizeMainGrid else {
                session.phase = .ignored
                session.dropTarget = nil
                mainPointerSession = session
                return
            }
            session.phase = .dragging
            session.longPressTriggered = false
        }

        var scheduledPageTurn: (edge: LauncherPagingEdge, dwellID: UUID)?
        var scheduledCombine: (entryID: UUID, dwellID: UUID)?
        var scheduledFolderExpansion: (entryID: UUID, dwellID: UUID)?
        if session.phase == .dragging,
           let sourceEntryID = session.sourceEntryID {
            guard topLevelEntry(withID: sourceEntryID) != nil,
                  canOrganizeMainGrid,
                  session.pageIndex == model.currentPage else {
                session.phase = .ignored
                session.dropTarget = nil
                session.pagingEdge = nil
                session.edgeDwellID = nil
                mainPointerSession = session
                return
            }

            let candidate: LauncherMainDropTarget?
            if metrics.cancelDropFrameInGrid.contains(effectiveLocation) {
                session.pagingEdge = nil
                session.edgeDwellID = nil
                session.requiresEdgeExit = false
                collapseMainFolderPreview(session: &session)
                candidate = .cancel
            } else if let expandedFolderEntryID = session.expandedFolderEntryID,
                      shouldKeepMainFolderPreview(
                        session: session,
                        folderEntryID: expandedFolderEntryID,
                        location: effectiveLocation
                      ) {
                // The first frame after expansion may arrive before preferences
                // have published the panel bounds. Keep the safe append preview
                // for that frame instead of immediately collapsing the panel.
                session.pagingEdge = nil
                session.edgeDwellID = nil
                session.requiresEdgeExit = false
                if hoverFolderGeometry.panelFrame.contains(effectiveLocation) {
                    session.expandedFolderHasEnteredPanel = true
                    candidate = resolveExpandedFolderDropTarget(
                        sourceEntryID: sourceEntryID,
                        folderEntryID: expandedFolderEntryID,
                        location: effectiveLocation
                    )
                } else {
                    candidate = session.dropTarget
                }
            } else {
                collapseMainFolderPreview(session: &session)
                scheduledPageTurn = prepareMainEdgePaging(
                    session: &session,
                    location: effectiveLocation,
                    metrics: metrics
                )
                // Keep the ordinary target live during the dwell. A quick
                // release on a real edge tile must still combine/reorder.
                var resolved = resolveMainDropTarget(
                    sourceEntryID: sourceEntryID,
                    pageIndex: session.pageIndex,
                    location: effectiveLocation,
                    metrics: metrics
                )
                if resolved == nil,
                   isReorderTarget(session.dropTarget),
                   mainGridGeometry.tileFrames[
                    LauncherPageTileFrameKey(
                        pageIndex: session.pageIndex,
                        entryID: sourceEntryID
                    )
                   ]?.contains(effectiveLocation) == true {
                    // The invisible source tile is the provisional placeholder.
                    // Remaining over it keeps the chosen slot stable.
                    resolved = session.dropTarget
                }
                candidate = resolved
            }
            if session.expandedFolderEntryID != nil {
                session.pendingCombineEntryID = nil
                session.combineDwellID = nil
                session.folderExpansionDwellID = nil
                session.dropTarget = candidate
            } else {
                scheduledCombine = prepareMainCombinePreview(
                    candidate: candidate,
                    session: &session
                )
                if case let .combine(targetEntryID) = candidate,
                   topLevelEntry(withID: sourceEntryID)?.applicationID != nil,
                   topLevelEntry(withID: targetEntryID)?.folder != nil,
                   session.folderExpansionDwellID == nil {
                    let dwellID = UUID()
                    session.folderExpansionDwellID = dwellID
                    scheduledFolderExpansion = (targetEntryID, dwellID)
                    LauncherDragDiagnostics.log("folder dwell scheduled")
                }
            }
        }
        if mainPointerSession != session {
            mainPointerSession = session
        }

        if let scheduledPageTurn {
            scheduleMainPageTurn(
                sessionID: session.id,
                dwellID: scheduledPageTurn.dwellID,
                edge: scheduledPageTurn.edge,
                metrics: metrics
            )
        }
        if let scheduledCombine {
            scheduleMainCombinePreview(
                sessionID: session.id,
                dwellID: scheduledCombine.dwellID,
                targetEntryID: scheduledCombine.entryID,
                metrics: metrics
            )
        }
        if let scheduledFolderExpansion {
            scheduleMainFolderExpansion(
                sessionID: session.id,
                dwellID: scheduledFolderExpansion.dwellID,
                targetEntryID: scheduledFolderExpansion.entryID,
                metrics: metrics
            )
        }
    }

    private func handleMainPointerEnded(
        _ value: DragGesture.Value,
        pageIndex gesturePageIndex: Int,
        metrics: LauncherGridMetrics
    ) {
        // Never manufacture a new session from a late `onEnded` delivered
        // after AppKit cancelled and the stale latch was reclaimed.
        guard let existingSession = mainPointerSession,
              existingSession.gesturePageIndex == gesturePageIndex else {
            return
        }
        handleMainPointerChanged(
            value,
            pageIndex: gesturePageIndex,
            metrics: metrics
        )
        guard let session = mainPointerSession,
              session.gesturePageIndex == gesturePageIndex else { return }

        mainPointerSession = nil
        switch session.phase {
        case .dragging:
            guard let sourceEntryID = session.sourceEntryID else {
                return
            }
            let target = session.dropTarget ?? resolveMainDropTarget(
                sourceEntryID: sourceEntryID,
                pageIndex: session.pageIndex,
                location: mainPointerLocation.location,
                metrics: metrics
            )
            guard let target else { return }
            if session.dropTarget == nil {
                LauncherDragDiagnostics.log("mouse-up resolved pending target")
            }
            commitMainDrop(
                sourceEntryID: sourceEntryID,
                pageIndex: session.pageIndex,
                target: target
            )

        case .pressing:
            if let sourceEntryID = session.sourceEntryID {
                guard !session.longPressTriggered,
                      let entry = displayedEntry(withID: sourceEntryID) else {
                    return
                }
                if isEditing, entry.folder == nil { return }
                selectedEntryID = entry.id
                activate(entry)
            } else {
                dismissFromMainPage()
            }

        case .ignored:
            return
        }
    }

    private var canOrganizeMainGrid: Bool {
        model.openFolderID == nil
            && model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scheduleMainLongPress(sessionID: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(520))
            guard var session = mainPointerSession,
                  session.id == sessionID,
                  session.phase == .pressing,
                  session.sourceEntryID != nil,
                  canOrganizeMainGrid else {
                return
            }
            session.longPressTriggered = true
            mainPointerSession = session
            enterEditingMode()
        }
    }

    private func prepareMainCombinePreview(
        candidate: LauncherMainDropTarget?,
        session: inout LauncherMainPointerSession
    ) -> (entryID: UUID, dwellID: UUID)? {
        guard case let .combine(entryID) = candidate else {
            session.pendingCombineEntryID = nil
            session.combineDwellID = nil
            session.folderExpansionDwellID = nil
            session.dropTarget = candidate
            return nil
        }

        if session.dropTarget == .combine(entryID: entryID) {
            session.pendingCombineEntryID = entryID
            return nil
        }
        if session.pendingCombineEntryID == entryID,
           session.combineDwellID != nil {
            session.dropTarget = nil
            return nil
        }

        let dwellID = UUID()
        session.folderExpansionDwellID = nil
        session.pendingCombineEntryID = entryID
        session.combineDwellID = dwellID
        session.dropTarget = nil
        return (entryID, dwellID)
    }

    private func isReorderTarget(_ target: LauncherMainDropTarget?) -> Bool {
        switch target {
        case .insertBefore, .insertAfter, .endOfPage:
            return true
        case .cancel, .combine, .insertIntoFolder, nil:
            return false
        }
    }

    private func scheduleMainCombinePreview(
        sessionID: UUID,
        dwellID: UUID,
        targetEntryID: UUID,
        metrics: LauncherGridMetrics
    ) {
        Task { @MainActor in
            try? await Task.sleep(
                for: .milliseconds(LauncherDragTuning.combineDwellMilliseconds)
            )
            guard var session = mainPointerSession,
                  session.id == sessionID,
                  session.phase == .dragging,
                  session.combineDwellID == dwellID,
                  session.pendingCombineEntryID == targetEntryID,
                  let sourceEntryID = session.sourceEntryID,
                  resolveMainDropTarget(
                    sourceEntryID: sourceEntryID,
                    pageIndex: session.pageIndex,
                    location: mainPointerLocation.location,
                    metrics: metrics
                  ) == .combine(entryID: targetEntryID) else {
                LauncherDragDiagnostics.log("combine dwell cancelled")
                return
            }

            session.dropTarget = .combine(entryID: targetEntryID)
            session.combineDwellID = nil
            mainPointerSession = session
            LauncherDragDiagnostics.log("combine dwell fired")
        }
    }

    private func scheduleMainFolderExpansion(
        sessionID: UUID,
        dwellID: UUID,
        targetEntryID: UUID,
        metrics: LauncherGridMetrics
    ) {
        Task { @MainActor in
            try? await Task.sleep(
                for: .milliseconds(LauncherDragTuning.folderExpansionDwellMilliseconds)
            )
            guard var session = mainPointerSession,
                  session.id == sessionID else {
                LauncherDragDiagnostics.log("folder dwell cancelled: session-ended")
                return
            }
            guard session.phase == .dragging else {
                LauncherDragDiagnostics.log("folder dwell cancelled: not-dragging")
                return
            }
            guard session.folderExpansionDwellID == dwellID else {
                LauncherDragDiagnostics.log("folder dwell cancelled: superseded")
                return
            }
            guard session.pendingCombineEntryID == targetEntryID
                    || session.dropTarget == .combine(entryID: targetEntryID) else {
                LauncherDragDiagnostics.log("folder dwell cancelled: target-changed")
                return
            }
            guard let sourceEntryID = session.sourceEntryID,
                  topLevelEntry(withID: sourceEntryID)?.applicationID != nil,
                  topLevelEntry(withID: targetEntryID)?.folder != nil else {
                LauncherDragDiagnostics.log("folder dwell cancelled: stale-identity")
                return
            }
            guard resolveMainDropTarget(
                sourceEntryID: sourceEntryID,
                pageIndex: session.pageIndex,
                location: mainPointerLocation.location,
                metrics: metrics
            ) == .combine(entryID: targetEntryID) else {
                LauncherDragDiagnostics.log("folder dwell cancelled: pointer-left-center")
                return
            }

            session.folderExpansionDwellID = nil
            session.combineDwellID = nil
            session.expandedFolderEntryID = targetEntryID
            session.expandedFolderHasEnteredPanel = false
            session.pendingCombineEntryID = nil
            session.dropTarget = .insertIntoFolder(
                entryID: targetEntryID,
                beforeApplicationID: nil
            )
            hoverFolderGeometry.reset()
            mainPointerSession = session
            LauncherDragDiagnostics.log("folder dwell fired; passive panel presented")
        }
    }

    private func collapseMainFolderPreview(
        session: inout LauncherMainPointerSession
    ) {
        let wasExpanded = session.expandedFolderEntryID != nil
        session.folderExpansionDwellID = nil
        session.expandedFolderEntryID = nil
        session.expandedFolderHasEnteredPanel = false
        if wasExpanded {
            hoverFolderGeometry.reset()
        }
    }

    private func shouldKeepMainFolderPreview(
        session: LauncherMainPointerSession,
        folderEntryID: UUID,
        location: CGPoint
    ) -> Bool {
        let panelFrame = hoverFolderGeometry.panelFrame
        let sourceFrame = mainGridGeometry.tileFrames[
            LauncherPageTileFrameKey(
                pageIndex: session.pageIndex,
                entryID: folderEntryID
            )
        ]
        guard panelFrame.width > 0, panelFrame.height > 0 else {
            // Preferences arrive one layout turn after expansion. During that
            // narrow interval retain only a finite halo around the folder tile;
            // a rapid move-away + mouse-up must never commit the stale append.
            return sourceFrame?
                .insetBy(dx: -44, dy: -44)
                .contains(location) == true
        }
        if panelFrame.contains(location) { return true }
        if session.expandedFolderHasEnteredPanel,
           panelFrame.insetBy(dx: -12, dy: -12).contains(location) {
            // Preserve a narrow edge halo so reaching the visible panel border
            // does not tear down the passive surface before auto-scroll reacts.
            return true
        }
        guard !session.expandedFolderHasEnteredPanel,
              let sourceFrame else {
            return false
        }

        // Before the pointer first enters the expanded panel, preserve a clear
        // corridor from the original folder tile to the panel. This prevents a
        // first/last-row folder from opening and instantly closing on the next
        // one-pixel movement while still letting movement away collapse it.
        return sourceFrame.union(panelFrame)
            .insetBy(dx: -24, dy: -24)
            .contains(location)
    }

    private func prepareMainEdgePaging(
        session: inout LauncherMainPointerSession,
        location: CGPoint,
        metrics: LauncherGridMetrics
    ) -> (edge: LauncherPagingEdge, dwellID: UUID)? {
        guard let edge = actionableMainPagingEdge(
            at: location,
            pageIndex: session.pageIndex,
            metrics: metrics
        ) else {
            session.pagingEdge = nil
            session.edgeDwellID = nil
            session.requiresEdgeExit = false
            return nil
        }

        if session.pagingEdge != edge {
            session.pagingEdge = edge
            session.edgeDwellID = nil
        }
        guard !session.requiresEdgeExit else { return nil }
        if session.edgeDwellID == nil {
            let dwellID = UUID()
            session.edgeDwellID = dwellID
            return (edge, dwellID)
        }
        return nil
    }

    private func actionableMainPagingEdge(
        at location: CGPoint,
        pageIndex: Int,
        metrics: LauncherGridMetrics
    ) -> LauncherPagingEdge? {
        guard canOrganizeMainGrid,
              location.y >= -36,
              location.y <= metrics.gridHeight + 36 else {
            return nil
        }

        // This must not overlap the first/last grid-column centres. The user
        // deliberately reaches the viewport edge to page; ordinary icon drops
        // remain available everywhere else.
        let edgeWidth = max(24, min(32, metrics.gridWidth * 0.022))
        if location.x <= edgeWidth, pageIndex > 0 {
            return .previous
        }
        if location.x >= metrics.gridWidth - edgeWidth,
           pageIndex < pageEntriesForDisplay.count - 1 {
            return .next
        }
        return nil
    }

    private func scheduleMainPageTurn(
        sessionID: UUID,
        dwellID: UUID,
        edge: LauncherPagingEdge,
        metrics: LauncherGridMetrics
    ) {
        Task { @MainActor in
            try? await Task.sleep(
                for: .milliseconds(LauncherDragTuning.edgePageDwellMilliseconds)
            )
            guard var session = mainPointerSession,
                  session.id == sessionID,
                  session.edgeDwellID == dwellID,
                  session.phase == .dragging,
                  session.pagingEdge == edge,
                  session.pageIndex == model.currentPage,
                  actionableMainPagingEdge(
                    at: mainPointerLocation.location,
                    pageIndex: session.pageIndex,
                    metrics: metrics
                  ) == edge else {
                return
            }

            let destination = edge == .previous
                ? session.pageIndex - 1
                : session.pageIndex + 1
            guard pageEntriesForDisplay.indices.contains(destination) else { return }

            // Publish the destination into the drag session first. The model's
            // synchronous page notification can then distinguish this internal
            // turn from an unrelated page change and keep the gesture alive.
            session.pageIndex = destination
            session.dropTarget = nil
            session.pendingCombineEntryID = nil
            session.combineDwellID = nil
            session.folderExpansionDwellID = nil
            session.expandedFolderEntryID = nil
            session.expandedFolderHasEnteredPanel = false
            session.edgeDwellID = nil
            session.requiresEdgeExit = true
            mainPointerSession = session
            model.selectPage(destination)
        }
    }

    private func mainEntryID(at location: CGPoint, pageIndex: Int) -> UUID? {
        mainGridGeometry.tileFrames.first { key, frame in
            key.pageIndex == pageIndex && frame.contains(location)
        }?.key.entryID
    }

    private func mainPointerStartsOnEditBadge(
        entryID: UUID,
        pageIndex: Int,
        location: CGPoint,
        iconSize: CGFloat
    ) -> Bool {
        guard isEditing,
              let entry = topLevelEntry(withID: entryID),
              entry.applicationID != nil,
              let frame = mainGridGeometry.tileFrames[
                LauncherPageTileFrameKey(pageIndex: pageIndex, entryID: entryID)
              ] else {
            return false
        }

        let iconFrame = CGRect(
            x: frame.midX - (iconSize + LauncherTileLayout.iconChrome) / 2,
            y: frame.minY,
            width: iconSize + LauncherTileLayout.iconChrome,
            height: iconSize + LauncherTileLayout.iconChrome
        )
        let hitSize: CGFloat = 32
        let hideRect = CGRect(
            x: iconFrame.maxX - hitSize,
            y: iconFrame.minY,
            width: hitSize,
            height: hitSize
        )
        if hideRect.contains(location) { return true }

        guard let applicationID = entry.applicationID,
              model.canUninstall(applicationID) else {
            return false
        }
        let deleteRect = CGRect(
            x: iconFrame.minX,
            y: iconFrame.minY,
            width: hitSize,
            height: hitSize
        )
        return deleteRect.contains(location)
    }

    private func resolveMainDropTarget(
        sourceEntryID: UUID,
        pageIndex: Int,
        location: CGPoint,
        metrics: LauncherGridMetrics
    ) -> LauncherMainDropTarget? {
        guard canOrganizeMainGrid,
              pageIndex == model.currentPage,
              let source = topLevelEntry(withID: sourceEntryID) else {
            return nil
        }

        let pageFrames = mainGridGeometry.tileFrames.filter { key, _ in
            key.pageIndex == pageIndex
        }
        let framesByEntryID = Dictionary(
            uniqueKeysWithValues: pageFrames.map { ($0.key.entryID, $0.value) }
        )
        let contentMaxY = max(
            metrics.gridHeight,
            (pageFrames.values.map(\.maxY).max() ?? 0) + metrics.verticalSpacing
        )
        guard location.x >= 0,
              location.x <= metrics.gridWidth,
              location.y >= 0,
              location.y <= contentMaxY else {
            return nil
        }

        if let sourceFrame = pageFrames[
            LauncherPageTileFrameKey(pageIndex: pageIndex, entryID: sourceEntryID)
        ], sourceFrame.contains(location) {
            return nil
        }

        if let hit = pageFrames.first(where: { key, frame in
            key.entryID != sourceEntryID && frame.contains(location)
        }), let target = topLevelEntry(withID: hit.key.entryID) {
            let iconCenter = CGPoint(
                x: hit.value.midX,
                y: hit.value.minY
                    + (metrics.iconSize + LauncherTileLayout.iconChrome) / 2
            )
            // Folders are frequent drop destinations, so their center affordance
            // is wider while the outer shoulders remain dedicated to ordering.
            let centerScale: CGFloat = target.folder == nil ? 0.78 : 0.92
            let combineSize = min(
                metrics.iconSize * centerScale,
                hit.value.width * 0.82
            )
            let combineRect = CGRect(
                x: iconCenter.x - combineSize / 2,
                y: iconCenter.y - combineSize / 2,
                width: combineSize,
                height: combineSize
            )
            if source.applicationID != nil,
               (target.applicationID != nil || target.folder != nil),
               combineRect.contains(location) {
                return .combine(entryID: target.id)
            }

            return location.x < hit.value.midX
                ? .insertBefore(entryID: target.id)
                : .insertAfter(entryID: target.id)
        }

        let displayedPages = pageEntriesForDisplay
        guard displayedPages.indices.contains(pageIndex) else { return nil }
        let orderedIDs = displayedPages[pageIndex].map(\.id)
        switch LauncherDropGeometry.nearestInsertion(
            at: location,
            orderedIDs: orderedIDs,
            frames: framesByEntryID,
            excluding: sourceEntryID
        ) {
        case let .before(entryID):
            return .insertBefore(entryID: entryID)
        case let .after(entryID):
            return .insertAfter(entryID: entryID)
        case .end:
            return .endOfPage
        case nil:
            return nil
        }
    }

    private func resolveExpandedFolderDropTarget(
        sourceEntryID: UUID,
        folderEntryID: UUID,
        location: CGPoint
    ) -> LauncherMainDropTarget? {
        guard let sourceApplicationID = topLevelEntry(withID: sourceEntryID)?.applicationID,
              let folder = topLevelEntry(withID: folderEntryID)?.folder,
              !folder.applicationIDs.contains(sourceApplicationID) else {
            return nil
        }

        let orderedIDs = folder.applicationIDs
        let frames = hoverFolderGeometry.tileFrames.filter { applicationID, frame in
            orderedIDs.contains(applicationID)
                && frame.width > 0
                && frame.height > 0
        }
        let framedIndices = orderedIDs.indices.filter { index in
            frames[orderedIDs[index]] != nil
        }
        let firstVisibleApplicationID = framedIndices.first.map { orderedIDs[$0] }
        let applicationIDAfterVisibleTail: String? = framedIndices.last.flatMap { index in
            let next = orderedIDs.index(after: index)
            return orderedIDs.indices.contains(next) ? orderedIDs[next] : nil
        }

        guard let firstMemberY = frames.values.map(\.minY).min(),
              let lastMemberY = frames.values.map(\.maxY).max(),
              let firstVisibleApplicationID else {
            return .insertIntoFolder(
                entryID: folderEntryID,
                beforeApplicationID: nil
            )
        }
        if location.y < firstMemberY - 16 {
            return .insertIntoFolder(
                entryID: folderEntryID,
                beforeApplicationID: firstVisibleApplicationID
            )
        }
        if location.y > lastMemberY + 20 {
            return .insertIntoFolder(
                entryID: folderEntryID,
                beforeApplicationID: applicationIDAfterVisibleTail
            )
        }

        if let hit = frames.first(where: { _, frame in frame.contains(location) }) {
            let beforeApplicationID: String?
            if location.x < hit.value.midX {
                beforeApplicationID = hit.key
            } else if let targetIndex = orderedIDs.firstIndex(of: hit.key),
                      orderedIDs.indices.contains(targetIndex + 1) {
                beforeApplicationID = orderedIDs[targetIndex + 1]
            } else {
                beforeApplicationID = nil
            }
            return .insertIntoFolder(
                entryID: folderEntryID,
                beforeApplicationID: beforeApplicationID
            )
        }

        let beforeApplicationID: String?
        switch LauncherDropGeometry.nearestInsertion(
            at: location,
            orderedIDs: orderedIDs,
            frames: frames,
            excluding: nil as String?
        ) {
        case let .before(applicationID):
            beforeApplicationID = applicationID
        case let .after(applicationID):
            if let targetIndex = orderedIDs.firstIndex(of: applicationID),
               orderedIDs.indices.contains(targetIndex + 1) {
                beforeApplicationID = orderedIDs[targetIndex + 1]
            } else {
                beforeApplicationID = nil
            }
        case .end:
            beforeApplicationID = applicationIDAfterVisibleTail
        case nil:
            beforeApplicationID = nil
        }
        return .insertIntoFolder(
            entryID: folderEntryID,
            beforeApplicationID: beforeApplicationID
        )
    }

    /// Programmatic scrolling can reveal a new row without producing another
    /// mouse-move callback. Re-resolve only after a controlled scroll step so
    /// the placeholder follows the newly visible, real member frames.
    private func refreshExpandedFolderDropTarget() {
        guard var session = mainPointerSession,
              session.phase == .dragging,
              let sourceEntryID = session.sourceEntryID,
              let folderEntryID = session.expandedFolderEntryID,
              hoverFolderGeometry.panelFrame.contains(mainPointerLocation.location),
              let target = resolveExpandedFolderDropTarget(
                sourceEntryID: sourceEntryID,
                folderEntryID: folderEntryID,
                location: mainPointerLocation.location
              ) else {
            return
        }
        guard session.dropTarget != target else { return }
        session.dropTarget = target
        mainPointerSession = session
    }

    private func commitMainDrop(
        sourceEntryID: UUID,
        pageIndex: Int,
        target: LauncherMainDropTarget
    ) {
        guard canOrganizeMainGrid,
              model.currentPage == pageIndex,
              let source = topLevelEntry(withID: sourceEntryID) else {
            return
        }

        switch target {
        case .cancel:
            return

        case let .combine(targetEntryID):
            guard let targetEntry = topLevelEntry(withID: targetEntryID) else { return }
            switch (source.kind, targetEntry.kind) {
            case let (.application(sourceID), .application(targetID)):
                model.createFolder(from: sourceID, onto: targetID)
            case let (.application(sourceID), .folder(folder)):
                guard model.addToFolder(
                    appID: sourceID,
                    folderID: folder.id,
                    before: nil
                ) else {
                    return
                }
                selectedFolderApplicationID = sourceID
                model.openFolder(folder.id)
                LauncherDragDiagnostics.log("folder drop committed and opened")
            default:
                return
            }

        case let .insertIntoFolder(targetEntryID, beforeApplicationID):
            guard case let .application(sourceApplicationID) = source.kind,
                  let folder = topLevelEntry(withID: targetEntryID)?.folder,
                  model.addToFolder(
                    appID: sourceApplicationID,
                    folderID: folder.id,
                    before: beforeApplicationID
                  ) else {
                return
            }
            selectedFolderApplicationID = sourceApplicationID
            model.openFolder(folder.id)

        case let .insertBefore(targetEntryID):
            guard topLevelEntry(withID: targetEntryID) != nil else { return }
            model.reorder(
                draggedID: source.id.uuidString,
                before: targetEntryID.uuidString
            )

        case let .insertAfter(targetEntryID):
            guard model.layout.pages.indices.contains(pageIndex) else { return }
            let entries = model.layout.pages[pageIndex].filter { $0.id != sourceEntryID }
            guard let targetIndex = entries.firstIndex(where: { $0.id == targetEntryID }) else {
                return
            }
            let nextIdentity = entries.indices.contains(targetIndex + 1)
                ? entries[targetIndex + 1].id.uuidString
                : nil
            model.reorder(draggedID: source.id.uuidString, before: nextIdentity)

        case .endOfPage:
            model.reorder(draggedID: source.id.uuidString, before: nil)
        }
    }

    private func mainDropIntent(
        for entryID: UUID,
        pageIndex: Int
    ) -> LauncherTileDropIntent? {
        if let preview = folderExternalDragPreview {
            switch preview.target {
            case let .moveIntoFolder(_, targetPage)
                where targetPage == pageIndex
                    && topLevelEntry(withID: entryID)?.folder != nil:
                if topLevelEntry(withID: entryID)?.folder?.id
                    == externalDestinationFolderID(preview.target) {
                    return .combine
                }
            case let .moveOutBefore(targetID, targetPage)
                where targetPage == pageIndex && targetID == entryID:
                return .reorderBefore
            case let .moveOutAfter(targetID, targetPage)
                where targetPage == pageIndex && targetID == entryID:
                return .reorderAfter
            default:
                break
            }
        }

        guard let session = mainPointerSession,
              session.phase == .dragging,
              session.pageIndex == pageIndex else {
            return nil
        }
        if session.pendingCombineEntryID == entryID,
           session.dropTarget != .combine(entryID: entryID) {
            return .combinePending
        }
        guard let target = session.dropTarget else { return nil }
        switch target {
        case let .combine(targetID) where targetID == entryID:
            return .combine
        case let .insertBefore(targetID) where targetID == entryID:
            return .reorderBefore
        case let .insertAfter(targetID) where targetID == entryID:
            return .reorderAfter
        default:
            return nil
        }
    }

    private func combinePreviewSourceApplicationID(
        for entryID: UUID,
        pageIndex: Int
    ) -> String? {
        if let preview = folderExternalDragPreview,
           case let .moveIntoFolder(folderID, targetPage) = preview.target,
           targetPage == pageIndex,
           topLevelEntry(withID: entryID)?.folder?.id == folderID {
            return preview.sourceApplicationID
        }

        guard let session = mainPointerSession,
              session.phase == .dragging,
              session.pageIndex == pageIndex,
              session.dropTarget == .combine(entryID: entryID),
              let sourceEntryID = session.sourceEntryID else {
            return nil
        }
        return topLevelEntry(withID: sourceEntryID)?.applicationID
    }

    private func externalDestinationFolderID(
        _ target: LauncherFolderDropTarget
    ) -> UUID? {
        guard case let .moveIntoFolder(folderID, _) = target else { return nil }
        return folderID
    }

    @ViewBuilder
    private func mainHoverFolderLayer(
        pageIndex: Int,
        metrics: LauncherGridMetrics
    ) -> some View {
        if let session = mainPointerSession,
           session.phase == .dragging,
           session.pageIndex == pageIndex,
           let sourceEntryID = session.sourceEntryID,
           let sourceApplicationID = topLevelEntry(withID: sourceEntryID)?.applicationID,
           let folderEntryID = session.expandedFolderEntryID,
           let folder = topLevelEntry(withID: folderEntryID)?.folder {
            let beforeApplicationID = expandedFolderBeforeApplicationID(
                session: session,
                folderEntryID: folderEntryID
            )

            LauncherHoverFolderPanel(
                folder: folder,
                sourceApplicationID: sourceApplicationID,
                beforeApplicationID: beforeApplicationID,
                applications: model.applications,
                pointerLocation: mainPointerLocation,
                geometry: hoverFolderGeometry,
                refreshDropTarget: refreshExpandedFolderDropTarget,
                iconProvider: model.icon,
                iconSize: min(metrics.iconSize, 84),
                showLabels: model.preferences.showLabels,
                reduceMotion: reduceMotion
            )
            .frame(
                width: min(940, max(1, metrics.gridWidth - 48)),
                height: min(620, max(1, metrics.gridHeight - 40))
            )
            .frame(width: metrics.gridWidth, height: metrics.gridHeight)
            .transition(
                reduceMotion
                    ? .opacity
                    : .scale(scale: 0.96).combined(with: .opacity)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(80)
        }
    }

    private func expandedFolderBeforeApplicationID(
        session: LauncherMainPointerSession,
        folderEntryID: UUID
    ) -> String? {
        guard case let .insertIntoFolder(targetEntryID, targetApplicationID) = session.dropTarget,
              targetEntryID == folderEntryID else {
            return nil
        }
        return targetApplicationID
    }

    @ViewBuilder
    private func mainDragOverlay(
        pageIndex: Int,
        metrics: LauncherGridMetrics
    ) -> some View {
        if let session = mainPointerSession,
           session.phase == .dragging,
           session.pageIndex == pageIndex,
           let sourceEntryID = session.sourceEntryID,
            let source = topLevelEntry(withID: sourceEntryID) {
            ZStack(alignment: .topLeading) {
                LauncherMainFloatingDragPreview(
                    pointerLocation: mainPointerLocation,
                    entry: source,
                    applications: model.applications,
                    iconProvider: model.icon,
                    showsEndBadge: session.dropTarget == .endOfPage
                )

                if let edge = session.pagingEdge {
                    Image(systemName: edge == .previous ? "chevron.left" : "chevron.right")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 58)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay {
                            Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                        .position(
                            x: edge == .previous ? 20 : metrics.gridWidth - 20,
                            y: metrics.gridHeight / 2
                        )
                }
            }
            .frame(
                width: metrics.gridWidth,
                height: metrics.gridHeight,
                alignment: .topLeading
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(100)
        }
    }

    private func beginRenaming(_ folder: LaunchFolder) {
        renameDraft = folder.name
        folderBeingRenamed = folder
    }

    private func activate(_ entry: LaunchEntry) {
        switch entry.kind {
        case let .application(applicationID):
            guard !isEditing else { return }
            model.launch(applicationID)
        case let .folder(folder):
            model.openFolder(folder.id)
            selectedFolderApplicationID = folder.applicationIDs.first
        }
    }

    private func topLevelEntry(withID entryID: UUID) -> LaunchEntry? {
        return model.layout.pages
            .joined()
            .first { $0.id == entryID }
    }

    private func displayedEntry(withID entryID: UUID) -> LaunchEntry? {
        model.currentPageEntries.first { $0.id == entryID }
            ?? topLevelEntry(withID: entryID)
    }

    private func selectFirstVisibleEntryIfNeeded(force: Bool = false) {
        let entries = model.currentPageEntries
        if force || !entries.contains(where: { $0.id == selectedEntryID }) {
            selectedEntryID = entries.first?.id
        }
    }

    private func handleKeyboardAction(_ action: LauncherKeyboardAction) -> Bool {
        switch action {
        case .cancel:
            if isEditing {
                finishEditing()
            } else if model.openFolderID != nil {
                model.closeFolder()
            } else {
                model.dismissLauncher()
            }
            return true

        case .activate:
            if isEditing {
                if model.currentFolder == nil,
                   let entry = model.currentPageEntries.first(where: {
                       $0.id == selectedEntryID
                   }), entry.folder != nil {
                    activate(entry)
                    return true
                }
                finishEditing()
                return true
            }
            if let folder = model.currentFolder,
               let selectedFolderApplicationID,
               folder.applicationIDs.contains(selectedFolderApplicationID) {
                model.launch(selectedFolderApplicationID)
                return true
            }
            guard let entry = model.currentPageEntries.first(where: { $0.id == selectedEntryID }) else {
                return false
            }
            activate(entry)
            return true

        case .left, .right, .up, .down:
            showsKeyboardSelection = true
            if let folder = model.currentFolder {
                moveFolderSelection(action, in: folder)
            } else {
                moveGridSelection(action)
            }
            return true
        }
    }

    private var deletionTitle: String {
        guard let applicationPendingDeletion else {
            return LaunchText.value("应用", "Application")
        }
        return "“\(applicationPendingDeletion.name)”"
    }

    private func enterEditingMode() {
        guard !isEditing else { return }
        searchIsFocused = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            isEditing = true
        }
    }

    private func finishEditing() {
        cancelMainPointerSession()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            isEditing = false
        }
        applicationPendingDeletion = nil
        Task { @MainActor in
            searchIsFocused = true
        }
    }

    private func requestDeletion(_ applicationID: String) {
        guard model.canUninstall(applicationID),
              !deletingApplicationIDs.contains(applicationID) else {
            return
        }

        // Context-menu actions are delivered while AppKit is still unwinding
        // menu tracking. Present the shared confirmation on the following
        // main-actor turn so it attaches after the launcher regains key status.
        // The same tiny deferral is harmless for an edit-mode delete badge.
        Task { @MainActor in
            await Task.yield()
            guard NSApp.isActive,
                  model.canUninstall(applicationID),
                  !deletingApplicationIDs.contains(applicationID),
                  applicationPendingDeletion == nil,
                  let application = model.applications[applicationID] else {
                return
            }
            applicationPendingDeletion = application
        }
    }

    private func moveApplicationToTrash(_ application: InstalledApplication) {
        applicationPendingDeletion = nil
        deletingApplicationIDs.insert(application.id)

        Task { @MainActor in
            await model.moveApplicationToTrash(application.id)
            deletingApplicationIDs.remove(application.id)
        }
    }

    private func requestWeChatCompanionRebuild(_ applicationID: String) {
        guard model.canRebuildWeChatCompanion(applicationID),
              !model.isRebuildingWeChatCompanion else {
            return
        }

        // A context-menu action runs while AppKit is still unwinding menu
        // tracking. Attaching a SwiftUI alert synchronously can make the
        // launcher panel's transient key transition look like a real
        // deactivation, clearing the pending presentation before the sheet is
        // attached. Present on the next main-actor turn, once the menu has
        // returned key status to the launcher.
        Task { @MainActor in
            await Task.yield()
            guard NSApp.isActive,
                  model.canRebuildWeChatCompanion(applicationID),
                  !model.isRebuildingWeChatCompanion,
                  applicationPendingWeChatRebuild == nil,
                  let application = model.applications[applicationID] else {
                return
            }
            applicationPendingWeChatRebuild = application
        }
    }

    private func rebuildWeChatCompanion(_ application: InstalledApplication) {
        applicationPendingWeChatRebuild = nil
        Task { @MainActor in
            await model.rebuildWeChatCompanion(application.id)
        }
    }

    private func moveGridSelection(_ action: LauncherKeyboardAction) {
        let entries = model.currentPageEntries
        guard !entries.isEmpty else { return }

        let currentIndex = entries.firstIndex { $0.id == selectedEntryID } ?? 0
        let columns = max(1, model.preferences.columns)
        var destination = currentIndex

        switch action {
        case .left:
            if currentIndex == 0, model.currentPage > 0 {
                model.selectPage(model.currentPage - 1)
                selectedEntryID = model.currentPageEntries.last?.id
                return
            }
            destination = max(0, currentIndex - 1)

        case .right:
            if currentIndex == entries.count - 1,
               model.currentPage < model.pageCount - 1 {
                model.selectPage(model.currentPage + 1)
                selectedEntryID = model.currentPageEntries.first?.id
                return
            }
            destination = min(entries.count - 1, currentIndex + 1)

        case .up:
            destination = max(0, currentIndex - columns)

        case .down:
            destination = min(entries.count - 1, currentIndex + columns)

        case .activate, .cancel:
            return
        }

        selectedEntryID = entries[destination].id
    }

    private func moveFolderSelection(_ action: LauncherKeyboardAction, in folder: LaunchFolder) {
        let applicationIDs = folder.applicationIDs
        guard !applicationIDs.isEmpty else { return }

        let currentID = applicationIDs.contains(selectedFolderApplicationID ?? "")
            ? selectedFolderApplicationID!
            : applicationIDs[0]
        guard let currentFrame = folderGridGeometry.tileFrames[currentID] else {
            // Geometry is unavailable for only the first layout turn. Preserve a
            // deterministic fallback until the adaptive grid publishes frames.
            let currentIndex = applicationIDs.firstIndex(of: currentID) ?? 0
            let fallbackColumns = min(6, max(1, model.preferences.columns - 1))
            let destination: Int
            switch action {
            case .left:
                destination = max(0, currentIndex - 1)
            case .right:
                destination = min(applicationIDs.count - 1, currentIndex + 1)
            case .up:
                destination = max(0, currentIndex - fallbackColumns)
            case .down:
                destination = min(applicationIDs.count - 1, currentIndex + fallbackColumns)
            case .activate, .cancel:
                return
            }
            selectedFolderApplicationID = applicationIDs[destination]
            return
        }

        let candidates = applicationIDs.compactMap { applicationID -> (String, CGRect)? in
            guard applicationID != currentID,
                  let frame = folderGridGeometry.tileFrames[applicationID] else {
                return nil
            }
            return (applicationID, frame)
        }
        let destination: String?
        switch action {
        case .left, .right:
            let movesLeft = action == .left
            let sameRow = candidates.filter { _, frame in
                let rowTolerance = max(currentFrame.height, frame.height) * 0.48
                let isInDirection = movesLeft
                    ? frame.midX < currentFrame.midX - 1
                    : frame.midX > currentFrame.midX + 1
                return isInDirection
                    && abs(frame.midY - currentFrame.midY) <= rowTolerance
            }
            destination = sameRow.min { lhs, rhs in
                abs(lhs.1.midX - currentFrame.midX)
                    < abs(rhs.1.midX - currentFrame.midX)
            }?.0

        case .up, .down:
            let movesUp = action == .up
            let directional = candidates.filter { _, frame in
                movesUp
                    ? frame.midY < currentFrame.midY - 1
                    : frame.midY > currentFrame.midY + 1
            }
            destination = directional.min { lhs, rhs in
                let lhsVertical = abs(lhs.1.midY - currentFrame.midY)
                let rhsVertical = abs(rhs.1.midY - currentFrame.midY)
                if abs(lhsVertical - rhsVertical) > 1 {
                    return lhsVertical < rhsVertical
                }
                return abs(lhs.1.midX - currentFrame.midX)
                    < abs(rhs.1.midX - currentFrame.midX)
            }?.0

        case .activate, .cancel:
            return
        }

        if let destination {
            selectedFolderApplicationID = destination
            return
        }

        // LazyVGrid may not instantiate members beyond its visible/preload
        // region, so those applications have no frame yet. Keep vertical
        // keyboard traversal moving by deriving the adaptive column count from
        // the rows that are currently measured; ScrollViewReader then reveals
        // the newly selected off-screen member.
        guard action == .up || action == .down,
              let currentIndex = applicationIDs.firstIndex(of: currentID) else {
            return
        }
        let observedColumns = inferredFolderColumnCount(
            frames: applicationIDs.compactMap { folderGridGeometry.tileFrames[$0] }
        )
        let fallbackIndex = action == .up
            ? max(0, currentIndex - observedColumns)
            : min(applicationIDs.count - 1, currentIndex + observedColumns)
        if fallbackIndex != currentIndex {
            selectedFolderApplicationID = applicationIDs[fallbackIndex]
        }
    }

    private func inferredFolderColumnCount(frames: [CGRect]) -> Int {
        guard !frames.isEmpty else {
            return min(6, max(1, model.preferences.columns - 1))
        }

        var rows: [[CGRect]] = []
        for frame in frames.sorted(by: { $0.midY < $1.midY }) {
            if let index = rows.indices.last,
               let representative = rows[index].first,
               abs(representative.midY - frame.midY)
                    <= max(representative.height, frame.height) * 0.45 {
                rows[index].append(frame)
            } else {
                rows.append([frame])
            }
        }
        return max(1, rows.map(\.count).max() ?? 1)
    }
}

@MainActor
private struct LauncherMainFloatingDragPreview: View {
    @ObservedObject var pointerLocation: LauncherPointerLocationState
    let entry: LaunchEntry
    let applications: [String: InstalledApplication]
    let iconProvider: (String) -> NSImage?
    let showsEndBadge: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LauncherDragPreview(
                entry: entry,
                applications: applications,
                iconProvider: iconProvider
            )

            if showsEndBadge {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.56), in: Circle())
            }
        }
        .scaleEffect(1.06)
        .shadow(color: .black.opacity(0.34), radius: 12, y: 5)
        .position(
            x: pointerLocation.location.x,
            y: pointerLocation.location.y
        )
    }
}

/// A passive folder surface that appears without changing `openFolderID` while
/// the main grid's DragGesture still owns the physical mouse sequence. Member
/// frames are reported in the main-grid viewport so the original recognizer can
/// keep resolving precise insertion slots.
@MainActor
private struct LauncherHoverFolderPanel: View {
    let folder: LaunchFolder
    let sourceApplicationID: String
    let beforeApplicationID: String?
    let applications: [String: InstalledApplication]
    let pointerLocation: LauncherPointerLocationState
    let geometry: LauncherFolderGridGeometryState
    let refreshDropTarget: () -> Void
    let iconProvider: (String) -> NSImage?
    let iconSize: CGFloat
    let showLabels: Bool
    let reduceMotion: Bool

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: max(86, iconSize + 28)), spacing: 26)]
    }

    private var previewApplicationIDs: [String] {
        let insertion: LauncherProvisionalInsertion<String>
        if let beforeApplicationID {
            insertion = .before(beforeApplicationID)
        } else {
            insertion = .end(pageIndex: 0)
        }
        return LauncherDragPreviewLayout.order(
            from: folder.applicationIDs,
            inserting: sourceApplicationID,
            insertion: insertion
        )
    }

    var body: some View {
        LauncherGlassPanel {
            VStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(
                        LaunchText.value(
                            "拖到所需位置",
                            "Drop in the desired position"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(minHeight: 46)

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        LazyVGrid(columns: columns, spacing: 24) {
                            ForEach(previewApplicationIDs, id: \.self) { applicationID in
                                if let application = applications[applicationID] {
                                    LauncherHoverFolderApplicationTile(
                                        application: application,
                                        icon: iconProvider(applicationID),
                                        iconSize: iconSize,
                                        showLabel: showLabels,
                                        isIncoming: applicationID == sourceApplicationID
                                    )
                                    .id(applicationID)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 230, alignment: .top)
                    }
                    .scrollIndicators(.hidden)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .preference(
                                    key: LauncherHoverFolderViewportFramePreferenceKey.self,
                                    value: proxy.frame(
                                        in: .named(LauncherCoordinateSpaces.mainGrid)
                                    )
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        LauncherFolderDragAutoScrollObserver(
                            pointerLocation: pointerLocation,
                            geometry: geometry,
                            orderedApplicationIDs: previewApplicationIDs,
                            fallbackAnchorID: sourceApplicationID,
                            isActive: true,
                            diagnosticContext: "passive",
                            reduceMotion: reduceMotion,
                            refreshDropTarget: refreshDropTarget,
                            scrollTo: { applicationID in
                                withAnimation(
                                    reduceMotion ? nil : .linear(duration: 0.13)
                                ) {
                                    scrollProxy.scrollTo(applicationID, anchor: .center)
                                }
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: previewApplicationIDs
        )
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: LauncherHoverFolderPanelFramePreferenceKey.self,
                        value: proxy.frame(
                            in: .named(LauncherCoordinateSpaces.mainGrid)
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
    }
}

@MainActor
private struct LauncherHoverFolderApplicationTile: View {
    let application: InstalledApplication
    let icon: NSImage?
    let iconSize: CGFloat
    let showLabel: Bool
    let isIncoming: Bool

    var body: some View {
        VStack(spacing: showLabel ? 8 : 0) {
            ZStack(alignment: .bottomTrailing) {
                LauncherAppIcon(
                    image: icon,
                    fallbackName: application.name,
                    size: iconSize
                )
                .opacity(isIncoming ? 0.38 : 1)

                if isIncoming {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.58), in: Circle())
                }
            }
            .frame(width: iconSize + 12, height: iconSize + 12)

            if showLabel {
                LauncherTileLabel(title: application.name)
                    .frame(height: 36, alignment: .top)
                    .opacity(isIncoming ? 0.55 : 1)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            if isIncoming {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                .white.opacity(0.22),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                            )
                    }
                    .padding(.horizontal, 3)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: LauncherHoverFolderTileFramePreferenceKey.self,
                        value: [
                            application.id: proxy.frame(
                                in: .named(LauncherCoordinateSpaces.mainGrid)
                            )
                        ]
                    )
                    .allowsHitTesting(false)
            }
        }
    }
}

@MainActor
private struct LauncherFolderDragAutoScrollObserver: View {
    @ObservedObject var pointerLocation: LauncherPointerLocationState
    @ObservedObject var geometry: LauncherFolderGridGeometryState
    let orderedApplicationIDs: [String]
    let fallbackAnchorID: String?
    let isActive: Bool
    let diagnosticContext: String
    let reduceMotion: Bool
    let refreshDropTarget: () -> Void
    let scrollTo: (String) -> Void

    @State private var activeDirection: LauncherDragAutoScrollDirection?
    @State private var scrollTask: Task<Void, Never>?
    @State private var lastIssuedTargetID: String?

    var body: some View {
        Color.clear
            .onAppear {
                updateDirection(for: pointerLocation.location)
            }
            .onChange(of: isActive) { _, active in
                if active {
                    updateDirection(for: pointerLocation.location)
                } else {
                    stopScrolling()
                }
            }
            .onChange(of: pointerLocation.location) { _, location in
                updateDirection(for: location)
            }
            .onChange(of: geometry.viewportFrame) { _, _ in
                updateDirection(for: pointerLocation.location)
            }
            .onChange(of: geometry.panelFrame) { _, _ in
                updateDirection(for: pointerLocation.location)
            }
            .onChange(of: orderedApplicationIDs) { _, _ in
                // A scroll step can move the incoming placeholder, producing a
                // new value-semantic View. Restart so the task captures that
                // latest order rather than continuing with its old snapshot.
                // Preserve the issued cursor so stale frames cannot send the
                // next retry back to the same row.
                stopScrolling(resetCursor: false)
                updateDirection(for: pointerLocation.location)
            }
            .onDisappear {
                stopScrolling()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func updateDirection(for location: CGPoint) {
        guard isActive else {
            stopScrolling()
            return
        }
        let viewport = geometry.viewportFrame
        let edgeBand = min(64, max(38, viewport.height * 0.14))
        let direction = LauncherDragAutoScrollGeometry.direction(
            at: location,
            in: viewport,
            activationFrame: geometry.panelFrame,
            edgeBand: edgeBand
        )
        guard direction != activeDirection else { return }
        stopScrolling()
        guard let direction else { return }

        activeDirection = direction
        let directionLabel = direction == .backward ? "backward" : "forward"
        LauncherDragDiagnostics.log(
            "\(diagnosticContext) auto-scroll started \(directionLabel)"
        )
        scrollTask = Task { @MainActor in
            while !Task.isCancelled, activeDirection == direction {
                let didScroll = performScrollStep(direction: direction)
                let settleMilliseconds = reduceMotion ? 45 : 140
                try? await Task.sleep(for: .milliseconds(settleMilliseconds))
                guard !Task.isCancelled, activeDirection == direction else { return }
                if didScroll {
                    refreshDropTarget()
                }
                try? await Task.sleep(for: .milliseconds(didScroll ? 55 : 130))
            }
        }
    }

    @discardableResult
    private func performScrollStep(
        direction: LauncherDragAutoScrollDirection
    ) -> Bool {
        let geometryTarget = LauncherDragAutoScrollGeometry.nextTarget(
            direction: direction,
            orderedIDs: orderedApplicationIDs,
            frames: geometry.tileFrames,
            viewport: geometry.viewportFrame
        )
        let targetID: String?
        if let geometryTarget, geometryTarget != lastIssuedTargetID {
            targetID = geometryTarget
        } else {
            targetID = LauncherDragAutoScrollGeometry.steppedTarget(
                direction: direction,
                orderedIDs: orderedApplicationIDs,
                after: lastIssuedTargetID ?? fallbackAnchorID,
                frames: geometry.tileFrames
            )
            if targetID != nil {
                LauncherDragDiagnostics.log(
                    "\(diagnosticContext) auto-scroll used frame fallback"
                )
            }
        }
        guard let targetID else {
            let visibleCount = geometry.tileFrames.values.filter {
                $0.intersects(geometry.viewportFrame)
            }.count
            LauncherDragDiagnostics.log(
                "\(diagnosticContext) auto-scroll no-target "
                    + "ordered=\(orderedApplicationIDs.count) "
                    + "framed=\(geometry.tileFrames.count) "
                    + "visible=\(visibleCount)"
            )
            return false
        }
        lastIssuedTargetID = targetID
        scrollTo(targetID)
        let directionLabel = direction == .backward ? "backward" : "forward"
        LauncherDragDiagnostics.log(
            "\(diagnosticContext) auto-scroll step \(directionLabel)"
        )
        return true
    }

    private func stopScrolling(resetCursor: Bool = true) {
        let wasActive = activeDirection != nil || scrollTask != nil
        scrollTask?.cancel()
        scrollTask = nil
        activeDirection = nil
        if resetCursor {
            lastIssuedTargetID = nil
        }
        if wasActive {
            LauncherDragDiagnostics.log("\(diagnosticContext) auto-scroll stopped")
        }
    }
}

private struct LauncherFolderPointerSession: Equatable {
    let id: UUID
    let sourceApplicationID: String?
    var phase: LauncherPointerPhase
    var longPressTriggered: Bool
    var dropTarget: LauncherFolderDropTarget?
    var pagingEdge: LauncherPagingEdge?
    var edgeDwellID: UUID?
    var requiresEdgeExit: Bool
}

@MainActor
private struct LauncherFolderPanel: View {
    let folder: LaunchFolder
    let applications: [String: InstalledApplication]
    let topLevelPages: [[LaunchEntry]]
    let currentPage: Int
    let launcherSize: CGSize
    let mainIconSize: CGFloat
    let mainGridGeometry: LauncherMainGridGeometryState
    let gridGeometry: LauncherFolderGridGeometryState
    // Keep high-frequency cursor publications out of the panel and LazyVGrid;
    // only LauncherFolderFloatingDragPreview observes this reference.
    let pointerLocation: LauncherPointerLocationState
    let wiggleClock: LauncherWiggleClock
    let cancelDropFrame: CGRect
    @Binding var dragIsActive: Bool
    let iconProvider: (String) -> NSImage?
    let iconSize: CGFloat
    let showLabels: Bool
    let isEditing: Bool
    let deletingApplicationIDs: Set<String>
    @Binding var selectedApplicationID: String?
    let canDelete: (String) -> Bool
    let beginEditing: () -> Void
    let finishEditing: () -> Void
    let requestDelete: (String) -> Void
    let launch: (String) -> Void
    let hide: (String) -> Void
    let canRebuildWeChatCompanion: (String) -> Bool
    let isRebuildingWeChatCompanion: Bool
    let requestWeChatCompanionRebuild: (String) -> Void
    let removeFromFolder: (String) -> Void
    let reorder: (String, String?) -> Void
    let moveOut: (String, Int, String?) -> Bool
    let moveIntoFolder: (String, UUID) -> Bool
    let selectPage: (Int) -> Void
    @Binding var externalDragPreview: LauncherFolderExternalDragPreview?
    let rename: () -> Void
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointerSession: LauncherFolderPointerSession?
    @State private var stalePointerCleanupTask: Task<Void, Never>?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: max(86, iconSize + 28)), spacing: 26)]
    }

    private var previewApplicationIDs: [String] {
        guard let session = pointerSession,
              session.phase == .dragging,
              let sourceID = session.sourceApplicationID,
              let target = session.dropTarget else {
            return folder.applicationIDs
        }

        let insertion: LauncherProvisionalInsertion<String>
        switch target {
        case let .insertBefore(applicationID):
            insertion = .before(applicationID)
        case let .insertAfter(applicationID):
            insertion = .after(applicationID)
        case .endOfFolder:
            insertion = .end(pageIndex: 0)
        case .cancel, .moveOutBefore, .moveOutAfter, .moveOutEnd, .moveIntoFolder:
            return folder.applicationIDs.filter { $0 != sourceID }
        }
        return LauncherDragPreviewLayout.order(
            from: folder.applicationIDs,
            moving: sourceID,
            insertion: insertion
        )
    }

    var body: some View {
        LauncherGlassPanel {
            VStack(spacing: 10) {
                ZStack {
                    Button(action: rename) {
                        HStack(spacing: 7) {
                            VStack(spacing: 2) {
                                Text(folder.name)
                                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                Text(
                                    LaunchText.value(
                                        "\(folder.applicationIDs.count) 个应用",
                                        "\(folder.applicationIDs.count) applications"
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isEditing)
                    .accessibilityLabel(LaunchText.value("重命名文件夹 \(folder.name)", "Rename folder \(folder.name)"))

                    HStack {
                        Spacer()
                        if isEditing {
                            Button(action: finishEditing) {
                                Text(LaunchText.value("完成", "Done"))
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 14)
                                    .frame(height: 34)
                                    .background(.white.opacity(0.11), in: Capsule())
                                    .overlay {
                                        Capsule().stroke(.white.opacity(0.1), lineWidth: 0.5)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(
                                LaunchText.value("退出应用编辑模式", "Exit application editing mode")
                            )
                        } else {
                            Button(action: close) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .symbolRenderingMode(.hierarchical)
                                    .frame(width: 32, height: 32)
                                    .background(.white.opacity(0.075), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(LaunchText.value("关闭文件夹", "Close folder"))
                        }
                    }
                }
                .frame(minHeight: 46)

                ScrollViewReader { scrollProxy in
                    ScrollView {
                    let folderIsDragging = pointerSession?.phase == .dragging
                    let wiggleIsActive = isEditing && !folderIsDragging && !reduceMotion
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(previewApplicationIDs, id: \.self) { applicationID in
                            if let application = applications[applicationID] {
                                LauncherFolderApplicationTile(
                                    application: application,
                                    icon: iconProvider(applicationID),
                                    iconSize: min(iconSize, 84),
                                    showLabel: showLabels,
                                    isSelected: selectedApplicationID == applicationID,
                                    isEditing: isEditing,
                                    isWiggling: wiggleIsActive,
                                    wiggleClock: wiggleClock,
                                    isBeingDragged: folderIsDragging
                                        && pointerSession?.sourceApplicationID == applicationID,
                                    insertionEdge: folderInsertionEdge(for: applicationID),
                                    canDelete: canDelete(applicationID),
                                    isDeleting: deletingApplicationIDs.contains(applicationID),
                                    launch: {
                                        selectedApplicationID = applicationID
                                        launch(applicationID)
                                    },
                                    requestDelete: { requestDelete(applicationID) },
                                    hide: { hide(applicationID) },
                                    canRebuildWeChatCompanion: canRebuildWeChatCompanion(
                                        applicationID
                                    ),
                                    isRebuildingWeChatCompanion: isRebuildingWeChatCompanion,
                                    requestWeChatCompanionRebuild: {
                                        requestWeChatCompanionRebuild(applicationID)
                                    },
                                    removeFromFolder: { removeFromFolder(applicationID) }
                                )
                                .id(applicationID)
                            }
                        }
                    }
                    .animation(
                        reduceMotion ? nil : .smooth(duration: 0.2),
                        value: previewApplicationIDs
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 250, alignment: .top)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(
                            minimumDistance: 0,
                            coordinateSpace: .named(LauncherCoordinateSpaces.launcherRoot)
                        )
                        .onChanged(handleFolderPointerChanged)
                        .onEnded(handleFolderPointerEnded),
                        including: .all
                    )
                    .overlay(alignment: .topLeading) {
                        folderDragOverlay
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .preference(
                                    key: LauncherFolderGridFramePreferenceKey.self,
                                    value: proxy.frame(
                                        in: .named(LauncherCoordinateSpaces.launcherRoot)
                                    )
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    .onPreferenceChange(LauncherFolderTileFramePreferenceKey.self) { frames in
                        gridGeometry.update(tileFrames: frames)
                    }
                    .onPreferenceChange(LauncherFolderGridFramePreferenceKey.self) { frame in
                        gridGeometry.update(gridFrame: frame)
                    }
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .preference(
                                    key: LauncherFolderViewportFramePreferenceKey.self,
                                    value: proxy.frame(
                                        in: .named(
                                            LauncherCoordinateSpaces.launcherRoot
                                        )
                                    )
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    .onPreferenceChange(
                        LauncherFolderViewportFramePreferenceKey.self
                    ) { frame in
                        gridGeometry.update(viewportFrame: frame)
                    }
                    .overlay {
                        LauncherFolderDragAutoScrollObserver(
                            pointerLocation: pointerLocation,
                            geometry: gridGeometry,
                            orderedApplicationIDs: previewApplicationIDs,
                            fallbackAnchorID: pointerSession?.sourceApplicationID,
                            isActive: pointerSession?.phase == .dragging,
                            diagnosticContext: "formal",
                            reduceMotion: reduceMotion,
                            refreshDropTarget: refreshFolderDropTargetAfterScroll,
                            scrollTo: { applicationID in
                                withAnimation(
                                    reduceMotion ? nil : .linear(duration: 0.13)
                                ) {
                                    scrollProxy.scrollTo(
                                        applicationID,
                                        anchor: .center
                                    )
                                }
                            }
                        )
                    }
                    .onChange(of: selectedApplicationID) { _, applicationID in
                        guard let applicationID,
                              pointerSession?.phase != .dragging else {
                            return
                        }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            scrollProxy.scrollTo(applicationID, anchor: .center)
                        }
                    }
                    .task(id: folder.id) {
                        // A precise hover-folder drop selects its inserted member
                        // before this real panel is mounted, so onChange does not
                        // fire. Reveal that initial selection after the lazy grid
                        // has had one turn to register its IDs.
                        await Task.yield()
                        guard pointerSession?.phase != .dragging,
                              let selectedApplicationID,
                              folder.applicationIDs.contains(
                                selectedApplicationID
                              ) else {
                            return
                        }
                        scrollProxy.scrollTo(selectedApplicationID, anchor: .center)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: LauncherFolderPanelFramePreferenceKey.self,
                        value: proxy.frame(
                            in: .named(LauncherCoordinateSpaces.launcherRoot)
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(LauncherFolderPanelFramePreferenceKey.self) { frame in
            gridGeometry.update(panelFrame: frame)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LaunchText.value("文件夹 \(folder.name)", "Folder \(folder.name)"))
        .onChange(of: folder.applicationIDs) { _, _ in
            cancelPointerSession()
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                cancelPointerSession()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
        ) { _ in
            cancelPointerSession()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
        ) { _ in
            scheduleStalePointerCleanup()
        }
        .onDisappear {
            stalePointerCleanupTask?.cancel()
            stalePointerCleanupTask = nil
            pointerSession = nil
            externalDragPreview = nil
            dragIsActive = false
        }
    }

    private func cancelPointerSession() {
        externalDragPreview = nil
        dragIsActive = false
        guard var session = pointerSession else { return }
        session.phase = .ignored
        session.dropTarget = nil
        session.pagingEdge = nil
        session.edgeDwellID = nil
        session.requiresEdgeExit = true
        pointerSession = session
    }

    private func scheduleStalePointerCleanup() {
        guard let session = pointerSession,
              session.phase == .ignored else {
            return
        }
        let sessionID = session.id
        stalePointerCleanupTask?.cancel()
        stalePointerCleanupTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let active = pointerSession,
                      active.id == sessionID,
                      active.phase == .ignored else {
                    return
                }

                if NSEvent.pressedMouseButtons & 1 == 0 {
                    pointerSession = nil
                    return
                }

                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private func handleFolderPointerChanged(_ value: DragGesture.Value) {
        if pointerSession == nil {
            let sourceID = gridGeometry.tileFrames.first { _, frame in
                frame.contains(value.startLocation)
            }?.key
            let startsOnBadge = sourceID.map { applicationID in
                pointerStartsOnEditBadge(
                    applicationID: applicationID,
                    location: value.startLocation
                )
            } ?? false
            let sessionID = UUID()
            pointerSession = LauncherFolderPointerSession(
                id: sessionID,
                sourceApplicationID: sourceID,
                phase: sourceID == nil || startsOnBadge ? .ignored : .pressing,
                longPressTriggered: false,
                dropTarget: nil,
                pagingEdge: nil,
                edgeDwellID: nil,
                requiresEdgeExit: false
            )
            if sourceID != nil, !startsOnBadge {
                scheduleLongPress(sessionID: sessionID)
            }
        }

        guard var session = pointerSession else { return }
        let effectiveLocation = launcherEffectiveDragLocation(
            value,
            clampedTo: CGRect(origin: .zero, size: launcherSize)
        )
        pointerLocation.update(effectiveLocation)
        guard session.phase != .ignored else {
            pointerSession = session
            return
        }
        let distance = hypot(value.translation.width, value.translation.height)
        if session.phase == .pressing,
           distance > LauncherDragTuning.activationDistance {
            guard let sourceID = session.sourceApplicationID,
                  folder.applicationIDs.contains(sourceID) else {
                session.phase = .ignored
                pointerSession = session
                return
            }
            session.phase = .dragging
            session.longPressTriggered = false
            dragIsActive = true
        }

        if session.phase == .dragging,
           let sourceID = session.sourceApplicationID {
            let scheduledPageTurn = prepareFolderEdgePaging(
                session: &session,
                location: effectiveLocation
            )
            var target = resolveDropTarget(
                sourceApplicationID: sourceID,
                location: effectiveLocation
            )
            if target == nil,
               session.dropTarget != nil,
               gridGeometry.tileFrames[sourceID]?.contains(effectiveLocation) == true {
                target = session.dropTarget
            }
            session.dropTarget = target
            updateExternalDragPreview(for: session, target: target)
            if let scheduledPageTurn {
                scheduleFolderPageTurn(
                    sessionID: session.id,
                    dwellID: scheduledPageTurn.dwellID,
                    edge: scheduledPageTurn.edge
                )
            }
        }
        if pointerSession != session {
            pointerSession = session
        }
    }

    private func handleFolderPointerEnded(_ value: DragGesture.Value) {
        // A cancelled recognizer may emit a late end after stale-session
        // cleanup. It must not recreate a press and launch an application.
        guard pointerSession != nil else { return }
        handleFolderPointerChanged(value)
        guard let session = pointerSession else { return }
        pointerSession = nil
        dragIsActive = false
        defer { externalDragPreview = nil }

        switch session.phase {
        case .dragging:
            guard let sourceID = session.sourceApplicationID,
                  let target = session.dropTarget,
                  folder.applicationIDs.contains(sourceID) else {
                return
            }
            commitDrop(sourceApplicationID: sourceID, target: target)

        case .pressing:
            guard let sourceID = session.sourceApplicationID,
                  !session.longPressTriggered,
                  !isEditing,
                  folder.applicationIDs.contains(sourceID) else {
                return
            }
            selectedApplicationID = sourceID
            launch(sourceID)

        case .ignored:
            return
        }
    }

    private func scheduleLongPress(sessionID: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(520))
            guard var session = pointerSession,
                  session.id == sessionID,
                  session.phase == .pressing,
                  session.sourceApplicationID != nil else {
                return
            }
            session.longPressTriggered = true
            pointerSession = session
            beginEditing()
        }
    }

    private func prepareFolderEdgePaging(
        session: inout LauncherFolderPointerSession,
        location: CGPoint
    ) -> (edge: LauncherPagingEdge, dwellID: UUID)? {
        guard let edge = actionableFolderPagingEdge(at: location) else {
            session.pagingEdge = nil
            session.edgeDwellID = nil
            session.requiresEdgeExit = false
            return nil
        }

        if session.pagingEdge != edge {
            session.pagingEdge = edge
            session.edgeDwellID = nil
        }
        guard !session.requiresEdgeExit else { return nil }
        if session.edgeDwellID == nil {
            let dwellID = UUID()
            session.edgeDwellID = dwellID
            return (edge, dwellID)
        }
        return nil
    }

    private func actionableFolderPagingEdge(
        at location: CGPoint
    ) -> LauncherPagingEdge? {
        guard !gridGeometry.panelFrame.contains(location),
              location.y >= 0,
              location.y <= launcherSize.height else {
            return nil
        }
        let edgeWidth = max(24, min(32, launcherSize.width * 0.022))
        if location.x <= edgeWidth, currentPage > 0 {
            return .previous
        }
        if location.x >= launcherSize.width - edgeWidth,
           currentPage < topLevelPages.count - 1 {
            return .next
        }
        return nil
    }

    private func scheduleFolderPageTurn(
        sessionID: UUID,
        dwellID: UUID,
        edge: LauncherPagingEdge
    ) {
        Task { @MainActor in
            try? await Task.sleep(
                for: .milliseconds(LauncherDragTuning.edgePageDwellMilliseconds)
            )
            guard var session = pointerSession,
                  session.id == sessionID,
                  session.phase == .dragging,
                  session.edgeDwellID == dwellID,
                  session.pagingEdge == edge,
                  actionableFolderPagingEdge(at: pointerLocation.location) == edge else {
                return
            }
            let destination = edge == .previous ? currentPage - 1 : currentPage + 1
            guard topLevelPages.indices.contains(destination) else { return }

            session.dropTarget = .moveOutEnd(pageIndex: destination)
            session.edgeDwellID = nil
            session.requiresEdgeExit = true
            pointerSession = session
            updateExternalDragPreview(for: session, target: session.dropTarget)
            selectPage(destination)
        }
    }

    private func pointerStartsOnEditBadge(
        applicationID: String,
        location: CGPoint
    ) -> Bool {
        guard isEditing,
              let frame = gridGeometry.tileFrames[applicationID] else {
            return false
        }
        let effectiveIconSize = min(iconSize, 84)
        let iconFrame = CGRect(
            x: frame.midX - (effectiveIconSize + 12) / 2,
            y: frame.minY,
            width: effectiveIconSize + 12,
            height: effectiveIconSize + 12
        )
        let hitSize: CGFloat = 32
        let hideRect = CGRect(
            x: iconFrame.maxX - hitSize,
            y: iconFrame.minY,
            width: hitSize,
            height: hitSize
        )
        if hideRect.contains(location) { return true }

        guard canDelete(applicationID) else { return false }
        return CGRect(
            x: iconFrame.minX,
            y: iconFrame.minY,
            width: hitSize,
            height: hitSize
        ).contains(location)
    }

    /// `ScrollViewReader` can reveal another row while the physical pointer is
    /// stationary, so no new `DragGesture.onChanged` callback is guaranteed.
    /// Re-resolve from the shared cursor reference after each controlled scroll
    /// step and publish only when the semantic insertion slot actually changes.
    private func refreshFolderDropTargetAfterScroll() {
        guard var session = pointerSession,
              session.phase == .dragging,
              let sourceApplicationID = session.sourceApplicationID,
              folder.applicationIDs.contains(sourceApplicationID) else {
            return
        }

        var target = resolveDropTarget(
            sourceApplicationID: sourceApplicationID,
            location: pointerLocation.location
        )
        if target == nil,
           session.dropTarget != nil,
           gridGeometry.tileFrames[sourceApplicationID]?
            .contains(pointerLocation.location) == true {
            target = session.dropTarget
        }
        guard target != session.dropTarget else { return }

        session.dropTarget = target
        updateExternalDragPreview(for: session, target: target)
        pointerSession = session
    }

    private func resolveDropTarget(
        sourceApplicationID: String,
        location: CGPoint
    ) -> LauncherFolderDropTarget? {
        guard folder.applicationIDs.contains(sourceApplicationID) else { return nil }
        if cancelDropFrame.contains(location) { return .cancel }
        let tileFrames = gridGeometry.tileFrames
        let viewport = gridGeometry.viewportFrame.width > 0
            && gridGeometry.viewportFrame.height > 0
            ? gridGeometry.viewportFrame
            : gridGeometry.gridFrame
        if viewport.contains(location) {
            if let sourceFrame = tileFrames[sourceApplicationID],
               sourceFrame.contains(location) {
                return nil
            }
            if let hit = tileFrames.first(where: { applicationID, frame in
                applicationID != sourceApplicationID
                    && frame.intersects(viewport)
                    && frame.contains(location)
            }) {
                return location.x < hit.value.midX
                    ? .insertBefore(applicationID: hit.key)
                    : .insertAfter(applicationID: hit.key)
            }

            let orderedApplicationIDs = previewApplicationIDs.filter {
                $0 != sourceApplicationID
            }
            let visibleFrames = tileFrames.filter { applicationID, frame in
                applicationID != sourceApplicationID
                    && frame.width > 0
                    && frame.height > 0
                    && frame.intersects(viewport)
            }
            let visibleApplicationIDs = orderedApplicationIDs.filter {
                visibleFrames[$0] != nil
            }
            guard let firstVisibleID = visibleApplicationIDs.first,
                  let lastVisibleID = visibleApplicationIDs.last,
                  let firstVisibleFrame = visibleFrames[firstVisibleID],
                  let lastVisibleFrame = visibleFrames[lastVisibleID] else {
                return orderedApplicationIDs.isEmpty ? .endOfFolder : nil
            }

            if location.y < firstVisibleFrame.minY {
                return .insertBefore(applicationID: firstVisibleID)
            }

            func targetAfterVisibleTail() -> LauncherFolderDropTarget {
                guard let lastIndex = orderedApplicationIDs.firstIndex(
                    of: lastVisibleID
                ), orderedApplicationIDs.indices.contains(lastIndex + 1) else {
                    return .endOfFolder
                }
                return .insertBefore(
                    applicationID: orderedApplicationIDs[lastIndex + 1]
                )
            }

            if location.y > lastVisibleFrame.maxY {
                return targetAfterVisibleTail()
            }

            switch LauncherDropGeometry.nearestInsertion(
                at: location,
                orderedIDs: orderedApplicationIDs,
                frames: visibleFrames,
                excluding: nil
            ) {
            case let .before(applicationID):
                return .insertBefore(applicationID: applicationID)
            case let .after(applicationID):
                return .insertAfter(applicationID: applicationID)
            case .end:
                return targetAfterVisibleTail()
            case nil:
                return nil
            }
        }

        // Moving through the panel's title or controls is not a drop. Once the
        // pointer crosses the panel boundary, the full launcher becomes a
        // clear, forgiving move-out surface.
        if gridGeometry.panelFrame.contains(location) { return nil }
        guard location.x >= 0,
              location.x <= launcherSize.width,
              location.y >= 0,
              location.y <= launcherSize.height else {
            return nil
        }
        return resolveMainGridTarget(at: location)
    }

    private func commitDrop(
        sourceApplicationID: String,
        target: LauncherFolderDropTarget
    ) {
        let currentIDs = folder.applicationIDs
        guard currentIDs.contains(sourceApplicationID) else { return }
        switch target {
        case .cancel:
            return

        case let .insertBefore(targetID):
            guard currentIDs.contains(targetID), targetID != sourceApplicationID else { return }
            reorder(sourceApplicationID, targetID)

        case let .insertAfter(targetID):
            let filtered = currentIDs.filter { $0 != sourceApplicationID }
            guard let targetIndex = filtered.firstIndex(of: targetID) else { return }
            let nextID = filtered.indices.contains(targetIndex + 1)
                ? filtered[targetIndex + 1]
                : nil
            reorder(sourceApplicationID, nextID)

        case .endOfFolder:
            reorder(sourceApplicationID, nil)

        case let .moveOutBefore(entryID, pageIndex):
            _ = moveOut(sourceApplicationID, pageIndex, entryID.uuidString)

        case let .moveOutAfter(entryID, pageIndex):
            guard topLevelPages.indices.contains(pageIndex) else { return }
            let entries = topLevelPages[pageIndex]
            guard let targetIndex = entries.firstIndex(where: { $0.id == entryID }) else {
                return
            }
            let nextIdentity = entries.indices.contains(targetIndex + 1)
                ? entries[targetIndex + 1].id.uuidString
                : nil
            _ = moveOut(sourceApplicationID, pageIndex, nextIdentity)

        case let .moveOutEnd(pageIndex):
            _ = moveOut(sourceApplicationID, pageIndex, nil)

        case let .moveIntoFolder(destinationFolderID, _):
            guard destinationFolderID != folder.id else { return }
            _ = moveIntoFolder(sourceApplicationID, destinationFolderID)
        }
    }

    private func folderInsertionEdge(for applicationID: String) -> LauncherInsertionEdge? {
        guard let session = pointerSession,
              session.phase == .dragging,
              let target = session.dropTarget else {
            return nil
        }
        switch target {
        case let .insertBefore(targetID) where targetID == applicationID:
            return .before
        case let .insertAfter(targetID) where targetID == applicationID:
            return .after
        default:
            return nil
        }
    }

    private func resolveMainGridTarget(
        at location: CGPoint
    ) -> LauncherFolderDropTarget {
        guard topLevelPages.indices.contains(currentPage),
              mainGridGeometry.rootFrame.contains(location) else {
            return .moveOutEnd(pageIndex: currentPage)
        }

        let entries = topLevelPages[currentPage]
        let pageFrames = mainGridGeometry.rootTileFrames.filter { key, _ in
            key.pageIndex == currentPage
                && entries.contains(where: { $0.id == key.entryID })
        }
        let framesByEntryID = Dictionary(
            uniqueKeysWithValues: pageFrames.map { ($0.key.entryID, $0.value) }
        )

        if let hit = pageFrames.first(where: { _, frame in frame.contains(location) }),
           let target = entries.first(where: { $0.id == hit.key.entryID }) {
            if let destinationFolder = target.folder {
                let combineSize = min(
                    hit.value.width * 0.84,
                    max(48, mainIconSize * 0.92)
                )
                let iconCenter = CGPoint(
                    x: hit.value.midX,
                    y: hit.value.minY
                        + (mainIconSize + LauncherTileLayout.iconChrome) / 2
                )
                let combineRect = CGRect(
                    x: iconCenter.x - combineSize / 2,
                    y: iconCenter.y - combineSize / 2,
                    width: combineSize,
                    height: combineSize
                )
                if combineRect.contains(location) {
                    return .moveIntoFolder(
                        folderID: destinationFolder.id,
                        pageIndex: currentPage
                    )
                }
            }
            return location.x < hit.value.midX
                ? .moveOutBefore(entryID: target.id, pageIndex: currentPage)
                : .moveOutAfter(entryID: target.id, pageIndex: currentPage)
        }

        switch LauncherDropGeometry.nearestInsertion(
            at: location,
            orderedIDs: entries.map(\.id),
            frames: framesByEntryID,
            excluding: nil
        ) {
        case let .before(entryID):
            return .moveOutBefore(entryID: entryID, pageIndex: currentPage)
        case let .after(entryID):
            return .moveOutAfter(entryID: entryID, pageIndex: currentPage)
        case .end, nil:
            return .moveOutEnd(pageIndex: currentPage)
        }
    }

    private func updateExternalDragPreview(
        for session: LauncherFolderPointerSession,
        target: LauncherFolderDropTarget?
    ) {
        guard let sourceApplicationID = session.sourceApplicationID,
              let target,
              target.isExternalFolderDropTarget else {
            if externalDragPreview != nil {
                externalDragPreview = nil
            }
            return
        }
        let next = LauncherFolderExternalDragPreview(
            sourceApplicationID: sourceApplicationID,
            placeholderEntryID: session.id,
            target: target
        )
        if externalDragPreview != next {
            externalDragPreview = next
        }
    }

    @ViewBuilder
    private var folderDragOverlay: some View {
        if let session = pointerSession,
           session.phase == .dragging,
           let sourceID = session.sourceApplicationID,
           let application = applications[sourceID],
           session.dropTarget?.isExternalFolderDropTarget != true {
            LauncherFolderFloatingDragPreview(
                pointerLocation: pointerLocation,
                application: application,
                icon: iconProvider(sourceID),
                coordinateOffset: CGPoint(
                    x: gridGeometry.gridFrame.minX,
                    y: gridGeometry.gridFrame.minY
                ),
                status: session.dropTarget?.dragStatus
            )
        }
    }
}

@MainActor
private struct LauncherFolderFloatingDragPreview: View {
    @ObservedObject var pointerLocation: LauncherPointerLocationState
    let application: InstalledApplication
    let icon: NSImage?
    let coordinateOffset: CGPoint
    let status: LauncherFolderDragStatus?

    var body: some View {
        VStack(spacing: 2) {
            LauncherAppIcon(
                image: icon,
                fallbackName: application.name,
                size: 58
            )
            .padding(8)

            if let status {
                Label(status.title, systemImage: status.systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(.black.opacity(0.62), in: Capsule())
                    .overlay {
                        Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5)
                    }
            }
        }
        .scaleEffect(1.05)
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
        .position(
            x: pointerLocation.location.x - coordinateOffset.x,
            y: pointerLocation.location.y - coordinateOffset.y
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .zIndex(100)
    }
}

@MainActor
private struct LauncherFolderApplicationTile: View {
    let application: InstalledApplication
    let icon: NSImage?
    let iconSize: CGFloat
    let showLabel: Bool
    let isSelected: Bool
    let isEditing: Bool
    let isWiggling: Bool
    let wiggleClock: LauncherWiggleClock
    let isBeingDragged: Bool
    let insertionEdge: LauncherInsertionEdge?
    let canDelete: Bool
    let isDeleting: Bool
    let launch: () -> Void
    let requestDelete: () -> Void
    let hide: () -> Void
    let canRebuildWeChatCompanion: Bool
    let isRebuildingWeChatCompanion: Bool
    let requestWeChatCompanionRebuild: () -> Void
    let removeFromFolder: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: showLabel ? 8 : 0) {
            ZStack {
                LauncherAppIcon(
                    image: icon,
                    fallbackName: application.name,
                    size: iconSize
                )
                .launcherWiggle(
                    isEditing: isWiggling,
                    clock: wiggleClock,
                    seed: application.id.hashValue
                )

                if isEditing {
                    if canDelete {
                        LauncherDeleteBadge(
                            isWorking: isDeleting,
                            action: requestDelete
                        )
                        .frame(
                            width: iconSize + 12,
                            height: iconSize + 12,
                            alignment: .topLeading
                        )
                    }

                    LauncherHideBadge(action: hide)
                        .frame(
                            width: iconSize + 12,
                            height: iconSize + 12,
                            alignment: .topTrailing
                        )
                }
            }
            .frame(width: iconSize + 12, height: iconSize + 12)
            .scaleEffect(
                insertionEdge != nil
                    ? 0.94
                    : (isHovering && !isEditing ? 1.05 : 1)
            )

            if showLabel {
                LauncherTileLabel(title: application.name)
                    .frame(height: 36, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background {
            LauncherTileSurface(
                isHovering: isHovering,
                isSelected: isSelected,
                isEditing: isEditing
            )
            .padding(.horizontal, 3)
        }
        .opacity(isBeingDragged ? 0.1 : 1)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: insertionEdge
        )
        .onHover { hovering in
            guard !isEditing else {
                if isHovering { isHovering = false }
                return
            }
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
        }
        .onChange(of: isEditing) { _, editing in
            guard editing, isHovering else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isHovering = false
            }
        }
        .contextMenu {
            if canRebuildWeChatCompanion {
                Button(action: requestWeChatCompanionRebuild) {
                    Label(
                        LaunchText.value("双开", "Dual Launch"),
                        systemImage: "square.on.square"
                    )
                }
                .disabled(isRebuildingWeChatCompanion)

                Divider()
            }

            Button(LaunchText.value("移出文件夹", "Move Out of Folder"), action: removeFromFolder)
            Button(action: hide) {
                Label(
                    LaunchText.value("隐藏", "Hide"),
                    systemImage: "eye.slash"
                )
            }

            if canDelete {
                Button(role: .destructive, action: requestDelete) {
                    Label(
                        LaunchText.value("卸载", "Uninstall"),
                        systemImage: "trash"
                    )
                }
            }
        }
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(application.name)
        .accessibilityHint(LaunchText.value("按回车键打开", "Press Return to open"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            guard !isEditing else { return }
            launch()
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: LauncherFolderTileFramePreferenceKey.self,
                        value: [
                            application.id: proxy.frame(
                                in: .named(LauncherCoordinateSpaces.launcherRoot)
                            )
                        ]
                    )
                    .allowsHitTesting(false)
            }
        }
    }

}

private struct LauncherLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(LaunchText.value("正在查找应用…", "Finding applications…"))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 7)
        .accessibilityElement(children: .combine)
    }
}

private struct LauncherEmptyView: View {
    let isSearching: Bool
    let clearSearch: () -> Void
    let rescan: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: isSearching ? "magnifyingglass" : "square.grid.3x3.fill")
                .font(.system(size: 28, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: 66, height: 66)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }

            Text(
                isSearching
                    ? LaunchText.value("没有结果", "No Results")
                    : LaunchText.value("没有应用", "No Applications")
            )
            .font(.system(size: 22, weight: .semibold, design: .rounded))

            Text(
                isSearching
                    ? LaunchText.value("请尝试其他应用名称。", "Try a different application name.")
                    : LaunchText.value("重新扫描后，启动台会自动添加应用。", "启动台 will add applications after a new scan.")
            )
            .font(.callout)
            .foregroundStyle(.white.opacity(0.62))

            Button(
                isSearching
                    ? LaunchText.value("清除搜索", "Clear Search")
                    : LaunchText.value("重新扫描", "Scan Again"),
                action: isSearching ? clearSearch : rescan
            )
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.2))
        }
        .padding(28)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct LauncherErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .lineLimit(2)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LaunchText.value("关闭错误提示", "Dismiss error"))
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
        .padding(.horizontal, 24)
    }
}

private struct LauncherProgressBanner: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(title)
                .lineLimit(1)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 15)
        .frame(height: 42)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.26), radius: 12, y: 5)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

private struct LauncherDragCancelZone: View {
    let isTargeted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label(LaunchText.value("取消", "Cancel"), systemImage: "xmark")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isTargeted ? Color.white : Color.white.opacity(0.86))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                isTargeted ? Color.red.opacity(0.72) : Color.black.opacity(0.24),
                in: Capsule()
            )
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().stroke(
                    isTargeted ? Color.white.opacity(0.48) : Color.white.opacity(0.16),
                    lineWidth: isTargeted ? 1.5 : 1
                )
            }
            .shadow(
                color: isTargeted ? Color.red.opacity(0.24) : Color.black.opacity(0.2),
                radius: isTargeted ? 14 : 9,
                y: 3
            )
            .scaleEffect(isTargeted ? 1.05 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: isTargeted
            )
    }
}
