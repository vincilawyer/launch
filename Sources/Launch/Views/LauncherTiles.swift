import AppKit
import SwiftUI

enum LauncherTileLayout {
    static let iconChrome: CGFloat = 18
    static let labelSpacing: CGFloat = 9
    static let labelHeight: CGFloat = 36

    static func chromeHeight(showLabel: Bool) -> CGFloat {
        iconChrome + (showLabel ? labelSpacing + labelHeight : 0)
    }

    static func requiredHeight(iconSize: CGFloat, showLabel: Bool) -> CGFloat {
        iconSize + chromeHeight(showLabel: showLabel)
    }

    static func fittedIconSize(
        availableHeight: CGFloat,
        rows: Int,
        spacing: CGFloat,
        showLabel: Bool
    ) -> CGFloat {
        let safeRows = max(1, rows)
        let spacingTotal = spacing * CGFloat(max(0, safeRows - 1))
        return (availableHeight - spacingTotal) / CGFloat(safeRows)
            - chromeHeight(showLabel: showLabel)
    }

    static func usedRows(itemCount: Int, columns: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let safeColumns = max(1, columns)
        return (itemCount + safeColumns - 1) / safeColumns
    }

    static func requiredGridHeight(
        itemCount: Int,
        columns: Int,
        iconSize: CGFloat,
        spacing: CGFloat,
        showLabel: Bool
    ) -> CGFloat {
        let rows = usedRows(itemCount: itemCount, columns: columns)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * requiredHeight(
            iconSize: iconSize,
            showLabel: showLabel
        ) + CGFloat(rows - 1) * max(0, spacing)
    }

    static func requiresVerticalScrolling(
        requiredHeight: CGFloat,
        availableHeight: CGFloat
    ) -> Bool {
        requiredHeight > max(0, availableHeight) + 0.5
    }
}

enum LauncherFolderIconLayout {
    static func columnCount(imageCount: Int) -> Int {
        imageCount <= 4 ? 2 : 3
    }

    static func miniSize(size: CGFloat, columns: Int) -> CGFloat {
        columns <= 2 ? size * 0.325 : size * 0.205
    }

    static func spacing(size: CGFloat, columns: Int) -> CGFloat {
        columns <= 2 ? size * 0.07 : size * 0.045
    }

    static func glassInset(size: CGFloat) -> CGFloat {
        size * 0.045
    }

    static func thumbnailExtent(size: CGFloat, columns: Int) -> CGFloat {
        let safeColumns = max(1, columns)
        return miniSize(size: size, columns: safeColumns) * CGFloat(safeColumns)
            + spacing(size: size, columns: safeColumns) * CGFloat(safeColumns - 1)
    }

    static func glassExtent(size: CGFloat) -> CGFloat {
        max(0, size - glassInset(size: size) * 2)
    }
}

