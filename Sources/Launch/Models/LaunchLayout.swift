import Foundation

/// The ordered pages displayed by Launch.
public struct LaunchLayout: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var pages: [[LaunchEntry]]

    public init(
        version: Int = LaunchLayout.currentVersion,
        pages: [[LaunchEntry]] = [[]]
    ) {
        self.version = version
        self.pages = pages.isEmpty ? [[]] : pages
    }

    public static let empty = LaunchLayout()

    /// Returns a layout containing every currently installed application exactly
    /// once while retaining the user's existing page, item, and folder ordering.
    ///
    /// Removed applications are discarded. Newly installed applications are
    /// appended to the final page, creating pages as required.
    public func reconciled(
        with applications: [InstalledApplication],
        pageCapacity: Int
    ) -> LaunchLayout {
        let capacity = max(1, pageCapacity)
        let installedIDs = Set(applications.map(\.id))
        var placedIDs = Set<String>()
        var reconciledPages: [[LaunchEntry]] = []
        var removedTopLevelEntry = false

        for page in pages {
            var reconciledPage: [LaunchEntry] = []

            for entry in page {
                switch entry.kind {
                case let .application(applicationID):
                    guard installedIDs.contains(applicationID),
                          placedIDs.insert(applicationID).inserted else {
                        removedTopLevelEntry = true
                        continue
                    }
                    reconciledPage.append(entry)

                case let .folder(folder):
                    var seenInFolder = Set<String>()
                    let remainingIDs = folder.applicationIDs.filter { applicationID in
                        installedIDs.contains(applicationID)
                            && !placedIDs.contains(applicationID)
                            && seenInFolder.insert(applicationID).inserted
                    }

                    guard !remainingIDs.isEmpty else {
                        removedTopLevelEntry = true
                        continue
                    }

                    placedIDs.formUnion(remainingIDs)
                    if remainingIDs.count == 1 {
                        // A one-item folder is no longer a meaningful
                        // container. Reuse the persisted entry identity so
                        // reconciliation does not make the surviving tile look
                        // like a newly installed application to SwiftUI.
                        reconciledPage.append(
                            LaunchEntry(
                                id: entry.id,
                                kind: .application(remainingIDs[0])
                            )
                        )
                    } else {
                        var reconciledFolder = folder
                        reconciledFolder.applicationIDs = remainingIDs
                        reconciledPage.append(
                            LaunchEntry(id: entry.id, kind: .folder(reconciledFolder))
                        )
                    }
                }
            }

            if !reconciledPage.isEmpty {
                reconciledPages.append(reconciledPage)
            }
        }

        if reconciledPages.isEmpty {
            reconciledPages = [[]]
        }

        var queuedIDs = placedIDs
        let newApplicationIDs = applications.compactMap { application -> String? in
            queuedIDs.insert(application.id).inserted ? application.id : nil
        }

        for applicationID in newApplicationIDs {
            if reconciledPages[reconciledPages.count - 1].count >= capacity {
                reconciledPages.append([])
            }
            reconciledPages[reconciledPages.count - 1].append(.application(applicationID))
            placedIDs.insert(applicationID)
        }

        var result = LaunchLayout(version: Self.currentVersion, pages: reconciledPages)
        if removedTopLevelEntry {
            result.compactPages(pageCapacity: capacity)
        }
        return result
    }

    public func reconciled(
        with applications: [InstalledApplication],
        preferences: LaunchPreferences
    ) -> LaunchLayout {
        reconciled(
            with: applications.filter { !preferences.hiddenApplicationIDs.contains($0.id) },
            pageCapacity: preferences.pageCapacity
        )
    }

    public var applicationIDs: [String] {
        pages.flatMap { page in
            page.flatMap { entry -> [String] in
                switch entry.kind {
                case let .application(applicationID):
                    return [applicationID]
                case let .folder(folder):
                    return folder.applicationIDs
                }
            }
        }
    }
}

/// A stable coordinate in the persisted page layout. This is intentionally a
/// model type so drag-and-drop mutations can be exercised without constructing
/// AppKit or SwiftUI state.
struct LaunchEntryLocation: Equatable, Sendable {
    var page: Int
    var index: Int
}

extension LaunchLayout {
    /// Packs top-level entries forward in their existing global order. A folder
    /// moves as one entry; its identity, name and member ordering are untouched.
    mutating func compactPages(pageCapacity requestedCapacity: Int) {
        let capacity = max(1, requestedCapacity)
        let entries = pages.flatMap { $0 }
        var compactedPages: [[LaunchEntry]] = []
        let requiredPageCount = entries.isEmpty ? 1 : ((entries.count - 1) / capacity) + 1
        compactedPages.reserveCapacity(requiredPageCount)

        for entry in entries {
            if compactedPages.isEmpty || compactedPages[compactedPages.count - 1].count >= capacity {
                compactedPages.append([])
            }
            compactedPages[compactedPages.count - 1].append(entry)
        }
        pages = compactedPages.isEmpty ? [[]] : compactedPages
    }

