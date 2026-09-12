import CoreGraphics
import Foundation

/// A geometry-only description of the insertion slot nearest a pointer.
/// Keeping this independent from SwiftUI state makes gap handling deterministic
/// and straightforward to exercise with synthetic frames.
enum LauncherNearestInsertion<ID: Hashable>: Equatable {
    case before(ID)
    case after(ID)
    case end
}

enum LauncherProvisionalInsertion<ID: Hashable>: Equatable {
    case before(ID)
    case after(ID)
    case end(pageIndex: Int)
}

enum LauncherDragAutoScrollDirection: Equatable {
    case backward
    case forward
}

enum LauncherDragAutoScrollGeometry {
    static func direction(
        at location: CGPoint,
        in viewport: CGRect,
        activationFrame: CGRect? = nil,
        edgeBand: CGFloat
    ) -> LauncherDragAutoScrollDirection? {
        guard viewport.width > 0, viewport.height > 0 else {
            return nil
        }

        let fallbackActivationFrame = viewport.insetBy(dx: 0, dy: -10)
        let proposedActivationFrame = activationFrame ?? fallbackActivationFrame
        let effectiveActivationFrame = proposedActivationFrame.width > 0
            && proposedActivationFrame.height > 0
            ? proposedActivationFrame
            : fallbackActivationFrame
        guard effectiveActivationFrame.contains(location) else { return nil }

        let band = min(max(24, edgeBand), viewport.height / 2)
        if location.y <= viewport.minY + band { return .backward }
        if location.y >= viewport.maxY - band { return .forward }
        return nil
    }

    static func nextTarget<ID: Hashable>(
        direction: LauncherDragAutoScrollDirection,
        orderedIDs: [ID],
        frames: [ID: CGRect],
        viewport: CGRect
    ) -> ID? {
        let visibleIndices = orderedIDs.indices.filter { index in
            guard let frame = frames[orderedIDs[index]],
                  frame.width > 0,
                  frame.height > 0 else {
                return false
            }
            return frame.intersects(viewport)
        }
        guard let first = visibleIndices.first,
              let last = visibleIndices.last else {
            return nil
        }

        switch direction {
        case .backward:
            guard first > orderedIDs.startIndex else { return nil }
            return orderedIDs[orderedIDs.index(before: first)]
        case .forward:
            guard last < orderedIDs.index(before: orderedIDs.endIndex) else {
                return nil
            }
            return orderedIDs[orderedIDs.index(after: last)]
        }
    }

    /// Provides a deterministic continuation when SwiftUI has not yet
    /// republished content frames after `ScrollViewProxy.scrollTo`. The cursor
    /// advances by one inferred visual row from the last issued target (or the
    /// dragged item for the first retry), so a dropped first request cannot
    /// permanently stall edge scrolling.
    static func steppedTarget<ID: Hashable>(
        direction: LauncherDragAutoScrollDirection,
        orderedIDs: [ID],
        after anchorID: ID?,
        frames: [ID: CGRect]
    ) -> ID? {
        guard !orderedIDs.isEmpty else { return nil }
        let anchorIndex: Int
        if let anchorID, let index = orderedIDs.firstIndex(of: anchorID) {
            anchorIndex = index
        } else {
            anchorIndex = direction == .backward
                ? orderedIDs.count - 1
                : 0
        }

        let stride = estimatedColumnCount(frames: frames)
        let destination = direction == .backward
            ? anchorIndex - stride
            : anchorIndex + stride
        guard orderedIDs.indices.contains(destination),
              destination != anchorIndex else {
            return nil
        }
        return orderedIDs[destination]
    }

    private static func estimatedColumnCount<ID: Hashable>(
        frames: [ID: CGRect]
    ) -> Int {
        let centers = frames.values
            .filter { $0.width > 0 && $0.height > 0 }
            .map(\.midX)
            .sorted()
        guard let first = centers.first else { return 1 }

        var distinctCenters: [CGFloat] = [first]
        for center in centers.dropFirst() where
            abs(center - distinctCenters[distinctCenters.count - 1]) > 6 {
            distinctCenters.append(center)
        }
        return min(8, max(1, distinctCenters.count))
    }
}