#if DEBUG
enum LauncherTileLayoutDebugChecks {
    private static let runOnce: Void = {
        assert(LauncherTileLayout.requiredHeight(iconSize: 112, showLabel: true) == 175)
        assert(LauncherTileLayout.requiredHeight(iconSize: 112, showLabel: false) == 130)
        // The factory preference is 100 pt. Its complete tile budget includes
        // the same chrome used by LauncherEntryTile, so labels and the next row
        // can never be laid out inside the icon's visual bounds.
        assert(LauncherTileLayout.requiredHeight(iconSize: 100, showLabel: true) == 163)
        assert(LauncherTileLayout.requiredHeight(iconSize: 100, showLabel: false) == 118)

        let defaultRows = 5
        let compactSpacing: CGFloat = 4
        let exactDefaultGridHeight = CGFloat(defaultRows) * 163
            + CGFloat(defaultRows - 1) * compactSpacing
        let exactDefaultFit = LauncherTileLayout.fittedIconSize(
            availableHeight: exactDefaultGridHeight,
            rows: defaultRows,
            spacing: compactSpacing,
            showLabel: true
        )
        assert(abs(exactDefaultFit - 100) < 0.001)

        let rows = 4
        let spacing: CGFloat = 6
        let exactHeight = CGFloat(rows) * 175 + CGFloat(rows - 1) * spacing
        let fitted = LauncherTileLayout.fittedIconSize(
            availableHeight: exactHeight,
            rows: rows,
            spacing: spacing,
            showLabel: true
        )
        assert(abs(fitted - 112) < 0.001)
        assert(
            CGFloat(rows) * LauncherTileLayout.requiredHeight(
                iconSize: fitted,
                showLabel: true
            ) + CGFloat(rows - 1) * spacing <= exactHeight + 0.001
        )

        assert(LauncherTileLayout.usedRows(itemCount: 0, columns: 7) == 0)
        assert(LauncherTileLayout.usedRows(itemCount: 1, columns: 7) == 1)
        assert(LauncherTileLayout.usedRows(itemCount: 8, columns: 7) == 2)

        let partialPageHeight = LauncherTileLayout.requiredGridHeight(
            itemCount: 8,
            columns: 7,
            iconSize: 112,
            spacing: 6,
            showLabel: true
        )
        assert(abs(partialPageHeight - (175 * 2 + 6)) < 0.001)
        assert(
            !LauncherTileLayout.requiresVerticalScrolling(
                requiredHeight: partialPageHeight,
                availableHeight: 356
            )
        )
        assert(
            LauncherTileLayout.requiresVerticalScrolling(
                requiredHeight: partialPageHeight,
                availableHeight: 355
            )
        )

        for iconSize: CGFloat in [48, 84, 100, 112] {
            let glassExtent = LauncherFolderIconLayout.glassExtent(
                size: iconSize
            )
            let twoColumnExtent = LauncherFolderIconLayout.thumbnailExtent(
                size: iconSize,
                columns: 2
            )
            let threeColumnExtent = LauncherFolderIconLayout.thumbnailExtent(
                size: iconSize,
                columns: 3
            )
            assert(
                twoColumnExtent <= glassExtent
            )
            assert(
                threeColumnExtent <= glassExtent
            )
            // Both layouts retain at least 9% of the icon size as inset on
            // each side of the thumbnail matrix, keeping the glass legible.
            assert(glassExtent - twoColumnExtent >= iconSize * 0.18)
            assert(glassExtent - threeColumnExtent >= iconSize * 0.18)
        }
    }()

    static func run() {
        _ = runOnce
    }
}
#endif

struct LauncherAppIcon: View {
    let image: NSImage?
    let fallbackName: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        Text(fallbackInitials)
                            .font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.3), radius: max(4, size * 0.08), y: max(2, size * 0.04))
        .accessibilityHidden(true)
    }

    private var fallbackInitials: String {
        fallbackName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

struct LauncherFolderIcon: View {
    let images: [NSImage]
    let size: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var columnCount: Int {
        LauncherFolderIconLayout.columnCount(imageCount: images.count)
    }
    private var maximumImageCount: Int { columnCount * columnCount }
    private var miniSize: CGFloat {
        LauncherFolderIconLayout.miniSize(size: size, columns: columnCount)
    }
    private var spacing: CGFloat {
        LauncherFolderIconLayout.spacing(size: size, columns: columnCount)
    }

    var body: some View {
        ZStack {
            folderGlass

            if images.isEmpty {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(size * 0.22)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(miniSize), spacing: spacing),
                        count: columnCount
                    ),
                    spacing: spacing
                ) {
                    ForEach(0..<min(images.count, maximumImageCount), id: \.self) { index in
                        Image(nsImage: images[index])
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: miniSize, height: miniSize)
                            .shadow(
                                color: .black.opacity(0.12),
                                radius: max(1, miniSize * 0.045),
                                y: max(0.5, miniSize * 0.02)
                            )
                    }
                }
                .frame(width: size, height: size, alignment: .center)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var folderGlass: some View {
        let shape = RoundedRectangle(
            cornerRadius: size * 0.235,
            style: .continuous
        )
        return ZStack {
            if reduceTransparency {
                shape.fill(Color.black.opacity(0.28))
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .opacity(0.64)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.055),
                            Color.white.opacity(0.01),
                            Color.black.opacity(0.055),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }

            shape.stroke(Color.white.opacity(0.08), lineWidth: 0.6)
        }
        .padding(LauncherFolderIconLayout.glassInset(size: size))
        .shadow(
            color: .black.opacity(0.13),
            radius: max(2, size * 0.055),
            y: max(1, size * 0.025)
        )
    }
}

struct LauncherTileLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
    }
}