    /// Finds a top-level entry by any identity the UI is allowed to put on the
    /// drag pasteboard: entry UUID, application ID, or folder UUID.
    func entryLocation(matching identity: String) -> LaunchEntryLocation? {
        let uuid = UUID(uuidString: identity)
        for pageIndex in pages.indices {
            if let entryIndex = pages[pageIndex].firstIndex(where: { entry in
                if entry.applicationID == identity { return true }
                guard let uuid else { return false }
                return entry.id == uuid || entry.folder?.id == uuid
            }) {
                return LaunchEntryLocation(page: pageIndex, index: entryIndex)
            }
        }
        return nil
    }

    func folderLocation(_ folderID: UUID) -> LaunchEntryLocation? {
        for pageIndex in pages.indices {
            if let entryIndex = pages[pageIndex].firstIndex(where: {
                $0.folder?.id == folderID
            }) {
                return LaunchEntryLocation(page: pageIndex, index: entryIndex)
            }
        }
        return nil
    }

    func topLevelApplicationLocation(_ applicationID: String) -> LaunchEntryLocation? {
        for pageIndex in pages.indices {
            if let entryIndex = pages[pageIndex].firstIndex(where: {
                $0.applicationID == applicationID
            }) {
                return LaunchEntryLocation(page: pageIndex, index: entryIndex)
            }
        }
        return nil
    }

    /// Moves one top-level entry before another, or to the end of a specific
    /// page when `targetIdentity` is nil. A non-nil but missing target is a stale
    /// drop and leaves the layout untouched.
    @discardableResult
    mutating func reorderEntry(
        matching draggedIdentity: String,
        before targetIdentity: String?,
        destinationPage: Int,
        pageCapacity: Int
    ) -> LaunchEntryLocation? {
        guard let source = entryLocation(matching: draggedIdentity) else {
            return nil
        }

        let original = self
        let entry = pages[source.page][source.index]

        if let targetIdentity {
            guard let target = entryLocation(matching: targetIdentity),
                  pages[target.page][target.index].id != entry.id else {
                return nil
            }

            pages[source.page].remove(at: source.index)
            let adjustedTargetIndex = source.page == target.page && source.index < target.index
                ? target.index - 1
                : target.index
            pages[target.page].insert(entry, at: adjustedTargetIndex)
        } else {
            guard !pages.isEmpty else { return nil }
            let page = min(max(0, destinationPage), pages.count - 1)
            pages[source.page].remove(at: source.index)
            pages[page].append(entry)
        }

        removeEmptyPages()
        enforcePageCapacity(pageCapacity)
        guard self != original else { return nil }
        return entryLocation(matching: entry.id.uuidString)
    }

    /// Replaces two top-level applications with one folder at the target's
    /// location. Both locations are validated before either entry is removed.
    @discardableResult
    mutating func createFolder(
        from sourceApplicationID: String,
        onto targetApplicationID: String,
        name: String,
        pageCapacity: Int
    ) -> LaunchFolder? {
        guard sourceApplicationID != targetApplicationID,
              let source = topLevelApplicationLocation(sourceApplicationID),
              let target = topLevelApplicationLocation(targetApplicationID) else {
            return nil
        }

        pages[source.page].remove(at: source.index)
        let adjustedTargetIndex = source.page == target.page && source.index < target.index
            ? target.index - 1
            : target.index
        pages[target.page].remove(at: adjustedTargetIndex)

        let folder = LaunchFolder(
            name: name,
            applicationIDs: [targetApplicationID, sourceApplicationID]
        )
        pages[target.page].insert(.folder(folder), at: adjustedTargetIndex)
        // Two top-level entries became one. Pack the remaining global sequence
        // forward so later pages immediately fill the vacated grid cell.
        compactPages(pageCapacity: pageCapacity)
        return folder
    }