enum LauncherDragPreviewLayout {
    /// Mirrors the model's carry-forward capacity behavior while intentionally
    /// preserving empty page indices for the lifetime of a drag preview.
    static func pages(
        from originalPages: [[LaunchEntry]],
        moving sourceID: UUID,
        insertion: LauncherProvisionalInsertion<UUID>,
        pageCapacity requestedCapacity: Int
    ) -> [[LaunchEntry]] {
        var pages = originalPages.isEmpty ? [[]] : originalPages
        guard let sourcePage = pages.firstIndex(where: { page in
            page.contains(where: { $0.id == sourceID })
        }), let sourceIndex = pages[sourcePage].firstIndex(where: { $0.id == sourceID }) else {
            return pages
        }

        let source = pages[sourcePage].remove(at: sourceIndex)
        switch insertion {
        case let .before(targetID):
            guard let targetPage = pages.firstIndex(where: { page in
                page.contains(where: { $0.id == targetID })
            }), let targetIndex = pages[targetPage].firstIndex(where: { $0.id == targetID }) else {
                return originalPages
            }
            pages[targetPage].insert(source, at: targetIndex)

        case let .after(targetID):
            guard let targetPage = pages.firstIndex(where: { page in
                page.contains(where: { $0.id == targetID })
            }), let targetIndex = pages[targetPage].firstIndex(where: { $0.id == targetID }) else {
                return originalPages
            }
            pages[targetPage].insert(source, at: targetIndex + 1)

        case let .end(pageIndex):
            guard pages.indices.contains(pageIndex) else { return originalPages }
            pages[pageIndex].append(source)
        }

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
        return pages
    }

    static func order<ID: Hashable>(
        from original: [ID],
        moving sourceID: ID,
        insertion: LauncherProvisionalInsertion<ID>
    ) -> [ID] {
        guard let sourceIndex = original.firstIndex(of: sourceID) else { return original }
        var result = original
        let source = result.remove(at: sourceIndex)

        switch insertion {
        case let .before(targetID):
            guard let targetIndex = result.firstIndex(of: targetID) else { return original }
            result.insert(source, at: targetIndex)
        case let .after(targetID):
            guard let targetIndex = result.firstIndex(of: targetID) else { return original }
            result.insert(source, at: targetIndex + 1)
        case .end:
            result.append(source)
        }
        return result
    }

    /// Builds a transient order for an item that is not yet a member of the
    /// destination collection. This is used while a top-level application is
    /// hovering over an expanded folder; the model remains untouched until the
    /// pointer ends.
    static func order<ID: Hashable>(
        from original: [ID],
        inserting sourceID: ID,
        insertion: LauncherProvisionalInsertion<ID>
    ) -> [ID] {
        var result = original.filter { $0 != sourceID }

        switch insertion {
        case let .before(targetID):
            guard let targetIndex = result.firstIndex(of: targetID) else { return original }
            result.insert(sourceID, at: targetIndex)
        case let .after(targetID):
            guard let targetIndex = result.firstIndex(of: targetID) else { return original }
            result.insert(sourceID, at: targetIndex + 1)
        case .end:
            result.append(sourceID)
        }
        return result
    }

    /// Adds a not-yet-top-level entry for a folder-member drag. This is purely
    /// visual; the model receives one atomic move only when the pointer ends.
    static func pages(
        from originalPages: [[LaunchEntry]],
        inserting entry: LaunchEntry,
        insertion: LauncherProvisionalInsertion<UUID>,
        pageCapacity requestedCapacity: Int
    ) -> [[LaunchEntry]] {
        var pages = originalPages.isEmpty ? [[]] : originalPages
        switch insertion {
        case let .before(targetID):
            guard let targetPage = pages.firstIndex(where: { page in
                page.contains(where: { $0.id == targetID })
            }), let targetIndex = pages[targetPage].firstIndex(where: { $0.id == targetID }) else {
                return originalPages
            }
            pages[targetPage].insert(entry, at: targetIndex)

        case let .after(targetID):
            guard let targetPage = pages.firstIndex(where: { page in
                page.contains(where: { $0.id == targetID })
            }), let targetIndex = pages[targetPage].firstIndex(where: { $0.id == targetID }) else {
                return originalPages
            }
            pages[targetPage].insert(entry, at: targetIndex + 1)

        case let .end(pageIndex):
            guard pages.indices.contains(pageIndex) else { return originalPages }
            pages[pageIndex].append(entry)
        }

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
        return pages
    }
}