struct LauncherTileSurface: View {
    let isHovering: Bool
    let isSelected: Bool
    let isEditing: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 19, style: .continuous)
            .fill(fillColor)
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .shadow(
                color: isSelected ? .black.opacity(0.16) : .clear,
                radius: 8,
                y: 3
            )
            .accessibilityHidden(true)
    }

    private var fillColor: Color {
        if isSelected && !isEditing {
            return .white.opacity(0.13)
        }
        if isHovering && !isEditing {
            return .white.opacity(0.075)
        }
        if isEditing {
            return .white.opacity(0.035)
        }
        return .clear
    }

    private var borderColor: Color {
        if isSelected && !isEditing {
            return .white.opacity(0.16)
        }
        if isHovering && !isEditing {
            return .white.opacity(0.08)
        }
        if isEditing {
            return .white.opacity(0.04)
        }
        return .clear
    }
}

struct LauncherDeleteBadge: View {
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                Circle()
                    .fill(Color.black.opacity(0.42))
                Circle()
                    .stroke(.white.opacity(0.55), lineWidth: 1)

                if isWorking {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 24, height: 24)
            .shadow(color: .black.opacity(0.38), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel(
            LaunchText.value("将应用移到废纸篓", "Move application to Trash")
        )
    }
}

struct LauncherHideBadge: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                Circle()
                    .fill(Color.black.opacity(0.36))
                Circle()
                    .stroke(.white.opacity(0.46), lineWidth: 1)

                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
            .shadow(color: .black.opacity(0.34), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help(LaunchText.value("从 Launch 中隐藏", "Hide from Launch"))
        .accessibilityLabel(
            LaunchText.value("从 Launch 中隐藏应用", "Hide application from Launch")
        )
    }
}

enum LauncherTileDropIntent: Equatable {
    case combinePending
    case combine
    case reorderBefore
    case reorderAfter
}

enum LauncherInsertionEdge: Equatable {
    case before
    case after
}

enum LauncherCoordinateSpaces {
    static let launcherRoot = "launcher.root"
    static let mainGrid = "launcher.main-grid"
}

struct LauncherPageTileFrameKey: Hashable {
    let pageIndex: Int
    let entryID: UUID
}

struct LauncherTileFramePreferenceKey: PreferenceKey {
    static let defaultValue: [LauncherPageTileFrameKey: CGRect] = [:]