    /// Moves an application from any top-level entry or other folder into the
    /// destination folder. Existing duplicates outside that folder are removed;
    /// duplicates inside it are collapsed while retaining member order.
    @discardableResult
    mutating func addApplication(
        _ applicationID: String,
        toFolder folderID: UUID,
        pageCapacity: Int
    ) -> LaunchEntryLocation? {
        guard folderLocation(folderID) != nil else { return nil }
        let original = self
        let originalTopLevelCount = pages.reduce(0) { $0 + $1.count }

        removeApplication(applicationID, excludingFolderID: folderID)
        guard let location = folderLocation(folderID),
              case var .folder(folder) = pages[location.page][location.index].kind else {
            self = original
            return nil
        }

        var seen = Set<String>()
        folder.applicationIDs = folder.applicationIDs.filter {
            seen.insert($0).inserted
        }
        if !seen.contains(applicationID) {
            folder.applicationIDs.append(applicationID)
        }
        pages[location.page][location.index].kind = .folder(folder)
        removeEmptyPages()

        guard self != original else { return nil }
        let newTopLevelCount = pages.reduce(0) { $0 + $1.count }
        if newTopLevelCount < originalTopLevelCount {
            // Moving a top-level app (or the sole member of another folder)
            // into this folder frees a cell; preserve global order while
            // pulling entries from subsequent pages forward.
            compactPages(pageCapacity: pageCapacity)
        }
        return folderLocation(folderID)
    }

    /// Atomically moves one top-level application into an exact position in an
    /// existing folder. `targetApplicationID == nil` appends; a non-nil target
    /// must still be a member of that folder. Folder members, malformed
    /// duplicates, stale targets, and self-targets are strict no-ops.
    @discardableResult
    mutating func addTopLevelApplication(
        _ applicationID: String,
        toFolder folderID: UUID,
        before targetApplicationID: String?,
        pageCapacity: Int
    ) -> LaunchEntryLocation? {
        guard let source = topLevelApplicationLocation(applicationID),
              applicationIDs.filter({ $0 == applicationID }).count == 1,
              let destination = folderLocation(folderID),
              case let .folder(destinationFolder) =
                pages[destination.page][destination.index].kind,
              Set(destinationFolder.applicationIDs).count
                == destinationFolder.applicationIDs.count,
              !destinationFolder.applicationIDs.contains(applicationID) else {
            return nil
        }

        let insertionIndex: Int
        if let targetApplicationID {
            guard targetApplicationID != applicationID,
                  let targetIndex = destinationFolder.applicationIDs.firstIndex(
                    of: targetApplicationID
                  ) else {
                return nil
            }
            insertionIndex = targetIndex
        } else {
            insertionIndex = destinationFolder.applicationIDs.endIndex
        }

        let original = self
        pages[source.page].remove(at: source.index)

        // Removing the top-level source may shift the folder's page or index;
        // resolve it again before committing the member insertion.
        guard let updatedDestination = folderLocation(folderID),
              case var .folder(updatedFolder) =
                pages[updatedDestination.page][updatedDestination.index].kind,
              updatedFolder.applicationIDs.indices.contains(insertionIndex)
                || insertionIndex == updatedFolder.applicationIDs.endIndex else {
            self = original
            return nil
        }
        updatedFolder.applicationIDs.insert(applicationID, at: insertionIndex)
        pages[updatedDestination.page][updatedDestination.index].kind =
            .folder(updatedFolder)

        // One top-level entry was removed. Fill the vacated cell from later
        // pages without changing folder identity or member ordering.
        compactPages(pageCapacity: pageCapacity)
        guard self != original else { return nil }
        return folderLocation(folderID)
    }

    /// Atomically moves one member out of a folder and into a top-level page.
    /// A non-nil target must still exist on `destinationPage`; stale drops leave
    /// the complete layout untouched. If the source folder is left with one
    /// member it dissolves in place while retaining its entry UUID.
    @discardableResult
    mutating func moveApplicationOutOfFolder(
        _ applicationID: String,
        fromFolder sourceFolderID: UUID,
        destinationPage: Int,
        before targetIdentity: String?,
        pageCapacity: Int
    ) -> LaunchEntryLocation? {
        guard pages.indices.contains(destinationPage),
              let source = folderLocation(sourceFolderID),
              case let .folder(sourceFolder) = pages[source.page][source.index].kind,
              sourceFolder.applicationIDs.contains(applicationID) else {
            return nil
        }

        let original = self
        let targetEntryID: UUID?
        if let targetIdentity {
            guard let target = entryLocation(matching: targetIdentity),
                  target.page == destinationPage else {
                return nil
            }
            targetEntryID = pages[target.page][target.index].id
        } else {
            targetEntryID = nil
        }

        // Remove every malformed duplicate at the same time as the real source
        // member. The source container is canonicalized by the helper below.
        removeApplication(applicationID, excludingFolderID: nil)

        let newEntry = LaunchEntry.application(applicationID)
        if let targetEntryID {
            guard let target = entryLocation(matching: targetEntryID.uuidString) else {
                self = original
                return nil
            }
            pages[target.page].insert(newEntry, at: target.index)
        } else {
            // Empty pages are intentionally retained until after insertion so
            // the caller's page index remains valid throughout the transaction.
            guard pages.indices.contains(destinationPage) else {
                self = original
                return nil
            }
            pages[destinationPage].append(newEntry)
        }

        removeEmptyPages()
        enforcePageCapacity(pageCapacity)
        guard self != original else { return nil }
        return entryLocation(matching: newEntry.id.uuidString)
    }