enum LauncherDropGeometry {
    private struct FramedItem<ID: Hashable> {
        let id: ID
        let order: Int
        let frame: CGRect
    }

    private struct Row<ID: Hashable> {
        var items: [FramedItem<ID>]

        var minY: CGFloat { items.map(\.frame.minY).min() ?? 0 }
        var maxY: CGFloat { items.map(\.frame.maxY).max() ?? 0 }
        var midY: CGFloat { (minY + maxY) / 2 }
        var height: CGFloat { max(1, maxY - minY) }
    }

    /// Resolves empty space to its nearest visual insertion slot. Horizontal
    /// gaps split between the two neighbours, vertical gaps choose the nearest
    /// row, and only blank space after the final row's final tile is `.end`.
    static func nearestInsertion<ID: Hashable>(
        at location: CGPoint,
        orderedIDs: [ID],
        frames: [ID: CGRect],
        excluding sourceID: ID?
    ) -> LauncherNearestInsertion<ID>? {
        let items = orderedIDs.enumerated().compactMap { index, id -> FramedItem<ID>? in
            guard id != sourceID,
                  let frame = frames[id],
                  frame.width > 0,
                  frame.height > 0 else {
                return nil
            }
            return FramedItem(id: id, order: index, frame: frame)
        }

        guard !items.isEmpty else { return .end }
        let rows = rows(from: items)
        guard let lastVisualRow = rows.last else { return nil }
        let trailingRowTolerance = min(10, lastVisualRow.height * 0.08)
        if location.y > lastVisualRow.maxY + trailingRowTolerance {
            return .end
        }
        guard let rowIndex = nearestRowIndex(to: location.y, rows: rows) else {
            return nil
        }

        let row = rows[rowIndex]
        let rowItems = row.items.sorted {
            if abs($0.frame.minX - $1.frame.minX) > 0.5 {
                return $0.frame.minX < $1.frame.minX
            }
            return $0.order < $1.order
        }
        guard let first = rowItems.first, let last = rowItems.last else { return nil }

        if location.x < first.frame.minX {
            return .before(first.id)
        }
        if location.x > last.frame.maxX {
            return rowIndex == rows.indices.last ? .end : .after(last.id)
        }

        // Inside a column's x-range while vertically between rows maps to that
        // column's nearer edge. Inside a horizontal gap maps to the neighbour
        // whose visible edge is closer, never to the end of the collection.
        let nearest = rowItems.min { lhs, rhs in
            let lhsDistance = horizontalDistance(from: location.x, to: lhs.frame)
            let rhsDistance = horizontalDistance(from: location.x, to: rhs.frame)
            if abs(lhsDistance - rhsDistance) > 0.5 {
                return lhsDistance < rhsDistance
            }
            return lhs.order < rhs.order
        }
        guard let nearest else { return nil }
        return location.x < nearest.frame.midX
            ? .before(nearest.id)
            : .after(nearest.id)
    }

    private static func rows<ID: Hashable>(
        from items: [FramedItem<ID>]
    ) -> [Row<ID>] {
        let verticallySorted = items.sorted {
            if abs($0.frame.midY - $1.frame.midY) > 0.5 {
                return $0.frame.midY < $1.frame.midY
            }
            if abs($0.frame.minX - $1.frame.minX) > 0.5 {
                return $0.frame.minX < $1.frame.minX
            }
            return $0.order < $1.order
        }

        var result: [Row<ID>] = []
        for item in verticallySorted {
            if let lastIndex = result.indices.last {
                let row = result[lastIndex]
                let tolerance = max(8, min(row.height, item.frame.height) * 0.45)
                if abs(item.frame.midY - row.midY) <= tolerance {
                    result[lastIndex].items.append(item)
                    continue
                }
            }
            result.append(Row(items: [item]))
        }
        return result
    }