    static func reduce(
        value: inout [LauncherPageTileFrameKey: CGRect],
        nextValue: () -> [LauncherPageTileFrameKey: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct LauncherRootTileFramePreferenceKey: PreferenceKey {
    static let defaultValue: [LauncherPageTileFrameKey: CGRect] = [:]

    static func reduce(
        value: inout [LauncherPageTileFrameKey: CGRect],
        nextValue: () -> [LauncherPageTileFrameKey: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct LauncherMainGridFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

struct LauncherFolderTileFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct LauncherFolderGridFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

struct LauncherFolderViewportFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

struct LauncherFolderPanelFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

/// Dedicated preferences for the passive folder preview shown during a
/// top-level drag. They must not share the live folder panel's keys because the
/// latter may remain mounted while another drag presentation is unwinding.
struct LauncherHoverFolderTileFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct LauncherHoverFolderPanelFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

struct LauncherHoverFolderViewportFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

@MainActor
final class LauncherWiggleClock: ObservableObject {
    @Published fileprivate(set) var phase: Double = 0

    private var updateTask: Task<Void, Never>?

    func setActive(_ active: Bool) {
        if !active {
            updateTask?.cancel()
            updateTask = nil
            if phase != 0 { phase = 0 }
            return
        }

        guard updateTask == nil else { return }
        updateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                phase = Date.timeIntervalSinceReferenceDate / 0.36 * .pi * 2
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// Only this leaf observes the shared clock. The surrounding tile, grid and
/// geometry preference reporters remain unchanged while icons wiggle.
@MainActor
private struct LauncherActiveWiggle<Content: View>: View {
    @ObservedObject var clock: LauncherWiggleClock
    let seed: Int
    let content: Content

    var body: some View {
        let transform = transform
        content
            .rotationEffect(.degrees(transform.rotation))
            .offset(y: transform.offset)
            .animation(.linear(duration: 0.1), value: clock.phase)
    }

    private var transform: (rotation: Double, offset: CGFloat) {
        let unsignedSeed = UInt(bitPattern: seed)
        let seedPhase = Double(unsignedSeed % 997) / 997.0 * .pi * 2
        let wave = sin(clock.phase + seedPhase)
        let lift = cos(clock.phase + seedPhase)
        return (wave * 1.15, CGFloat(lift * 0.7))
    }
}

@MainActor
private struct LauncherWiggleContainer<Content: View>: View {
    let isActive: Bool
    let clock: LauncherWiggleClock
    let seed: Int
    let content: Content

    @ViewBuilder
    var body: some View {
        if isActive {
            LauncherActiveWiggle(clock: clock, seed: seed, content: content)
        } else {
            content
        }
    }
}

extension View {
    @MainActor
    func launcherWiggle(
        isEditing: Bool,
        clock: LauncherWiggleClock,
        seed: Int
    ) -> some View {
        LauncherWiggleContainer(
            isActive: isEditing,
            clock: clock,
            seed: seed,
            content: self
        )
    }
}

@MainActor
struct LauncherEntryTile: View {
    let entry: LaunchEntry
    let pageIndex: Int
    let applications: [String: InstalledApplication]
    let iconProvider: (String) -> NSImage?
    let iconSize: CGFloat
    let tileWidth: CGFloat
    let showLabel: Bool
    let isSelected: Bool
    let isEditing: Bool
    let isWiggling: Bool
    let wiggleClock: LauncherWiggleClock
    let reportsDropGeometry: Bool
    let reportsRootGeometry: Bool
    let isBeingDragged: Bool
    let dropIntent: LauncherTileDropIntent?
    let combinePreviewSourceApplicationID: String?
    let canDelete: Bool
    let isDeleting: Bool
    let activate: () -> Void
    let requestDelete: () -> Void
    let hideApplication: (String) -> Void
    let canRebuildWeChatCompanion: (String) -> Bool
    let isRebuildingWeChatCompanion: Bool
    let requestWeChatCompanionRebuild: (String) -> Void
    let renameFolder: (LaunchFolder) -> Void
    let removeFolder: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var title: String {
        switch entry.kind {
        case let .application(applicationID):
            applications[applicationID]?.name ?? LaunchText.value("应用", "Application")
        case let .folder(folder):
            folder.name
        }
    }

    private var folder: LaunchFolder? {
        entry.folder
    }

    private var applicationID: String? {
        entry.applicationID
    }

    private var isCombineDropTargeted: Bool {
        dropIntent == .combine || dropIntent == .combinePending
    }

    private var isCombinePreviewReady: Bool {
        dropIntent == .combine && combinePreviewSourceApplicationID != nil
    }

    private var isReorderPreviewTarget: Bool {
        dropIntent == .reorderBefore || dropIntent == .reorderAfter
    }

    private var folderImages: [NSImage] {
        guard let folder else { return [] }
        return folder.applicationIDs.prefix(9).compactMap(iconProvider)
    }

    private var previewFolderImages: [NSImage] {
        guard let sourceID = combinePreviewSourceApplicationID else {
            return folderImages
        }

        var applicationIDs: [String]
        if let applicationID {
            applicationIDs = [applicationID]
        } else {
            applicationIDs = folder?.applicationIDs ?? []
        }
        if !applicationIDs.contains(sourceID) {
            applicationIDs.append(sourceID)
        }
        return applicationIDs.prefix(9).compactMap(iconProvider)
    }

    var body: some View {
        VStack(spacing: showLabel ? LauncherTileLayout.labelSpacing : 0) {
            ZStack {
                if isCombineDropTargeted {
                    RoundedRectangle(cornerRadius: iconSize * 0.25, style: .continuous)
                        .fill(.white.opacity(isCombinePreviewReady ? 0.16 : 0.085))
                        .overlay {
                            RoundedRectangle(cornerRadius: iconSize * 0.25, style: .continuous)
                                .stroke(
                                    .white.opacity(isCombinePreviewReady ? 0.34 : 0.2),
                                    style: StrokeStyle(
                                        lineWidth: isCombinePreviewReady ? 1.5 : 1,
                                        dash: isCombinePreviewReady ? [] : [4, 4]
                                    )
                                )
                        }
                        .frame(
                            width: iconSize + LauncherTileLayout.iconChrome,
                            height: iconSize + LauncherTileLayout.iconChrome
                        )
                }

                icon
                    .launcherWiggle(
                        isEditing: isWiggling,
                        clock: wiggleClock,
                        seed: entry.id.hashValue
                    )

                if isCombinePreviewReady {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: max(15, iconSize * 0.2), weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.42), in: Circle())
                        .offset(x: iconSize * 0.35, y: iconSize * 0.35)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }

                if isEditing, let applicationID {
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

                    LauncherHideBadge {
                        hideApplication(applicationID)
                    }
                    .frame(
                        width: iconSize + 12,
                        height: iconSize + 12,
                        alignment: .topTrailing
                    )
                }
            }
            .frame(
                width: iconSize + LauncherTileLayout.iconChrome,
                height: iconSize + LauncherTileLayout.iconChrome
            )
            .scaleEffect(
                isReorderPreviewTarget
                    ? 0.94
                    : (isHovering && !isEditing ? 1.05 : 1)
            )

            if showLabel {
                LauncherTileLabel(title: title)
                    .frame(height: LauncherTileLayout.labelHeight, alignment: .top)
            }
        }
        .frame(
            minWidth: interactiveWidth,
            maxWidth: interactiveWidth,
            minHeight: LauncherTileLayout.requiredHeight(
                iconSize: iconSize,
                showLabel: showLabel
            )
        )
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
            value: dropIntent
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
        .contextMenu { contextMenu }
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            folder.map {
                LaunchText.value("文件夹，包含 \($0.applicationIDs.count) 个应用", "Folder, \($0.applicationIDs.count) applications")
            } ?? LaunchText.value("应用", "Application")
        )
        .accessibilityHint(
            folder == nil
                ? LaunchText.value("按回车键打开", "Press Return to open")
                : LaunchText.value("按回车键打开文件夹", "Press Return to open folder")
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            guard !isEditing || folder != nil else { return }
            activate()
        }
        .background {
            if reportsDropGeometry {
                GeometryReader { proxy in
                    ZStack {
                        Color.clear
                            .preference(
                                key: LauncherTileFramePreferenceKey.self,
                                value: [
                                    LauncherPageTileFrameKey(
                                        pageIndex: pageIndex,
                                        entryID: entry.id
                                    ): proxy.frame(
                                        in: .named(LauncherCoordinateSpaces.mainGrid)
                                    )
                                ]
                            )

                        if reportsRootGeometry {
                            Color.clear
                                .preference(
                                    key: LauncherRootTileFramePreferenceKey.self,
                                    value: [
                                        LauncherPageTileFrameKey(
                                            pageIndex: pageIndex,
                                            entryID: entry.id
                                        ): proxy.frame(
                                            in: .named(LauncherCoordinateSpaces.launcherRoot)
                                        )
                                    ]
                                )
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        // The flexible grid cell remains full-width for layout, while every
        // pointer gesture and drop target above is confined to this tile's
        // visible icon-and-label surface.
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var icon: some View {
        switch entry.kind {
        case let .application(applicationID):
            if isCombinePreviewReady {
                LauncherFolderIcon(images: previewFolderImages, size: iconSize)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
            } else {
                let application = applications[applicationID]
                LauncherAppIcon(
                    image: iconProvider(applicationID),
                    fallbackName: application?.name ?? LaunchText.value("应用", "Application"),
                    size: iconSize
                )
            }

        case .folder:
            LauncherFolderIcon(
                images: isCombinePreviewReady ? previewFolderImages : folderImages,
                size: iconSize
            )
        }
    }

    private var interactiveWidth: CGFloat {
        let labelWidth: CGFloat = showLabel ? 132 : 0
        return min(
            tileWidth,
            max(iconSize + LauncherTileLayout.iconChrome, labelWidth)
        )
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let applicationID {
            if canRebuildWeChatCompanion(applicationID) {
                Button {
                    requestWeChatCompanionRebuild(applicationID)
                } label: {
                    Label(
                        LaunchText.value("双开", "Dual Launch"),
                        systemImage: "square.on.square"
                    )
                }
                .disabled(isRebuildingWeChatCompanion)

                Divider()
            }

            Button {
                hideApplication(applicationID)
            } label: {
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

        if let folder {
            Button(LaunchText.value("重命名文件夹…", "Rename Folder…")) {
                renameFolder(folder)
            }
            Button(LaunchText.value("移除文件夹", "Remove Folder"), role: .destructive) {
                removeFolder(folder.id)
            }
        }
    }
}

@MainActor
struct LauncherDragPreview: View {
    let entry: LaunchEntry
    let applications: [String: InstalledApplication]
    let iconProvider: (String) -> NSImage?

    var body: some View {
        Group {
            switch entry.kind {
            case let .application(applicationID):
                LauncherAppIcon(
                    image: iconProvider(applicationID),
                    fallbackName: applications[applicationID]?.name ?? LaunchText.value("应用", "Application"),
                    size: 58
                )
            case let .folder(folder):
                LauncherFolderIcon(
                    images: folder.applicationIDs.prefix(9).compactMap(iconProvider),
                    size: 58
                )
            }
        }
        .padding(8)
    }
}