    /// Atomically moves a member between two existing folders. The destination
    /// keeps its identity and member order; the source is dissolved in place if
    /// only one member remains. A same-folder or stale drop is a strict no-op.
    @discardableResult
    mutating func moveApplication(
        _ applicationID: String,
        fromFolder sourceFolderID: UUID,
        toFolder destinationFolderID: UUID,
        pageCapacity: Int
    ) -> LaunchEntryLocation? {
        guard sourceFolderID != destinationFolderID,
              let source = folderLocation(sourceFolderID),
              case let .folder(sourceFolder) = pages[source.page][source.index].kind,
              sourceFolder.applicationIDs.contains(applicationID),
              folderLocation(destinationFolderID) != nil else {
            return nil
        }

        let original = self
        let originalTopLevelCount = pages.reduce(0) { $0 + $1.count }
        removeApplication(
            applicationID,
            excludingFolderID: destinationFolderID
        )

        guard let destination = folderLocation(destinationFolderID),
              case var .folder(destinationFolder) = pages[destination.page][destination.index].kind else {
            self = original
            return nil
        }

        var seen = Set<String>()
        destinationFolder.applicationIDs = destinationFolder.applicationIDs.filter {
            seen.insert($0).inserted
        }
        if !seen.contains(applicationID) {
            destinationFolder.applicationIDs.append(applicationID)
        }
        pages[destination.page][destination.index].kind = .folder(destinationFolder)
        removeEmptyPages()

        if pages.reduce(0, { $0 + $1.count }) < originalTopLevelCount {
            compactPages(pageCapacity: pageCapacity)
        }
        guard self != original else { return nil }
        return folderLocation(destinationFolderID)
    }

    /// Reorders applications inside a folder. `nil` means append; a non-nil
    /// missing target is rejected rather than silently moving the app to the end.
    @discardableResult
    mutating func reorderApplication(
        inFolder folderID: UUID,
        draggedID: String,
        before targetID: String?
    ) -> Bool {
        guard let location = folderLocation(folderID),
              case var .folder(folder) = pages[location.page][location.index].kind,
              let sourceIndex = folder.applicationIDs.firstIndex(of: draggedID) else {
            return false
        }
        if let targetID {
            guard targetID != draggedID,
                  folder.applicationIDs.contains(targetID) else {
                return false
            }
        }

        let originalIDs = folder.applicationIDs
        let applicationID = folder.applicationIDs.remove(at: sourceIndex)
        let destination = targetID
            .flatMap { folder.applicationIDs.firstIndex(of: $0) }
            ?? folder.applicationIDs.endIndex
        folder.applicationIDs.insert(applicationID, at: destination)
        guard folder.applicationIDs != originalIDs else { return false }

        pages[location.page][location.index].kind = .folder(folder)
        return true
    }

    private mutating func removeApplication(
        _ applicationID: String,
        excludingFolderID: UUID?
    ) {
        for pageIndex in pages.indices {
            pages[pageIndex] = pages[pageIndex].compactMap { entry in
                switch entry.kind {
                case let .application(existingID):
                    return existingID == applicationID ? nil : entry

                case var .folder(folder):
                    if folder.id == excludingFolderID {
                        return entry
                    }
                    let originalMemberCount = folder.applicationIDs.count
                    folder.applicationIDs.removeAll { $0 == applicationID }
                    guard folder.applicationIDs.count != originalMemberCount else {
                        return entry
                    }
                    switch folder.applicationIDs.count {
                    case 0:
                        return nil
                    case 1:
                        return LaunchEntry(
                            id: entry.id,
                            kind: .application(folder.applicationIDs[0])
                        )
                    default:
                        return LaunchEntry(id: entry.id, kind: .folder(folder))
                    }
                }
            }
        }
    }

    private mutating func removeEmptyPages() {
        pages.removeAll(where: \.isEmpty)
        if pages.isEmpty {
            pages = [[]]
        }
    }

    /// Carries only overflow forward. Deliberately under-filled earlier pages
    /// remain grouped as the user arranged them.
    private mutating func enforcePageCapacity(_ requestedCapacity: Int) {
        let capacity = max(1, requestedCapacity)
        var pageIndex = 0
        while pageIndex < pages.count {
            if pages[pageIndex].count > capacity {
                let overflow = Array(pages[pageIndex].dropFirst(capacity))
                pages[pageIndex].removeSubrange(capacity...)
                if pageIndex + 1 == pages.count {
                    pages.append(overflow)
                } else {
                    pages[pageIndex + 1].insert(contentsOf: overflow, at: 0)
                }
            }
            pageIndex += 1
        }
        removeEmptyPages()
    }
}