    private static func nearestRowIndex<ID: Hashable>(
        to y: CGFloat,
        rows: [Row<ID>]
    ) -> Int? {
        rows.indices.min { lhs, rhs in
            let lhsDistance = verticalDistance(from: y, to: rows[lhs])
            let rhsDistance = verticalDistance(from: y, to: rows[rhs])
            if abs(lhsDistance - rhsDistance) > 0.5 {
                return lhsDistance < rhsDistance
            }
            return lhs < rhs
        }
    }

    private static func horizontalDistance(from x: CGFloat, to frame: CGRect) -> CGFloat {
        if x < frame.minX { return frame.minX - x }
        if x > frame.maxX { return x - frame.maxX }
        return 0
    }

    private static func verticalDistance<ID: Hashable>(
        from y: CGFloat,
        to row: Row<ID>
    ) -> CGFloat {
        if y < row.minY { return row.minY - y }
        if y > row.maxY { return y - row.maxY }
        return 0
    }
}

#if DEBUG
enum LauncherDropGeometryDebugChecks {
    private static let runOnce: Void = {
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 80, height: 100),
            "b": CGRect(x: 120, y: 0, width: 80, height: 100),
            "c": CGRect(x: 0, y: 140, width: 80, height: 100)
        ]
        let ids = ["a", "b", "c"]

        assert(
            LauncherDropGeometry.nearestInsertion(
                at: CGPoint(x: 92, y: 50),
                orderedIDs: ids,
                frames: frames,
                excluding: nil
            ) == .after("a")
        )
        assert(
            LauncherDropGeometry.nearestInsertion(
                at: CGPoint(x: 112, y: 50),
                orderedIDs: ids,
                frames: frames,
                excluding: nil
            ) == .before("b")
        )
        assert(
            LauncherDropGeometry.nearestInsertion(
                at: CGPoint(x: 240, y: 50),
                orderedIDs: ids,
                frames: frames,
                excluding: nil
            ) == .after("b")
        )
        assert(
            LauncherDropGeometry.nearestInsertion(
                at: CGPoint(x: 120, y: 190),
                orderedIDs: ids,
                frames: frames,
                excluding: nil
            ) == .end
        )
        assert(
            LauncherDropGeometry.nearestInsertion(
                at: CGPoint(x: 20, y: 300),
                orderedIDs: ids,
                frames: frames,
                excluding: nil
            ) == .end
        )

        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let previewPages = LauncherDragPreviewLayout.pages(
            from: [
                [.application("a", id: firstID), .application("b", id: secondID)],
                [.application("c", id: thirdID)]
            ],
            moving: firstID,
            insertion: .before(thirdID),
            pageCapacity: 2
        )
        assert(previewPages[0].map(\.id) == [secondID])
        assert(previewPages[1].map(\.id) == [firstID, thirdID])
        assert(
            LauncherDragPreviewLayout.order(
                from: ["a", "b", "c"],
                moving: "a",
                insertion: .after("b")
            ) == ["b", "a", "c"]
        )
        assert(
            LauncherDragPreviewLayout.order(
                from: ["a", "b", "c"],
                inserting: "d",
                insertion: .before("b")
            ) == ["a", "d", "b", "c"]
        )
        assert(
            LauncherDragPreviewLayout.order(
                from: ["a", "b", "c"],
                inserting: "d",
                insertion: .end(pageIndex: 0)
            ) == ["a", "b", "c", "d"]
        )

        let viewport = CGRect(x: 0, y: 0, width: 220, height: 180)
        let enclosingPanel = CGRect(x: -20, y: -70, width: 260, height: 320)
        assert(
            LauncherDragAutoScrollGeometry.direction(
                at: CGPoint(x: 110, y: 8),
                in: viewport,
                edgeBand: 44
            ) == .backward
        )
        assert(
            LauncherDragAutoScrollGeometry.direction(
                at: CGPoint(x: 110, y: 172),
                in: viewport,
                edgeBand: 44
            ) == .forward
        )
        assert(
            LauncherDragAutoScrollGeometry.direction(
                at: CGPoint(x: 110, y: 90),
                in: viewport,
                edgeBand: 44
            ) == nil
        )
        // The visible panel includes its title and bottom padding outside the
        // ScrollView viewport. Those real visual edges must still activate the
        // corresponding direction.
        assert(
            LauncherDragAutoScrollGeometry.direction(
                at: CGPoint(x: 110, y: -34),
                in: viewport,
                activationFrame: enclosingPanel,
                edgeBand: 44
            ) == .backward
        )
        assert(
            LauncherDragAutoScrollGeometry.direction(
                at: CGPoint(x: 110, y: 224),
                in: viewport,
                activationFrame: enclosingPanel,
                edgeBand: 44
            ) == .forward
        )
        assert(
            LauncherDragAutoScrollGeometry.direction(
                at: CGPoint(x: 110, y: 270),
                in: viewport,
                activationFrame: enclosingPanel,
                edgeBand: 44
            ) == nil
        )
        assert(
            LauncherDragAutoScrollGeometry.nextTarget(
                direction: .forward,
                orderedIDs: ["a", "b", "c", "d"],
                frames: [
                    "a": CGRect(x: 0, y: -100, width: 80, height: 80),
                    "b": CGRect(x: 0, y: 10, width: 80, height: 80),
                    "c": CGRect(x: 100, y: 10, width: 80, height: 80),
                    "d": CGRect(x: 0, y: 210, width: 80, height: 80),
                ],
                viewport: viewport
            ) == "d"
        )
        // After one scroll step publishes a new visible range, the next pure
        // step advances again rather than remaining locked to the first ID.
        assert(
            LauncherDragAutoScrollGeometry.nextTarget(
                direction: .forward,
                orderedIDs: ["a", "b", "c", "d", "e"],
                frames: [
                    "a": CGRect(x: 0, y: -220, width: 80, height: 80),
                    "b": CGRect(x: 0, y: -100, width: 80, height: 80),
                    "c": CGRect(x: 0, y: 10, width: 80, height: 80),
                    "d": CGRect(x: 100, y: 10, width: 80, height: 80),
                    "e": CGRect(x: 0, y: 210, width: 80, height: 80),
                ],
                viewport: viewport
            ) == "e"
        )
        assert(
            LauncherDragAutoScrollGeometry.nextTarget(
                direction: .backward,
                orderedIDs: ["a", "b", "c", "d"],
                frames: [
                    "a": CGRect(x: 0, y: -100, width: 80, height: 80),
                    "b": CGRect(x: 0, y: 10, width: 80, height: 80),
                    "c": CGRect(x: 100, y: 10, width: 80, height: 80),
                    "d": CGRect(x: 0, y: 210, width: 80, height: 80),
                ],
                viewport: viewport
            ) == "a"
        )

        let threeColumnFrames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 80, height: 80),
            "b": CGRect(x: 100, y: 0, width: 80, height: 80),
            "c": CGRect(x: 200, y: 0, width: 80, height: 80),
            "d": CGRect(x: 0, y: 100, width: 80, height: 80),
            "e": CGRect(x: 100, y: 100, width: 80, height: 80),
            "f": CGRect(x: 200, y: 100, width: 80, height: 80),
        ]
        assert(
            LauncherDragAutoScrollGeometry.steppedTarget(
                direction: .backward,
                orderedIDs: ["a", "b", "c", "d", "e", "f", "g", "h"],
                after: "h",
                frames: threeColumnFrames
            ) == "e"
        )
        assert(
            LauncherDragAutoScrollGeometry.steppedTarget(
                direction: .backward,
                orderedIDs: ["a", "b", "c", "d", "e", "f", "g", "h"],
                after: "e",
                frames: threeColumnFrames
            ) == "b"
        )
        assert(
            LauncherDragAutoScrollGeometry.steppedTarget(
                direction: .forward,
                orderedIDs: ["a", "b", "c", "d", "e", "f", "g", "h"],
                after: "a",
                frames: threeColumnFrames
            ) == "d"
        )
    }()

    static func run() {
        _ = runOnce
    }
}
#endif
